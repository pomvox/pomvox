import Darwin
import XCTest
@testable import Pomvox

/// Settings ▸ Models "Downloaded models" (#100) against a temp cache: the list with
/// sizes, the in-use rule, and a removal that never touches an in-use, busy or undeletable model.
final class DownloadedModelsTests: XCTestCase {
    private var tmp: URL!
    private var roots: DownloadedModels.Roots!
    private let stt = "mlx-community/parakeet-tdt-0.6b-v2"
    private let cleanup = "abhiram3040/simplewords-dictation-cleanup-v3"
    private let qwen = "mlx-community/Qwen3-4B-4bit"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-models-\(UUID().uuidString)", isDirectory: true)
        roots = DownloadedModels.Roots(hubCache: tmp.appendingPathComponent("hub", isDirectory: true),
                                       fluidModels: tmp.appendingPathComponent("fluid", isDirectory: true))
        try write(roots.hubCache, "models--mlx-community--Qwen3-4B-4bit/snapshots/a/model.safetensors", bytes: 3000)
        try write(roots.hubCache, "models--abhiram3040--simplewords-dictation-cleanup-v3/blobs/x", bytes: 2000)
        try write(roots.hubCache, "models--mlx-community--parakeet-tdt-0.6b-v3/blobs/y", bytes: 500)
        try write(roots.hubCache, ".locks/models--mlx-community--Qwen3-4B-4bit/x.lock", bytes: 0)
        try write(roots.hubCache, "version.txt", bytes: 1)
        try write(roots.fluidModels, "parakeet-tdt-0.6b-v2-coreml/Encoder.mlmodelc/w", bytes: 700)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    private func write(_ root: URL, _ rel: String, bytes: Int) throws {
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    private func scan() -> [DownloadedModel] {
        DownloadedModels.scan(roots: roots, sttModel: stt, cleanupModel: cleanup)
    }

    func testScanListsEveryModelWithSizeAndInUseMark() {
        // `models--org--name` maps to `org/name`; `.locks` and `version.txt` are not models.
        let models = scan()
        XCTAssertEqual(models.map(\.id),
                       [cleanup, qwen, "mlx-community/parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v2-coreml"])
        XCTAssertEqual(models.map(\.bytes), [2000, 3000, 500, 700])
        XCTAssertEqual(models.map(\.inUse), [true, false, false, true])
    }

    func testInUseFollowsTheResolvedSpeechModelNotTheTypedString() {
        // A typo falls back to v2 at arm(), so v2's files stay in use.
        XCTAssertTrue(DownloadedModels.isInUse(
            repoID: "parakeet-tdt-0.6b-v2-coreml", sttModel: "whisper-large", cleanupModel: cleanup))
        XCTAssertFalse(DownloadedModels.isInUse(
            repoID: "parakeet-tdt-0.6b-v2-coreml", sttModel: "mlx-community/parakeet-tdt-0.6b-v3", cleanupModel: cleanup))
        XCTAssertTrue(DownloadedModels.isInUse(repoID: qwen, sttModel: stt, cleanupModel: " \(qwen) "))
    }

    func testRemoveDeletesOnlyUnusedModelsAndReportsBytesFreed() {
        let outcome = DownloadedModels.remove(scan(), roots: roots)
        XCTAssertEqual(outcome.removed, [qwen, "mlx-community/parakeet-tdt-0.6b-v3"])
        XCTAssertEqual(outcome.bytesFreed, 3500)
        XCTAssertEqual(outcome.kept, [cleanup, "parakeet-tdt-0.6b-v2-coreml"])
        // In-use files are intact; the stale lock folder went with its model.
        XCTAssertEqual(scan().map { ($0.id, $0.bytes) }.map { "\($0.0)=\($0.1)" },
                       ["\(cleanup)=2000", "parakeet-tdt-0.6b-v2-coreml=700"])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: roots.hubCache.appendingPathComponent(".locks/models--mlx-community--Qwen3-4B-4bit").path))
    }

    func testRemoveSkipsAModelWhoseDownloadLockIsHeld() {
        let fd = open(roots.hubCache.appendingPathComponent(".locks/models--mlx-community--Qwen3-4B-4bit/x.lock").path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        defer { flock(fd, LOCK_UN); close(fd) }

        let busy = scan().filter { $0.id == qwen }
        XCTAssertEqual(DownloadedModels.remove(busy, roots: roots),
                       DownloadedModels.Outcome(removed: [], kept: [qwen], bytesFreed: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: busy[0].folder.path))
    }

    func testRemoveFailureKeepsTheModelInsteadOfCrashing() {
        let ghost = DownloadedModel(id: "x/gone", folder: roots.hubCache.appendingPathComponent("models--x--gone"),
                                    bytes: 9, inUse: false)
        XCTAssertEqual(DownloadedModels.remove([ghost], roots: roots),
                       DownloadedModels.Outcome(removed: [], kept: ["x/gone"], bytesFreed: 0))
    }

    func testRemovalWaitsForLoadsAndDownloads() {
        let busy = DownloadedModels.busyReason
        XCTAssertNil(busy(.ready, nil, .onDisk))
        XCTAssertNil(busy(.off, nil, .ready))
        XCTAssertNotNil(busy(.preparing, nil, .onDisk), "arm in progress")
        XCTAssertNotNil(busy(.ready, "Loading…", .onDisk), "speech model loading")
        XCTAssertNotNil(busy(.ready, nil, .downloading(fraction: 0.2)), "cleanup downloading")
        XCTAssertNotNil(busy(.ready, nil, .loading), "cleanup loading")
    }
}
