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
}
