import XCTest
@testable import Pomvox

@MainActor
final class DictionaryStoreTests: XCTestCase {
    private var dir: URL!
    private var dictPath: String { dir.appendingPathComponent("dictionary.toml").path }
    private var cfgPath: String { dir.appendingPathComponent("config.toml").path }

    override func setUp() async throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dict-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMigratesLegacyConfigOnFirstLoad() throws {
        try """
        [dictionary]
        words = ["Kubernetes"]
        [dictionary.replacements]
        "pom box" = "Pomvox"
        """.write(toFile: cfgPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertEqual(store.file.words, ["Kubernetes"])
        XCTAssertEqual(store.file.rules.count, 1)
        // Migration WROTE the new file; config.toml untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dictPath))
        let cfg = try String(contentsOfFile: cfgPath, encoding: .utf8)
        XCTAssertTrue(cfg.contains("pom box"))
    }

    func testAddWordSavesAndDedupes() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.addWord("MLX")
        store.addWord("  MLX ")   // dupe after trim
        store.addWord("")
        XCTAssertEqual(store.file.words, ["MLX"])
        let onDisk = try DictionaryDocument.parse(String(contentsOfFile: dictPath, encoding: .utf8))
        XCTAssertEqual(onDisk.words, ["MLX"])
    }

    func testUpsertAndRemoveRule() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let r = DictionaryRule(sources: ["pom box"], target: "Pomvox", enabled: true, origin: "manual")
        store.upsert(r, replacingID: nil)
        XCTAssertEqual(store.file.rules, [r])
        var edited = r
        edited.sources = ["pom box", "palm vox"]
        store.upsert(edited, replacingID: r.id)
        XCTAssertEqual(store.file.rules, [edited])
        store.removeRule(id: edited.id)
        XCTAssertEqual(store.file.rules, [])
    }

    func testUpsertDropsEmptySourcesAndDupes() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.upsert(DictionaryRule(sources: [" pom box ", "", "pom box"], target: "Pomvox",
                                    enabled: true, origin: "manual"), replacingID: nil)
        XCTAssertEqual(store.file.rules.first?.sources, ["pom box"])
    }

    func testSetRuleEnabled() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let r = DictionaryRule(sources: ["a b"], target: "AB", enabled: true, origin: "manual")
        store.upsert(r, replacingID: nil)
        store.setRuleEnabled(id: r.id, false)
        XCTAssertEqual(store.file.rules.first?.enabled, false)
    }

    func testSavePostsDidChange() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let exp = expectation(forNotification: .pomvoxDictionaryDidChange, object: nil)
        store.addWord("Anthropic")
        wait(for: [exp], timeout: 1)
    }

    func testMalformedFileSurfacesParseErrorAndKeepsEditsBlocked() throws {
        try "words = [broken".write(toFile: dictPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertNotNil(store.parseError)
        store.addWord("X")   // must NOT clobber the malformed file
        let raw = try String(contentsOfFile: dictPath, encoding: .utf8)
        XCTAssertTrue(raw.contains("broken"))
    }

    func testBlockedEditsDoNotMutateInMemoryFile() throws {
        try "words = [broken".write(toFile: dictPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertNotNil(store.parseError)
        store.addWord("X")
        store.upsert(DictionaryRule(sources: ["a b"], target: "AB",
                                    enabled: true, origin: "manual"), replacingID: nil)
        XCTAssertEqual(store.file, DictionaryFile())   // untouched, not phantom-edited
    }

    func testNoOpMutationsDoNotSaveOrNotify() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        var notified = false
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: nil, queue: nil) { _ in notified = true }
        defer { NotificationCenter.default.removeObserver(token) }
        store.removeRule(id: "no-such-id")
        store.removeWord("no-such-word")
        XCTAssertFalse(notified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dictPath))
    }

    func testAddWordsSavesOnceAndDedupes() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        var saves = 0
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: store, queue: nil
        ) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.addWords([" MLX ", "Kubernetes", "MLX", "", "  "])
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(store.file.words, ["MLX", "Kubernetes"])
        let onDisk = try DictionaryDocument.parse(String(contentsOfFile: dictPath, encoding: .utf8))
        XCTAssertEqual(onDisk.words, ["MLX", "Kubernetes"])
    }

    func testAddWordsNoOpDoesNotSave() {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        store.addWord("MLX")
        var saves = 0
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: store, queue: nil
        ) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.addWords(["MLX", "", "  MLX "])
        XCTAssertEqual(saves, 0)
        XCTAssertEqual(store.file.words, ["MLX"])
    }

    func testUpsertAllSavesOnceAndSkipsDuplicateIds() throws {
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        let first = DictionaryRule(sources: ["pom box"], target: "Pomvox",
                                    enabled: true, origin: "manual")
        let second = DictionaryRule(sources: ["um"], target: "",
                                     enabled: true, origin: "manual")
        var saves = 0
        let token = NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: store, queue: nil
        ) { _ in saves += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        store.upsertAll([first, second, first])
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(store.file.rules, [first, second])
        let onDisk = try DictionaryDocument.parse(String(contentsOfFile: dictPath, encoding: .utf8))
        XCTAssertEqual(onDisk.rules, [first, second])
    }

    func testBatchMutatorsDoNotClobberAMalformedFile() throws {
        try "words = [broken".write(toFile: dictPath, atomically: true, encoding: .utf8)
        let store = DictionaryStore(path: dictPath, configPath: cfgPath)
        XCTAssertNotNil(store.parseError)
        store.addWords(["X", "Y"])
        store.upsertAll([
            DictionaryRule(sources: ["a b"], target: "AB", enabled: true, origin: "manual"),
        ])
        let raw = try String(contentsOfFile: dictPath, encoding: .utf8)
        XCTAssertEqual(raw, "words = [broken")
        XCTAssertEqual(store.file, DictionaryFile())
    }

    func testSecondStoreInstanceSeesExternalSave() {
        let a = DictionaryStore(path: dictPath, configPath: cfgPath)
        let b = DictionaryStore(path: dictPath, configPath: cfgPath)
        a.addWord("Kubernetes")
        // b must resync from the didChange notification, not stay on its
        // launch-era snapshot (the C1 clobber bug).
        XCTAssertEqual(b.file.words, ["Kubernetes"])
        b.addWord("MLX")
        XCTAssertEqual(b.file.words, ["Kubernetes", "MLX"])   // merged, not clobbered
        XCTAssertEqual(a.file.words, ["Kubernetes", "MLX"])
    }
}
