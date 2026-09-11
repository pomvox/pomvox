import Foundation

/// What Pomvox stores, where, and how big it is on disk — the honest version of
/// Wispr's "Privacy Mode." The Privacy pane reads this so the local-only claim is
/// verifiable, not marketing (decision #7). Path assembly + size formatting are
/// pure and unit-tested; the live byte counts come from `FileManager`.
struct StorageItem: Identifiable {
    let id = UUID()
    let label: String
    let displayPath: String   // home collapsed to ~
    let detail: String
    let bytes: Int64

    var sizeText: String { StorageInspector.humanSize(bytes) }
}

enum StorageInspector {
    /// Human-friendly size; "empty" rather than "Zero KB" for a clean pane.
    static func humanSize(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "empty" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    /// Collapse the user's home directory back to `~` for display.
    static func collapseHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The artifacts to list, in display order, as (label, primary path, sibling
    /// paths that count toward its size, detail). Pure — `scan` adds sizes.
    static func artifacts(dbPath: String = HistoryReader.defaultPath(),
                          configPath: String = SettingsModel.defaultPath(),
                          evalDir: String = EvalPaths.captureDir())
        -> [(label: String, primary: String, paths: [String], detail: String, isDir: Bool)] {
        let modelsDir = NSString(string: "~/.cache/huggingface/hub").expandingTildeInPath
        return [
            ("Dictation history", dbPath, [dbPath, dbPath + "-wal", dbPath + "-shm"],
             "Transcripts only — never audio. Cleared below or by retention.", false),
            ("Settings", configPath, [configPath],
             "Your config.toml — edited right here in Settings.", false),
            ("Downloaded models", modelsDir, [modelsDir],
             "Speech + cleanup models. Re-downloadable, so a wipe leaves them.", true),
            ("Evaluation pairs", evalDir, [evalDir],
             "Raw + cleaned text pairs, only while capture is on. Never audio.", true),
        ]
    }

    /// Live report: each artifact with its current on-disk size.
    static func scan(dbPath: String = HistoryReader.defaultPath(),
                     configPath: String = SettingsModel.defaultPath(),
                     evalDir: String = EvalPaths.captureDir()) -> [StorageItem] {
        artifacts(dbPath: dbPath, configPath: configPath, evalDir: evalDir).map { a in
            let bytes = a.isDir ? directorySize(a.primary)
                                : a.paths.reduce(0) { $0 + fileSize($1) }
            return StorageItem(label: a.label, displayPath: collapseHome(a.primary),
                               detail: a.detail, bytes: bytes)
        }
    }

    // MARK: - sizes (FileManager, not pure)

    private static func fileSize(_ path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            let v = try? f.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
        }
        return total
    }
}
