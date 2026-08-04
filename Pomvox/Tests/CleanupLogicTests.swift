import XCTest

@testable import Pomvox

/// 1:1 port of `tests/test_cleanup.py` — test-vector parity with the
/// Linux-tested Python spec (build_messages, accept_output, run_cleanup,
/// common_prefix_len), not re-derived.
final class CleanupLogicTests: XCTestCase {

    let raw = "um so I think we should uh ship it tomorrow maybe"

    // MARK: - buildMessages

    func testBuildMessagesEmbedsTextAndRules() {
        let msgs = CleanupLogic.buildMessages(text: "hello world", style: "light")
        XCTAssertEqual(msgs[0].role, "system")
        let rules = msgs[0].content.lowercased()
        XCTAssertTrue(rules.contains("filler"))
        XCTAssertTrue(rules.contains("punctuation"))
        XCTAssertTrue(rules.contains("never change the meaning"))
        XCTAssertEqual(msgs.last, ChatMessage(role: "user", content: "hello world"))
    }

    func testBuildMessagesInjectsTermsHint() {
        let hint = "- Keep these terms spelled exactly: Salammagari.\n"
        let system = CleanupLogic.buildMessages(text: "x", style: "polish", termsHint: hint)[0].content
        XCTAssertTrue(system.contains("Salammagari"))
        // The hint sits among the rules, before the final "Output only" line.
        XCTAssertLessThan(system.range(of: "Salammagari")!.lowerBound,
                          system.range(of: "Output only")!.lowerBound)
    }

    func testBuildMessagesTermsHintDefaultsEmpty() {
        let system = CleanupLogic.buildMessages(text: "x", style: "light")[0].content
        XCTAssertFalse(system.contains("{terms}"))  // placeholder fully resolved
    }

    func testBuildMessagesStylesDiffer() {
        let light = CleanupLogic.buildMessages(text: "x", style: "light")[0].content.lowercased()
        let polish = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertNotEqual(light, polish)
        XCTAssertTrue(polish.contains("smooth"))
        XCTAssertFalse(light.contains("smooth"))
    }

    func testBuildMessagesHasFewShotPairs() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        let roles = msgs.map(\.role)
        XCTAssertEqual(roles.first, "system")
        XCTAssertEqual(roles.last, "user")
        let assistants = roles.filter { $0 == "assistant" }.count
        XCTAssertGreaterThanOrEqual(assistants, 2)
        // user/assistant examples alternate between system and the final user turn
        let middle = Array(roles[1..<(roles.count - 1)])
        XCTAssertEqual(middle, Array(repeating: ["user", "assistant"], count: assistants).flatMap { $0 })
    }

    // MARK: - acceptOutput

    func testAcceptNormalOutput() {
        let cleaned = "I think we should ship it tomorrow."
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: raw, cleaned: cleaned), cleaned)
    }

    func testAcceptStripsWrappingQuotes() {
        XCTAssertEqual(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "\"I think we should ship it tomorrow.\""),
            "I think we should ship it tomorrow.")
    }

    func testRejectEmpty() {
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: ""))
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: "   \n"))
    }

    func testRejectThinkArtifacts() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "<think>hmm</think>Ship it tomorrow, I think."))
    }

    func testRejectRolePrefix() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: raw, cleaned: "assistant: I think we should ship it tomorrow."))
    }

    func testRejectFarTooLong() {
        XCTAssertNil(
            CleanupLogic.acceptOutput(raw: "short text here ok", cleaned: String(repeating: "x", count: 200)))
    }

    func testRejectFarTooShort() {
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: "ok"))
    }

    func testShortRawSkipsLowerBound() {
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: "ok", cleaned: "OK."), "OK.")
    }

    // MARK: - Correction-aware length floor

    /// The production case this shipped for. The flat 0.30 floor was INVERTED
    /// here: it rejected the correct output (0.277) and admitted the wrong one
    /// (0.308), so the user got either the raw disfluent text or the wrong day.
    func testASelfCorrectionKeepsOnlyTheRevisionAndSurvivesTheFloor() {
        let raw = "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually."
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: raw, cleaned: "Let's meet Friday."),
                       "Let's meet Friday.")
    }

    /// The inversion, stated as a ratio so the numbers in the doc comment are
    /// checked rather than asserted in prose.
    func testTheCorrectAnswerIsShorterThanTheWrongOne() {
        let raw = "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually."
        let right = Double("Let's meet Friday.".count) / Double(raw.count)
        let wrong = Double("Let's meet Thursday.".count) / Double(raw.count)
        XCTAssertLessThan(right, wrong)
        XCTAssertLessThan(right, CleanupLogic.minRatio, "the flat floor would reject the right answer")
        XCTAssertGreaterThan(right, CleanupLogic.minRatioCorrection)
    }

    func testCorrectionMarkersLowerTheFloor() {
        for raw in [
            "Let's meet Thursday. No, no, wait, we'll meet Friday.",
            "Send it Tuesday, scratch that, Wednesday.",
            "We need four, I mean five.",
            "Ship it Monday, make that Tuesday.",
            "Call him first, or rather email him first.",
            "Let's do Friday. Or actually, let's do Thursday.",
            "Book the big room, hold on, the small one.",
            "We'll need two, let's say three.",
        ] {
            XCTAssertEqual(CleanupLogic.minRatio(forRaw: raw), CleanupLogic.minRatioCorrection, raw)
        }
    }

    /// The exclusion that keeps the relaxation narrow: a bare "no" is ordinary
    /// content, and "actually"/"I mean" as emphasis still lower the floor — the
    /// floor only widens what is ADMITTED, it never forces a rewrite.
    func testOrdinaryContentKeepsTheStrictFloor() {
        for raw in [
            "There's no rush on this one at all.",
            "No, I don't think that's going to work for us.",
            "We have no idea what happened to the build.",
            "The meeting is confirmed for Tuesday at 3 PM.",
        ] {
            XCTAssertEqual(CleanupLogic.minRatio(forRaw: raw), CleanupLogic.minRatio, raw)
        }
    }

    /// A doubled "no" IS a correction marker; a single one is not.
    func testDoubledNoIsACorrectionMarkerButASingleNoIsNot() {
        XCTAssertEqual(CleanupLogic.minRatio(forRaw: "Bananas. No, no, oranges."),
                       CleanupLogic.minRatioCorrection)
        XCTAssertEqual(CleanupLogic.minRatio(forRaw: "Bananas. No no oranges."),
                       CleanupLogic.minRatioCorrection)
        XCTAssertEqual(CleanupLogic.minRatio(forRaw: "No, oranges are what we need here."),
                       CleanupLogic.minRatio)
    }

    /// The relaxed floor is a floor, not a licence: an output that collapses to
    /// nearly nothing is still rejected even with a marker present.
    func testTheRelaxedFloorStillRejectsATotalCollapse() {
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually.",
            cleaned: "Fri"))
    }

    /// Ordinary over-trimming on a raw with no marker is unaffected.
    func testTheStrictFloorStillAppliesWithoutAMarker() {
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "The meeting is confirmed for Tuesday at 3 PM in the main room.",
            cleaned: "Tuesday."))
    }

    // MARK: - runCleanup

    final class FakeEngine: CleanupCleaning {
        struct Boom: Error {}
        let result: String?
        let throws_: Bool
        var calls: [(text: String, style: String, timeoutS: Double)] = []

        init(result: String? = nil, throws throws_: Bool = false) {
            self.result = result
            self.throws_ = throws_
        }

        func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
            calls.append((text, style, timeoutS))
            if throws_ { throw Boom() }
            return result
        }
    }

    func testRunCleanupOk() async {
        let engine = FakeEngine(result: "The meeting is on Friday.")
        let (out, status) = await runCleanup(
            engine, text: "um the meeting is on tuesday wait no friday", style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, "The meeting is on Friday.")
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(engine.calls.count, 1)
        XCTAssertEqual(engine.calls[0].text, "um the meeting is on tuesday wait no friday")
        XCTAssertEqual(engine.calls[0].style, "polish")
        XCTAssertEqual(engine.calls[0].timeoutS, 3.0)
    }

    func testRunCleanupTimeoutFallsBackToRaw() async {
        let (out, status) = await runCleanup(FakeEngine(result: nil), text: raw, style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .timeout)
    }

    func testRunCleanupErrorFallsBackToRaw() async {
        let (out, status) = await runCleanup(
            FakeEngine(throws: true), text: raw, style: "light", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .error)
    }

    func testRunCleanupRejectedFallsBackToRaw() async {
        let engine = FakeEngine(result: "<think>let me reason</think>")
        let (out, status) = await runCleanup(engine, text: raw, style: "polish", timeoutS: 3.0)
        XCTAssertEqual(out, raw)
        XCTAssertEqual(status, .rejected)
    }

    // MARK: - commonPrefixLen

    func testCommonPrefixLenDiverging() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2, 4]), 2)
    }

    func testCommonPrefixLenIdentical() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2, 3]), 3)
    }

    func testCommonPrefixLenOneIsPrefixOfOther() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([1, 2, 3], [1, 2]), 2)
    }

    func testCommonPrefixLenEmpty() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([], [1, 2]), 0)
    }

    func testCommonPrefixLenNoOverlap() {
        XCTAssertEqual(CleanupLogic.commonPrefixLen([9], [1]), 0)
    }

    // MARK: - self-correction coverage

    func testCorrectionRuleCoversCountRevisions() {
        let rules = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertTrue(rules.contains("wait no"))
        XCTAssertTrue(rules.contains("number, or count"))
    }

    func testFewShotIncludesCountRevisionExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        XCTAssertTrue(pairs.contains { $0.0.contains("four options wait no five") })
    }

    // MARK: - spoken list commands

    func testListRulePresentInBothStyles() {
        for style in ["light", "polish"] {
            let rules = CleanupLogic.buildMessages(text: "x", style: style)[0].content.lowercased()
            XCTAssertTrue(rules.contains("make a list"))
            XCTAssertTrue(rules.contains("list down"))
            XCTAssertTrue(rules.contains("bulleted"))
        }
    }

    func testFewShotIncludesListExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        let example = pairs.first { $0.0.contains("make a list") }?.1
        XCTAssertNotNil(example)
        // the modelled answer is a real bulleted list, one "- " item per line
        let bullets = (example ?? "").split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        XCTAssertGreaterThanOrEqual(bullets, 3)
    }

    // MARK: - substituted / answered outputs (on-device regressions, 2026-07-16)

    func testRejectAnsweredQuestion() {
        // "Should I test manually one by one?" pasted as "Yes, test manually
        // one by one." — the model answered the question instead of cleaning it.
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "Should I test manually one by one?",
            cleaned: "Yes, test manually one by one."))
    }

    func testAcceptQuestionCleanedAsQuestion() {
        XCTAssertEqual(
            CleanupLogic.acceptOutput(
                raw: "um should I test manually one by one?",
                cleaned: "Should I test manually one by one?"),
            "Should I test manually one by one?")
    }

    func testAcceptQuestionMarkMovedButKept() {
        // Cleanup may restructure punctuation as long as the question survives.
        XCTAssertNotNil(CleanupLogic.acceptOutput(
            raw: "is it done? the build done?", cleaned: "Is it done? The build done?"))
    }

    func testRejectShortRawSubstitution() {
        // "Go ahead." pasted as "Okay." — a full rewrite sharing no words with
        // what was spoken. Short raws skip the length floor, so without a
        // word-overlap check they had no guard at all.
        XCTAssertNil(CleanupLogic.acceptOutput(raw: "Go ahead.", cleaned: "Okay."))
    }

    func testAcceptShortRawSharingAWord() {
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: "go ahead", cleaned: "Go ahead."), "Go ahead.")
    }

    func testAcceptShortRawFillerRemoved() {
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: "um yes", cleaned: "Yes."), "Yes.")
    }

    func testFewShotIncludesQuestionPassthroughExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        // at least one modelled answer keeps a spoken question a question
        XCTAssertTrue(pairs.contains { $0.1.hasSuffix("?") })
    }

    func testFewShotListExamplesVaryHeader() {
        // Two list examples with different headers, so the model derives the
        // header from the input instead of parroting a single example's
        // ("Things to pack:" showed up on a dictated shopping list on-device).
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        let headers = Set(pairs.compactMap { pair -> String? in
            let lines = pair.1.split(separator: "\n")
            guard lines.contains(where: { $0.hasPrefix("- ") }) else { return nil }
            return lines.first.map(String.init)
        })
        XCTAssertGreaterThanOrEqual(headers.count, 2)
    }

    func testRejectUnrequestedBullets() {
        // With two list few-shots in the prompt the model started bulleting tiny
        // non-list inputs ("Go ahead." -> "- Go ahead."). Bullets are only valid
        // when the speaker asked for a list — and every trigger phrase the prompt
        // names contains "list" or "bullet".
        XCTAssertNil(CleanupLogic.acceptOutput(raw: "Go ahead.", cleaned: "- Go ahead."))
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "we need mangoes and grapes", cleaned: "- Mangoes\n- Grapes"))
    }

    func testAcceptRequestedBullets() {
        XCTAssertEqual(
            CleanupLogic.acceptOutput(
                raw: "make a list of groceries mangoes and grapes", cleaned: "- Mangoes\n- Grapes"),
            "- Mangoes\n- Grapes")
        XCTAssertNotNil(CleanupLogic.acceptOutput(
            raw: "let's create a shopping list mangoes oranges avocados",
            cleaned: "Shopping list:\n- Mangoes\n- Oranges\n- Avocados"))
    }

    // MARK: - assistant-mode breakout (rc.1 on-device regressions, 2026-07-17)

    func testRejectEchoedInputWithCommentary() {
        // rc.1: dictating ABOUT the cleanup rules made the model paste the
        // input back wrapped in analysis. On a long raw the 2x+20 length bound
        // cannot catch this (generation is capped at ~2x the input, so
        // echo+commentary always fits under it); a legit cleanup never
        // contains the raw verbatim PLUS substantial extra.
        let raw = "The above are the text that I just put in. In one case, I saw the a "
            + "being there, as and ums are supposed to be removed, and then uh there "
            + "is one more thing. The list, it is not being actually displayed as a "
            + "list, like one, two, three. This is with the R C build, by the way."
        let out = "The text you provided is:\n\n\"" + raw + "\"\n\n"
            + "Filler words are removed only when they are disfluencies."
        XCTAssertLessThanOrEqual(out.count, 2 * raw.count + 20)  // length bound provably blind
        XCTAssertNil(CleanupLogic.acceptOutput(raw: raw, cleaned: out))
    }

    func testAcceptPassthroughAndTinyPunctuationAdditions() {
        let raw = "this is with the R C build by the way"
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: raw, cleaned: raw), raw)
        XCTAssertEqual(CleanupLogic.acceptOutput(raw: "is it done", cleaned: "Is it done."), "Is it done.")
    }

    func testRejectMarkdownHeaders() {
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "tell me why the list is not showing up here today",
            cleaned: "### Analysis:\nThe list did not trigger."))
    }

    func testRejectNumberedBulletsWithoutListRequest() {
        XCTAssertNil(CleanupLogic.acceptOutput(
            raw: "we need mangoes and also grapes for the week", cleaned: "1. Mangoes\n2. Grapes"))
    }

    func testAcceptNumberedListOnRequest() {
        XCTAssertNotNil(CleanupLogic.acceptOutput(
            raw: "here's a list of to dos one get groceries two go to walmart",
            cleaned: "To dos:\n1. Get groceries\n2. Go to Walmart"))
    }

    // MARK: - list coverage (rc.1: announcements + numbered enumerations)

    func testListRuleCoversNumberedEnumerations() {
        let rules = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertTrue(rules.contains("1.") || rules.contains("numbered"))
    }

    func testFewShotIncludesNumberedListExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        XCTAssertTrue(pairs.contains { pair in
            pair.1.split(separator: "\n").contains { $0.hasPrefix("1. ") }
        })
    }

    func testFewShotIncludesAnnouncementListExample() {
        let msgs = CleanupLogic.buildMessages(text: "x", style: "polish")
        var pairs: [(String, String)] = []
        var i = 1
        while i < msgs.count - 1 {
            pairs.append((msgs[i].content, msgs[i + 1].content))
            i += 2
        }
        XCTAssertTrue(pairs.contains { $0.0.contains("we have a shopping list") })
    }

    func testRulesSayNeverDiscussTheRules() {
        let rules = CleanupLogic.buildMessages(text: "x", style: "polish")[0].content.lowercased()
        XCTAssertTrue(rules.contains("never reply") || rules.contains("never respond"))
    }
}
