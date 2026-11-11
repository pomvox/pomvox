import XCTest
@testable import Pomvox

final class DictionarySuggestionLogicTests: XCTestCase {
    private func fix(_ heard: String, _ target: String, origin: String = "history") -> DictionaryRule {
        DictionaryRule(sources: [heard], target: target, enabled: true, origin: origin)
    }

    private func suggest(_ rules: [DictionaryRule], words: [String] = [],
                         dismissed: Set<String> = []) -> [DictionarySuggestion] {
        DictionarySuggestionLogic.suggestions(
            file: DictionaryFile(words: words, rules: rules), dismissed: dismissed)
    }

    func testThresholdFixesOfOneWordGiveOneSuggestion() {
        let rules = [fix("pom box", "Pomvox"), fix("palm vox", "Pomvox"), fix("pom fox", "Pomvox")]
        XCTAssertEqual(DictionarySuggestionLogic.threshold, 3)
        XCTAssertEqual(suggest(rules), [DictionarySuggestion(word: "Pomvox", fixes: 3)])
        // More fixes still give one suggestion, not one per fix.
        XCTAssertEqual(suggest(rules + [fix("bomb box", "Pomvox")]),
                       [DictionarySuggestion(word: "Pomvox", fixes: 4)])
    }

    func testBelowThresholdGivesNothing() {
        XCTAssertEqual(suggest([fix("pom box", "Pomvox"), fix("palm vox", "Pomvox")]), [])
    }

    func testCaseAndWhitespaceAreTheSameWordAndLatestSpellingWins() {
        let rules = [fix("a", "pomvox"), fix("b", " POMVOX "), fix("c", "Pomvox")]
        XCTAssertEqual(suggest(rules), [DictionarySuggestion(word: "Pomvox", fixes: 3)])
    }

    func testOnlyHistoryFixesCount() {
        let rules = [fix("a", "Pomvox"), fix("b", "Pomvox"),
                     fix("c", "Pomvox", origin: "manual"), fix("d", "Pomvox", origin: "variant")]
        XCTAssertEqual(suggest(rules), [])
    }

    func testRemovalRulesAreNotWords() {
        XCTAssertEqual(suggest([fix("um", ""), fix("uh", ""), fix("er", " ")]), [])
    }

    func testWordAlreadyInDictionaryIsNotSuggested() {
        let rules = [fix("a", "Pomvox"), fix("b", "Pomvox"), fix("c", "Pomvox")]
        XCTAssertEqual(suggest(rules, words: ["pomvox"]), [])
    }

    func testDismissedWordIsNotSuggestedAndOthersStillAre() {
        let rules = [fix("a", "Pomvox"), fix("b", "Pomvox"), fix("c", "Pomvox"),
                     fix("d", "Abhi"), fix("e", "Abhi"), fix("f", "Abhi")]
        XCTAssertEqual(suggest(rules).map(\.word), ["Pomvox", "Abhi"])
        XCTAssertEqual(suggest(rules, dismissed: [DictionarySuggestionLogic.key("Pomvox")]).map(\.word),
                       ["Abhi"])
    }
}

@MainActor
final class DictionarySuggestionStoreTests: XCTestCase {
    private var dir: String!
    private var path: String { dir + "/dictionary-suggestions.json" }

    override func setUp() {
        dir = NSTemporaryDirectory() + "dict-suggest-\(UUID().uuidString)"
    }
    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testDismissalSurvivesRelaunch() {
        let rules = (0..<3).map {
            DictionaryRule(sources: ["heard \($0)"], target: "Pomvox", enabled: true, origin: "history")
        }
        let file = DictionaryFile(rules: rules)
        let first = DictionarySuggestionStore(path: path)
        XCTAssertEqual(DictionarySuggestionLogic.suggestions(file: file, dismissed: first.dismissed).count, 1)
        first.dismiss(" Pomvox ")

        // A new instance is what a relaunch gets: it only knows what is on disk.
        let relaunched = DictionarySuggestionStore(path: path)
        XCTAssertEqual(relaunched.dismissed, ["pomvox"])
        XCTAssertEqual(DictionarySuggestionLogic.suggestions(file: file, dismissed: relaunched.dismissed), [])
    }

    func testCorruptSidecarStartsEmptyAndWritesCleanly() throws {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try "not json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = DictionarySuggestionStore(path: path)
        XCTAssertEqual(store.dismissed, [])
        store.dismiss("Pomvox")
        XCTAssertEqual(DictionarySuggestionStore(path: path).dismissed, ["pomvox"])
    }

    func testPathHonoursEnvOverride() {
        XCTAssertEqual(DictionarySuggestionStore.defaultPath(
            environment: ["POMVOX_DICTIONARY_SUGGESTIONS_PATH": "/tmp/x.json"]), "/tmp/x.json")
        XCTAssertTrue(DictionarySuggestionStore.defaultPath(environment: [:])
            .hasSuffix("/.pomvox/dictionary-suggestions.json"))
    }
}
