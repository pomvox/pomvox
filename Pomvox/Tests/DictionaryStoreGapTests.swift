import XCTest
@testable import Pomvox

/// No-op and parse-error branches the v2 review left unpinned. A hand-edited
/// file that fails to parse must stay on disk byte for byte: these mutators
/// return before `save()`.
@MainActor
final class DictionaryStoreGapTests: XCTestCase {
    private var dir: URL!
    private var dictPath: String { dir.appendingPathComponent("dictionary.toml").path }
    private var cfgPath: String { dir.appendingPathComponent("config.toml").path }

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dict-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUpsertNoOpsDoNotSaveOrNotify() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let rule = DictionaryRule(sources: ["pom box"], target: "Pomvox",
                                   enabled: true, origin: "manual")
        store.upsert(rule, replacingID: nil)
        let before = try Data(contentsOf: URL(fileURLWithPath: dictPath))

        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: nil, queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }

        // Unknown replacing id and nothing to insert (every source blank).
        store.upsert(
            DictionaryRule(sources: ["", "  "], target: "Gone", enabled: true, origin: "manual"),
            replacingID: "no-such-id")
        // Same content id as the rule already stored: not a second insert.
        store.upsert(rule, replacingID: nil)

        XCTAssertFalse(notified)
        XCTAssertEqual(store.file.rules, [rule])
        let after = try Data(contentsOf: URL(fileURLWithPath: dictPath))
        XCTAssertEqual(after, before)
    }

    func testParseErrorBlocksMutatorsAgainstTheLastGoodFile() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.addWord("Kubernetes")
        let rule = DictionaryRule(sources: ["pom box"], target: "Pomvox",
                                   enabled: true, origin: "manual")
        store.upsert(rule, replacingID: nil)
        let good = store.file

        let stale = "words = [\"Kubernetes\"\n"
        try stale.write(toFile: dictPath, atomically: true, encoding: .utf8)
        store.reloadFromDisk()
        XCTAssertNotNil(store.parseError)
        XCTAssertEqual(store.file, good)   // last good kept; disk is the stale file

        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: nil, queue: nil
        ) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }

        store.removeWord("Kubernetes")
        store.removeRule(id: rule.id)
        store.setRuleEnabled(id: rule.id, false)

        XCTAssertFalse(notified)
        XCTAssertEqual(store.file, good)
        let raw = try String(contentsOfFile: dictPath, encoding: .utf8)
        XCTAssertEqual(raw, stale)
    }
}
