import XCTest
@testable import Pomvox

final class DictionaryInterchangeTests: XCTestCase {

    func testWordListRoundTrip() {
        let words = ["Kubernetes", "MLX", "Salammagari"]
        let text = DictionaryInterchange.wordList(words)
        XCTAssertEqual(text, "Kubernetes\nMLX\nSalammagari\n")
        XCTAssertEqual(DictionaryInterchange.parseWordList(text), words)
    }

    func testParseWordListSkipsBlanksCommentsAndTrims() {
        XCTAssertEqual(
            DictionaryInterchange.parseWordList("# my words\n  MLX  \n\nKubernetes\n"),
            ["MLX", "Kubernetes"])
    }

    func testRulesCSVRoundTrip() {
        let rules = [
            DictionaryRule(sources: ["pom box", "palm vox"], target: "Pomvox",
                           enabled: true, origin: "manual"),
            DictionaryRule(sources: ["um"], target: "", enabled: true, origin: "manual"),
        ]
        let csv = DictionaryInterchange.rulesCSV(rules)
        XCTAssertEqual(csv, "pom box|palm vox,Pomvox\num,\n")
        XCTAssertEqual(DictionaryInterchange.parseRulesCSV(csv).map(\.sources),
                       [["pom box", "palm vox"], ["um"]])
        XCTAssertEqual(DictionaryInterchange.parseRulesCSV(csv).map(\.target), ["Pomvox", ""])
    }

    func testParseRulesCSVSkipsMalformedRows() {
        // No comma at all → not a rule row; skipped, not fatal.
        let rules = DictionaryInterchange.parseRulesCSV("just words\npom box,Pomvox\n")
        XCTAssertEqual(rules.count, 1)
    }

    func testImportedRulesAreManualOriginAndEnabled() {
        let r = DictionaryInterchange.parseRulesCSV("a b,AB\n")[0]
        XCTAssertEqual(r.origin, "manual")
        XCTAssertTrue(r.enabled)
    }

    func testParseStripsCRLFAndBareCR() {
        XCTAssertEqual(
            DictionaryInterchange.parseWordList("MLX\r\nKubernetes\r\n"),
            ["MLX", "Kubernetes"])
        XCTAssertEqual(
            DictionaryInterchange.parseWordList("# note\r\n  MLX\rKubernetes\r"),
            ["MLX", "Kubernetes"])
        let rules = DictionaryInterchange.parseRulesCSV("pom box,Pomvox\r\num,\r")
        XCTAssertEqual(rules.map(\.sources), [["pom box"], ["um"]])
        XCTAssertEqual(rules.map(\.target), ["Pomvox", ""])
    }

    func testCommaAndBackslashInTargetRoundTrip() {
        let rules = [
            DictionaryRule(sources: ["hello there"], target: "Hello, world",
                           enabled: true, origin: "manual"),
            DictionaryRule(sources: ["bs"], target: #"a\b"#,
                           enabled: true, origin: "manual"),
            DictionaryRule(sources: ["comma"], target: ",",
                           enabled: true, origin: "manual"),
        ]
        let csv = DictionaryInterchange.rulesCSV(rules)
        XCTAssertEqual(csv, "hello there,Hello\\, world\nbs,a\\\\b\ncomma,\\,\n")
        let parsed = DictionaryInterchange.parseRulesCSV(csv)
        XCTAssertEqual(parsed.map(\.sources), rules.map(\.sources))
        XCTAssertEqual(parsed.map(\.target), rules.map(\.target))
    }

    func testSourceCommaStillSplitsOnTheSeparator() {
        // Sources may contain raw commas; only the target's commas are escaped,
        // because the separator is the last unescaped comma.
        let rules = DictionaryInterchange.parseRulesCSV("hello, world|pom box,Pomvox\n")
        XCTAssertEqual(rules.map(\.sources), [["hello, world", "pom box"]])
        XCTAssertEqual(rules.map(\.target), ["Pomvox"])
    }
}
