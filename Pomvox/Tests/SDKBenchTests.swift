import XCTest

@testable import Pomvox

/// The `CleanupBenchTests` workload, run through the SDK backend, so in-app and
/// SDK numbers come out of the same harness on the same machine and can be
/// compared without arguing about methodology.
///
/// Skipped unless `POMVOX_LLM_BENCH=1`:
///   TEST_RUNNER_POMVOX_LLM_BENCH=1 DEVELOPER_DIR=… xcodebuild test … \
///     -only-testing:PomvoxTests/SDKBenchTests
///
/// Every outcome is reported, including failures. A latency number computed
/// over successes only is how you accidentally publish a p95 that no user has.
final class SDKBenchTests: XCTestCase {

    /// Same three fixtures `CleanupBenchTests` uses: a short greeting, a
    /// self-correction and a counted list.
    static let fixtures: [(name: String, text: String)] = [
        ("greeting", "um hello there"),
        ("correction", "let's meet on tuesday wait no friday at noon"),
        ("list", "number one review the report number two update the draft "
            + "number three send it on friday"),
    ]

    private static func requireBench() throws -> URL {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POMVOX_LLM_BENCH"] == "1",
                          "set TEST_RUNNER_POMVOX_LLM_BENCH=1 to run the SDK bench")
        let directory = SDKCleanupBackend.defaultPackDirectory()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.path),
                          "no installed pack at \(directory.path)")
        return directory
    }

    func testWarmLatencyAcrossTheFixtureSet() async throws {
        let pack = try Self.requireBench()
        let backend = SDKCleanupBackend(packDirectory: pack)
        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        let prepareMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard case .loaded = outcome else { return XCTFail("prepare failed: \(outcome)") }

        var all: [Double] = []
        var statuses: [String: Int] = [:]
        var perFixture: [String] = []
        for fixture in Self.fixtures {
            var latencies: [Double] = []
            for _ in 0..<5 {
                let start = CFAbsoluteTimeGetCurrent()
                let (_, status) = await runCleanup(backend, text: fixture.text, style: "polish", timeoutS: 30)
                latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                statuses[status.rawValue, default: 0] += 1
            }
            all += latencies
            let sorted = latencies.sorted()
            perFixture.append(String(format: "%@ median=%.0f", fixture.name, sorted[sorted.count / 2]))
        }
        await backend.unload()
        let sorted = all.sorted()
        // Nearest-rank p95, same convention as the SDK's own consumer benchmark.
        let p95 = sorted[max(0, Int((Double(sorted.count) * 0.95).rounded(.up)) - 1)]
        print(String(format: "SDK-bench prepareMS=%.0f n=%d median=%.0f p95=%.0f %@ | %@",
                     prepareMs, all.count, sorted[sorted.count / 2], p95,
                     statuses.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "),
                     perFixture.joined(separator: " ")))
        XCTAssertEqual(statuses["ok"], all.count, "every warm bench request should clean")
    }

    /// A deadline the pass cannot possibly meet must produce the raw transcript,
    /// not a partial or empty one.
    func testTimeoutFallsBackToTheRawTranscript() async throws {
        let pack = try Self.requireBench()
        let backend = SDKCleanupBackend(packDirectory: pack)
        guard case .loaded = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID,
                                                   onProgress: nil)
        else { return XCTFail("prepare failed") }
        let raw = String(repeating: "um so then we went over the whole schedule again ", count: 20)
        let (text, status) = await runCleanup(backend, text: raw, style: "polish", timeoutS: 0.2)
        await backend.unload()
        XCTAssertNotEqual(status, .ok)
        XCTAssertEqual(text, raw, "the never-lose-words fallback must survive the SDK boundary")
    }

    /// What a dictation pays when it lands right after an eviction. The in-app
    /// engine keeps its prefix caches across this; the SDK does not, so this is
    /// the number that decides whether `idle_evict_s = 0` stops being optional.
    func testPostEvictionReloadLatency() async throws {
        let pack = try Self.requireBench()
        let backend = SDKCleanupBackend(packDirectory: pack)
        guard case .loaded = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID,
                                                   onProgress: nil)
        else { return XCTFail("prepare failed") }
        _ = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
        await backend.unload()
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let t0 = CFAbsoluteTimeGetCurrent()
        let outcome = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        let reloadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        guard case .loaded = outcome else { return XCTFail("reload failed: \(outcome)") }
        let start = CFAbsoluteTimeGetCurrent()
        let (_, status) = await runCleanup(backend, text: "um hello there", style: "polish", timeoutS: 30)
        let firstMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        await backend.unload()
        print(String(format: "SDK-bench post-eviction reloadMS=%.0f firstRequestMS=%.0f status=%@",
                     reloadMs, firstMs, status.rawValue))
        XCTAssertEqual(status, .ok)
    }

    /// A dictionary is the common case, not the exception. If the SDK's prefix
    /// cache cannot be reused once a vocabulary is attached, this is where the
    /// cost shows up as a plain before/after.
    func testDictionaryHintLatencyDelta() async throws {
        let pack = try Self.requireBench()
        let fixture = Self.fixtures[1].text
        var results: [String] = []
        for (label, hint) in [("no-dictionary", ""), ("dictionary", dictionaryPromptHint(["Pomvox", "Parakeet"]))] {
            let backend = SDKCleanupBackend(packDirectory: pack)
            await backend.setTermsHint(hint)
            guard case .loaded = await backend.prepare(modelID: SDKCleanupBackend.supportedModelID,
                                                       onProgress: nil)
            else { return XCTFail("prepare failed for \(label)") }
            var latencies: [Double] = []
            var cachedRuns = 0
            for _ in 0..<5 {
                let start = CFAbsoluteTimeGetCurrent()
                let (_, status) = await runCleanup(backend, text: fixture, style: "polish", timeoutS: 30)
                latencies.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                XCTAssertEqual(status, .ok)
                if !(await backend.warnings).contains("prefix-cache-not-used") { cachedRuns += 1 }
            }
            await backend.unload()
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let sorted = latencies.sorted()
            results.append(String(format: "%@ median=%.0f cached=%d/5", label, sorted[sorted.count / 2], cachedRuns))
        }
        print("SDK-bench dictionary-delta: " + results.joined(separator: " | "))
    }
}
