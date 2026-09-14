import XCTest

@testable import Pomvox

/// The gate for speculative decoding, in the spirit of
/// `CleanupPrefixCacheDifferentialTests`: the fast loop is admissible only
/// if it produces the SAME TEXT as plain greedy decoding, character for
/// character, on the real model.
///
/// Two comparisons, because two things could go wrong:
///
/// 1. `greedyLoop` vs `library` — `SpeculativeDecoder` with drafting off is a
///    re-implementation of one-token-per-pass greedy decoding against the plain
///    forward pass. If it differs from `MLXLMCommon.generate` (EOS handling,
///    detokenization, the prefill), the loop is wrong before speculation even
///    starts.
/// 2. `speculative` vs `greedyLoop` — snapshot + replay must leave the hybrid
///    model's caches (attention K/V AND the recurrent states) exactly where a
///    step-wise decode would have left them. A drift there does not throw; it
///    changes text. Only this comparison sees it.
///
/// The speculative run must also show drafts being ACCEPTED, so the test cannot
/// pass by comparing plain against plain.
///
/// Skipped unless POMVOX_E2E=1 — it loads ~2 GB and generates three times:
///   TEST_RUNNER_POMVOX_E2E=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
///     -destination 'platform=macOS' \
///     -only-testing:PomvoxTests/CleanupSpeculativeDifferentialTests
final class CleanupSpeculativeDifferentialTests: XCTestCase {

    /// The prefix-cache differential's transcripts plus a long ramble — the
    /// case speculation exists for, and the one with the most rounds for a
    /// state drift to compound over.
    static let transcripts: [String] = CleanupPrefixCacheDifferentialTests.transcripts + [
        "so um i wanted to walk you through the plan uh first we do the research then um "
            + "we build a prototype and uh after that you know we test it with users and then um "
            + "based on the feedback we iterate and uh finally we ship it maybe by end of quarter "
            + "i hope",
        "I want you to understand as much as possible whatever it takes the state of the art "
            + "way to improve the performance of this one. First come up with a plan, it should "
            + "be super fast. I don't know where the problem is, where it is the issue. The "
            + "cleanup should be super, super fast. So, think of the best way, and also that I "
            + "see that the formatting of the formatting, as in like the response formatting, is "
            + "not happening.",
        "number one fix the login bug number two update the docs number three ship it on friday",
    ]

    private func prepared(_ decoding: CleanupDecoding) async throws -> CleanupEngine {
        let engine = CleanupEngine(decoding: decoding)
        let outcome = await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        if case .failed(let reason) = outcome {
            throw XCTSkip("prepare failed: \(reason)")
        }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "model should be resident")
        return engine
    }

    private struct Run {
        var outputs: [String] = []
        var times: [Double] = []
        var stats: [CleanupGenStats] = []
        var p50: Double { times.sorted()[times.count / 2] }
    }

    private func run(_ decoding: CleanupDecoding) async throws -> Run {
        let engine = try await prepared(decoding)
        var r = Run()
        for text in Self.transcripts {
            let t = CFAbsoluteTimeGetCurrent()
            let out = try await engine.clean(text, style: "polish", timeoutS: 60)
            r.times.append(CFAbsoluteTimeGetCurrent() - t)
            r.outputs.append(out ?? "<nil>")
            if let s = await engine.lastGenStats { r.stats.append(s) }
        }
        await engine.unload()
        return r
    }

    private func diff(_ a: Run, _ b: Run, _ aName: String, _ bName: String) -> [String] {
        var out: [String] = []
        for (i, text) in Self.transcripts.enumerated() where a.outputs[i] != b.outputs[i] {
            out.append(
                """
                [\(i)] \(text)
                    \(aName): \(a.outputs[i])
                    \(bName): \(b.outputs[i])
                """)
        }
        return out
    }

    func testSpeculativeMatchesGreedyMatchesLibrary() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_E2E"] == "1",
            "set TEST_RUNNER_POMVOX_E2E=1 to run the speculative-decoding differential")

        let modelID = MemoryTier.standardCleanupModel
        XCTAssertTrue(
            CleanupPromptProfile.forModel(modelID).usesSpeculativeDecoding,
            "this test is meaningless unless the shipped default actually speculates")

        // Reference first, so a failure reads as "the new loop changed it".
        let library = try await run(.library)
        let greedy = try await run(.greedyLoop)
        let spec = try await run(.speculative)

        let loopMismatches = diff(library, greedy, "library", "greedy")
        XCTAssertTrue(
            loopMismatches.isEmpty,
            "the greedy loop differs from MLXLMCommon.generate on \(loopMismatches.count) of "
                + "\(Self.transcripts.count) transcripts:\n" + loopMismatches.joined(separator: "\n"))

        let specMismatches = diff(greedy, spec, "greedy", "speculative")
        XCTAssertTrue(
            specMismatches.isEmpty,
            "speculative decoding CHANGED the output on \(specMismatches.count) of "
                + "\(Self.transcripts.count) transcripts — snapshot+replay is not sound for this "
                + "model, and usesSpeculativeDecoding must go back to false:\n"
                + specMismatches.joined(separator: "\n"))

        let drafted = spec.stats.map(\.specDrafted).reduce(0, +)
        let accepted = spec.stats.map(\.specAccepted).reduce(0, +)
        XCTAssertGreaterThan(
            accepted, 0,
            "no draft was ever accepted — the comparison above proved nothing about speculation")

        print(
            String(
                format: "SPEC-DIFF: %d transcripts | library p50 %.2fs | greedy p50 %.2fs | "
                    + "speculative p50 %.2fs (%.2fx) | drafts accepted %d/%d (%.0f%%)",
                Self.transcripts.count, library.p50, greedy.p50, spec.p50,
                greedy.p50 / max(spec.p50, 0.0001), accepted, drafted,
                drafted > 0 ? 100 * Double(accepted) / Double(drafted) : 0))
        for (i, s) in spec.stats.enumerated() {
            print(
                String(
                    format: "SPEC-DIFF [%d] %.2fs greedy → %.2fs spec | decode %d tok | "
                        + "accepted %d/%d in %d rounds",
                    i, greedy.times[i], spec.times[i], s.decodeTokens, s.specAccepted,
                    s.specDrafted, s.specRounds))
        }
        if spec.p50 >= greedy.p50 {
            print(
                String(
                    format: "SPEC-DIFF WARNING: speculative p50 %.2fs is not faster than greedy "
                        + "%.2fs", spec.p50, greedy.p50))
        }
    }
}
