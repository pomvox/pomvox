import XCTest

@testable import Pomvox

/// The M0 `pomvox-bench-llm` benchmark, relocated inside the Xcode app target —
/// mlx-swift's default.metallib is an Xcode build-phase artifact, so this is
/// the supported home for cleanup inference (docs/native-swift-path.md,
/// "Toolchain & packaging").
///
/// `testBenchAgainstPythonGate` benchmarks `MemoryTier.standardCleanupModel`
/// (whatever ships as the default), not a fixed reference model — the
/// 2026-09-02 v2-vs-v3 comparison on this machine (short/medium/long
/// fixtures, warm prefix cache, 3 runs each) found the two models
/// indistinguishable on speed: v2 0.66-0.71 / 1.47-1.53 / 3.23-3.33 s vs v3
/// 0.66-0.67 / 1.45-1.51 / 3.27-3.34 s. A regression here is model-speed, not
/// model-*choice*. It won't reproduce idle-eviction or dictionary-hint
/// re-prefill costs, which real usage shows dominate (see the other three
/// tests below).
///
/// Skipped unless POMVOX_LLM_BENCH=1 — it loads the real ~2.3 GB model:
///   TEST_RUNNER_POMVOX_LLM_BENCH=1 DEVELOPER_DIR=... xcodebuild test ... \
///     -only-testing:PomvoxTests/CleanupBenchTests
final class CleanupBenchTests: XCTestCase {

    /// The make-fixtures.sh utterances — the same texts the Python baseline's
    /// STT step feeds its cleanup pass (transcripts are near-perfect on the
    /// synthetic voice, so the prompt workload matches).
    static let fixtures: [(name: String, text: String)] = [
        (
            "short_3s",
            "let's meet on Tuesday, wait no, Friday at two pm to review the draft"
        ),
        (
            "medium_8s",
            "um so the three things are uh first do the thing wait no two things "
                + "first do the thing and second ship it. also remind me to email the team about "
                + "the quarterly numbers before the end of the week"
        ),
        (
            "long_15s",
            "okay so here's the plan for the pomvox project. first we benchmark "
                + "the new speech model on the neural engine and compare it against the current "
                + "pipeline. then if the numbers hold up we port the hotkey state machine and the "
                + "endpoint detector, keeping the python tests as the specification. finally we wire "
                + "up the cleanup model and measure the end to end latency against the budget in "
                + "the spec document"
        ),
    ]

    func testBenchAgainstPythonGate() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM bench")

        let engine = CleanupEngine()
        let t0 = CFAbsoluteTimeGetCurrent()
        await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        let loaded = await engine.isLoaded
        print(String(format: "bench prepare (load+warmup): %.2fs", CFAbsoluteTimeGetCurrent() - t0))
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        for (name, text) in Self.fixtures {
            var times: [String] = []
            var statuses: [CleanupStatus] = []
            var output = ""
            for _ in 0..<3 {
                let t = CFAbsoluteTimeGetCurrent()
                let (out, status) = await runCleanup(engine, text: text, style: "light", timeoutS: 30.0)
                times.append(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - t))
                statuses.append(status)
                output = out
            }
            print("bench clean \(name): \(times)s \(statuses.map(\.rawValue))")
            print("bench output \(name): \(output)")
            XCTAssertTrue(statuses.allSatisfy { $0 == .ok }, "\(name): \(statuses)")
        }
        await engine.unload()
    }

    /// SPEC §5 Phase-3 acceptance, natively: the self-correction utterance must
    /// clean to the SAME output as the Python engine (measured on this machine,
    /// both styles, 2026-06-12 — see the M6 PR), and a forced timeout must
    /// return the raw text untouched (the kill-mid-request criterion: the
    /// deadline abandons generation, runCleanup falls back to raw).
    func testPhase3AcceptanceParityAndTimeoutFallback() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let utterance = "um so the three things are uh first do the thing wait no two things"
            + " first do the thing and second ship it"
        let pythonOutput = "The two things: first, do the thing; second, ship it."

        let engine = CleanupEngine()
        await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit")
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        for style in CleanupLogic.styles {
            let (out, status) = await runCleanup(engine, text: utterance, style: style, timeoutS: 10.0)
            XCTAssertEqual(status, .ok, "style \(style)")
            XCTAssertEqual(out, pythonOutput, "style \(style)")
        }

        let (out, status) = await runCleanup(engine, text: utterance, style: "polish", timeoutS: 0.05)
        XCTAssertEqual(status, .timeout)
        XCTAssertEqual(out, utterance, "a timeout must paste the raw transcript, never lose it")
        await engine.unload()
    }

    /// Regression (on-device history 2026-07-16: 16 of 60 dictations pasted raw,
    /// every one after a >5 min idle gap): a dictation right after idle eviction
    /// must get CLEANED text. Mirrors NativeEngine's ordering exactly — finish()
    /// fires ensureCleanupLoaded (fire-and-forget prepare) and the utterance's
    /// cleanup runs immediately, racing the reload. clean() must wait out the
    /// in-flight load within the utterance deadline, and the prefilled prompt
    /// prefixes must survive eviction so the wait is the ~1 s weight reload,
    /// not a ~10 s re-prefill of both styles.
    func testPostEvictionCleanWaitsForReload() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let engine = CleanupEngine()
        await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit")
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        let text = Self.fixtures[0].text
        let (warm, warmStatus) = await runCleanup(engine, text: text, style: "light", timeoutS: 30.0)
        XCTAssertEqual(warmStatus, .ok)

        await engine.unload()
        // The reload is fire-and-forget, exactly like ensureCleanupLoaded…
        let reload = Task { await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit") }
        // …and this utterance's cleanup races it (12.5 s = the on-device config
        // that still pasted raw; the default 5 s must fit once caches survive).
        let t0 = CFAbsoluteTimeGetCurrent()
        let (out, status) = await runCleanup(engine, text: text, style: "light", timeoutS: 12.5)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        _ = await reload.value
        print(String(format: "bench post-evict clean: %.2fs status=%@", elapsed, status.rawValue))
        XCTAssertEqual(status, .ok, "post-eviction dictation pasted raw (took \(elapsed)s)")
        XCTAssertEqual(out, warm, "greedy decode with the retained prefix must reproduce the warm output")
        XCTAssertLessThan(
            elapsed, 10.0,
            "the reload must reuse the retained prefix caches (~1 s weights), not re-prefill (~10 s)")
        await engine.unload()
    }

    /// Cold LAUNCH (rc.1 regression, distinct from post-eviction): a fresh
    /// process has no retained prefix caches, so the first dictation races the
    /// full prepare() — load + per-style prefill — on the serial GPU queue.
    /// rc.1 burned 12.9 s behind the wrong style's prefill and pasted raw.
    /// With the configured style built first and clean() waiting for exactly
    /// that prefix, the first dictation must fit the on-device 12.5 s budget.
    func testColdLaunchFirstDictationFitsTheBudget() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let engine = CleanupEngine()
        await engine.setPreferredStyle("polish")   // the app's default config
        // Fire-and-forget, exactly like ensureCleanupLoaded on a fresh launch…
        let load = Task { await engine.prepare(modelID: "mlx-community/Qwen3-4B-4bit") }
        // …and the first dictation races the whole cold prepare.
        let text = Self.fixtures[0].text
        let t0 = CFAbsoluteTimeGetCurrent()
        let (out, status) = await runCleanup(engine, text: text, style: "polish", timeoutS: 12.5)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        _ = await load.value
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")
        print(String(format: "bench cold-launch clean: %.2fs status=%@", elapsed, status.rawValue))
        XCTAssertEqual(status, .ok, "cold-launch first dictation pasted raw (took \(elapsed)s)")
        XCTAssertFalse(out.isEmpty)
        await engine.unload()
    }

    /// A transcript around the length that timed out on device (the recorded
    /// failures were 1189–2053 chars). Long enough that no fixed `timeout_s`
    /// the settings slider allows could ever cover it.
    ///
    /// Deliberately NON-repetitive. A first cut repeated one paragraph four
    /// times and cleaned in 4.3 s against a 19.3 s budget — the model
    /// deduplicated it down to a single paragraph, so almost nothing was
    /// decoded. Cost tracks the OUTPUT, and `CleanupDeadline` uses input length
    /// only as its proxy; a fixture whose output collapses measures nothing.
    static let longDictation =
        "okay so the next thing i wanted to walk through is the release checklist because "
        + "we keep forgetting a step. first we tag the build and wait for notarization to "
        + "come back green, then we bump the cask, and only after that do we cut the "
        + "announcement. um and if the appcast is stale the updater silently does nothing, "
        + "which is the failure mode that bit us last time. "
        + "second thing, the dictation history window. right now it opens on the most recent "
        + "entry but there's no way to search it, and once you have a few hundred rows that's "
        + "basically useless, so i think we want a filter box at the top and maybe a date "
        + "grouping in the sidebar. uh not urgent but people have asked twice now. "
        + "third, and this is the one i keep putting off, the onboarding flow still asks for "
        + "microphone access before it explains why it needs it, which is exactly backwards "
        + "and i suspect it's why the drop off between install and first dictation is as bad "
        + "as it is. we should show the one screen explaining the local only bit first. "
        + "and then last thing, someone in the issue tracker pointed out that the menu bar "
        + "icon doesn't change when the engine is disarmed, so you genuinely cannot tell "
        + "whether the app is listening or not without opening the panel. that seems like a "
        + "small fix and a real papercut so let's just do it this week. "
        + "oh and i almost forgot, we still owe the docs a page on the custom dictionary "
        + "because the only explanation of how the variants work lives in a pull request "
        + "description, which nobody is going to find. even a short page with two worked "
        + "examples would be better than what we have. um i can draft that if nobody else "
        + "wants it, it shouldn't take more than an afternoon to write up properly."

    /// The length half of the 2026-09-02 raw-paste defect, on real hardware.
    ///
    /// Pure policy tests (`CleanupDeadlineTests`) pin the shape of the deadline;
    /// only this one can check the throughput constant it rests on. It asserts
    /// both directions: the configured budget genuinely cannot clean a long
    /// transcript (the defect), and the widened one genuinely can (the fix, and
    /// evidence that `CleanupDeadline.throughputCharsPerS` is not optimistic).
    func testLongDictationFitsTheWidenedDeadline() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let engine = CleanupEngine()
        await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")

        let text = Self.longDictation
        let base = 12.5   // the on-device ~/.pomvox/config.toml value that pasted raw
        XCTAssertGreaterThan(text.count, 1100, "fixture must be past the observed timeout floor")

        // The defect, machine-independently: the work provably outruns the
        // configured budget, so the pass could only ever have pasted raw.
        XCTAssertGreaterThan(
            CleanupDeadline.estimateS(chars: text.count), base,
            "fixture no longer reproduces the fixed-budget defect")

        // The fix: the deadline the policy actually hands this transcript, and
        // whether it covers the work on real hardware. (Asserted on elapsed vs
        // the BUDGET, not an absolute number — the manual cleanup-bench CI job
        // runs on a hosted runner with no GPU passthrough.)
        let effective = CleanupDeadline.effectiveTimeoutS(base: base, chars: text.count)
        let t0 = CFAbsoluteTimeGetCurrent()
        let (out, status) = await runCleanup(
            engine, text: text, style: "polish", timeoutS: effective)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        print(
            String(
                format: "bench long clean: %d chars in → %d out, %.2fs (budget %.1fs, %.0f ch/s) %@",
                text.count, out.count, elapsed, effective,
                Double(out.count) / elapsed, status.rawValue))
        XCTAssertEqual(status, .ok, "long dictation still pasted raw (took \(elapsed)s)")
        XCTAssertGreaterThan(
            out.count, text.count / 2,
            "output collapsed — this fixture can't measure decode cost (see longDictation)")
        XCTAssertLessThan(
            elapsed, effective,
            "throughputCharsPerS is optimistic on this hardware — the widened budget is too tight")
        await engine.unload()
    }

    /// Post-eviction on the DEFAULT model, which
    /// `testPostEvictionCleanWaitsForReload` does not cover: it drives the
    /// legacy `Qwen3-4B-4bit` profile, whose two prefix keys make a partial
    /// cache (and so a full re-prefill) possible. The shipped fine-tune is the
    /// frozen profile with exactly ONE key, so production can never take that
    /// path — the retained caches either match or the model changed.
    ///
    /// Asserts cache REUSE rather than elapsed time (which is flaky): after an
    /// evict/reload cycle with a dictionary hint set, `prepare()` must keep the
    /// retained prefix, not rebuild it.
    func testPostEvictionReusesPrefixCachesWithADictionaryHint() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
            "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the cleanup LLM acceptance")

        let engine = CleanupEngine()
        // A non-empty hint across the whole cycle: an empty one matches
        // trivially, which is why the existing post-eviction test cannot catch
        // a hint-keyed invalidation.
        await engine.setTermsHint("Spell these as written: Pomvox, MLX, Parakeet.")
        await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        let loaded = await engine.isLoaded
        try XCTSkipUnless(loaded, "model failed to load — see the cleanup: NSLogs")
        let cachedAfterPrepare = await engine.hasPrefixCache
        XCTAssertTrue(cachedAfterPrepare, "nothing to retain — prefill failed")
        let generationBefore = await engine.generation

        await engine.unload()
        let cachedAfterUnload = await engine.hasPrefixCache
        XCTAssertTrue(cachedAfterUnload, "unload() must retain the prefix caches")

        // Exactly what ensureCleanupLoaded does on the next dictation: re-apply
        // the same hint, then reload.
        await engine.setTermsHint("Spell these as written: Pomvox, MLX, Parakeet.")
        await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        let reloaded = await engine.isLoaded
        let cachedAfterReload = await engine.hasPrefixCache
        let generationAfter = await engine.generation
        XCTAssertTrue(reloaded)
        XCTAssertTrue(cachedAfterReload)
        XCTAssertGreaterThan(generationAfter, generationBefore, "no reload happened")

        let (out, status) = await runCleanup(
            engine, text: Self.fixtures[0].text, style: "polish", timeoutS: 12.5)
        XCTAssertEqual(status, .ok, "post-eviction dictation pasted raw")
        XCTAssertFalse(out.isEmpty)
        await engine.unload()
    }
}
