#!/usr/bin/env python
"""Ship-gate eval for simplewords-dictation-cleanup-v2 (fused, 8-bit).

All 28 cases from eval rounds 1-3, run with the repo's OWN recipe (frozen
system_v2.txt, greedy, enable_thinking=False), through a Python port of
Pomvox's acceptOutput guard (Pomvox/Sources/Engine/CleanupLogic.swift), with
auto-scored checks on the release-gate cases.

Gate: zero self-correction inversions, zero guard rejections on ordinary
speech, no regression on v1's wins.

    uv run python scripts/eval_cleanup_v2.py
    uv run python scripts/eval_cleanup_v2.py --json /tmp/eval-v2.json

The --json dump is the parity reference: run the same raw strings through the
Swift engine (CleanupModelLoadProbeTests) and compare outputs case by case.
Keep the accept_output port below in sync with CleanupLogic.acceptOutput —
the Swift version is the source of truth.
"""
import re, time
from pathlib import Path
from huggingface_hub import snapshot_download
from mlx_lm import load, generate
from mlx_lm.sample_utils import make_sampler

REPO = "abhiram3040/simplewords-dictation-cleanup-v2"

# NOT an optimization — DO NOT REMOVE. This is the same file set Pomvox's Swift
# loader fetches (CleanupEngine.frozenSnapshotGlobs). An unfiltered
# snapshot_download also pulls the repo's adapter/adapters.safetensors (67 MB of
# LoRA tensors) into the SHARED Hugging Face cache snapshot directory that Pomvox
# then loads with ModelConfiguration(directory:). mlx-swift-lm's loadWeights
# enumerates that directory RECURSIVELY, merges every .safetensors it finds, and
# calls update(parameters:verify: [.all]), which rejects the unused lora_a/lora_b
# keys — so the app's cleanup prepare() fails and every dictation pastes the raw
# transcript until someone purges the cache by hand. Running this script must not
# break the app it validates. mlx_lm's own loader reads the weight index rather
# than globbing recursively, so the filter does not change this script's results.
ALLOW_PATTERNS = ["model*.safetensors", "*.json", "*.jinja", "system_v2.txt"]

# ---- acceptOutput port (CleanupLogic.swift) ----
QUOTES_OPEN = {'"', "'", "“"}; QUOTES_CLOSE = {'"', "'", "”"}
ROLE_PREFIXES = ("assistant:", "user:", "system:"); SHORT_RAW = 15
def words(s): return set(re.findall(r"[a-z0-9]+", s.lower()))
def is_list_item_line(l): return l.startswith("- ") or re.match(r"\d+\. ", l) is not None
def accept_output(raw, cleaned):
    out = cleaned.strip()
    rq = (len(raw) == 0) or (raw[0] in QUOTES_OPEN)
    if len(out) >= 2 and out[0] in QUOTES_OPEN and out[-1] in QUOTES_CLOSE and not rq:
        out = out[1:-1].strip()
    if not out: return None
    low = out.lower()
    if "<think>" in low or "</think>" in low: return None
    if any(low.startswith(p) for p in ROLE_PREFIXES): return None
    if len(out) > 2 * len(raw) + 20: return None
    if len(raw) > SHORT_RAW and len(out) < 0.3 * len(raw): return None
    if raw.strip().endswith("?") and "?" not in out: return None
    if len(raw) <= SHORT_RAW:
        rw = words(raw)
        if rw and rw.isdisjoint(words(out)): return None
    tr = raw.strip()
    if tr and tr in out and len(out) >= len(raw) + 20: return None
    if any(l.lstrip().startswith("#") for l in out.split("\n")): return None
    if any(is_list_item_line(l) for l in out.split("\n")):
        lr = raw.lower()
        if "list" not in lr and "bullet" not in lr: return None
    return out

# Checks: (must_contain, must_not_contain, extra) — all case-insensitive word checks
def has(o, s): return re.search(r"\b" + re.escape(s.lower()) + r"\b", o.lower()) is not None

TESTS = [
    # (name, raw, must_contain, must_not_contain, special)
    ("R1 filler/false-start", "Did you bring any snacks? Uh, wait no, did you maybe bring some snacks, like, uh, you know, snacks?", ["snacks"], ["wait no"], "question"),
    ("R1 filler", "How old, um, how old is the cousin like I mean?", ["cousin"], ["um"], "question"),
    ("R1 already-clean", "The meeting is confirmed for Tuesday at 3 PM in the main conference room.", [], [], "unchanged"),
    ("R1 SHORT 'go ahead'", "go ahead", ["go ahead"], [], "period"),
    ("R1 buried question", "um should I test manually one by one", ["test manually"], ["um"], "question"),
    ("R1 GATE day-correction", "let's meet on tuesday wait no friday at noon", ["friday", "noon"], ["tuesday"], None),
    ("R1 GATE count-correction", "So there are four options wait no five options to consider", ["five"], ["four"], None),
    ("R1 list on request", "let's make a list of things to pack shirts socks toothbrush and a charger", ["shirts"], [], "bullets"),
    ("R1 numbered list", "here's a list of to dos one go get groceries two get some food for tomorrow and three go to walmart", ["groceries", "walmart"], [], "numbered"),
    ("R1 NO list trigger", "so first we grab coffee then we drive to the office then we start the meeting", ["coffee"], [], "no-bullets"),
    ("R1 homophone leave", "i went to the store their were no apples", ["their"], [], None),
    ("R1 meaning-preserve", "yeah um i think the the budget is like around fifty thousand dollars give or take", ["fifty thousand", "give or take"], ["um"], None),
    ("R3 extreme um/uh", "um so uh yeah um i was thinking uh maybe we could um you know like go to the uh the store later", ["store later"], ["um"], None),
    ("R3 stutter repeat", "i i i just wanted to to say that that the the report is is ready", ["report"], [], None),
    ("R3 trailing off", "so the thing is that we um we really need to uh yeah", ["need"], ["um"], None),
    ("R3 keep 'like a charm'", "honestly it works like a charm and it's like really really fast", ["like a charm"], [], None),
    ("R3 run-on ramble", "okay so basically what happened was we went to the meeting and then uh the client said they wanted changes and um so we're gonna have to redo the whole thing by friday i think", ["gonna", "friday"], ["um"], None),
    ("R3 GATE time-correction", "let's meet at uh three thirty no wait four o'clock on the fifteenth", ["four o'clock", "fifteenth"], ["three thirty"], None),
    ("R3 email + proper nouns", "send an email to john saying uh hey john can you review the doc when you get a sec thanks", ["John"], ["uh"], "cap-John"),
    ("R3 GATE triple correction", "i'll take the red one no the blue one actually the green one", ["green"], ["red", "blue"], None),
    ("R3 false start mid-word", "we should def we should definitely ship it today", ["definitely ship"], [], None),
    ("R3 question in fillers", "um so like do you think we should uh you know push this today or maybe wait", ["push this today"], ["um"], "question"),
    ("R3 um between repeats", "the budget is um the budget is around um fifty grand give or take", ["fifty grand"], ["um"], None),
    ("R3 casual register", "yeah nah i dunno man it's like whatever honestly", ["dunno"], [], None),
    ("R3 technical terms", "so the uh the api endpoint returns a four oh four error like sometimes randomly", ["endpoint"], ["uh"], None),
    ("R3 long paragraph", "so um i wanted to walk you through the plan uh first we do the research then um we build a prototype and uh after that you know we test it with users and then um based on the feedback we iterate and uh finally we ship it maybe by end of quarter i hope", ["prototype", "iterate"], ["um"], "multi-sentence"),
    ("R3 almost all filler", "um uh so yeah like you know", [], [], "guard-pass"),
    ("R3 numbers", "we sold uh like twenty five hundred units last month up from um two thousand", ["twenty", "two thousand"], ["uh"], None),
]

def special_ok(kind, raw, out, accepted):
    if kind is None: return True
    if kind == "question": return accepted is not None and accepted.rstrip().endswith("?")
    if kind == "unchanged": return accepted == raw
    if kind == "period": return accepted is not None and accepted.rstrip()[-1:] in ".!?"
    if kind == "bullets": return accepted is not None and any(l.startswith("- ") for l in accepted.split("\n"))
    if kind == "numbered": return accepted is not None and any(re.match(r"\d+\. ", l) for l in accepted.split("\n"))
    if kind == "no-bullets": return accepted is not None and not any(is_list_item_line(l) for l in accepted.split("\n"))
    if kind == "cap-John": return accepted is not None and "John" in accepted
    if kind == "multi-sentence": return accepted is not None and accepted.count(".") + accepted.count("?") + accepted.count("!") >= 3
    if kind == "guard-pass": return accepted is not None
    return True

def main():
    import argparse, json
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", dest="json_path", default=None,
                    help="write per-case raw/out/accepted to this path")
    opts = ap.parse_args()

    path = snapshot_download(REPO, allow_patterns=ALLOW_PATTERNS)
    system = (Path(path) / "system_v2.txt").read_text().strip()
    model, tok = load(path)
    sampler = make_sampler(temp=0.0)

    def clean(raw):
        prompt = tok.apply_chat_template(
            [{"role": "user", "content": f"{system}\n\n{raw}"}],
            add_generation_prompt=True, enable_thinking=False, tokenize=False)
        t0 = time.time()
        out = generate(model, tok, prompt=prompt, max_tokens=512, sampler=sampler).strip()
        return out, time.time() - t0

    passed = failed = 0
    gate_failures = []
    times = []
    results = {}
    for name, raw, must, must_not, special in TESTS:
        out, dt = clean(raw)
        times.append(dt)
        accepted = accept_output(raw, out)
        results[name] = {"raw": raw, "out": out, "accepted": accepted}
        probe = accepted if accepted is not None else ""
        errs = []
        for m in must:
            if not has(probe, m): errs.append(f"missing {m!r}")
        for m in must_not:
            if has(probe, m): errs.append(f"contains {m!r}")
        if not special_ok(special, raw, out, accepted):
            errs.append(f"special check '{special}' failed")
        if accepted is None and special != "guard-pass":
            errs.append("GUARD-REJECTED (raw pastes)")
        status = "PASS" if not errs else "FAIL"
        if errs: failed += 1
        else: passed += 1
        if "GATE" in name and errs: gate_failures.append(name)
        print(f"\n[{status}] {name}  ({dt*1000:.0f}ms)")
        print(f"  raw : {raw!r}")
        print(f"  out : {out!r}")
        if accepted != out and accepted is not None: print(f"  acc : {accepted!r}")
        if accepted is None: print("  acc : <REJECTED -> raw pastes>")
        for e in errs: print(f"  ERR : {e}")

    times.sort()
    p50 = times[len(times)//2]; p95 = times[int(len(times)*0.95)]
    print("\n" + "=" * 70)
    print(f"TOTAL: {passed}/{passed+failed} passed   latency p50={p50*1000:.0f}ms p95={p95*1000:.0f}ms")
    print(f"GATE (self-correction) failures: {gate_failures or 'NONE'}")

    if opts.json_path:
        with open(opts.json_path, "w") as fh:
            json.dump(results, fh, indent=2, sort_keys=True)
        print(f"wrote {opts.json_path}")

if __name__ == "__main__":
    main()
