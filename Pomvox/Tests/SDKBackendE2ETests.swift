import XCTest

@testable import Pomvox

/// The `CleanupE2ETests` corpus, run through the SDK backend instead of the
/// in-app engine, plus a byte-for-byte differential between the two.
///
/// Skipped unless `POMVOX_E2E=1` — it opens the real ~2 GB model:
///   TEST_RUNNER_POMVOX_E2E=1 TEST_RUNNER_POMVOX_CLEANUP_PACK=/path/to/pack \
///   DEVELOPER_DIR=… xcodebuild test … -only-testing:PomvoxTests/SDKBackendE2ETests
///
/// The two engines are never resident at once: the SDK takes a process-wide
/// MLX lease, and two ~2 GB allocations on a 16 GB Mac is how you get a
/// swap-thrashing test run rather than a measurement.
final class SDKBackendE2ETests: XCTestCase {

    static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func requirePack() throws -> URL {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POMVOX_E2E"] == "1",
                          "set TEST_RUNNER_POMVOX_E2E=1 to run the real-model SDK suite")
        let directory = SDKCleanupBackend.defaultPackDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path),
                          "no installed pack at \(directory.path); see docs/cleanup-engine-sdk-integration.md")
        return directory
    }

    private static func openBackend(_ pack: URL, hint: String = "") async throws -> SDKCleanupBackend {
        let backend = SDKCleanupBackend(packDirectory: pack)
        await backend.setTermsHint(hint)
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        guard case .loaded = outcome else {
            XCTFail("SDK backend did not load: \(outcome)")
            throw CleanupBackendFailure.unavailable
        }
        return backend
    }

    // MARK: - Behaviour

    /// Every `CleanupE2ETests` case through the SDK. Same contract: required
    /// words survive, superseded words are gone, and a case marked `knownGap`
    /// is reported rather than failed.
    func testCorpusThroughTheSDKBackend() async throws {
        let pack = try Self.requirePack()
        let backend = try await Self.openBackend(pack)
        defer { Task { await backend.unload() } }

        var failures: [String] = []
        var gaps: [String] = []
        var statuses: [CleanupStatus: Int] = [:]
        for testCase in CleanupE2ETests.cases {
            let (text, status) = await runCleanup(backend, text: testCase.raw, style: "polish", timeoutS: 30)
            statuses[status, default: 0] += 1
            let accepted = status == .ok
            // Same shape as CleanupE2ETests so the two runs are comparable:
            // word checks only apply when the model's output was accepted, and
            // they are word-boundary matches, not substrings.
            var problems: [String] = []
            if let expected = testCase.expectAccepted, expected != accepted {
                problems.append("expected accepted=\(expected), got status=\(status.rawValue)")
            } else if accepted {
                for word in testCase.mustKeep where !Self.containsWord(text, word) {
                    problems.append("lost \"\(word)\"")
                }
                for word in testCase.mustDrop where Self.containsWord(text, word) {
                    problems.append("kept \"\(word)\"")
                }
            }
            guard !problems.isEmpty else {
                if testCase.knownGap != nil { gaps.append("[now passing] \(testCase.name)") }
                continue
            }
            let line = "\(testCase.name): \(problems.joined(separator: "; "))\n  out: \(text)"
            if let gap = testCase.knownGap { gaps.append("[known gap: \(gap)] \(line)") }
            else { failures.append(line) }
        }
        print("SDK-E2E statuses:", statuses.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
        if !gaps.isEmpty { print("SDK-E2E known gaps:\n" + gaps.joined(separator: "\n")) }
        XCTAssertTrue(failures.isEmpty, "SDK backend regressions:\n" + failures.joined(separator: "\n"))
    }

    /// The headline question this whole branch exists to answer: does the
    /// extracted SDK produce *the same bytes* as the engine it was extracted
    /// from, on the same inputs, with the same pack?
    ///
    /// Corpus: the app's own E2E cases, plus anything in `POMVOX_PARITY_CORPUS`
    /// (a JSONL file of `{"raw": "…"}` lines — used locally for real transcripts
    /// out of history.db, never committed).
    func testInAppAndSDKProduceIdenticalText() async throws {
        let pack = try Self.requirePack()
        var corpus = CleanupE2ETests.cases.map(\.raw)
        var corpusLabel = "e2e"
        if let path = ProcessInfo.processInfo.environment["POMVOX_PARITY_CORPUS"],
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let extra = text.split(separator: "\n").compactMap { line -> String? in
                guard let data = line.data(using: .utf8),
                      let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = row["raw"] as? String, !raw.isEmpty else { return nil }
                return raw
            }
            corpus += extra
            corpusLabel += "+corpus(\(extra.count))"
        }

        // Pass 1: the in-app engine, alone in the process.
        let inApp = CleanupEngine()
        let prepared = await inApp.prepare(modelID: SDKCleanupBackend.supportedModelID)
        guard case .loaded = prepared else { return XCTFail("in-app engine did not load: \(prepared)") }
        var reference: [(text: String, status: CleanupStatus)] = []
        for raw in corpus {
            reference.append(await runCleanup(inApp, text: raw, style: "polish", timeoutS: 60))
        }
        await inApp.unload()

        // Pass 2: the SDK, after the in-app weights are gone.
        let backend = try await Self.openBackend(pack)
        var mismatches: [String] = []
        var statusOnly = 0
        for (index, raw) in corpus.enumerated() {
            let (text, status) = await runCleanup(backend, text: raw, style: "polish", timeoutS: 60)
            if Array(text.utf8) != Array(reference[index].text.utf8) {
                mismatches.append("""
                    #\(index) status \(reference[index].status.rawValue) → \(status.rawValue)
                      in-app: \(reference[index].text.prefix(200))
                      sdk   : \(text.prefix(200))
                    """)
            } else if status != reference[index].status {
                statusOnly += 1
            }
        }
        await backend.unload()
        print("SDK-parity corpus=\(corpusLabel) n=\(corpus.count) "
              + "identical=\(corpus.count - mismatches.count) differing=\(mismatches.count) "
              + "status-only=\(statusOnly)")
        XCTAssertTrue(mismatches.isEmpty,
                      "the SDK must reproduce the engine it was extracted from:\n"
                      + mismatches.prefix(10).joined(separator: "\n"))
    }

    // MARK: - Lifecycle

    /// A dictation that lands while the model is still opening must wait inside
    /// its own deadline rather than pasting raw — the post-eviction case that
    /// cost 16 of 60 dictations on-device before the in-app engine learned to
    /// wait. The SDK has no such wait; the backend supplies it.
    func testCleanWaitsForAnInFlightOpenInsteadOfPastingRaw() async throws {
        let pack = try Self.requirePack()
        let backend = SDKCleanupBackend(packDirectory: pack)
        async let opening: Void = {
            _ = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        }()
        // Deliberately racing the open, exactly as a key-up would.
        let (text, status) = await runCleanup(
            backend, text: "um so i think we should uh ship it tomorrow", style: "polish", timeoutS: 30)
        await opening
        XCTAssertEqual(status, .ok, "a dictation racing the open should still be cleaned; got \(text)")
        await backend.unload()
    }

    /// Closing and reopening is the SDK's only eviction story. This records
    /// what that costs, because the in-app engine keeps its prefix caches and
    /// the SDK does not.
    func testReopenAfterUnloadWorksAndIsMeasured() async throws {
        let pack = try Self.requirePack()
        let backend = try await Self.openBackend(pack)
        let (_, first) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
        XCTAssertEqual(first, .ok)
        let generation = await backend.generation
        await backend.unload()
        let unloaded = await backend.isLoaded
        XCTAssertFalse(unloaded)

        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        let reopenMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard case .loaded = outcome else { return XCTFail("reopen failed: \(outcome)") }
        let reopened = await backend.generation
        XCTAssertGreaterThan(reopened, generation)
        print(String(format: "SDK-reopen ms=%.0f", reopenMs))
        let (_, second) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
        XCTAssertEqual(second, .ok)
        await backend.unload()
    }

    /// A configured model the pinned pack is not for must fail loudly, not be
    /// served by the wrong weights.
    func testUnsupportedModelFailsToPrepare() async throws {
        let pack = try Self.requirePack()
        let backend = SDKCleanupBackend(packDirectory: pack)
        let outcome = await backend.prepare(modelID: "mlx-community/Qwen3-1.7B-4bit", onProgress: nil)
        guard case .failed(let reason) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("simplewords"), reason)
        let loaded = await backend.isLoaded
        XCTAssertFalse(loaded)
    }
}
