"""Pure-logic tests for the cleanup pass (no mlx required)."""

from pomvox.cleanup import (
    MIN_RATIO,
    MIN_RATIO_CORRECTION,
    accept_output,
    build_messages,
    common_prefix_len,
    min_ratio,
    run_cleanup,
)

RAW = "um so I think we should uh ship it tomorrow maybe"


# --- build_messages ---------------------------------------------------------


def test_build_messages_embeds_text_and_rules():
    msgs = build_messages("hello world", "light")
    assert msgs[0]["role"] == "system"
    rules = msgs[0]["content"].lower()
    assert "filler" in rules
    assert "punctuation" in rules
    assert "never change the meaning" in rules
    assert msgs[-1] == {"role": "user", "content": "hello world"}


def test_build_messages_injects_terms_hint():
    hint = "- Keep these terms spelled exactly: Salammagari.\n"
    system = build_messages("x", "polish", hint)[0]["content"]
    assert "Salammagari" in system
    # The hint sits among the rules, before the final "output only" line.
    assert system.index("Salammagari") < system.index("Output only")


def test_build_messages_terms_hint_defaults_empty():
    system = build_messages("x", "light")[0]["content"]
    assert "{terms}" not in system  # placeholder fully resolved


def test_build_messages_styles_differ():
    light = build_messages("x", "light")[0]["content"].lower()
    polish = build_messages("x", "polish")[0]["content"].lower()
    assert light != polish
    assert "smooth" in polish
    assert "smooth" not in light


def test_build_messages_has_few_shot_pairs():
    msgs = build_messages("x", "polish")
    roles = [m["role"] for m in msgs]
    assert roles[0] == "system"
    assert roles[-1] == "user"
    assert roles.count("assistant") >= 2
    # user/assistant examples alternate between system and the final user turn
    assert roles[1:-1] == ["user", "assistant"] * (roles.count("assistant"))


# --- accept_output ----------------------------------------------------------


def test_accept_normal_output():
    cleaned = "I think we should ship it tomorrow."
    assert accept_output(RAW, cleaned) == cleaned


def test_accept_strips_wrapping_quotes():
    assert (
        accept_output(RAW, '"I think we should ship it tomorrow."')
        == "I think we should ship it tomorrow."
    )


def test_reject_empty():
    assert accept_output(RAW, "") is None
    assert accept_output(RAW, "   \n") is None


def test_reject_think_artifacts():
    assert accept_output(RAW, "<think>hmm</think>Ship it tomorrow, I think.") is None


def test_reject_role_prefix():
    assert accept_output(RAW, "assistant: I think we should ship it tomorrow.") is None


def test_reject_far_too_long():
    assert accept_output("short text here ok", "x" * 200) is None


def test_reject_far_too_short():
    assert accept_output(RAW, "ok") is None


def test_short_raw_skips_lower_bound():
    assert accept_output("ok", "OK.") == "OK."


# --- correction-aware length floor ------------------------------------------

_CORRECTION_RAW = "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually."


def test_self_correction_survives_the_floor():
    """The flat 0.30 floor was inverted here: it rejected the correct output
    (ratio 0.277) and admitted the wrong one (0.308)."""
    assert accept_output(_CORRECTION_RAW, "Let's meet Friday.") == "Let's meet Friday."


def test_the_correct_answer_is_shorter_than_the_wrong_one():
    right = len("Let's meet Friday.") / len(_CORRECTION_RAW)
    wrong = len("Let's meet Thursday.") / len(_CORRECTION_RAW)
    assert right < wrong
    assert right < MIN_RATIO  # the flat floor would reject the right answer
    assert right > MIN_RATIO_CORRECTION


def test_correction_markers_lower_the_floor():
    for raw in (
        "Let's meet Thursday. No, no, wait, we'll meet Friday.",
        "Send it Tuesday, scratch that, Wednesday.",
        "We need four, I mean five.",
        "Ship it Monday, make that Tuesday.",
        "Call him first, or rather email him first.",
        "Let's do Friday. Or actually, let's do Thursday.",
        "Book the big room, hold on, the small one.",
        "We'll need two, let's say three.",
    ):
        assert min_ratio(raw) == MIN_RATIO_CORRECTION, raw


def test_ordinary_content_keeps_the_strict_floor():
    """A bare "no" must not buy an utterance a weaker floor."""
    for raw in (
        "There's no rush on this one at all.",
        "No, I don't think that's going to work for us.",
        "We have no idea what happened to the build.",
        "The meeting is confirmed for Tuesday at 3 PM.",
    ):
        assert min_ratio(raw) == MIN_RATIO, raw


def test_doubled_no_is_a_marker_but_a_single_no_is_not():
    assert min_ratio("Bananas. No, no, oranges.") == MIN_RATIO_CORRECTION
    assert min_ratio("Bananas. No no oranges.") == MIN_RATIO_CORRECTION
    assert min_ratio("No, oranges are what we need here.") == MIN_RATIO


def test_the_relaxed_floor_still_rejects_a_total_collapse():
    assert accept_output(_CORRECTION_RAW, "Fri") is None


def test_the_strict_floor_still_applies_without_a_marker():
    raw = "The meeting is confirmed for Tuesday at 3 PM in the main room."
    assert accept_output(raw, "Tuesday.") is None


# --- run_cleanup ------------------------------------------------------------


class FakeEngine:
    def __init__(self, result=None, exc=None):
        self.result = result
        self.exc = exc
        self.calls = []

    def clean(self, text, style, timeout_s):
        self.calls.append((text, style, timeout_s))
        if self.exc is not None:
            raise self.exc
        return self.result


def test_run_cleanup_ok():
    engine = FakeEngine(result="The meeting is on Friday.")
    out = run_cleanup(engine, "um the meeting is on tuesday wait no friday", "polish", 3.0)
    assert out == ("The meeting is on Friday.", "ok")
    assert engine.calls == [("um the meeting is on tuesday wait no friday", "polish", 3.0)]


def test_run_cleanup_timeout_falls_back_to_raw():
    assert run_cleanup(FakeEngine(result=None), RAW, "polish", 3.0) == (RAW, "timeout")


def test_run_cleanup_error_falls_back_to_raw():
    engine = FakeEngine(exc=RuntimeError("boom"))
    assert run_cleanup(engine, RAW, "light", 3.0) == (RAW, "error")


def test_run_cleanup_rejected_falls_back_to_raw():
    engine = FakeEngine(result="<think>let me reason</think>")
    assert run_cleanup(engine, RAW, "polish", 3.0) == (RAW, "rejected")


# --- common_prefix_len -------------------------------------------------------


def test_common_prefix_len_diverging():
    assert common_prefix_len([1, 2, 3], [1, 2, 4]) == 2


def test_common_prefix_len_identical():
    assert common_prefix_len([1, 2, 3], [1, 2, 3]) == 3


def test_common_prefix_len_one_is_prefix_of_other():
    assert common_prefix_len([1, 2, 3], [1, 2]) == 2


def test_common_prefix_len_empty():
    assert common_prefix_len([], [1, 2]) == 0


def test_common_prefix_len_no_overlap():
    assert common_prefix_len([9], [1]) == 0


def test_correction_rule_covers_count_revisions():
    rules = build_messages("x", "polish")[0]["content"].lower()
    assert "wait no" in rules
    assert "number, or count" in rules


def test_few_shot_includes_count_revision_example():
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    assert any("four options wait no five" in raw for raw, _ in pairs)


# --- spoken list commands ---------------------------------------------------


def test_list_rule_present_in_both_styles():
    for style in ("light", "polish"):
        rules = build_messages("x", style)[0]["content"].lower()
        assert "make a list" in rules
        assert "list down" in rules
        assert "bulleted" in rules


def test_few_shot_includes_list_example():
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    example = next((c for r, c in pairs if "make a list" in r), None)
    assert example is not None
    # the modelled answer is a real bulleted list, one "- " item per line
    lines = example.splitlines()
    assert sum(1 for line in lines if line.startswith("- ")) >= 3


# --- substituted / answered outputs (on-device regressions, 2026-07-16) ------


def test_reject_answered_question():
    # "Should I test manually one by one?" pasted as "Yes, test manually one
    # by one." — the model answered the question instead of cleaning it.
    assert accept_output(
        "Should I test manually one by one?", "Yes, test manually one by one."
    ) is None


def test_accept_question_cleaned_as_question():
    assert (
        accept_output("um should I test manually one by one?", "Should I test manually one by one?")
        == "Should I test manually one by one?"
    )


def test_accept_question_mark_moved_but_kept():
    # Cleanup may restructure punctuation as long as the question survives.
    assert accept_output("is it done? the build done?", "Is it done? The build done?") is not None


def test_reject_short_raw_substitution():
    # "Go ahead." pasted as "Okay." — a full rewrite sharing no words with
    # what was spoken. Short raws skip the length floor, so without a word-
    # overlap check they had no guard at all.
    assert accept_output("Go ahead.", "Okay.") is None


def test_accept_short_raw_sharing_a_word():
    assert accept_output("go ahead", "Go ahead.") == "Go ahead."


def test_accept_short_raw_filler_removed():
    assert accept_output("um yes", "Yes.") == "Yes."


def test_few_shot_includes_question_passthrough_example():
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    # at least one modelled answer keeps a spoken question a question
    assert any(cleaned.rstrip().endswith("?") for _, cleaned in pairs)


def test_few_shot_list_examples_vary_header():
    # Two list examples with different headers, so the model derives the
    # header from the input instead of parroting a single example's
    # ("Things to pack:" showed up on a dictated shopping list on-device).
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    headers = {
        cleaned.splitlines()[0]
        for _, cleaned in pairs
        if any(line.startswith("- ") for line in cleaned.splitlines())
    }
    assert len(headers) >= 2


def test_reject_unrequested_bullets():
    # With two list few-shots in the prompt the model started bulleting tiny
    # non-list inputs ("Go ahead." -> "- Go ahead."). Bullets are only valid
    # when the speaker asked for a list — and every trigger phrase the prompt
    # names contains "list" or "bullet".
    assert accept_output("Go ahead.", "- Go ahead.") is None
    assert accept_output("we need mangoes and grapes", "- Mangoes\n- Grapes") is None


def test_accept_requested_bullets():
    assert (
        accept_output("make a list of groceries mangoes and grapes", "- Mangoes\n- Grapes")
        == "- Mangoes\n- Grapes"
    )
    assert accept_output(
        "let's create a shopping list mangoes oranges avocados",
        "Shopping list:\n- Mangoes\n- Oranges\n- Avocados",
    ) is not None


# --- assistant-mode breakout (rc.1 on-device regressions, 2026-07-17) --------


def test_reject_echoed_input_with_commentary():
    # rc.1: dictating ABOUT the cleanup rules made the model paste the input
    # back wrapped in analysis ("The text you provided is: ... ### Analysis").
    # On a long raw the 2x+20 length bound cannot catch this (generation is
    # capped at ~2x the input, so echo+commentary always fits under it); a
    # legit cleanup never contains the raw verbatim PLUS substantial extra.
    raw = (
        "The above are the text that I just put in. In one case, I saw the a "
        "being there, as and ums are supposed to be removed, and then uh there "
        "is one more thing. The list, it is not being actually displayed as a "
        "list, like one, two, three. This is with the R C build, by the way."
    )
    out = 'The text you provided is:\n\n"' + raw + '"\n\nFiller words are removed only when they are disfluencies.'
    assert len(out) <= 2 * len(raw) + 20  # the length bound provably can't catch it
    assert accept_output(raw, out) is None


def test_accept_passthrough_and_tiny_punctuation_additions():
    # out == raw stays fine, and adding a few chars (a period, casing) is a
    # legit minimal cleanup, not an echo-with-commentary.
    raw = "this is with the R C build by the way"
    assert accept_output(raw, raw) == raw
    assert accept_output("is it done", "Is it done.") == "Is it done."


def test_reject_markdown_headers():
    # Cleanup output is plain prose (or a list); markdown headers only appear
    # when the model has broken out into assistant mode.
    assert accept_output(
        "tell me why the list is not showing up here today",
        "### Analysis:\nThe list did not trigger.",
    ) is None


def test_reject_numbered_bullets_without_list_request():
    # The numbered variant of the unrequested-bullets guard.
    assert accept_output(
        "we need mangoes and also grapes for the week", "1. Mangoes\n2. Grapes"
    ) is None


def test_accept_numbered_list_on_request():
    assert (
        accept_output(
            "here's a list of to dos one get groceries two go to walmart",
            "To dos:\n1. Get groceries\n2. Go to Walmart",
        )
        is not None
    )


# --- list coverage (rc.1: announcements + numbered enumerations) -------------


def test_list_rule_covers_numbered_enumerations():
    rules = build_messages("x", "polish")[0]["content"].lower()
    assert "1." in rules or "numbered" in rules


def test_few_shot_includes_numbered_list_example():
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    assert any(
        any(line.startswith("1. ") for line in cleaned.splitlines()) for _, cleaned in pairs
    )


def test_few_shot_includes_announcement_list_example():
    # "we have a shopping list and I'll get..." is an announcement, not an
    # imperative — rc.1 echoed it verbatim instead of formatting.
    msgs = build_messages("x", "polish")
    pairs = [(msgs[i]["content"], msgs[i + 1]["content"]) for i in range(1, len(msgs) - 1, 2)]
    assert any("we have a shopping list" in raw for raw, _ in pairs)


def test_rules_say_never_discuss_the_rules():
    # rc.1: dictations that TALK ABOUT transcripts/rules flipped the model
    # into answering. The prompt must pin them as ordinary content.
    rules = build_messages("x", "polish")[0]["content"].lower()
    assert "never reply" in rules or "never respond" in rules
