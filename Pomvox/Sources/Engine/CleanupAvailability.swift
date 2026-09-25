import Darwin
import Foundation

/// Why a cleanup model isn't usable, in words the Settings pane and the menu
/// bar can show verbatim. Download failures and load failures are different
/// events: a bad network leaves bytes unwritten, a bad load means the snapshot
/// is already on disk.
enum CleanupFailure: Equatable {
    case download(String)
    case load(String)
}

/// Where the cleanup model actually is. Independent of the enabled toggle:
/// the toggle is the user's choice, this is whether that choice can run.
enum CleanupModelPhase: Equatable {
    case notDownloaded
    case downloading(fraction: Double?)
    /// Snapshot is in the Hugging Face cache; weights are not in memory.
    case onDisk
    case loading
    case ready
    case failed(CleanupFailure)
}

/// What to do next for an enabled cleanup setting. A download already in
/// flight is never replaced — a second `downloadSnapshot` waits forever on
/// the same file lock (`maxRetries: nil`).
enum CleanupModelAction: Equatable {
    case none
    case download
    case load
}

/// Pure transitions for cleanup availability. The engine applies these; it
/// does not invent a second policy beside them.
///
/// Two events are deliberately no-ops on the download itself:
/// - `utteranceTimedOut` — the 5 s cleanup budget abandons *this dictation*.
///   It must not cancel a first-time download or model load.
/// - `engineRestarted` — disarm/re-arm drops in-memory weights, but a
///   download that already started keeps the file lock until it finishes.
///   Cancelling it is what left a 0-byte `.lock` and no blobs.
struct CleanupAvailabilityState: Equatable {
    var enabled: Bool
    var phase: CleanupModelPhase
    var downloadInFlight: Bool
    /// Set only when a download is actually cancelled. Utterance timeouts and
    /// engine restarts must leave this false.
    var downloadCancelled: Bool

    static let initial = CleanupAvailabilityState(
        enabled: false, phase: .notDownloaded,
        downloadInFlight: false, downloadCancelled: false)

    func applying(_ event: Event) -> CleanupAvailabilityState {
        switch event {
        case .downloadStarted, .retry:
            guard !downloadInFlight else { return self }
            switch phase {
            case .notDownloaded, .failed:
                var s = self
                s.phase = .downloading(fraction: nil)
                s.downloadInFlight = true
                s.downloadCancelled = false
                return s
            default:
                return self
            }
        case .progress(let fraction):
            guard downloadInFlight else { return self }
            var s = self
            s.phase = .downloading(fraction: fraction)
            return s
        case .downloadFinished:
            var s = self
            s.downloadInFlight = false
            if case .downloading = s.phase { s.phase = .onDisk }
            return s
        case .loadStarted:
            var s = self
            s.phase = .loading
            return s
        case .loadFinished:
            var s = self
            s.phase = .ready
            return s
        case .failed(let failure):
            var s = self
            s.downloadInFlight = false
            s.phase = .failed(failure)
            return s
        case .evicted:
            var s = self
            if s.phase == .ready { s.phase = .onDisk }
            return s
        case .engineRestarted:
            // Weights are dropped with the engine. A download in flight is
            // not part of the engine session and is left running.
            var s = self
            switch s.phase {
            case .ready, .loading:
                s.phase = .onDisk
            default:
                break
            }
            return s
        case .utteranceTimedOut:
            return self
        case .turnedOn:
            var s = self
            s.enabled = true
            return s
        case .turnedOff:
            var s = self
            s.enabled = false
            if s.phase == .ready || s.phase == .loading { s.phase = .onDisk }
            return s
        }
    }

    enum Event: Equatable {
        case downloadStarted
        case retry
        case progress(Double)
        case downloadFinished
        case loadStarted
        case loadFinished
        case failed(CleanupFailure)
        case evicted
        case engineRestarted
        case utteranceTimedOut
        case turnedOn
        case turnedOff
    }
}

enum CleanupAvailability {
    /// Next step when cleanup is enabled. `.none` while a download is already
    /// in flight, and while the weights are loading or resident.
    static func action(for state: CleanupAvailabilityState) -> CleanupModelAction {
        guard state.enabled, !state.downloadInFlight else { return .none }
        switch state.phase {
        case .notDownloaded:
            return .download
        case .onDisk:
            return .load
        case .failed, .downloading, .loading, .ready:
            // A failure stays failed until Retry. Starting another download
            // on every arm would also race the file lock.
            return .none
        }
    }

    static func percent(_ fraction: Double) -> Int {
        max(0, min(100, Int((fraction * 100).rounded())))
    }

    /// Settings → Models, and the menu bar while cleanup is on but not ready.
    static func modelStatusLine(_ phase: CleanupModelPhase) -> String {
        switch phase {
        case .notDownloaded:
            return "Cleanup model not downloaded"
        case .downloading(let fraction):
            if let fraction {
                return "Cleanup model downloading… \(percent(fraction))%"
            }
            return "Cleanup model downloading…"
        case .onDisk:
            return "Cleanup model downloaded"
        case .loading:
            return "Loading the cleanup model…"
        case .ready:
            return "Cleanup model ready"
        case .failed(.download(let reason)):
            return "Download failed: \(reason)"
        case .failed(.load(let reason)):
            return "Cleanup model failed to load: \(reason)"
        }
    }

    /// Menu bar / engine row. Quiet once the model is actually resident —
    /// the toggle being on is the whole story then.
    static func menuLine(_ state: CleanupAvailabilityState) -> String? {
        guard state.enabled else { return nil }
        switch state.phase {
        case .ready: return nil
        default: return modelStatusLine(state.phase)
        }
    }

    /// Beside the cleanup toggle: the choice and whether it is really running.
    static func runtimeSummary(_ state: CleanupAvailabilityState) -> String {
        guard state.enabled else { return "Cleanup is off" }
        switch state.phase {
        case .ready:
            return "Cleanup is on — model loaded"
        case .notDownloaded:
            return "Cleanup is on — model not downloaded"
        case .downloading(let fraction):
            if let fraction {
                return "Cleanup is on — downloading model… \(percent(fraction))%"
            }
            return "Cleanup is on — downloading model…"
        case .onDisk:
            return "Cleanup is on — model downloaded, not loaded yet"
        case .loading:
            return "Cleanup is on — loading the model…"
        case .failed(.download(let reason)):
            return "Cleanup is on — download failed: \(reason)"
        case .failed(.load(let reason)):
            return "Cleanup is on — model failed to load: \(reason)"
        }
    }

    static func statusSymbol(_ state: CleanupAvailabilityState) -> String {
        switch state.phase {
        case .ready where state.enabled: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        default: return "arrow.down.circle"
        }
    }

    /// Button next to the cleanup model. Hidden while a transfer or load is
    /// already underway, and once the snapshot is on disk.
    static func buttonTitle(_ phase: CleanupModelPhase) -> String? {
        switch phase {
        case .notDownloaded: return "Download model"
        case .failed: return "Retry download"
        default: return nil
        }
    }

    /// What a dictation tells the user when cleanup was requested and the
    /// model can't run. `nil` means "try cleanup" — including a weights load
    /// already in flight, which `clean()` waits out inside the utterance
    /// budget. `afterWaiting` is that wait expiring before the weights landed.
    static func dictationNotice(_ phase: CleanupModelPhase, afterWaiting: Bool = false) -> String? {
        switch phase {
        case .ready:
            return nil
        case .downloading:
            return "cleanup unavailable (downloading)"
        case .notDownloaded:
            return "cleanup unavailable (model not downloaded)"
        case .loading, .onDisk:
            return afterWaiting ? "cleanup unavailable (still loading)" : nil
        case .failed(.download(let reason)):
            return "cleanup unavailable (download failed: \(reason))"
        case .failed(.load(let reason)):
            return "cleanup unavailable (model failed to load: \(reason))"
        }
    }

    /// Short, single-line reason for the UI. The log keeps the full error.
    static func failureMessage(_ error: Error) -> String {
        let raw: String
        if let localized = (error as? LocalizedError)?.errorDescription,
           !localized.isEmpty {
            raw = localized
        } else {
            raw = String(describing: error)
        }
        let trimmed = raw.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 180 { return trimmed }
        return String(trimmed.prefix(177)) + "…"
    }
}

/// Hugging Face blob locks (`~/.cache/huggingface/hub/.locks/…/*.lock`).
///
/// `FileLock` creates the file with `O_CREAT|O_TRUNC` *before* any blob is
/// written, and `downloadSnapshot` waits on it forever (`maxRetries: nil`).
/// The file is kept after release, so a crash or a killed download leaves a
/// 0-byte `.lock` and no snapshot. The lock is `flock(2)`, not the file's
/// existence: if nobody holds it, delete it so the next attempt doesn't sit
/// behind a leftover. A lock another live download still holds is left alone.
enum HuggingFaceStaleLock {
    static func defaultHubCache() -> URL {
        let env = ProcessInfo.processInfo.environment["HF_HUB_CACHE"]
            ?? ProcessInfo.processInfo.environment["HUGGINGFACE_HUB_CACHE"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// `.locks/models--org--name/` for a `org/name` repo id.
    static func lockDirectory(repoID: String, hubCache: URL) -> URL {
        let folder = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        return hubCache
            .appendingPathComponent(".locks", isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    /// Deletes unheld `*.lock` files under `directory`. Returns how many were
    /// removed. A file another process (or this one) still has `flock`'d is
    /// not deleted.
    static func reclaimUnheldLocks(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])
        else { return 0 }
        var removed = 0
        for case let url as URL in enumerator {
            guard url.pathExtension == "lock" else { continue }
            if reclaim(url) { removed += 1 }
        }
        return removed
    }

    static func reclaimUnheldLocks(forRepo repoID: String, hubCache: URL = defaultHubCache()) -> Int {
        reclaimUnheldLocks(in: lockDirectory(repoID: repoID, hubCache: hubCache))
    }

    /// Acquire a non-blocking exclusive lock. If that succeeds, nobody else
    /// holds it — unlink the directory entry and release. Returns whether the
    /// file was removed.
    static func reclaim(_ lockFile: URL) -> Bool {
        let fd = open(lockFile.path, O_RDWR | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let result = flock(fd, LOCK_EX | LOCK_NB)
        guard result == 0 else { return false }
        defer { flock(fd, LOCK_UN) }
        return unlink(lockFile.path) == 0
    }
}
