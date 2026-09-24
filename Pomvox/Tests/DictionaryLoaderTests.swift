import XCTest
@testable import Pomvox

final class DictionaryLoaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dict-loader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }
    private func write(_ name: String, _ text: String) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try text.write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    func testLoadsDictionaryTomlWhenPresent() throws {
        let dict = try write("dictionary.toml", """
        words = ["MLX"]
        [[rule]]
        sources = ["em el ex"]
        target = "MLX"
        """)
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("none.toml").path,
                                      dictionaryPath: dict)
        XCTAssertEqual(r.file.words, ["MLX"])
        XCTAssertEqual(r.file.rules.count, 1)
        XCTAssertFalse(r.fromLegacy)
        XCTAssertNil(r.parseError)
    }

    func testFallsBackToLegacyConfigSection() throws {
        let cfg = try write("config.toml", """
        [dictionary]
        enabled = true
        words = ["Kubernetes", "Anthropic"]
        [dictionary.replacements]
        "pom box" = "Pomvox"
        """)
        let r = DictionaryLoader.load(configPath: cfg,
                                      dictionaryPath: dir.appendingPathComponent("missing.toml").path)
        XCTAssertTrue(r.fromLegacy)
        XCTAssertEqual(r.file.words, ["Kubernetes", "Anthropic"])
        XCTAssertEqual(r.file.rules, [DictionaryRule(
            sources: ["pom box"], target: "Pomvox", enabled: true, origin: "manual")])
    }

    func testDictionaryTomlWinsOverLegacy() throws {
        let cfg = try write("config.toml", "[dictionary]\nwords = [\"Old\"]\n")
        let dict = try write("dictionary.toml", "words = [\"New\"]\n")
        let r = DictionaryLoader.load(configPath: cfg, dictionaryPath: dict)
        XCTAssertEqual(r.file.words, ["New"])
        XCTAssertFalse(r.fromLegacy)
    }

    func testMalformedFileReportsErrorAndLoadsNothing() throws {
        let dict = try write("dictionary.toml", "words = [broken\n")
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("none.toml").path,
                                      dictionaryPath: dict)
        XCTAssertNotNil(r.parseError)
        XCTAssertEqual(r.file, DictionaryFile())   // empty, never a crash
    }

    func testPathsHonorEnvOverridesAndIgnoreEmptyOnes() {
        XCTAssertEqual(
            DictionaryPaths.dictionaryPath(environment: ["POMVOX_DICTIONARY_PATH": "/tmp/dict.toml"]),
            "/tmp/dict.toml")
        XCTAssertEqual(
            DictionaryPaths.statsPath(environment: ["POMVOX_DICTIONARY_STATS_PATH": "/tmp/stats.json"]),
            "/tmp/stats.json")
        // An empty override must fall through. Rigs set the variable only when
        // they mean it; a blank value is not a path.
        let blank = ["POMVOX_DICTIONARY_PATH": "", "POMVOX_DICTIONARY_STATS_PATH": ""]
        XCTAssertEqual(
            DictionaryPaths.dictionaryPath(environment: blank),
            NSString(string: "~/.pomvox/dictionary.toml").expandingTildeInPath)
        XCTAssertEqual(
            DictionaryPaths.statsPath(environment: blank),
            NSString(string: "~/.pomvox/dictionary-stats.json").expandingTildeInPath)
    }

    func testBothMissingIsEmpty() {
        let r = DictionaryLoader.load(configPath: dir.appendingPathComponent("a.toml").path,
                                      dictionaryPath: dir.appendingPathComponent("b.toml").path)
        XCTAssertEqual(r.file, DictionaryFile())
        XCTAssertFalse(r.fromLegacy)
        XCTAssertNil(r.parseError)
    }
}
