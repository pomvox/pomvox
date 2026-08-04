import XCTest

@testable import Pomvox

/// The gate for the prompt-prefix KV cache on a HYBRID model.
///
/// Reusing a prefilled prefix is only sound if the cache the model carries out
/// of a bulk read is the same state it would have had reading one token at a
/// time. For a full-attention layer that is near-tautological — the cache is a
/// per-token transcript either way. For a linear-attention (Mamba) layer it is
/// a real claim: the layer holds a running recurrence, and MLX may reach that
/// recurrence by a chunked scan during prefill and a step-wise update during
/// decode. If those two disagree even slightly, nothing throws. The model just
/// produces *different text* — silently, plausibly, and only sometimes.
///
/// No correctness assertion catches that, because both answers look fine. Only
/// a side-by-side comparison does. So this runs the same transcripts through
/// the same model twice, once with the cache and once without, and demands the
/// output match character-for-character.
///
/// If this test ever fails, the prefix cache is unsound for the model in
/// question and `CleanupPromptProfile.usesPrefixCache` must go back to `false`
/// for it. "Still reads correctly" is NOT the bar — divergence at all means the
/// cached path is not the path we validated the model on.
///
/// Skipped unless POMVOX_E2E=1 — it loads ~2 GB and generates twice:
///   TEST_RUNNER_POMVOX_E2E=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
///     -destination 'platform=macOS' \
///     -only-testing:PomvoxTests/CleanupPrefixCacheDifferentialTests
final class CleanupPrefixCacheDifferentialTests: XCTestCase {

    /// Transcripts chosen to stress the cases where a drifting recurrent state
    /// would show up first: long inputs (more decode steps for drift to
    /// compound over), self-corrections (the behaviour v3 exists for, and the
    /// one most sensitive to the model's read of earlier context), and list
    /// formatting (structured output where one wrong token derails the shape).
    static let transcripts: [String] = [
        "let's meet on tuesday wait no friday at noon",
        "so there are four options wait no five options to consider",
        "Let's meet Thursday. No, no, wait, uh we'll meet Friday actually.",
        "Let's schedule a meeting for this Thursday. No, no, no. Friday at noon.",
        "Let's do uh a shopping list. Uh we'll get bananas, apples and mangoes."
            + " No, no, oranges.",
        "Hi, how are you doing? Can we meet on Friday? Or actually, let's do"
            + " Thursday, not Friday.",
        "um so i think we should uh probably ship it tomorrow",
        "okay so basically what happened was we went to the meeting and then uh the "
            + "client said they wanted changes and um so we're gonna have to redo the whole "
            + "thing by friday i think",
        "we sold uh like twenty five hundred units last month up from um two thousand",
        "The meeting is confirmed for Tuesday at 3 PM in the main conference room.",
        "let's make a list of things to pack shirts socks toothbrush and a charger",
        "i i i just wanted to to say that that the the report is is ready",
        "go ahead",
    ]

    private func prepared(prefixCacheDisabled: Bool) async throws -> CleanupEngine {
        let engine = CleanupEngine(prefixCacheDisabled: prefixCacheDisabled)
        let outcome = await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        if case .failed(let reason) = outcome {
            throw XCTSkip("prepare failed: \(reason)")
        }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "model should be resident")
        return engine
    }

    func testCachedAndUncachedProduceIdenticalText() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_E2E"] == "1",
            "set TEST_RUNNER_POMVOX_E2E=1 to run the prefix-cache differential")

        let modelID = MemoryTier.standardCleanupModel
        XCTAssertTrue(
            CleanupPromptProfile.forModel(modelID).usesPrefixCache,
            "this test is meaningless unless the shipped default actually caches")

        // Two engines, same model, same prompts — one allowed to cache, one not.
        // Uncached runs first so a failure reads as "caching changed it", not
        // "the model is nondeterministic".
        let uncached = try await prepared(prefixCacheDisabled: true)
        var reference: [String] = []
        var uncachedTimes: [Double] = []
        for text in Self.transcripts {
            let t = CFAbsoluteTimeGetCurrent()
            let out = try await uncached.clean(text, style: "polish", timeoutS: 30)
            uncachedTimes.append(CFAbsoluteTimeGetCurrent() - t)
            reference.append(out ?? "<nil>")
        }
        await uncached.unload()

        let cached = try await prepared(prefixCacheDisabled: false)
        let cacheEngaged = await cached.hasPrefixCache
        XCTAssertTrue(
            cacheEngaged,
            "the prefix cache never built — this run would silently compare uncached "
                + "against uncached and pass for the wrong reason")

        var mismatches: [String] = []
        var cachedTimes: [Double] = []
        for (i, text) in Self.transcripts.enumerated() {
            let t = CFAbsoluteTimeGetCurrent()
            let out = try await cached.clean(text, style: "polish", timeoutS: 30)
            cachedTimes.append(CFAbsoluteTimeGetCurrent() - t)
            let got = out ?? "<nil>"
            if got != reference[i] {
                mismatches.append(
                    """
                    [\(i)] \(text)
                        uncached: \(reference[i])
                        cached:   \(got)
                    """)
            }
        }
        await cached.unload()

        let uMed = uncachedTimes.sorted()[uncachedTimes.count / 2]
        let cMed = cachedTimes.sorted()[cachedTimes.count / 2]
        print(
            String(
                format: "PREFIX-DIFF: %d transcripts | uncached p50 %.2fs | cached p50 %.2fs "
                    + "| speedup %.2fx",
                Self.transcripts.count, uMed, cMed, uMed / max(cMed, 0.0001)))

        XCTAssertTrue(
            mismatches.isEmpty,
            "the prefix cache CHANGED the output on \(mismatches.count) of "
                + "\(Self.transcripts.count) transcripts — it is not sound for this model, "
                + "and usesPrefixCache must go back to false:\n"
                + mismatches.joined(separator: "\n"))

        // Not a hard perf gate (CI hardware varies), but a cache that saves
        // nothing is a bug worth seeing in the log rather than a silent no-op.
        if cMed >= uMed {
            print(
                String(
                    format: "PREFIX-DIFF WARNING: cached p50 %.2fs is not faster than "
                        + "uncached %.2fs", cMed, uMed))
        }
    }
}
