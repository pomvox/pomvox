import Darwin
import Foundation

/// One model on disk, for Settings ▸ Models. `inUse` means the saved config
/// names it; those rows are never removable.
struct DownloadedModel: Identifiable, Equatable {
    let id: String          // repo id, e.g. "mlx-community/Qwen3-4B-4bit"
    let folder: URL
    let bytes: Int64
    let inUse: Bool
    var sizeText: String { StorageInspector.humanSize(bytes) }
}

/// Lists and removes downloaded models (#100). Two roots: the Hugging Face hub cache
/// (`models--org--name`, mlx-swift-lm and the Python engine) and FluidAudio's `Models/<repo>`,
/// where the Parakeet speech model actually lives. Unit-tested against a temp cache.
enum DownloadedModels {
    struct Roots: Equatable { let hubCache: URL; let fluidModels: URL }

    static func defaultRoots() -> Roots {
        Roots(hubCache: HuggingFaceStaleLock.defaultHubCache(),
              fluidModels: FileManager.default.homeDirectoryForCurrentUser
                  .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true))
    }

    /// `models--org--name` → `org/name`; anything else (`.locks`, `version.txt`) is nil.
    static func repoID(hubFolder name: String) -> String? {
        guard name.hasPrefix("models--") else { return nil }
        let id = name.dropFirst("models--".count).replacingOccurrences(of: "--", with: "/")
        return id.isEmpty ? nil : id
    }

    /// In use = named by the saved config, or the Parakeet family at the version
    /// the engine will actually load (a typo resolves to the default, so the
    /// default's files are in use; the Python engine's `mlx-community/parakeet-…` counts too).
    static func isInUse(repoID: String, sttModel: String, cleanupModel: String) -> Bool {
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if repoID == trim(sttModel) || repoID == trim(cleanupModel) { return true }
        let lower = repoID.lowercased()
        return lower.contains("parakeet")
            && lower.contains(CompiledModelCache.matchToken(for: SttModel.resolve(sttModel)))
    }

    /// Why removal must wait, or nil when it is safe: a speech load, a cleanup
    /// download or load, and the arm itself have files open under these roots.
    static func busyReason(engineStatus: NativeEngine.Status, speechLoad: String?,
                           cleanupPhase: CleanupModelPhase) -> String? {
        if engineStatus == .preparing || speechLoad != nil {
            return "Wait for the speech model to finish loading."
        }
        switch cleanupPhase {
        case .downloading: return "Wait for the cleanup model download to finish."
        case .loading: return "Wait for the cleanup model to finish loading."
        default: return nil
        }
    }

    // MARK: - Disk scan (thin shell)

    static func scan(roots: Roots = defaultRoots(), sttModel: String, cleanupModel: String) -> [DownloadedModel] {
        let fm = FileManager.default
        func folders(_ root: URL, id: (String) -> String?) -> [DownloadedModel] {
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().compactMap { name in
                let folder = root.appendingPathComponent(name, isDirectory: true)
                var isDir: ObjCBool = false
                guard let id = id(name), fm.fileExists(atPath: folder.path, isDirectory: &isDir),
                      isDir.boolValue else { return nil }
                return DownloadedModel(
                    id: id, folder: folder, bytes: StorageInspector.directorySize(folder.path),
                    inUse: isInUse(repoID: id, sttModel: sttModel, cleanupModel: cleanupModel))
            }
        }
        return folders(roots.hubCache, id: repoID(hubFolder:))
            + folders(roots.fluidModels) { $0.hasPrefix(".") ? nil : $0 }
    }

    // MARK: - Removal (thin shell; never touches an in-use or busy model)

    struct Outcome: Equatable { var removed: [String] = []; var kept: [String] = []; var bytesFreed: Int64 = 0 }

    /// Delete the unused models among `models`. An in-use model, one whose hub
    /// lock a download still holds, or one the filesystem refuses to delete is
    /// kept, files intact, and named in `kept`.
    static func remove(_ models: [DownloadedModel], roots: Roots = defaultRoots()) -> Outcome {
        var outcome = Outcome()
        for m in models {
            let lockDir = HuggingFaceStaleLock.lockDirectory(repoID: m.id, hubCache: roots.hubCache)
            guard !m.inUse, !isLockHeld(in: lockDir) else { outcome.kept.append(m.id); continue }
            do {
                try FileManager.default.removeItem(at: m.folder)
                try? FileManager.default.removeItem(at: lockDir)
                outcome.removed.append(m.id)
                outcome.bytesFreed += m.bytes
            } catch {
                NSLog("models: could not remove %@: %@", m.id, String(describing: error))
                outcome.kept.append(m.id)
            }
        }
        return outcome
    }

    /// True when any `*.lock` under `directory` is flock'd: a download in flight,
    /// in this process or another (`HuggingFaceStaleLock`: existence alone means nothing).
    static func isLockHeld(in directory: URL) -> Bool {
        guard let e = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return false }
        for case let url as URL in e where url.pathExtension == "lock" {
            let fd = open(url.path, O_RDWR | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 { return true }
            flock(fd, LOCK_UN)
        }
        return false
    }
}
