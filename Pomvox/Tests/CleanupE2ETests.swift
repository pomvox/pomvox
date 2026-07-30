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
    }

    static let cases: [Case] = [
        Case(name: "gate: day self-correction",
             raw: "let's meet on tuesday wait no friday at noon",
             mustKeep: ["friday", "noon"], mustDrop: ["tuesday"], expectAccepted: true),
        Case(name: "gate: count self-correction",
             raw: "so there are four options wait no five options to consider",
             mustKeep: ["five"], mustDrop: ["four"], expectAccepted: true),
        Case(name: "gate: triple self-correction",
             raw: "i'll take the red one no the blue one actually the green one",
             mustKeep: ["green"], mustDrop: ["red", "blue"], expectAccepted: true),
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

            if let want = c.expectAccepted, want != accepted {
                failures.append("\(c.name): expected accepted=\(want), got status=\(status.rawValue)")
                continue
            }
            guard accepted else { continue }  // raw pasted; word checks don't apply

            for w in c.mustKeep where !containsWord(out, w) {
                failures.append("\(c.name): lost \"\(w)\" → \(out)")
            }
            for w in c.mustDrop where containsWord(out, w) {
                failures.append("\(c.name): kept \"\(w)\" → \(out)")
            }
        }

        latencies.sort()
        print(String(format: "\nE2E SUMMARY: %d cases, %d failures, p50 %.2fs, max %.2fs",
                     Self.cases.count, failures.count,
                     latencies[latencies.count / 2], latencies.last ?? 0))
        for f in failures { print("  FAIL \(f)") }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) case(s) failed:\n" + failures.joined(separator: "\n"))
    }
}
