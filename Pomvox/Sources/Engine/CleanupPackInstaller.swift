import CryptoKit
import Foundation

/// Turns a Hugging Face snapshot into an installed pack the cleanup SDK will
/// open.
///
/// The SDK deliberately ships no acquisition or installation code — its
/// `Cleaner.open` takes a directory that already holds `pack.json` plus exactly
/// the seven pinned artifacts, as *regular* files, with nothing else beside
/// them. The app's snapshot is none of those things: it is an HF cache
/// directory of symlinks into `blobs/`, and `Cleaner.open` refuses symlinks and
/// unexpected entries. `scripts/prepare-local-pack.py` in the SDK repo does
/// this job on the command line; a shipping app cannot ask a user to run a
/// Python script, so this is that script's behaviour in Swift.
///
/// Guarantees, same as the Python installer: the source snapshot is never
/// modified; a partially written pack is never visible at the destination
/// (staging is published by one atomic rename rather than assembled in place);
/// checksums are computed over the bytes actually written, not the bytes read;
/// and a failure removes only what this call created.
protocol CleanupPackInstalling: Sendable {
    /// Ensure `packDirectory` holds a complete, correctly sized pack for
    /// `modelID`, downloading and installing it if it does not.
    func ensureInstalled(packDirectory: URL, modelID: String,
                         onProgress: (@Sendable (Double) -> Void)?) async throws
}

enum CleanupPackInstallError: Error, Equatable, LocalizedError {
    case manifestMissing
    case manifestUnreadable(String)
    case modelMismatch(expected: String, configured: String)
    case sourceMissing(String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case checksumMismatch(path: String)
    case destinationIncomplete(String)
    case publishFailed(String)

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "The bundled cleanup pack manifest is missing from the app."
        case .manifestUnreadable(let detail):
            return "The cleanup pack manifest could not be read: \(detail)"
        case .modelMismatch(let expected, let configured):
            return "The bundled pack is for \(expected), not \(configured)."
        case .sourceMissing(let path):
            return "The downloaded snapshot is missing \(path)."
        case .sizeMismatch(let path, let expected, let actual):
            return "\(path) is \(actual) bytes, expected \(expected)."
        case .checksumMismatch(let path):
            return "\(path) does not match its pinned checksum."
        case .destinationIncomplete(let path):
            return "\(path) exists but is not a complete pack; remove it and retry."
        case .publishFailed(let detail):
            return "The cleanup pack could not be published: \(detail)"
        }
    }
}

/// The subset of the SDK's pack manifest this installer needs. Decoded from the
/// verbatim copy of the SDK's `packs/simplewords-v3/pack.json` bundled with the
/// app — the file is copied, never re-serialized, because `Cleaner.open` hashes
/// its exact bytes and any re-encoding (key order, whitespace) would change the
/// manifest digest recorded in provenance.
struct CleanupPackManifest: Decodable, Equatable {
    struct Artifact: Decodable, Equatable {
        let path: String
        let bytes: Int
        let sha256: String
    }
    let id: String
    let version: String
    let modelID: String
    let modelRevision: String
    let artifacts: [Artifact]

    static let bundledResourceName = "simplewords-v3.pack"

    /// The bundled manifest's exact bytes and its decoded form.
    static func bundled(in bundle: Bundle = .main) throws -> (data: Data, manifest: CleanupPackManifest) {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json") else {
            throw CleanupPackInstallError.manifestMissing
        }
        return try load(contentsOf: url)
    }

    static func load(contentsOf url: URL) throws -> (data: Data, manifest: CleanupPackManifest) {
        do {
            let data = try Data(contentsOf: url)
            return (data, try JSONDecoder().decode(CleanupPackManifest.self, from: data))
        } catch let error as CleanupPackInstallError {
            throw error
        } catch {
            throw CleanupPackInstallError.manifestUnreadable(String(describing: error))
        }
    }
}

struct CleanupPackInstaller: CleanupPackInstalling {
    /// Where the manifest comes from. Injectable so tests need no app bundle.
    private let manifestSource: @Sendable () throws -> (data: Data, manifest: CleanupPackManifest)
    /// How the snapshot is obtained. Injectable so tests never download.
    private let fetchSnapshot: @Sendable (String, (@Sendable (Double) -> Void)?) async throws -> URL

    init(
        manifestSource: @escaping @Sendable () throws -> (data: Data, manifest: CleanupPackManifest)
            = { try CleanupPackManifest.bundled() },
        fetchSnapshot: @escaping @Sendable (String, (@Sendable (Double) -> Void)?) async throws -> URL
            = { modelID, onProgress in
                try await CleanupEngine.fetchFrozenSnapshot(modelID: modelID, onProgress: onProgress)
            }
    ) {
        self.manifestSource = manifestSource
        self.fetchSnapshot = fetchSnapshot
    }

    func ensureInstalled(packDirectory: URL, modelID: String,
                         onProgress: (@Sendable (Double) -> Void)?) async throws {
        let (manifestData, manifest) = try manifestSource()
        guard manifest.modelID == modelID else {
            throw CleanupPackInstallError.modelMismatch(expected: manifest.modelID, configured: modelID)
        }
        switch Self.inspect(packDirectory, manifest: manifest) {
        case .complete:
            return
        case .incomplete:
            // Never repair in place: `Cleaner.open` would meanwhile see a
            // half-written pack, and silently deleting 2 GB the user may have
            // placed there is not this installer's call.
            throw CleanupPackInstallError.destinationIncomplete(packDirectory.path)
        case .absent:
            break
        }
        let snapshot = try await fetchSnapshot(modelID, onProgress)
        try Self.install(from: snapshot, to: packDirectory,
                         manifest: manifest, manifestData: manifestData)
        NSLog("cleanup: installed pack %@ %@ at %@", manifest.id, manifest.version, packDirectory.path)
    }

    // MARK: - Inspection

    enum State: Equatable { case absent, incomplete, complete }

    /// Cheap completeness check: every artifact present as a regular file of
    /// the pinned size, plus `pack.json`, and nothing else in the directory.
    /// Checksums are deliberately not recomputed here — `Cleaner.open` hashes
    /// every byte on the way in, so doing it twice would add seconds to each
    /// arm for a guarantee the SDK already enforces.
    static func inspect(_ directory: URL, manifest: CleanupPackManifest) -> State {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory) else { return .absent }
        guard isDirectory.boolValue else { return .incomplete }
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else { return .incomplete }
        let expected = Set(manifest.artifacts.map(\.path)).union(["pack.json"])
        guard Set(entries) == expected else { return .incomplete }
        for artifact in manifest.artifacts {
            let url = directory.appendingPathComponent(artifact.path)
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, values.fileSize == artifact.bytes
            else { return .incomplete }
        }
        return .complete
    }

    // MARK: - Installation

    static func install(from snapshot: URL, to destination: URL,
                        manifest: CleanupPackManifest, manifestData: Data) throws {
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).staging-\(UUID().uuidString)")
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            for artifact in manifest.artifacts {
                // The HF cache stores each file as a symlink into blobs/;
                // resolve it so the installed pack contains regular files,
                // which is what the SDK's validator requires.
                let source = snapshot.appendingPathComponent(artifact.path).resolvingSymlinksInPath()
                guard fm.fileExists(atPath: source.path) else {
                    throw CleanupPackInstallError.sourceMissing(artifact.path)
                }
                let target = staging.appendingPathComponent(artifact.path)
                try fm.copyItem(at: source, to: target)
                let size = (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
                guard size == artifact.bytes else {
                    throw CleanupPackInstallError.sizeMismatch(path: artifact.path,
                                                               expected: artifact.bytes, actual: size)
                }
                guard try sha256(of: target) == artifact.sha256.lowercased() else {
                    throw CleanupPackInstallError.checksumMismatch(path: artifact.path)
                }
            }
            // Last, so a crashed install can never leave a directory that looks
            // complete: without pack.json the SDK refuses it outright.
            try manifestData.write(to: staging.appendingPathComponent("pack.json"))
            do {
                try fm.moveItem(at: staging, to: destination)
            } catch {
                throw CleanupPackInstallError.publishFailed(String(describing: error))
            }
        } catch {
            // Only this invocation's staging — never the destination, which
            // another installer may legitimately own by now.
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Chunked so a 2 GB weights file does not become 2 GB of resident memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
