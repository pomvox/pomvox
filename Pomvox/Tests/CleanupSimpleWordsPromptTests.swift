import XCTest

@testable import Pomvox

/// The frozen path's byte contract. The fine-tune saw exactly
/// "{system}\n\n{raw}" in a single user turn during training (the model repo's
/// example.py), so these pin the SHAPE, never the wording — the wording lives
/// with the weights.
final class CleanupSimpleWordsPromptTests: XCTestCase {

    /// Stands in for system_v2.txt. Shaped like it (prose line, then rules) but
    /// deliberately not a copy: copying the real bytes here is the drift this
    /// design exists to prevent.
    private let system = """
        You clean up raw voice dictation into polished written text.

        - Remove fillers.
        - Never output markdown headers.
        """

    func testProducesASingleUserTurn() {
        let messages = CleanupLogic.buildSimpleWordsMessages(text: "um hello", system: system)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, "user")
    }

    func testFoldsTheSystemTextIntoTheUserTurn() {
        let messages = CleanupLogic.buildSimpleWordsMessages(text: "um hello", system: system)
        XCTAssertEqual(messages[0].content, system + "\n\num hello")
    }

    /// example.py reads the file with `.read_text().strip()`; matching that is
    /// what keeps the Swift prompt byte-identical to the Python one.
    func testTrimsTheFrozenTextTheWayExamplePyDoes() {
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: "\n\n" + system + "  \n")
        XCTAssertEqual(messages[0].content, system + "\n\num hello")
    }

    func testTermsHintFollowsTheFrozenTextAndPrecedesTheTranscript() {
        let hint = dictionaryPromptHint(["Pomvox", "Parakeet"])
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: system, termsHint: hint)
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(messages[0].content, system + "\n" + trimmedHint + "\n\num hello")
    }

    /// The frozen bytes must stay a strict prefix of every prompt, so the
    /// prefilled KV cache still covers them when a dictionary hint is present.
    func testTheFrozenTextStaysAPrefixWithAHint() {
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: system, termsHint: dictionaryPromptHint(["Pomvox"]))
        XCTAssertTrue(messages[0].content.hasPrefix(system))
    }

    func testAWhitespaceOnlyHintChangesNothing() {
        XCTAssertEqual(
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system, termsHint: "  \n"),
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system))
    }

    func testAnEmptyHintChangesNothing() {
        XCTAssertEqual(
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system, termsHint: ""),
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system))
    }

    /// Regression guard: the legacy builder is untouched — one system message,
    /// ten few-shot pairs, one user turn.
    func testTheLegacyBuilderIsUnchanged() {
        let messages = CleanupLogic.buildMessages(text: "um hello", style: "polish")
        XCTAssertEqual(messages.count, 22)
        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last, ChatMessage(role: "user", content: "um hello"))
    }
}
