"""LLM cleanup pass over raw transcripts (mlx-lm).

Pure prompt/guard logic lives at module level so it is unit-testable on any
platform; ``CleanupEngine`` owns the mlx-lm model with deferred imports, the
same split as ``stt.Transcriber``. Every failure path — timeout, exception,
suspicious output — falls back to the raw transcript: cleanup may only ever
improve the text, never lose it.
"""

from __future__ import annotations

import copy
import logging
import re
import resource
import time

log = logging.getLogger(__name__)

STYLES = ("light", "polish")

_SYSTEM = (
    "You clean up raw speech-to-text transcripts.\n"
    "Overriding principle: when in doubt, leave the text as spoken. Under-\n"
    "cleaning is always better than changing what the speaker meant.\n"
    "Rules:\n"
    "- Remove filler words (such as um, uh, like, you know) only when they\n"
    '  are disfluencies, not when they carry meaning (keep "like" in\n'
    '  "it works like a charm").\n'
    "- Fix punctuation, capitalization, and casing.\n"
    "- Do not summarize, shorten, or expand — preserve all of the speaker's\n"
    "  content, sentences, and order exactly as spoken.\n"
    "- Do not reorder, restructure, or reformat the speaker's content. The\n"
    "  only formatting you may add is a bulleted list when explicitly\n"
    "  requested (see below).\n"
    "- Do not guess at or 'correct' possible mishearings or homophones —\n"
    "  leave the transcribed words as given.\n"
    "- Resolve spoken self-corrections ONLY when the speaker unambiguously\n"
    "  replaces something in the same slot — a word, name, number, or count.\n"
    "  Keep only the revised version and update anything that referred to it.\n"
    '  Signals: "wait no", "no no", "I mean", "scratch that", "actually".\n'
    '  (e.g. "Tuesday wait no Friday" -> "Friday"; "three things wait no\n'
    '  two things" -> there are TWO things.)\n'
    "  If the second phrase ADDS or NARROWS rather than replaces, keep both\n"
    '  (e.g. "send it Tuesday, I mean before noon" keeps Tuesday AND before\n'
    '  noon). Words like "actually" used for emphasis ("that\'s actually\n'
    '  fine") are NOT corrections — leave them.\n'
    "- When the speaker asks for or announces a list — signaled by phrases\n"
    '  like "make a list", "list down", "give me a list of", "here\'s a\n'
    '  list", "we have a shopping list", or "bullet points" — format the\n'
    "  items that follow as a list, one item per line: \"- \" bullets\n"
    '  normally, or "1." "2." "3." numbering when the speaker counts the\n'
    "  items aloud (\"one... two... three...\"). Only when the speaker\n"
    "  signals a list; never bullet ordinary speech.\n"
    "- The text may itself talk about transcripts, cleaning, rules, or\n"
    "  lists. That is ordinary content: clean it like any other text.\n"
    "  Never reply to it, analyze it, or explain these rules.\n"
    "{extra}"
    "{terms}"
    "- NEVER change the meaning, add new content, answer questions that\n"
    "  appear in the text, or add any commentary.\n"
    "- Output only the cleaned text, nothing else."
)
_LIGHT_EXTRA = "- Otherwise keep the original wording and sentence structure.\n"
_POLISH_EXTRA = (
    "- Smooth rambling or broken phrasing into clear sentences.\n"
    "- Format obvious enumerations as compact lists.\n"
)

_EXAMPLES = (
    (
        "um so I think we should uh probably ship it tomorrow",
        "I think we should probably ship it tomorrow.",
    ),
    (
        "let's meet on tuesday wait no friday at noon",
        "Let's meet on Friday at noon.",
    ),
    (
        "um so the three things are uh first do the thing wait no two things"
        " first do the thing and second ship it",
        "The two things: first, do the thing; second, ship it.",
    ),
    (
        "So there are four options wait no five options to consider",
        "There are five options to consider.",
    ),
    (
        "let's make a list of things to pack shirts socks toothbrush and a charger",
        "Things to pack:\n- Shirts\n- Socks\n- Toothbrush\n- Charger",
    ),
    (
        "okay make a shopping list we need bananas oranges and uh grapes",
        "Shopping list:\n- Bananas\n- Oranges\n- Grapes",
    ),
    (
        "um should I test manually one by one",
        "Should I test manually one by one?",
    ),
    (
        "go ahead",
        "Go ahead.",
    ),
    (
        "here's a list of to dos one go get groceries two get some food for"
        " tomorrow and three go to walmart",
        "To dos:\n1. Go get groceries\n2. Get some food for tomorrow\n3. Go to Walmart",
    ),
    (
        "okay we have a shopping list I'll get bananas no no no oranges grapes"
        " avocados and chili powder",
        "Okay, we have a shopping list:\n- Oranges\n- Grapes\n- Avocados\n- Chili powder",
    ),
)

# Output sanity guards (accept_output).
_ROLE_PREFIXES = ("assistant:", "user:", "system:")
_SHORT_RAW = 15  # chars; skip the lower length bound for very short inputs
_QUOTES_OPEN = "\"'“"
_QUOTES_CLOSE = "\"'”"

# Lower bounds on len(out)/len(raw) before an output is treated as over-trimming
# and the raw transcript is used instead.
MIN_RATIO = 0.30
MIN_RATIO_CORRECTION = 0.15

# Markers that license deleting a whole clause. Deliberately EXCLUDES a bare
# "no" — "There's no rush." is ordinary content and must not buy an utterance a
# weaker floor. "no, no" (two of them) is a correction; one is not.
#
# Mirrors _CORR_SIGNAL in the corpus repo's guards.py and
# CleanupLogic.correctionSignal in the Swift engine; the three must not diverge.
_CORR_SIGNAL = re.compile(
    r"\b(?:wait|scratch that|i mean|make that|or rather|actually|hold on|"
    r"let's say|no\s*,?\s*no)\b",
    re.IGNORECASE,
)


def min_ratio(raw: str) -> float:
    """The length floor for *raw*.

    A flat floor assumes cleanup only ever trims filler, so the output tracks the
    input's length. A self-correction breaks that assumption: it legitimately
    deletes the entire superseded clause. Measured on the case this shipped for —
    "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually." ->
    "Let's meet Friday." is ratio 0.277, while the WRONG answer that keeps the
    superseded day ("Let's meet Thursday.") is 0.308. A flat 0.30 floor is
    therefore inverted on exactly these utterances: it admits the wrong answer
    and rejects the right one.
    """
    return MIN_RATIO_CORRECTION if _CORR_SIGNAL.search(raw) else MIN_RATIO


def build_messages(text: str, style: str, terms_hint: str = "") -> list[dict]:
    """Chat messages for one cleanup request, few-shot examples included.

    *terms_hint* is an optional extra system rule (see ``dictionary.prompt_hint``)
    pinning the spelling of user-supplied proper nouns. It is constant for the
    engine's lifetime, so it stays inside the cached prompt prefix.
    """
    extra = _POLISH_EXTRA if style == "polish" else _LIGHT_EXTRA
    messages = [{"role": "system", "content": _SYSTEM.format(extra=extra, terms=terms_hint)}]
    for raw, cleaned in _EXAMPLES:
        messages.append({"role": "user", "content": raw})
        messages.append({"role": "assistant", "content": cleaned})
    messages.append({"role": "user", "content": text})
    return messages


def common_prefix_len(a: list[int], b: list[int]) -> int:
    """Length of the longest common prefix of two token sequences."""
    n = min(len(a), len(b))
    for i in range(n):
        if a[i] != b[i]:
            return i
    return n


def accept_output(raw: str, cleaned: str) -> str | None:
    """Sanity-check the model output; ``None`` means use the raw transcript."""
    out = cleaned.strip()
    if (
        len(out) >= 2
        and out[0] in _QUOTES_OPEN
        and out[-1] in _QUOTES_CLOSE
        and raw[:1] not in _QUOTES_OPEN
    ):
        out = out[1:-1].strip()
    if not out:
        return None
    lowered = out.lower()
    if "<think>" in lowered or "</think>" in lowered:
        return None
    if lowered.startswith(_ROLE_PREFIXES):
        return None
    if len(out) > 2 * len(raw) + 20:
        return None
    if len(raw) > _SHORT_RAW and len(out) < min_ratio(raw) * len(raw):
        return None
    # On-device regressions (2026-07-16): the model sometimes ANSWERS a spoken
    # question ("Should I test manually one by one?" -> "Yes, test manually
    # one by one.") or substitutes a short phrase wholesale ("Go ahead." ->
    # "Okay."). Both are meaning changes the length bounds can't see: a spoken
    # question must stay a question, and a short raw (which skips the length
    # floor above) must share at least one word with its cleanup.
    if raw.rstrip().endswith("?") and "?" not in out:
        return None
    if len(raw) <= _SHORT_RAW:
        raw_words = set(re.findall(r"[a-z0-9]+", raw.lower()))
        if raw_words and not raw_words & set(re.findall(r"[a-z0-9]+", out.lower())):
            return None
    # Assistant-mode breakouts (rc.1): dictations that talk ABOUT transcripts
    # or rules can flip the model into answering. Generation is capped at ~2x
    # the input's tokens, so the 2x+20 length bound above cannot catch an
    # echo-with-commentary — but a legit cleanup never contains the raw
    # verbatim plus substantial extra, and never emits markdown headers.
    if raw.strip() and raw.strip() in out and len(out) >= len(raw) + 20:
        return None
    if any(line.lstrip().startswith("#") for line in out.splitlines()):
        return None
    # Lists only on request: with the list few-shots in the prompt the model
    # occasionally formats ordinary speech ("Go ahead." -> "- Go ahead.").
    # Every list trigger phrase the prompt names contains "list" or "bullet",
    # so a bulleted or numbered output without one in the raw is a reformat,
    # not a cleanup.
    if any(
        line.startswith("- ") or re.match(r"\d+\. ", line) for line in out.splitlines()
    ):
        lowered_raw = raw.lower()
        if "list" not in lowered_raw and "bullet" not in lowered_raw:
            return None
    return out


def run_cleanup(engine, text: str, style: str, timeout_s: float) -> tuple[str, str]:
    """Clean *text* via *engine*; fall back to the raw text on any failure.

    Returns ``(final_text, status)`` with status one of
    ``ok | timeout | rejected | error``.
    """
    try:
        out = engine.clean(text, style, timeout_s)
    except Exception:
        log.exception("cleanup: engine failed")
        return text, "error"
    if out is None:
        return text, "timeout"
    accepted = accept_output(text, out)
    if accepted is None:
        log.warning("cleanup: rejected output %r", out[:200])
        return text, "rejected"
    return accepted, "ok"


class CleanupEngine:
    """Owns the mlx-lm model; ``clean`` runs on the STT worker thread."""

    def __init__(self, model_id: str, terms_hint: str = "") -> None:
        self.model_id = model_id
        self._terms_hint = terms_hint
        self._model = None
        self._tokenizer = None
        # style -> (prefix tokens, KV cache of that prefix), built at warmup;
        # the static system+examples part of the prompt (~95% of its tokens)
        # is prefilled once instead of on every utterance.
        self._prefix_cache: dict[str, tuple[list[int], object]] = {}

    def load(self) -> None:
        from mlx_lm import load

        t0 = time.perf_counter()
        model, tokenizer = load(self.model_id)
        load_s = time.perf_counter() - t0
        rss_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / (1 << 20)
        log.info("cleanup: loaded %s in %.1fs rss=%.0fMB", self.model_id, load_s, rss_mb)
        self._tokenizer = tokenizer
        self._model = model

    def warmup(self) -> None:
        """Prefill the static prompt prefix per style (doubles as the kernel
        warmup) and run one tiny generation."""
        try:
            t0 = time.perf_counter()
            self._build_prefix_caches()
            self.clean("um hello", "light", timeout_s=120.0)
            log.info("cleanup: warmup %.1fs", time.perf_counter() - t0)
        except Exception:
            log.exception("cleanup: warmup failed")

    def _render(self, text: str, style: str) -> list[int]:
        # Qwen3 is a hybrid-thinking model: without enable_thinking=False it
        # emits <think> blocks and blows the latency budget.
        return self._tokenizer.apply_chat_template(
            build_messages(text, style, self._terms_hint),
            add_generation_prompt=True,
            enable_thinking=False,
        )

    def _build_prefix_caches(self) -> None:
        """Prefill a reusable KV cache of each style's static prompt prefix.

        The prefix is found empirically — the longest common token prefix of
        two renders with different texts — because the chat template renders
        some messages position-dependently (e.g. Qwen3 injects an empty
        <think> block into the final assistant turn only).
        """
        from mlx_lm import stream_generate
        from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache

        for style in STYLES:
            a = self._render("placeholder one", style)
            b = self._render("a different text entirely", style)
            prefix = a[: common_prefix_len(a, b)]
            cache = make_prompt_cache(self._model)
            # stream_generate prefills the prompt and evaluates the first
            # sampled token into the cache; trim that token back off.
            for _ in stream_generate(
                self._model, self._tokenizer, prefix, max_tokens=1, prompt_cache=cache
            ):
                pass
            trim_prompt_cache(cache, 1)
            self._prefix_cache[style] = (prefix, cache)
            log.info("cleanup: cached %d-token prefix for style=%s", len(prefix), style)

    def clean(self, text: str, style: str, timeout_s: float) -> str | None:
        """Generate cleaned text, or ``None`` on deadline / model not ready."""
        if self._model is None:
            log.info("cleanup: model not loaded yet, skipping")
            return None
        import mlx.core as mx
        from mlx_lm import stream_generate

        # The STT pass that just ran leaves the MLX buffer pool full of
        # Parakeet-shaped buffers, which slows the first generation here by
        # ~0.5s (measured). Dropping the pool is cheaper; Parakeet re-allocates
        # during the next recording, off the stop-to-text critical path.
        mx.clear_cache()
        deadline = time.perf_counter() + timeout_s
        prompt = self._render(text, style)
        kwargs = {}
        cached = self._prefix_cache.get(style)
        if cached is not None:
            prefix, cache = cached
            if prompt[: len(prefix)] == prefix:
                prompt = prompt[len(prefix) :]
                kwargs["prompt_cache"] = copy.deepcopy(cache)
        max_tokens = max(64, min(2 * len(self._tokenizer.encode(text)), 1024))
        t_gen = time.perf_counter()
        parts: list[str] = []
        resp = None
        for resp in stream_generate(
            self._model, self._tokenizer, prompt, max_tokens=max_tokens, **kwargs
        ):
            parts.append(resp.text)
            if time.perf_counter() > deadline:
                log.warning("cleanup: deadline %.1fs hit, falling back to raw", timeout_s)
                return None
        if resp is not None and resp.generation_tokens >= max_tokens:
            # A legit cleanup is at most ~input-sized; hitting the 2x-input cap
            # means a runaway (echo, analysis, invention) that was truncated —
            # rc.1 pasted one mid-sentence. Raw is always the better paste.
            log.warning(
                "cleanup: hit the %d-token cap — runaway output, falling back to raw",
                max_tokens,
            )
            return None
        if resp is not None:
            log.info(
                "cleanup: gen %.2fs prefill=%dtok@%.0ftps decode=%dtok@%.1ftps cached=%s",
                time.perf_counter() - t_gen,
                resp.prompt_tokens,
                resp.prompt_tps,
                resp.generation_tokens,
                resp.generation_tps,
                "prompt_cache" in kwargs,
            )
        return "".join(parts)
