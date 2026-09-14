import XCTest

@testable import Pomvox

final class SpokenFormattingTests: XCTestCase {

    // The two outputs the shipped model produced on 2026-09-13 for spoken
    // commands — commands became words.
    func testNewLineAsTheModelRendersIt() {
        XCTAssertEqual(
            SpokenFormatting.apply("Hi John, new line, thanks for the update. New line, best Abhi."),
            "Hi John,\nThanks for the update.\nBest Abhi.")
    }

    func testNewParagraphAsTheModelRendersIt() {
        XCTAssertEqual(
            SpokenFormatting.apply(
                "The first paragraph is about the budget. New paragraph: the second one is about hiring."),
            "The first paragraph is about the budget.\n\nThe second one is about hiring.")
    }

    func testRawTranscriptWithoutPunctuation() {
        XCTAssertEqual(
            SpokenFormatting.apply("hi john new line thanks for the update new line best abhi"),
            "hi john\nThanks for the update\nBest abhi")
    }

    func testBulletPoints() {
        XCTAssertEqual(
            SpokenFormatting.apply("Things to do. Bullet fix login. Bullet point update docs. Bullet ship it."),
            "Things to do.\n- Fix login.\n- Update docs.\n- Ship it.")
    }

    func testContentUsesStayWords() {
        for text in [
            "We launched a new line of products.",
            "The new line of products sells well.",
            "That was a silver bullet.",
            "Every bullet point on that slide matters.",
            "It was the magic bullet.",
            "There's a new paragraph in the contract that changes everything.",
        ] {
            XCTAssertEqual(SpokenFormatting.apply(text), text, text)
        }
    }

    func testIdempotent() {
        let once = SpokenFormatting.apply("Hi, new line, there. New paragraph. Bye.")
        XCTAssertEqual(SpokenFormatting.apply(once), once)
    }

    func testNoCommandsNoChange() {
        let text = "Nothing to see here, just a sentence."
        XCTAssertEqual(SpokenFormatting.apply(text), text)
    }

    func testCaseInsensitiveAndAtTheEdges() {
        XCTAssertEqual(SpokenFormatting.apply("NEW LINE hello"), "\nHello")
        XCTAssertEqual(SpokenFormatting.apply("hello new line"), "hello\n")
    }
}
