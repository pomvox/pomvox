import SwiftUI

/// Loads the read-only history once and republishes derived stats. A plain
/// `@MainActor ObservableObject` — the heavy lifting lives in `HistoryReader`,
/// which is unit-tested without any UI.
@MainActor
final class HubModel: ObservableObject {
    @Published private(set) var rows: [Dictation] = []
    @Published private(set) var stats: HubStats = .empty
    @Published private(set) var heatmap: [HeatmapCell] = []
    @Published private(set) var hasDatabase: Bool = false
    /// The database is there but could not be read. Distinct from "no rows":
    /// the views must never show an empty history for a failed read.
    @Published private(set) var loadFailed: Bool = false

    private let reader = HistoryReader()
    private let writer = HistoryWriter()

    func reload() {
        hasDatabase = reader.databaseExists
        let outcome = reader.loadOutcome()
        loadFailed = outcome.failed
        let loaded = outcome.rows
        let nowDate = Date()
        rows = loaded
        var s = reader.stats(rows: loaded, now: nowDate)
        if let lifetime = reader.lifetimeTotals() {
            s.lifetimeWords = lifetime.words
            s.lifetimeDictations = lifetime.dictations
        }
        stats = s
        heatmap = reader.heatmap(rows: loaded, now: nowDate, calendar: .current)
    }

    // MARK: - Destructive actions (the Hub's only writes — explicit user intent)

    /// Delete one row, then re-read so every view reflects the on-disk truth.
    func delete(_ dictation: Dictation) {
        _ = writer.delete(id: dictation.id)
        reload()
    }

    /// Clear every dictation (History "Delete all"). Confirmed in the view.
    func deleteAll() {
        _ = writer.deleteAll()
        reload()
    }

    /// Privacy wipe: erase all history and shrink the file on disk. Confirmed
    /// in the Privacy pane; identical data effect to `deleteAll` plus VACUUM.
    func wipe() {
        _ = writer.wipe()
        reload()
    }

    func recent(_ n: Int) -> [Dictation] { Array(rows.prefix(n)) }

    func search(_ query: String) -> [Dictation] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return rows }
        return rows.filter { $0.final.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }
}
