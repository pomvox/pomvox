import Foundation
import XCTest

@testable import Pomvox

/// The fnmatch behaviour the whole frozen path rests on.
///
/// `HubClient.downloadSnapshot` filters with `fnmatch(glob, relativePath, 0)`.
/// With flags 0 there is no `FNM_PATHNAME`, so `*` crosses '/' — which is exactly
/// why the globs cannot be the stock `*.safetensors`. Until now this was defended
/// only by a doc comment; these pin it, because if it ever changes the app stops
/// loading its default cleanup model (`loadWeights` merges every `.safetensors`
/// under the model directory and then rejects the unused LoRA keys).
final class CleanupEngineSnapshotGlobTests: XCTestCase {

    private func matches(_ glob: String, _ path: String) -> Bool {
        fnmatch(glob, path, 0) == 0
    }

    /// Would any shipped glob fetch this repo-relative path?
    private func fetched(_ path: String) -> Bool {
        CleanupEngine.frozenSnapshotGlobs.contains { matches($0, path) }
    }

    /// The load-bearing assumption, stated directly: the weight glob must be
    /// anchored to `model` so it cannot reach into a subfolder.
    func testTheWeightGlobExcludesAdapterWeightsButMatchesModelWeights() {
        XCTAssertFalse(matches("model*.safetensors", "adapter/adapters.safetensors"))
        XCTAssertTrue(matches("model*.safetensors", "model.safetensors"))
        // Sharded weights must still be fetched.
        XCTAssertTrue(matches("model*.safetensors", "model-00001-of-00002.safetensors"))
    }

    /// The stock glob is why `ModelConfiguration(id:)` can't be used here: with
    /// flags 0, `*` crosses '/' and it drags the adapter weights in.
    func testTheStockWeightGlobWouldHaveMatchedTheAdapter() {
        XCTAssertTrue(matches("*.safetensors", "adapter/adapters.safetensors"))
    }

    func testTheFrozenPromptPatternIsALiteralAndDoesNotCrossASubfolder() {
        XCTAssertTrue(matches(CleanupPromptProfile.frozenPromptFilename, "system_v2.txt"))
        XCTAssertFalse(matches(CleanupPromptProfile.frozenPromptFilename, "adapter/system_v2.txt"))
    }

    /// The known, inert leak, pinned so it's documented rather than discovered:
    /// `*.json` DOES cross '/', so a v2 snapshot lands `adapter/adapter_config.json`
    /// (a training manifest). Harmless — nothing in the load path reads json
    /// recursively; only the adapter WEIGHTS break `loadWeights`.
    func testTheJSONGlobDoesCrossASubfolderWhichIsKnownAndInert() {
        XCTAssertTrue(matches("*.json", "adapter/adapter_config.json"))
    }

    /// The same question the shipped globs answer, asked through them.
    func testTheShippedGlobSetFetchesTheModelFilesAndNotTheAdapterWeights() {
        XCTAssertTrue(fetched("model.safetensors"))
        XCTAssertTrue(fetched("config.json"))
        XCTAssertTrue(fetched("tokenizer.json"))
        XCTAssertTrue(fetched("chat_template.jinja"))
        XCTAssertTrue(fetched("system_v2.txt"))
        XCTAssertFalse(fetched("adapter/adapters.safetensors"))
    }

    // MARK: - strayWeightFile

    private func makeSnapshot(_ relativePaths: [String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomvox-snapshot-\(UUID().uuidString)")
        for relative in relativePaths {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testACleanSnapshotHasNoStrayWeights() throws {
        let dir = try makeSnapshot([
            "model.safetensors", "config.json", "tokenizer.json", "system_v2.txt",
            "adapter/adapter_config.json",
        ])
        XCTAssertNil(CleanupEngine.strayWeightFile(in: dir))
    }

    /// The reported failure: another tool's unfiltered snapshot_download left the
    /// adapter weights in the SHARED cache directory Pomvox loads from.
    func testAdapterWeightsInASubdirectoryAreDetected() throws {
        let dir = try makeSnapshot([
            "model.safetensors", "config.json", "adapter/adapters.safetensors",
        ])
        let stray = CleanupEngine.strayWeightFile(in: dir)
        XCTAssertEqual(stray?.lastPathComponent, "adapters.safetensors")
    }

    /// Detection is recursive: the stray file is never at the top level.
    func testAStrayWeightFileNestedTwoLevelsDeepIsDetected() throws {
        let dir = try makeSnapshot(["model.safetensors", "a/b/other.safetensors"])
        XCTAssertNotNil(CleanupEngine.strayWeightFile(in: dir))
    }

    func testShardedTopLevelWeightsAreNotMistakenForStrays() throws {
        let dir = try makeSnapshot([
            "model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors",
            "model.safetensors.index.json",
        ])
        XCTAssertNil(CleanupEngine.strayWeightFile(in: dir))
    }

    /// A subfolder file whose NAME starts with "model" is still a stray: the glob
    /// is matched against the repo-relative path, which `model*` cannot reach into.
    func testASubfolderFileNamedLikeAModelShardIsStillAStray() throws {
        let dir = try makeSnapshot(["model.safetensors", "extra/model.safetensors"])
        XCTAssertEqual(
            CleanupEngine.strayWeightFile(in: dir)?.pathComponents.suffix(2).joined(separator: "/"),
            "extra/model.safetensors")
    }

    func testAMissingDirectoryIsNotReportedAsStray() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomvox-absent-\(UUID().uuidString)")
        XCTAssertNil(CleanupEngine.strayWeightFile(in: dir))
    }
}

/// `readFrozenPrompt` is the failure path the design names by name: a snapshot
/// without a usable frozen prompt must throw, so `prepare()` leaves the engine
/// unloaded and dictation pastes the raw transcript instead of prompting the
/// fine-tune off-distribution.
final class CleanupFrozenPromptReadTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomvox-frozen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ contents: String) throws {
        try Data(contents.utf8).write(
            to: dir.appendingPathComponent(CleanupPromptProfile.frozenPromptFilename))
    }

    func testReadsThePromptWhenPresent() throws {
        let text = "You clean up raw voice dictation.\n\n- Remove fillers.\n"
        try write(text)
        XCTAssertEqual(try CleanupEngine.readFrozenPrompt(in: dir), text)
    }

    func testThrowsWhenTheFileIsMissing() {
        XCTAssertThrowsError(try CleanupEngine.readFrozenPrompt(in: dir))
    }

    func testThrowsWhenTheFileIsEmpty() throws {
        try write("")
        XCTAssertThrowsError(try CleanupEngine.readFrozenPrompt(in: dir))
    }

    /// Whitespace-only is as unusable as empty — the shape the fine-tune was
    /// trained on would collapse to a bare transcript.
    func testThrowsWhenTheFileIsWhitespaceOnly() throws {
        try write("  \n\t\n ")
        XCTAssertThrowsError(try CleanupEngine.readFrozenPrompt(in: dir))
    }

    /// The thrown error must name the path, since the user-facing failure is a
    /// `.failed` string in the cold-start log.
    func testTheErrorNamesTheOffendingPath() {
        do {
            _ = try CleanupEngine.readFrozenPrompt(in: dir)
            XCTFail("expected a throw for a missing frozen prompt")
        } catch {
            XCTAssertTrue(
                String(describing: error).contains(CleanupPromptProfile.frozenPromptFilename),
                String(describing: error))
        }
    }
}
