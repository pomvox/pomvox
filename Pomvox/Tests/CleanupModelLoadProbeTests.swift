import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers
import XCTest

@testable import Pomvox

/// Diagnostics for how the SimpleWords cleanup model reaches disk and memory.
/// Skipped unless POMVOX_MODEL_PROBE=1 — it downloads and loads ~2 GB:
///   TEST_RUNNER_POMVOX_MODEL_PROBE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
///     -destination 'platform=macOS' -only-testing:PomvoxTests/CleanupModelLoadProbeTests
final class CleanupModelLoadProbeTests: XCTestCase {

    static let modelID = "abhiram3040/simplewords-dictation-cleanup-v2"

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_MODEL_PROBE"] == "1",
            "set TEST_RUNNER_POMVOX_MODEL_PROBE=1 to run the model load probe")
    }

    /// The stock mlx-swift-lm path. Expected to FAIL while the model repo keeps
    /// an adapter/ subfolder on main: the download globs let `*.safetensors`
    /// cross '/', and loadWeights merges every .safetensors it finds under the
    /// model directory into a fused graph that has no LoRA parameters.
    func testStockRepoIDPath() async throws {
        try skipUnlessEnabled()
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: Self.modelID))
            let dir = try await container.modelDirectory
            let fm = FileManager.default
            print("PROBE stock: LOADED dir=\(dir.path)")
            print("PROBE stock: system_v2.txt present="
                + "\(fm.fileExists(atPath: dir.appendingPathComponent("system_v2.txt").path))")
            print("PROBE stock: adapter present="
                + "\(fm.fileExists(atPath: dir.appendingPathComponent("adapter/adapters.safetensors").path))")
        } catch {
            print("PROBE stock: FAILED \(error)")
        }
    }

    /// The path Pomvox actually ships: an explicit snapshot fetch that includes
    /// the frozen prompt and excludes the adapter weights, then a
    /// directory-based load. Asserts, unlike the stock-path diagnostic above.
    ///
    /// Run this BEFORE `testStockRepoIDPath` on a cold cache (alphabetical
    /// order does that): the stock globs pull `adapter/adapters.safetensors`
    /// into the shared snapshot directory, and `loadWeights` enumerates that
    /// directory recursively — so the stock probe poisons this path's snapshot
    /// until the adapter folder leaves the repo's main branch.
    func testFrozenPathLoadsAndCarriesThePrompt() async throws {
        try skipUnlessEnabled()
        let engine = CleanupEngine()
        let outcome = await engine.prepare(modelID: Self.modelID)
        if case .failed(let reason) = outcome { XCTFail("prepare failed: \(reason)") }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "the frozen model should be resident after prepare()")

        let prompt = await engine.frozenPrompt
        XCTAssertNotNil(prompt, "system_v2.txt should have been read from the snapshot")
        XCTAssertFalse(prompt?.isEmpty ?? true)

        // A cleanup the fine-tune is specifically trained for: a spoken
        // self-correction must keep only the revision.
        let cleaned = try await engine.clean(
            "let's meet on tuesday wait no friday at noon", style: "polish", timeoutS: 30)
        print("PROBE frozen: \(String(describing: cleaned))")
        let accepted = try XCTUnwrap(cleaned).lowercased()
        XCTAssertTrue(accepted.contains("friday"), accepted)
        XCTAssertFalse(accepted.contains("tuesday"), accepted)
    }
}
