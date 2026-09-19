import CryptoKit
import XCTest

@testable import Pomvox

/// The installer turns an HF snapshot (symlinks into a shared blob store) into
/// the flat, regular-file, exactly-eight-entry directory the cleanup SDK will
/// open. These run on synthetic byte-identical stand-ins — the real 2 GB
/// install is exercised by `SDKProbeTests` — because what needs pinning here is
/// the failure behaviour: never a half-written pack, never a modified source,
/// never a silent overwrite.
final class CleanupPackInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pack-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let snapshot: URL
        let blobs: URL
        let manifest: CleanupPackManifest
        let manifestData: Data
    }

    /// An HF-cache-shaped snapshot: every artifact is a symlink into `blobs/`.
    private func makeSnapshot(contents: [String: String] = [
        "config.json": "{\"hidden_size\": 2048}",
        "system_v2.txt": "You clean up raw speech-to-text transcripts.",
        "model.safetensors": "weights-stand-in",
    ]) throws -> Fixture {
        let snapshot = root.appendingPathComponent("snapshots/abc123")
        let blobs = root.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        var artifacts: [[String: Any]] = []
        for (name, body) in contents.sorted(by: { $0.key < $1.key }) {
            let data = Data(body.utf8)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let blob = blobs.appendingPathComponent(digest)
            try data.write(to: blob)
            try FileManager.default.createSymbolicLink(
                at: snapshot.appendingPathComponent(name), withDestinationURL: blob)
            artifacts.append(["path": name, "bytes": data.count, "sha256": digest])
        }
        let manifestObject: [String: Any] = [
            "schemaVersion": 1, "id": "test-pack", "version": "0.0.1-test",
            "modelID": SDKCleanupBackend.supportedModelID, "modelRevision": String(repeating: "a", count: 40),
            "artifacts": artifacts,
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject,
                                                     options: [.prettyPrinted, .sortedKeys])
        let manifest = try JSONDecoder().decode(CleanupPackManifest.self, from: manifestData)
        return Fixture(snapshot: snapshot, blobs: blobs, manifest: manifest, manifestData: manifestData)
    }

    private func installer(_ fixture: Fixture, fetch: (@Sendable () -> URL)? = nil) -> CleanupPackInstaller {
        let snapshot = fixture.snapshot
        let data = fixture.manifestData
        let manifest = fixture.manifest
        return CleanupPackInstaller(
            manifestSource: { (data, manifest) },
            fetchSnapshot: { _, _ in fetch?() ?? snapshot })
    }

    // MARK: - Happy path

    func testInstallsRegularFilesFromASymlinkedSnapshotAndLeavesTheSourceAlone() async throws {
        let fixture = try makeSnapshot()
        let destination = root.appendingPathComponent("pack")
        try await installer(fixture).ensureInstalled(
            packDirectory: destination, modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)

        let entries = try FileManager.default.contentsOfDirectory(atPath: destination.path)
        XCTAssertEqual(Set(entries), Set(fixture.manifest.artifacts.map(\.path) + ["pack.json"]),
                       "the SDK refuses a pack directory with anything unexpected in it")
        for artifact in fixture.manifest.artifacts {
            let url = destination.appendingPathComponent(artifact.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            XCTAssertEqual(values.isRegularFile, true, "\(artifact.path) must be a regular file")
            XCTAssertEqual(values.isSymbolicLink, false)
            XCTAssertEqual(values.fileSize, artifact.bytes)
            XCTAssertEqual(try CleanupPackInstaller.sha256(of: url), artifact.sha256)
        }
        // The manifest is copied byte for byte: its exact bytes are the digest
        // the SDK records as provenance.
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("pack.json")),
                       fixture.manifestData)
        // The snapshot is untouched: still symlinks, still pointing at blobs.
        for artifact in fixture.manifest.artifacts {
            let link = fixture.snapshot.appendingPathComponent(artifact.path)
            XCTAssertEqual(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        }
    }

    func testASecondInstallIsANoOpAndDoesNotRefetch() async throws {
        let fixture = try makeSnapshot()
        let destination = root.appendingPathComponent("pack")
        try await installer(fixture).ensureInstalled(
            packDirectory: destination, modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        let stamp = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("pack.json").path)[.modificationDate] as? Date

        let refetched = Unchecked(false)
        let second = CleanupPackInstaller(
            manifestSource: { (fixture.manifestData, fixture.manifest) },
            fetchSnapshot: { _, _ in refetched.value = true; return fixture.snapshot })
        try await second.ensureInstalled(packDirectory: destination,
                                         modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
        XCTAssertFalse(refetched.value, "an installed pack must not trigger a 2 GB re-download")
        let after = try FileManager.default.attributesOfItem(
            atPath: destination.appendingPathComponent("pack.json").path)[.modificationDate] as? Date
        XCTAssertEqual(stamp, after)
    }

    // MARK: - Refusals

    func testRefusesAnIncompleteDestinationInsteadOfRepairingItInPlace() async throws {
        let fixture = try makeSnapshot()
        let destination = root.appendingPathComponent("pack")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: destination.appendingPathComponent("config.json"))

        do {
            try await installer(fixture).ensureInstalled(
                packDirectory: destination, modelID: SDKCleanupBackend.supportedModelID, onProgress: nil)
            XCTFail("an incomplete destination must be refused")
        } catch let error as CleanupPackInstallError {
            guard case .destinationIncomplete = error else { return XCTFail("wrong error: \(error)") }
        }
        // Whatever was there is still there: the installer never deletes 2 GB
        // it did not create.
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("config.json")),
                       Data("half".utf8))
    }

    func testAStrayFileMakesTheDestinationIncomplete() throws {
        let fixture = try makeSnapshot()
        let destination = root.appendingPathComponent("pack")
        try CleanupPackInstaller.install(from: fixture.snapshot, to: destination,
                                         manifest: fixture.manifest, manifestData: fixture.manifestData)
        XCTAssertEqual(CleanupPackInstaller.inspect(destination, manifest: fixture.manifest), .complete)
        // Finder browsing the folder is enough to do this, and the SDK's
        // validator then refuses the pack outright — so the installer has to
        // see it as incomplete rather than reporting a pack that will not open.
        try Data().write(to: destination.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(CleanupPackInstaller.inspect(destination, manifest: fixture.manifest), .incomplete)
    }

    func testChecksumMismatchAbortsAndLeavesNoDestination() throws {
        let fixture = try makeSnapshot()
        // A blob whose bytes no longer match the manifest's hash: silent
        // corruption, or the wrong snapshot entirely.
        let corrupted = fixture.snapshot.appendingPathComponent("config.json").resolvingSymlinksInPath()
        try Data("{\"hidden_size\": 9999}".utf8).write(to: corrupted)
        let destination = root.appendingPathComponent("pack")
        XCTAssertThrowsError(
            try CleanupPackInstaller.install(from: fixture.snapshot, to: destination,
                                             manifest: fixture.manifest,
                                             manifestData: fixture.manifestData)
        ) { error in
            // Either check may fire first — the corrupted body differs in both
            // length and hash — and both are the same refusal.
            switch error as? CleanupPackInstallError {
            case .sizeMismatch, .checksumMismatch: break
            default: XCTFail("expected a size or checksum failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path),
                       "a failed install must not leave a directory the SDK would try to open")
        // …and no staging directory either.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".pack.staging-") }, "staging must be cleaned up")
    }

    func testMissingSourceFileAbortsCleanly() throws {
        let fixture = try makeSnapshot()
        try FileManager.default.removeItem(at: fixture.snapshot.appendingPathComponent("system_v2.txt"))
        let destination = root.appendingPathComponent("pack")
        XCTAssertThrowsError(
            try CleanupPackInstaller.install(from: fixture.snapshot, to: destination,
                                             manifest: fixture.manifest,
                                             manifestData: fixture.manifestData)
        ) { XCTAssertEqual($0 as? CleanupPackInstallError, .sourceMissing("system_v2.txt")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRefusesAModelTheBundledManifestIsNotFor() async throws {
        let fixture = try makeSnapshot()
        do {
            try await installer(fixture).ensureInstalled(
                packDirectory: root.appendingPathComponent("pack"),
                modelID: "mlx-community/Qwen3-1.7B-4bit", onProgress: nil)
            XCTFail("a mismatched model must be refused, not served by the pinned weights")
        } catch let error as CleanupPackInstallError {
            guard case .modelMismatch = error else { return XCTFail("wrong error: \(error)") }
        }
    }

    func testPublishIsAtomicSoAConcurrentInstallerCannotOverwrite() throws {
        let fixture = try makeSnapshot()
        let destination = root.appendingPathComponent("pack")
        try CleanupPackInstaller.install(from: fixture.snapshot, to: destination,
                                         manifest: fixture.manifest, manifestData: fixture.manifestData)
        let first = try Data(contentsOf: destination.appendingPathComponent("config.json"))
        // A second installer racing to the same destination must lose, not
        // half-overwrite a pack another process may already have open.
        XCTAssertThrowsError(
            try CleanupPackInstaller.install(from: fixture.snapshot, to: destination,
                                             manifest: fixture.manifest,
                                             manifestData: fixture.manifestData)
        ) { error in
            guard case .publishFailed = (error as? CleanupPackInstallError) ?? .manifestMissing else {
                return XCTFail("expected publishFailed, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("config.json")), first)
    }

    // MARK: - The shipped manifest

    /// The app bundles a verbatim copy of the SDK's manifest. If the two drift,
    /// the installed pack's `pack.json` no longer matches the artifact set the
    /// SDK's runtime pins and `Cleaner.open` fails at arm.
    ///
    /// Pinned by hash rather than by reading the submodule at runtime: the
    /// working copy lives on iCloud Drive, where reading an evicted file blocks
    /// indefinitely instead of failing, which hung this suite. The constant is
    /// the SHA-256 of `vendor/pomvox-cleanup-engine/packs/simplewords-v3/pack.json`
    /// at submodule commit 00bd4d8, so drift on either side fails here.
    func testBundledManifestMatchesThePinnedSDKManifest() throws {
        let (data, manifest) = try CleanupPackManifest.bundled()
        XCTAssertEqual(
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            "b18de5147868b8f24b706eeee065236926471ea3156aa69670ec43fa5f15059e",
            "Pomvox/Resources/simplewords-v3.pack.json must stay a byte-for-byte copy "
                + "of the SDK's packs/simplewords-v3/pack.json")
        XCTAssertEqual(manifest.modelID, SDKCleanupBackend.supportedModelID)
        XCTAssertEqual(manifest.modelRevision, "b1f7ac8282ce060e4ad1374cb9a34750e31723c1")
        XCTAssertEqual(manifest.artifacts.count, 7)
        XCTAssertTrue(manifest.artifacts.contains { $0.path == "system_v2.txt" },
                      "the frozen prompt is part of the pinned artifact set")
        XCTAssertEqual(manifest.artifacts.first { $0.path == "model.safetensors" }?.bytes, 2_000_043_615)
    }
}

private final class Unchecked<Value>: @unchecked Sendable {
    var value: Value
    init(_ value: Value) { self.value = value }
}
