import XCTest
import SQLite3
@testable import Pomvox

/// Stats parity: the Swift Hub must compute the same numbers the Python
/// HistoryStore would over the same rows. The definitions live in
/// HistoryReader; these fixtures pin them.
///
/// Equivalent Python (reused from src/pomvox/history.py rows):
///   total_words = sum(len(r.final_text.split()) for r in rows)
///   count       = len(rows)
///   timed       = [r for r in rows if r.duration_s and r.duration_s > 0]
///   avg_wpm     = round(sum(len(r.final_text.split()) for r in timed)
///                       / (sum(r.duration_s for r in timed) / 60))
final class HistoryReaderTests: XCTestCase {

    /// Fixed clock so the 30-day window and day buckets are deterministic.
    /// 2026-06-11 18:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_781_200_800)
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()

    private struct Row { let final: String; let raw: String; let dur: Double?; let agoSeconds: Double }

    private func fixture() -> [Row] {
        [
            Row(final: "let's meet on friday",        raw: "lets meet on friday",  dur: 6,  agoSeconds: 3600),       // today, 4w
            Row(final: "do the thing and ship it",    raw: "do the thing ship it", dur: 12, agoSeconds: 7200),       // today, 6w
            Row(final: "hello there",                 raw: "hello there",          dur: nil, agoSeconds: 86_400),     // -1d, 2w, untimed
            Row(final: "one two three four five",     raw: "one two three four",   dur: 5,  agoSeconds: 3 * 86_400),  // -3d, 5w
            Row(final: "",                            raw: "uh",                   dur: 2,  agoSeconds: 40 * 86_400), // -40d, 0w, outside window
        ]
    }

    private func makeDB(_ rows: [Row]) throws -> String {
        let path = NSTemporaryDirectory() + "pomvox-test-\(UUID().uuidString).db"
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE history (id INTEGER PRIMARY KEY, ts REAL, raw_text TEXT, final_text TEXT,
              cleanup_status TEXT, app_hint TEXT, duration_s REAL, timings_json TEXT);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)

        // Bound parameters, not string interpolation — final_text contains
        // apostrophes ("let's") that would otherwise break the SQL.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let insert = "INSERT INTO history (ts,raw_text,final_text,cleanup_status,app_hint,duration_s,timings_json)"
            + " VALUES (?,?,?,?,NULL,?,'');"
        for r in rows {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, insert, -1, &stmt, nil), SQLITE_OK)
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970 - r.agoSeconds)
            sqlite3_bind_text(stmt, 2, r.raw, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, r.final, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, "ok", -1, SQLITE_TRANSIENT)
            if let d = r.dur { sqlite3_bind_double(stmt, 5, d) } else { sqlite3_bind_null(stmt, 5) }
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE, "insert failed")
            sqlite3_finalize(stmt)
        }
        return path
    }

    func testStatsMatchExpected() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = HistoryReader(path: path)
        let rows = reader.load()
        XCTAssertEqual(rows.count, 5)
        // newest first
        XCTAssertEqual(rows.first?.final, "let's meet on friday")

        let s = reader.stats(rows: rows, now: now, calendar: utc)
        XCTAssertEqual(s.totalWords, 17)        // 4+6+2+5+0
        XCTAssertEqual(s.dictationCount, 5)
        // wordsTimed = 4+6+5+0 = 15; seconds = 6+12+5+2 = 25 → 15 / (25/60) = 36
        XCTAssertEqual(s.averageWPM, 36)
        XCTAssertEqual(s.secondsSpoken, 25)
    }

    func testActivityBuckets() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = HistoryReader(path: path)
        let s = reader.stats(rows: reader.load(), now: now, calendar: utc)

        XCTAssertEqual(s.activity.count, 30)
        let byOffset = Dictionary(uniqueKeysWithValues: s.activity.map { ($0.id, $0.words) })
        XCTAssertEqual(byOffset[29], 10)   // today: 4 + 6
        XCTAssertEqual(byOffset[28], 2)    // yesterday
        XCTAssertEqual(byOffset[26], 5)    // 3 days ago (offset 29-3)
        XCTAssertEqual(s.activity.map(\.words).reduce(0, +), 17)  // -40d row excluded
    }

    func testMissingDatabaseIsEmptyNotError() {
        let reader = HistoryReader(path: NSTemporaryDirectory() + "does-not-exist.db")
        XCTAssertFalse(reader.databaseExists)
        XCTAssertTrue(reader.load().isEmpty)
        let s = reader.stats(rows: [], now: now, calendar: utc)
        XCTAssertEqual(s.totalWords, 0)
        XCTAssertEqual(s.averageWPM, 0)
    }

    func testWordCount() {
        XCTAssertEqual(Dictation.countWords("one two three"), 3)
        XCTAssertEqual(Dictation.countWords("  spaced   out  "), 2)
        XCTAssertEqual(Dictation.countWords(""), 0)
    }

    // MARK: - heatmap (90-day calendar grid)

    private func dictation(daysAgo: Int, words: Int) -> Dictation {
        let ts = utc.date(byAdding: .day, value: -daysAgo, to: now)!
        let final = words > 0 ? Array(repeating: "w", count: words).joined(separator: " ") : ""
        return Dictation(id: Int64(daysAgo), timestamp: ts, raw: final, final: final,
                         cleanupStatus: "ok", appHint: nil, durationSeconds: nil)
    }

    func testHeatmapGridShape() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }
        let reader = HistoryReader(path: path)
        let cells = reader.heatmap(rows: reader.load(), now: now, calendar: utc, weeks: 13)

        XCTAssertEqual(cells.count, 91)                       // 13 weeks × 7 days
        XCTAssertEqual(cells.map(\.week).max(), 12)
        XCTAssertTrue(cells.allSatisfy { (0...6).contains($0.weekday) })

        let today = utc.startOfDay(for: now)
        XCTAssertTrue(cells.filter { $0.inFuture }.allSatisfy { $0.date > today })
        XCTAssertTrue(cells.filter { !$0.inFuture }.allSatisfy { $0.date <= today })

        // today (June 11) is a Thursday → Fri+Sat are the only future cells.
        XCTAssertEqual(cells.filter(\.inFuture).count, 2)

        // The 90-day window includes the -40d row (0 words); total still 17.
        let todayCell = cells.first { utc.isDate($0.date, inSameDayAs: now) }
        XCTAssertEqual(todayCell?.words, 10)                  // 4 + 6
        XCTAssertEqual(cells.filter { !$0.inFuture }.reduce(0) { $0 + $1.words }, 17)
    }

    // MARK: - streak (your consecutive active days)

    func testStreakCountsConsecutiveDays() {
        let r = [dictation(daysAgo: 0, words: 4),
                 dictation(daysAgo: 1, words: 2),
                 dictation(daysAgo: 2, words: 9)]
        XCTAssertEqual(HistoryReader().streak(rows: r, now: now, calendar: utc), 3)
    }

    func testStreakStopsAtAGap() {
        let r = [dictation(daysAgo: 0, words: 4),
                 dictation(daysAgo: 1, words: 2),
                 dictation(daysAgo: 3, words: 9)]   // gap at -2d
        XCTAssertEqual(HistoryReader().streak(rows: r, now: now, calendar: utc), 2)
    }

    func testStreakGraceWhenTodayEmpty() {
        // Nothing today yet, but yesterday + the day before were active.
        let r = [dictation(daysAgo: 1, words: 2), dictation(daysAgo: 2, words: 3)]
        XCTAssertEqual(HistoryReader().streak(rows: r, now: now, calendar: utc), 2)
    }

    func testStreakZeroWhenStale() {
        let r = [dictation(daysAgo: 3, words: 3), dictation(daysAgo: 4, words: 3)]
        XCTAssertEqual(HistoryReader().streak(rows: r, now: now, calendar: utc), 0)
    }

    func testStreakIgnoresEmptyText() {
        // A 0-word row today must not count as an active day.
        let r = [dictation(daysAgo: 0, words: 0), dictation(daysAgo: 1, words: 2)]
        XCTAssertEqual(HistoryReader().streak(rows: r, now: now, calendar: utc), 1)  // grace → yesterday
    }

    // MARK: - lifetime totals (read side)

    func testLifetimeTotalsSurfaceThroughReader() throws {
        let path = NSTemporaryDirectory() + "pomvox-lifetime-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = try XCTUnwrap(HistoryStore(path: path, retentionDays: 7))
        s.add(ts: 1.0, rawText: "r", finalText: "one two", cleanupStatus: "ok", timingsJson: "")
        s.close()
        let t = try XCTUnwrap(HistoryReader(path: path).lifetimeTotals())
        XCTAssertEqual(t.words, 2)
        XCTAssertEqual(t.dictations, 1)
    }

    func testLifetimeTotalsNilWhenTableMissing() throws {
        // Old-format db (the fixture has no lifetime table): the Hub falls
        // back to the windowed sum instead of showing zero.
        let path = try makeDB(fixture())
        XCTAssertNil(HistoryReader(path: path).lifetimeTotals())
    }

    // MARK: - reading a WAL database (the 2026-08-27 "empty history" bug)

    /// The engine keeps the database in WAL mode, and a clean quit checkpoints
    /// and deletes the `-wal`/`-shm` sidecars. A `SQLITE_OPEN_READONLY`
    /// connection cannot recreate them, so every query failed and the Hub drew
    /// an empty history — indistinguishable from a wiped database.
    func testReadsAWalDatabaseAfterItsSidecarsAreGone() throws {
        let path = NSTemporaryDirectory() + "pomvox-wal-\(UUID().uuidString).db"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try XCTUnwrap(HistoryStore(path: path, retentionDays: 7))
        store.add(ts: 1.0, rawText: "r", finalText: "one two three",
                  cleanupStatus: "ok", timingsJson: "")
        store.close()
        // Whatever the close left behind, ensure the sidecars are absent — that
        // is the on-disk state the failure needs.
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: path + suffix)
        }

        let outcome = HistoryReader(path: path).loadOutcome()
        XCTAssertFalse(outcome.failed, "a WAL database with no sidecars must still read")
        XCTAssertEqual(outcome.rows.count, 1)
        XCTAssertEqual(outcome.rows.first?.final, "one two three")
    }

    /// The invariant that matters most. A failed read must report itself: a
    /// silent `.rows([])` renders as "No dictations yet", and a user reads that
    /// as their history having been deleted.
    func testUnreadableDatabaseIsReportedNotRenderedAsEmpty() throws {
        let path = NSTemporaryDirectory() + "pomvox-garbage-\(UUID().uuidString).db"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "this is not a sqlite database".write(
            toFile: path, atomically: true, encoding: .utf8)

        let outcome = HistoryReader(path: path).loadOutcome()
        XCTAssertEqual(outcome, .unreadable)
        XCTAssertTrue(outcome.failed)
        XCTAssertTrue(outcome.rows.isEmpty)
    }

    /// A fresh install is not a failure — it must not show the error copy.
    func testMissingDatabaseIsNoDatabaseNotAFailure() {
        let path = NSTemporaryDirectory() + "pomvox-absent-\(UUID().uuidString).db"
        let outcome = HistoryReader(path: path).loadOutcome()
        XCTAssertEqual(outcome, .noDatabase)
        XCTAssertFalse(outcome.failed)
        XCTAssertTrue(outcome.rows.isEmpty)
    }

    /// `load()` keeps its old rows-only shape for callers that don't branch.
    func testLoadStillReturnsRowsOnly() throws {
        let path = try makeDB(fixture())
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(HistoryReader(path: path).load().count, 5)
    }
}
