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

    static let modelID = "abhiram3040/simplewords-dictation-cleanup-v3"

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_MODEL_PROBE"] == "1",
            "set TEST_RUNNER_POMVOX_MODEL_PROBE=1 to run the model load probe")
    }

    /// The stock mlx-swift-lm path. Diagnostic only — it asserts nothing.
    ///
    /// Against v2 this FAILED, and that failure is why the shipped path exists:
    /// v2 keeps an adapter/ subfolder on main, the stock download globs let
    /// `*.safetensors` cross '/', and loadWeights merges every .safetensors under
    /// the model directory into a fused graph that has no LoRA parameters.
    ///
    /// v3 publishes its adapter as a SEPARATE repo, so this path is expected to
    /// pass now. That is a property of how v3 happens to be laid out, not a
    /// guarantee — the shipped path still filters explicitly
    /// (`CleanupEngine.frozenSnapshotGlobs`) because the HF cache is shared and
    /// any other tool's unfiltered snapshot_download can still poison it.
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
    /// Ordering mattered against v2: the stock globs pulled
    /// `adapter/adapters.safetensors` into the shared snapshot directory that
    /// `loadWeights` enumerates recursively, so `testStockRepoIDPath` poisoned
    /// this one unless it ran second (alphabetical order does that). v3 keeps its
    /// adapter in a separate repo, so there is nothing left to pull — the
    /// ordering is preserved anyway, since it costs nothing and the hazard
    /// returns the moment a fused repo gains a subfolder.
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
