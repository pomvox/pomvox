import MLX
import MLXLMCommon
import XCTest

@testable import Pomvox

/// Measures what one forward pass costs on the shipped model as a function of
/// how many tokens it carries, on THIS machine's Swift stack — the number
/// `SpeculativeDecoder.DraftPolicy` is tuned against. Prints a table; asserts
/// nothing. Skipped unless POMVOX_MODEL_PROBE=1.
final class CleanupPassCostProbeTests: XCTestCase {

    func testPassCostByTokenCount() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_MODEL_PROBE"] == "1",
            "set TEST_RUNNER_POMVOX_MODEL_PROBE=1 to run the pass-cost probe")
        let engine = CleanupEngine()
        let outcome = await engine.prepare(modelID: MemoryTier.standardCleanupModel)
        if case .failed(let reason) = outcome { throw XCTSkip("prepare failed: \(reason)") }
        let rows = await engine.probePassCost(tokenCounts: [1, 2, 3, 4, 5, 6, 8, 12, 16, 24, 32])
        for (t, ms) in rows { print(String(format: "PASS-COST T=%3d: %7.1f ms", t, ms)) }
        await engine.unload()
    }
}
