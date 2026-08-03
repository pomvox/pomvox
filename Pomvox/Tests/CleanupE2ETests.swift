import XCTest

@testable import Pomvox

/// End-to-end cleanup verification against the REAL default model, through the
/// REAL production path: `CleanupEngine.prepare` → `runCleanup` → `acceptOutput`.
/// This is everything downstream of the microphone — the transcripts below stand
/// in for what Parakeet hands the cleanup stage.
///
/// Skipped unless POMVOX_E2E=1 — it downloads/loads ~2 GB:
///   TEST_RUNNER_POMVOX_E2E=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
///     -destination 'platform=macOS' -only-testing:PomvoxTests/CleanupE2ETests
final class CleanupE2ETests: XCTestCase {

    /// One case: what was "said", and what must (or must not) survive cleanup.
    /// `mustDrop` entries are checked as whole words so "Tuesday" doesn't match
    /// inside another token.
    struct Case {
        let name: String
        let raw: String
        let mustKeep: [String]
        let mustDrop: [String]
        /// nil = either outcome is legitimate; true/false = the guard verdict
        /// this case is asserting.
        let expectAccepted: Bool?
        /// Non-nil = a gap the shipped model is known to have, documented on its
        /// model card and accepted as a trade. Reported in the run output —
        /// including when it starts passing — but never failed, so the suite
        /// tracks the gap instead of going permanently red on it.
        /// (`var` so the memberwise init carries it with a default — Swift omits
        /// a defaulted `let` from that init entirely.)
        var knownGap: String? = nil
    }

    static let cases: [Case] = [
        Case(name: "gate: day self-correction",
             raw: "let's meet on tuesday wait no friday at noon",
             mustKeep: ["friday", "noon"], mustDrop: ["tuesday"], expectAccepted: true),
        Case(name: "gate: count self-correction",
             raw: "so there are four options wait no five options to consider",
             mustKeep: ["five"], mustDrop: ["four"], expectAccepted: true),
        // The one row v3 regressed against v2 (43/44 vs 44/44 on the intra-sentence
        // set). A chained TRIPLE correction in lowercase unpunctuated form comes
        // back unchanged. It was anti-correlated with the cross-sentence gate across
        // all 30 training checkpoints — every checkpoint that passed this one failed
        // the cross-sentence cases that caused the real user-visible bug — so it was
        // traded away deliberately. Single corrections (the two cases above) are
        // unaffected.
        Case(name: "gate: triple self-correction",
             raw: "i'll take the red one no the blue one actually the green one",
             mustKeep: ["green"], mustDrop: ["red", "blue"], expectAccepted: true,
             knownGap: "v3 reg_003: chained triple correction returns unchanged"),
        Case(name: "gate: narrowing is NOT a correction",
             raw: "send it tuesday i mean before noon",
             mustKeep: ["tuesday", "noon"], mustDrop: [], expectAccepted: true),
        Case(name: "filler removal",
             raw: "um so i think we should uh probably ship it tomorrow",
             mustKeep: ["ship", "tomorrow"], mustDrop: ["um", "uh"], expectAccepted: true),
        Case(name: "question stays a question",
             raw: "um should i test manually one by one",
             mustKeep: ["test"], mustDrop: ["um"], expectAccepted: true),
        Case(name: "meaning-bearing 'like' survives",
             raw: "honestly it works like a charm and it's like really really fast",
             mustKeep: ["charm"], mustDrop: [], expectAccepted: true),
        Case(name: "casual register preserved",
             raw: "yeah nah i dunno man it's like whatever honestly",
             mustKeep: ["dunno"], mustDrop: [], expectAccepted: true),
        Case(name: "numbers survive",
             raw: "we sold uh like twenty five hundred units last month up from um two thousand",
             mustKeep: ["two thousand"], mustDrop: ["uh"], expectAccepted: true),
        Case(name: "already clean, leave alone",
             raw: "The meeting is confirmed for Tuesday at 3 PM in the main conference room.",
             mustKeep: ["conference room"], mustDrop: [], expectAccepted: true),
        Case(name: "list only when asked",
             raw: "let's make a list of things to pack shirts socks toothbrush and a charger",
             mustKeep: ["shirts", "charger"], mustDrop: [], expectAccepted: true),
        Case(name: "no list without the trigger",
             raw: "so first we grab coffee then we drive to the office then we start the meeting",
             mustKeep: ["coffee"], mustDrop: [], expectAccepted: true),
        Case(name: "long ramble stays intact",
             raw: "okay so basically what happened was we went to the meeting and then uh the "
                + "client said they wanted changes and um so we're gonna have to redo the whole "
                + "thing by friday i think",
             mustKeep: ["client", "friday", "gonna"], mustDrop: ["um"], expectAccepted: true),
        Case(name: "stutter repair",
             raw: "i i i just wanted to to say that that the the report is is ready",
             mustKeep: ["report", "ready"], mustDrop: [], expectAccepted: true),
        Case(name: "short input survives the guards",
             raw: "go ahead",
             mustKeep: ["go ahead"], mustDrop: [], expectAccepted: true),
        // Not asserted either way: the model is known to over-trim near-empty
        // filler, and acceptOutput correctly rejects it → raw pastes. Recorded
        // so the report shows which way it went.
        Case(name: "near-empty filler (guard may reject)",
             raw: "um uh so yeah like you know",
             mustKeep: [], mustDrop: [], expectAccepted: nil),

        // MARK: - Cross-sentence self-correction (the five v3 shipped for)
        //
        // The correction lands in a LATER sentence than the thing it supersedes.
        // Every correction case above is intra-sentence, which is why this class
        // of failure survived the v2 ship gate and reached users: v2 kept the
        // superseded clause and pasted the wrong day. Case 1 is additionally the
        // one the length floor gates — the correct output is ratio 0.277 against
        // a flat 0.30 floor, so before the correction-aware floor it pasted raw
        // disfluent text even once the model got it right.
        Case(name: "cross: thursday→friday (no no wait)",
             raw: "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually.",
             mustKeep: ["Friday"], mustDrop: ["Thursday"], expectAccepted: true),
        Case(name: "cross: thursday→friday (no,)",
             raw: "Let's schedule a meeting for this Thursday. No, Friday at noon.",
             mustKeep: ["Friday", "noon"], mustDrop: ["Thursday"], expectAccepted: true),
        Case(name: "cross: thursday→friday (no no no)",
             raw: "Let's schedule a meeting for this Thursday. No, no, no. Friday at noon.",
             mustKeep: ["Friday", "noon"], mustDrop: ["Thursday"], expectAccepted: true),
        // "list" is in the raw, so the list guard permits bullets here.
        Case(name: "cross: mangoes→oranges (in a list)",
             raw: "Let's do uh a shopping list. Uh we'll get bananas, apples and mangoes."
                + " No, no, oranges.",
             mustKeep: ["Oranges", "Bananas", "Apples"], mustDrop: ["mangoes"],
             expectAccepted: true),
        // Friday must SURVIVE here — "not Friday" is part of the correction, but
        // the earlier "Can we meet on Friday?" is the question being answered.
        Case(name: "cross: friday→thursday (or actually)",
             raw: "Hi, how are you doing? Can we meet on Friday? Or actually, let's do"
                + " Thursday, not Friday.",
             mustKeep: ["Thursday"], mustDrop: [], expectAccepted: true),

        // MARK: - The model must not INVENT a correction
        //
        // The counterweight to the relaxed floor: a marker present in the raw
        // lowers the length floor, so these confirm the model does not then treat
        // ordinary speech as a correction and delete a clause.
        Case(name: "negative: 'I mean' adds, it does not replace",
             raw: "We need 4 chairs. I mean an extension cord.",
             mustKeep: ["4 chairs", "extension cord"], mustDrop: [], expectAccepted: true),
        Case(name: "negative: 'actually' as emphasis is not a correction",
             raw: "That's you know actually fine.",
             mustKeep: ["actually", "fine"], mustDrop: ["you know"], expectAccepted: true),
    ]

    private func containsWord(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    func testCleanupEndToEndAgainstTheShippedDefault() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_E2E"] == "1",
            "set TEST_RUNNER_POMVOX_E2E=1 to run the end-to-end cleanup check")

        let modelID = MemoryTier.standardCleanupModel
        print("E2E: model = \(modelID)")
        XCTAssertEqual(CleanupPromptProfile.forModel(modelID), .simpleWords,
                       "the shipped default must route through the frozen-prompt path")

        let engine = CleanupEngine()
        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = await engine.prepare(modelID: modelID)
        if case .failed(let reason) = outcome { return XCTFail("prepare failed: \(reason)") }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "model should be resident")
        print(String(format: "E2E: prepare %.1fs", CFAbsoluteTimeGetCurrent() - t0))

        var failures: [String] = []
        var latencies: [Double] = []

        for c in Self.cases {
            let t = CFAbsoluteTimeGetCurrent()
            // The real production entry point: guards included, raw on any failure.
            let (out, status) = await runCleanup(
                engine, text: c.raw, style: "polish", timeoutS: 12.5)
            let dt = CFAbsoluteTimeGetCurrent() - t
            latencies.append(dt)
            let accepted = (status == .ok)

            print("\nE2E [\(c.name)]  \(String(format: "%.2fs", dt))  status=\(status.rawValue)")
            print("  raw: \(c.raw)")
            print("  out: \(out)")

            // Collect this case's complaints first, then decide whether they are
            // failures or just a report — a known gap must not go red.
            var problems: [String] = []
            if let want = c.expectAccepted, want != accepted {
                problems.append("expected accepted=\(want), got status=\(status.rawValue)")
            } else if accepted {  // raw pasted; word checks don't apply
                for w in c.mustKeep where !containsWord(out, w) { problems.append("lost \"\(w)\"") }
                for w in c.mustDrop where containsWord(out, w) { problems.append("kept \"\(w)\"") }
            }

            if let gap = c.knownGap {
                print("  KNOWN GAP [\(gap)]: "
                    + (problems.isEmpty
                        ? "now PASSING — re-measure and consider promoting to an assertion"
                        : problems.joined(separator: "; ")))
                continue
            }
            for p in problems { failures.append("\(c.name): \(p) → \(out)") }
        }

        latencies.sort()
        print(String(format: "\nE2E SUMMARY: %d cases, %d failures, p50 %.2fs, max %.2fs",
                     Self.cases.count, failures.count,
                     latencies[latencies.count / 2], latencies.last ?? 0))
        for f in failures { print("  FAIL \(f)") }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) case(s) failed:\n" + failures.joined(separator: "\n"))
    }
}
