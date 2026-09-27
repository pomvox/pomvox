import CryptoKit
import Foundation
import PomvoxCleanupMLX

/// Where the SDK backend's verified pack comes from.
///
/// The SDK installs and validates; the host decides *what* to trust and
/// *where* it lives. Trust comes only from the manifest bundled in the app —
/// the SDK's pinned `packs/simplewords-v3/pack.json`, copied byte for byte and
/// checked against `bundledManifestSHA256` — never from bytes found in a
/// downloaded snapshot or an existing directory.
enum SDKProvisionedPack: Sendable {
    /// Installed by this call. The installer already hashed every byte, so the
    /// first open reuses its handle instead of hashing 2 GB again.
    case installed(ValidatedPack)
    /// An existing installation whose manifest is the trusted one. Opening it
    /// performs the full `.directory` validation.
    case existing(URL)

    var source: PackSource {
        switch self {
        case .installed(let pack): return .validated(pack)
        case .existing(let url): return .directory(url)
        }
    }
}

protocol SDKPackProvisioning: Sendable {
    /// SHA-256 of the trusted manifest bytes — the digest a correctly opened
    /// cleaner reports as `pack.digest`.
    var trustedDigest: String { get }
    /// The trusted manifest, decoded (capabilities, identity) before any open.
    var trustedManifest: PackManifest { get }
    func provision(onProgress: (@Sendable (Double) -> Void)?) async throws -> SDKProvisionedPack
}

enum SDKPackError: Error, Equatable, LocalizedError {
    case manifestMissing
    case manifestNotTrusted
    case existingInstallationDiffers(String)
    case untrustedPackOpened

    var errorDescription: String? {
        switch self {
        case .manifestMissing:
            return "The app's cleanup pack manifest is missing."
        case .manifestNotTrusted:
            return "The app's cleanup pack manifest does not match its pinned hash."
        case .existingInstallationDiffers(let path):
            return "The cleanup pack at \(path) is not the one this app trusts. It is left untouched; "
                + "remove it to reinstall."
        case .untrustedPackOpened:
            return "The opened cleanup pack is not the one this app trusts."
        }
    }
}

struct SDKPackProvisioner: SDKPackProvisioning {
    /// SHA-256 of `Resources/simplewords-v3.pack.json`, identical to the SDK's
    /// `packs/simplewords-v3/pack.json` (`scripts/check-cleanup-pack-manifest.sh`
    /// compares the two at the repo level; tests never read the submodule).
    static let bundledManifestSHA256 =
        "b18de5147868b8f24b706eeee065236926471ea3156aa69670ec43fa5f15059e"
    static let bundledResourceName = "simplewords-v3.pack"

    let manifestData: Data
    let trustedManifest: PackManifest
    let trustedDigest: String
    /// Parent of every installation: `~/Library/Application Support/Pomvox/CleanupPacks`.
    let root: URL
    /// Acquire the licensed snapshot the manifest describes. The host's job,
    /// explicitly: the SDK never downloads.
    private let acquireSnapshot: @Sendable (PackManifest, (@Sendable (Double) -> Void)?) async throws -> URL

    init(manifestData: Data, pinnedSHA256: String = Self.bundledManifestSHA256, root: URL,
         acquireSnapshot: @escaping @Sendable (PackManifest, (@Sendable (Double) -> Void)?) async throws -> URL
    ) throws {
        let digest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        guard digest == pinnedSHA256 else { throw SDKPackError.manifestNotTrusted }
        self.manifestData = manifestData
        self.trustedManifest = try JSONDecoder().decode(PackManifest.self, from: manifestData)
        self.trustedDigest = digest
        self.root = root
        self.acquireSnapshot = acquireSnapshot
    }

    /// The app's configuration: bundled manifest, Application Support, and the
    /// same Hugging Face snapshot download the in-app engine uses.
    static func bundled(in bundle: Bundle = .main) throws -> SDKPackProvisioner {
        guard let url = bundle.url(forResource: bundledResourceName, withExtension: "json") else {
            throw SDKPackError.manifestMissing
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomvox/CleanupPacks", isDirectory: true)
        return try SDKPackProvisioner(manifestData: try Data(contentsOf: url), root: root) { manifest, progress in
            try await CleanupEngine.fetchFrozenSnapshot(modelID: manifest.modelID, onProgress: progress)
        }
    }

    /// One directory per trusted manifest. A different manifest (a new pack
    /// version) installs beside the old one; nothing is ever overwritten.
    var destination: URL {
        root.appendingPathComponent(
            "\(trustedManifest.id)-\(trustedManifest.version)-\(trustedDigest.prefix(12))", isDirectory: true)
    }

    func provision(onProgress: (@Sendable (Double) -> Void)?) async throws -> SDKProvisionedPack {
        let destination = self.destination
        if try existingMatches(destination) { return .existing(destination) }
        let snapshot = try await acquireSnapshot(trustedManifest, onProgress)
        try Task.checkCancellation()
        let data = manifestData
        // Synchronous filesystem work: clone/copy then a full hash pass. Off
        // every actor, and cancellation is forwarded (the installer checks it
        // between files and while hashing).
        let install = Task.detached(priority: .utility) {
            try PackInstaller.install(snapshot: snapshot, manifestData: data, destination: destination)
        }
        do {
            let pack = try await withTaskCancellationHandler {
                try await install.value
            } onCancel: { install.cancel() }
            NSLog("cleanup: installed pack %@ %@", trustedManifest.id, trustedManifest.version)
            return .installed(pack)
        } catch let error as CleanupError {
            // Exclusive publish lost to a concurrent installer: use theirs, but
            // only if it is the trusted manifest.
            if case .invalidPack = error, try existingMatches(destination) {
                return .existing(destination)
            }
            throw error
        }
    }

    /// Whether `destination` holds an installation of the trusted manifest.
    /// Only `pack.json` is compared here; the artifacts are hashed by the SDK
    /// when the directory is opened.
    private func existingMatches(_ destination: URL) throws -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) else {
            return false
        }
        let manifest = destination.appendingPathComponent("pack.json")
        guard isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: manifest.path),
              (attributes[.size] as? Int ?? .max) <= 65_536,
              let existing = try? Data(contentsOf: manifest), existing == manifestData
        else { throw SDKPackError.existingInstallationDiffers(destination.path) }
        return true
    }

    /// After open: the cleaner must report the trusted manifest's digest.
    static func verify(_ pack: ValidatedPack, trustedDigest: String) throws {
        guard pack.digest == trustedDigest else { throw SDKPackError.untrustedPackOpened }
    }
}
