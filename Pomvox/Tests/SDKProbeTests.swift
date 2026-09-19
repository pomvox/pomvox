import XCTest

@testable import Pomvox


/// Probes that measure what the SDK actually does at its edges, on the real
/// model, where the app's behaviour depends on the answer.
///
/// These are not pass/fail regression tests in the usual sense — most of them
/// assert only that the SDK is self-consistent and print the number a decision
/// needs. Their output is the evidence behind `docs/cleanup-engine-sdk-gaps.md`.
///
/// Skipped unless `POMVOX_SDK_PROBE=1`:
///   TEST_RUNNER_POMVOX_SDK_PROBE=1 DEVELOPER_DIR=… xcodebuild test … \
///     -only-testing:PomvoxTests/SDKProbeTests
final class SDKProbeTests: XCTestCase {

    private static func requirePack() throws -> URL {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POMVOX_SDK_PROBE"] == "1",
                          "set TEST_RUNNER_POMVOX_SDK_PROBE=1 to run the SDK probes")
        let directory = SDKCleanupBackend.defaultPackDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path),
                          "no installed pack at \(directory.path)")
        return directory
    }

    private func open(_ pack: URL, hint: String = "") async throws -> SDKCleanupBackend {
        let backend = SDKCleanupBackend(packDirectory: pack)
        await backend.setTermsHint(hint)
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        guard case .loaded = outcome else {
            XCTFail("prepare failed: \(outcome)")
            throw CleanupBackendFailure.unavailable
        }
        return backend
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Vocabulary vs the prefix cache

    /// The SDK builds one prompt prefix at open, from the frozen system text
    /// alone, then renders the dictionary hint *after* that text on every
    /// request. If the hint changes the token stream inside the cached prefix,
    /// every request from a user with a dictionary runs uncached — which is
    /// most users. The in-app engine avoids this by baking the hint into the
    /// prefix at load and rebuilding it when the dictionary changes.
    ///
    /// Measures both: whether the SDK warns `prefix-cache-not-used`, and what
    /// it costs in wall-clock.
    func testVocabularySizeVersusPrefixCacheReuse() async throws {
        let pack = try Self.requirePack()
        let fixture = "um so i wanted to walk you through the plan uh first we do the research"
        var report: [String] = []
        for termCount in [0, 1, 10, 64] {
            let terms = (1...max(termCount, 1)).prefix(termCount).map { "Term\($0)" }
            let backend = try await open(pack, hint: dictionaryPromptHint(Array(terms)))
            var latencies: [Double] = []
            var cached = 0
            for _ in 0..<5 {
                let t0 = CFAbsoluteTimeGetCurrent()
                let (_, status) = await runCleanup(backend, text: fixture, style: "polish", timeoutS: 60)
                latencies.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                XCTAssertEqual(status, .ok)
                let warnings = await backend.warnings
                if !warnings.contains("prefix-cache-not-used") { cached += 1 }
            }
            await backend.unload()
            report.append(String(format: "terms=%d cachedRuns=%d/5 medianMS=%.0f",
                                 termCount, cached, Self.median(latencies)))
            // Give the lease time to drop before the next open.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        print("SDK-probe vocabulary-vs-prefix:\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - Input length

    /// `CleanupRequest.validate()` admits 16,384 bytes of text, but generation
    /// is capped at `min(2 × inputTokens, 1024)` output tokens. Somewhere
    /// between those two numbers a long dictation stops being cleanable and
    /// starts being silently truncated into a `tokenLimit` fallback. This finds
    /// where, so the app knows when to stop asking.
    func testLongInputsFindTheTokenCapCliff() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        let sentence = "and then we talked about the schedule and the budget and what to do next "
        var report: [String] = []
        for targetChars in [500, 1_000, 2_000, 4_000, 8_000] {
            var text = "um so here is the whole thing "
            while text.count < targetChars { text += sentence }
            let t0 = CFAbsoluteTimeGetCurrent()
            let (out, status) = await runCleanup(backend, text: text, style: "polish", timeoutS: 60)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            report.append(String(format: "chars=%d status=%@ outChars=%d ms=%.0f",
                                 text.count, status.rawValue, out.count, ms))
            // Whatever happens, the transcript survives — that is the contract
            // the app depends on and the one thing worth asserting here.
            XCTAssertFalse(out.isEmpty)
            if status != .ok { XCTAssertEqual(out, text, "a failed cleanup must paste the raw transcript") }
        }
        await backend.unload()
        print("SDK-probe long-inputs:\n  " + report.joined(separator: "\n  "))
    }

    // MARK: - Quarantine after cancellation / timeout

    /// The SDK quarantines its worker: once a request is cancelled or times
    /// out, every later request returns `unavailable` until the abandoned
    /// generation actually returns. For a dictation app that means the *next*
    /// utterance after a cancel pastes raw. This measures how long that lasts.
    func testQuarantineWindowAfterCancellation() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        let long = String(repeating: "um so then we discussed the plan and the schedule again ", count: 20)

        let running = Task { await runCleanup(backend, text: long, style: "polish", timeoutS: 60) }
        try await Task.sleep(nanoseconds: 400_000_000)   // let the generation start
        running.cancel()
        _ = await running.value

        var recoveredAfterMs: Double?
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            let (_, status) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
            if status == .ok { recoveredAfterMs = (CFAbsoluteTimeGetCurrent() - start) * 1000; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await backend.unload()
        print(String(format: "SDK-probe cancel-quarantine: recoveredAfterMS=%@",
                     recoveredAfterMs.map { String(format: "%.0f", $0) } ?? "never(10s)"))
        XCTAssertNotNil(recoveredAfterMs, "the backend must become usable again after a cancelled request")
    }

    /// Same question for the other way a request ends early: its deadline.
    func testQuarantineWindowAfterDeadline() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        let long = String(repeating: "um so then we discussed the plan and the schedule again ", count: 20)
        // A deadline far too short for this input: the SDK resolves the caller
        // and leaves the generation running.
        let (_, first) = await runCleanup(backend, text: long, style: "polish", timeoutS: 1.0)
        XCTAssertNotEqual(first, .ok)

        var recoveredAfterMs: Double?
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            let (_, status) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
            if status == .ok { recoveredAfterMs = (CFAbsoluteTimeGetCurrent() - start) * 1000; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        await backend.unload()
        print(String(format: "SDK-probe deadline-quarantine: recoveredAfterMS=%@",
                     recoveredAfterMs.map { String(format: "%.0f", $0) } ?? "never(10s)"))
        XCTAssertNotNil(recoveredAfterMs)
    }

    // MARK: - Admission

    /// One worker, two queued, everything else refused. Dictation is serial, so
    /// this is mostly a sanity check that a burst cannot lose a transcript.
    func testConcurrentRequestsAreBoundedAndNeverLoseText() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        let inputs = (0..<4).map { "um so this is request number \($0) about the schedule" }
        let results = await withTaskGroup(of: (String, CleanupStatus).self) { group in
            for input in inputs {
                group.addTask { await runCleanup(backend, text: input, style: "polish", timeoutS: 30) }
            }
            var all: [(String, CleanupStatus)] = []
            for await result in group { all.append(result) }
            return all
        }
        await backend.unload()
        let cleaned = results.filter { $0.1 == .ok }.count
        print("SDK-probe admission: cleaned=\(cleaned)/4 statuses="
              + results.map { $0.1.rawValue }.sorted().joined(separator: ","))
        for (text, _) in results { XCTAssertFalse(text.isEmpty, "no request may lose its text") }
        XCTAssertGreaterThanOrEqual(cleaned, 1, "at least the admitted request must be cleaned")
    }

    // MARK: - Reopen cost

    /// The app evicts on memory pressure and on idle. The in-app engine keeps
    /// its prefix caches across that, so a reload is a weight read; the SDK
    /// closes everything and re-validates the whole 2 GB pack on reopen. Five
    /// cycles, so the number is not one warm-cache fluke.
    func testCloseReopenCycleCost() async throws {
        let pack = try Self.requirePack()
        let backend = SDKCleanupBackend(packDirectory: pack)
        var opens: [Double] = []
        for cycle in 0..<5 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            guard case .loaded = outcome else { return XCTFail("cycle \(cycle) failed: \(outcome)") }
            opens.append(ms)
            let (_, status) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
            XCTAssertEqual(status, .ok, "cycle \(cycle)")
            await backend.unload()
            // The SDK releases its process-wide lease only once the closed
            // cleaner is actually deallocated; without a pause the next open
            // can lose the race. How long that takes is itself the finding.
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        print("SDK-probe reopen-cost ms=" + opens.map { String(format: "%.0f", $0) }.joined(separator: ","))
    }

    /// Close immediately followed by open, with no pause: does the host have to
    /// know about the lease, or does the SDK serialize it?
    func testImmediateReopenAfterClose() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        await backend.unload()
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        switch outcome {
        case .loaded: print("SDK-probe immediate-reopen: ok")
        case .failed(let reason): print("SDK-probe immediate-reopen: FAILED — \(reason)")
        case .skipped: print("SDK-probe immediate-reopen: skipped")
        }
        await backend.unload()
    }

    // MARK: - Pack hygiene

    /// Three ways a pack directory goes wrong in the field, and what the SDK
    /// does about each. The app has to distinguish "reinstall" from "refuse".
    func testPackValidationRefusals() async throws {
        let pack = try Self.requirePack()
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sdk-probe-pack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        // A Finder visit is enough to add this.
        let strayed = scratch.appendingPathComponent("strayed")
        try FileManager.default.copyItem(at: pack, to: strayed)
        try Data().write(to: strayed.appendingPathComponent(".DS_Store"))
        let strayBackend = SDKCleanupBackend(packDirectory: strayed)
        let strayOutcome = await strayBackend.prepare(
            modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        print("SDK-probe pack .DS_Store: \(strayOutcome)")
        if case .loaded = strayOutcome { XCTFail("a stray file must not be silently accepted") }

        // One flipped byte in a small artifact.
        let corrupted = scratch.appendingPathComponent("corrupted")
        try FileManager.default.copyItem(at: pack, to: corrupted)
        let victim = corrupted.appendingPathComponent("tokenizer_config.json")
        var bytes = try Data(contentsOf: victim)
        bytes[0] = bytes[0] == 0x20 ? 0x09 : 0x20
        try bytes.write(to: victim)
        let corruptBackend = SDKCleanupBackend(packDirectory: corrupted)
        let corruptOutcome = await corruptBackend.prepare(
            modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        print("SDK-probe pack corrupted-byte: \(corruptOutcome)")
        if case .loaded = corruptOutcome { XCTFail("a corrupted artifact must not load") }

        // A pack whose weights never finished copying.
        let truncated = scratch.appendingPathComponent("truncated")
        try FileManager.default.createDirectory(at: truncated, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: truncated.appendingPathComponent("config.json"))
        let truncatedBackend = SDKCleanupBackend(packDirectory: truncated)
        let truncatedOutcome = await truncatedBackend.prepare(
            modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        print("SDK-probe pack incomplete: \(truncatedOutcome)")
        if case .loaded = truncatedOutcome { XCTFail("an incomplete pack must not load") }
    }

    // MARK: - Soak

    /// Two hundred warm requests over the SDK's own fixture set: outcome
    /// histogram, latency distribution and RSS drift. A leak or a slow
    /// degradation shows up here and nowhere else in this suite.
    func testWarmSoak() async throws {
        let pack = try Self.requirePack()
        let backend = try await open(pack)
        let fixtures = CleanupE2ETests.cases.map(\.raw)
        var latencies: [Double] = []
        var statuses: [String: Int] = [:]
        let rssStart = Self.residentBytes()
        for index in 0..<200 {
            let raw = fixtures[index % fixtures.count]
            let t0 = CFAbsoluteTimeGetCurrent()
            let (_, status) = await runCleanup(backend, text: raw, style: "polish", timeoutS: 60)
            latencies.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            statuses[status.rawValue, default: 0] += 1
        }
        let rssEnd = Self.residentBytes()
        await backend.unload()
        let sorted = latencies.sorted()
        print(String(format: "SDK-probe soak n=%d p50=%.0f p95=%.0f max=%.0f rssStartMB=%.0f rssEndMB=%.0f %@",
                     latencies.count, sorted[sorted.count / 2],
                     sorted[Int(Double(sorted.count) * 0.95)], sorted.last ?? 0,
                     Double(rssStart) / 1_048_576, Double(rssEnd) / 1_048_576,
                     statuses.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")))
        XCTAssertGreaterThan(statuses["ok", default: 0], 150,
                             "a warm soak should clean the overwhelming majority of requests")
    }

    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
