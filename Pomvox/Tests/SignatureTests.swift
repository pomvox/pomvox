import XCTest

@testable import Pomvox

/// The opt-in dictation mark. The invariants that matter are the ones that keep
/// it from corrupting text: never on unless asked, never on empty text, never
/// applied twice, and never swallowing a trailing newline.
final class SignatureTests: XCTestCase {

    // MARK: - Off by default

    func testDefaultIsOff() {
        XCTAssertFalse(Signature().enabled)
        XCTAssertEqual(Signature().apply(to: "Ship it."), "Ship it.")
    }

    func testAbsentSectionReadsAsOff() {
        let doc = ConfigDocument(text: "[cleanup]\nenabled = true\n")
        XCTAssertFalse(Signature.read(doc).enabled)
    }

    func testReadsEnabledAndMark() {
        let doc = ConfigDocument(text: "[signature]\nenabled = true\nmark = \"✨\"\n")
        let sig = Signature.read(doc)
        XCTAssertTrue(sig.enabled)
        XCTAssertEqual(sig.mark, "✨")
    }

    func testReadDefaultsTheMarkWhenOnlyEnabledIsSet() {
        let doc = ConfigDocument(text: "[signature]\nenabled = true\n")
        XCTAssertEqual(Signature.read(doc).mark, Signature.defaultMark)
    }

    // MARK: - Appending

    func testAppendsAfterASingleSpace() {
        let sig = Signature(enabled: true, mark: "🎙️")
        XCTAssertEqual(sig.apply(to: "Ship it."), "Ship it. 🎙️")
    }

    func testKeepsTrailingWhitespaceAfterTheMark() {
        let sig = Signature(enabled: true, mark: "🎙️")
        XCTAssertEqual(sig.apply(to: "Ship it.\n"), "Ship it. 🎙️\n")
        XCTAssertEqual(sig.apply(to: "Ship it.  "), "Ship it. 🎙️  ")
    }

    func testPreservesInteriorNewlines() {
        let sig = Signature(enabled: true, mark: "🎙️")
        XCTAssertEqual(sig.apply(to: "One\nTwo"), "One\nTwo 🎙️")
    }

    func testHonorsACustomMark() {
        XCTAssertEqual(Signature(enabled: true, mark: "🪶").apply(to: "Hi"), "Hi 🪶")
    }

    func testTrimsWhitespaceAroundTheConfiguredMark() {
        let sig = Signature(enabled: true, mark: "  ✨ ")
        XCTAssertEqual(sig.mark, "✨")
        XCTAssertEqual(sig.apply(to: "Hi"), "Hi ✨")
    }

    // MARK: - Guards

    func testEmptyTextIsNeverMarked() {
        let sig = Signature(enabled: true)
        XCTAssertEqual(sig.apply(to: ""), "")
        XCTAssertEqual(sig.apply(to: "   \n"), "   \n")
    }

    func testApplyingTwiceIsANoOp() {
        let sig = Signature(enabled: true, mark: "🎙️")
        let once = sig.apply(to: "Ship it.")
        XCTAssertEqual(sig.apply(to: once), once)
    }

    func testAnEmptyMarkReadsAsOff() {
        let sig = Signature(enabled: true, mark: "")
        XCTAssertFalse(sig.enabled)
        XCTAssertEqual(sig.apply(to: "Hi"), "Hi")
    }

    func testAnOverLongMarkReadsAsOff() {
        let long = String(repeating: "✨", count: Signature.maxGraphemes + 1)
        let sig = Signature(enabled: true, mark: long)
        XCTAssertFalse(sig.enabled)
        XCTAssertEqual(sig.apply(to: "Hi"), "Hi")
    }

    func testAMarkAtTheLengthLimitIsAllowed() {
        let atLimit = String(repeating: "✨", count: Signature.maxGraphemes)
        XCTAssertTrue(Signature(enabled: true, mark: atLimit).enabled)
    }

    func testMultiScalarEmojiCountsAsOneGrapheme() {
        // "🎙️" is U+1F399 + U+FE0F; a scalar-based cap would misjudge these.
        XCTAssertEqual(Signature.defaultMark.count, 1)
        XCTAssertTrue(Signature(enabled: true, mark: Signature.defaultMark).enabled)
    }

    func testEveryPresetIsWithinTheLimit() {
        for mark in Signature.presets {
            XCTAssertTrue(Signature(enabled: true, mark: mark).enabled, "preset \(mark) is rejected")
        }
    }
}
