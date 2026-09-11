import Foundation

/// Opt-in, off-by-default capture of (raw transcript, cleaned text) pairs for
/// evaluating the cleanup model — one JSON file per dictation under
/// `~/.pomvox/eval/`.
///
/// Local disk only. Nothing in this file has a network path, and audio is
/// never written: a record is exactly the pair History already shows side by
/// side, plus the model provenance History's frozen schema cannot hold (which
/// cleanup model actually ran, the STT model, the app build). Unlike history
/// it is not subject to retention, so an eval set can accumulate deliberately
/// and be deleted deliberately (Settings → Privacy).
///
/// The flag lives in UserDefaults — native-app state like `telemetry.consent`,
/// not shared `config.toml`, which the Python engine reads and must never learn
/// about. The engine re-reads it per dictation, so the toggle applies without
/// a re-arm. Writes happen strictly after the paste, off the latency path, and
/// every failure is log-and-continue: capture must never cost a word.
enum EvalPaths {
    /// `~/.pomvox/eval`, overridable like `POMVOX_CONFIG_PATH` so tests and
    /// rigs can redirect it.
    static func captureDir() -> String {
        if let o = ProcessInfo.processInfo.environment["POMVOX_EVAL_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/eval").expandingTildeInPath
    }
}

/// The on/off switch. Default off; absent key reads as off.
struct EvalCaptureSetting {
    static let key = "eval.capturePairs"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isOn: Bool {
        get { defaults.bool(forKey: Self.key) }
        nonmutating set { defaults.set(newValue, forKey: Self.key) }
    }
}

/// One captured dictation. Field names are the file format — snake_case on
/// disk so downstream Python tooling reads them without a mapping layer.
///
/// `cleaned` is what the cleanup model produced (or the raw text it fell back
/// to — see `cleanup_status`), captured *before* dictionary fixups and the
/// dictation mark so the pair reflects the model alone. `cleanup_status` is
/// what makes a record usable: without it a timeout's raw fallback would
/// masquerade as a cleaned pair and poison the eval set.
struct EvalRecord: Codable, Equatable {
    let id: String
    let ts: String            // ISO 8601, UTC, millisecond precision
    let rawAsr: String
    let cleaned: String
    let durationMs: Int       // audio length, not wall-clock latency
    let modelVersion: String  // cleanup model that ran, or "off"
    let cleanupStatus: String // ok | timeout | rejected | error | off
    let sttModel: String
    let style: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case id, ts, cleaned, style
        case rawAsr = "raw_asr"
        case durationMs = "duration_ms"
        case modelVersion = "model_version"
        case cleanupStatus = "cleanup_status"
        case sttModel = "stt_model"
        case appVersion = "app_version"
    }

    init(id: UUID = UUID(), at date: Date = Date(),
         rawAsr: String, cleaned: String, durationS: Double,
         modelVersion: String, cleanupStatus: String,
         sttModel: String, style: String, appVersion: String) {
        self.id = id.uuidString.lowercased()
        self.ts = Self.iso8601(date)
        self.rawAsr = rawAsr
        self.cleaned = cleaned
        self.durationMs = Self.milliseconds(durationS)
        self.modelVersion = modelVersion
        self.cleanupStatus = cleanupStatus
        self.sttModel = sttModel
        self.style = style
        self.appVersion = appVersion
    }

    /// Capture only real dictations: the flag is on, STT heard something, and
    /// something was actually pasted (the empty-transcript path never records,
    /// mirroring history).
    static func shouldCapture(enabled: Bool, raw: String, pasted: String) -> Bool {
        enabled && !raw.isEmpty && !pasted.isEmpty
    }

    static func milliseconds(_ seconds: Double) -> Int {
        Int((seconds * 1000).rounded())
    }

    static func iso8601(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// `20260910-211305-<uuid>.json` — sorts chronologically in a listing, and
    /// the UUID keeps two dictations in the same second from colliding.
    var fileName: String {
        let compact = ts.replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "T", with: "-")
        let stamp = String(compact.prefix(15))   // yyyyMMdd-HHmmss
        return "\(stamp)-\(id).json"
    }

    /// "0.2.6 (17)" — marketing version + build, no product prefix.
    static func appVersion(_ bundle: Bundle = .main) -> String {
        let v = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

extension Notification.Name {
    /// A record was written or the folder was purged — the Privacy pane and
    /// the storage report refresh their counts.
    static let pomvoxEvalCaptureDidChange = Notification.Name("app.pomvox.evalCaptureDidChange")
}

/// The folder: create, write, count, purge. Lock-guarded — the engine writes
/// from its post-paste background task while the Privacy pane reads on the
/// main actor. Best-effort throughout: a failed write is logged and dropped,
/// never surfaced into the dictation path.
final class EvalCaptureStore: @unchecked Sendable {
    static let shared = EvalCaptureStore()

    let dir: String
    private let lock = NSLock()

    init(dir: String = EvalPaths.captureDir()) {
        self.dir = dir
    }

    var directoryURL: URL { URL(fileURLWithPath: dir, isDirectory: true) }

    /// Create the folder (owner-only, like history.db) if it isn't there.
    /// Returns false when it can't be created — e.g. the path is a file.
    @discardableResult
    func ensureDirectory() -> Bool {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) {
            return isDir.boolValue
        }
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            NSLog("eval-capture: cannot create %@: %@", dir, String(describing: error))
            return false
        }
    }

    /// Write one record as its own file. Atomic, so a crash mid-write leaves
    /// no half-record for tooling to choke on.
    @discardableResult
    func write(_ record: EvalRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ensureDirectory() else { return false }
        let url = directoryURL.appendingPathComponent(record.fileName)
        do {
            let data = try Self.encoder.encode(record)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("eval-capture: write failed: %@", String(describing: error))
            return false
        }
        NotificationCenter.default.post(name: .pomvoxEvalCaptureDidChange, object: nil)
        return true
    }

    /// The record files: `*.json` directly inside the folder, nothing nested.
    func recordFiles() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return recordFilesLocked()
    }

    func count() -> Int { recordFiles().count }

    func bytes() -> Int64 {
        recordFiles().reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + Int64(size)
        }
    }

    /// Delete every record file. Only `*.json` directly in the folder — a
    /// user's own notes or subfolders dropped in there are left alone. Returns
    /// how many were removed.
    @discardableResult
    func purge() -> Int {
        lock.lock()
        var removed = 0
        for url in recordFilesLocked() {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                NSLog("eval-capture: purge could not remove %@: %@",
                      url.lastPathComponent, String(describing: error))
            }
        }
        lock.unlock()
        NotificationCenter.default.post(name: .pomvoxEvalCaptureDidChange, object: nil)
        return removed
    }

    private func recordFilesLocked() -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .sorted()
            .map { directoryURL.appendingPathComponent($0) }
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                    && !isDir.boolValue
            }
    }

    /// Stable, readable files: sorted keys so two records diff cleanly, and
    /// model ids like `org/name` stay unescaped.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}
