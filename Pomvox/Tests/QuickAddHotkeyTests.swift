import XCTest
import AppKit
@testable import Pomvox

final class QuickAddHotkeyTests: XCTestCase {

    func testParsesCmdShiftLetter() throws {
        let b = try XCTUnwrap(QuickAddHotkey.parse("cmd+shift+d"))
        XCTAssertTrue(b.flags.contains(.command))
        XCTAssertTrue(b.flags.contains(.shift))
        XCTAssertEqual(b.keyCode, 2)   // ANSI d
    }

    func testParsesCtrlAltDigit() throws {
        let b = try XCTUnwrap(QuickAddHotkey.parse("ctrl+alt+1"))
        XCTAssertTrue(b.flags.contains(.control))
        XCTAssertTrue(b.flags.contains(.option))
        XCTAssertEqual(b.keyCode, 18)  // ANSI 1
    }

    func testOptionAliases() {
        XCTAssertNotNil(QuickAddHotkey.parse("option+cmd+p"))
        XCTAssertNotNil(QuickAddHotkey.parse("alt+cmd+p"))
    }

    func testRejectsNoModifier() {
        XCTAssertNil(QuickAddHotkey.parse("d"))          // bare key would fire while typing
    }

    func testRejectsUnknownKeyAndEmpty() {
        XCTAssertNil(QuickAddHotkey.parse(""))
        XCTAssertNil(QuickAddHotkey.parse("cmd+µ"))
        XCTAssertNil(QuickAddHotkey.parse("cmd+"))
    }

    func testCaseAndWhitespaceInsensitive() {
        XCTAssertNotNil(QuickAddHotkey.parse(" CMD + Shift + D "))
    }

    func testInlineErrorNamesTheActualProblem() {
        XCTAssertNil(QuickAddHotkey.inlineError(for: ""))
        XCTAssertNil(QuickAddHotkey.inlineError(for: "cmd+shift+d"))
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "d"),
            "Needs at least one modifier (e.g. cmd+shift+d).")
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "cmd+µ"),
            "Unknown key. Use a letter or digit (e.g. cmd+shift+d).")
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "cmd+"),
            "Unknown key. Use a letter or digit (e.g. cmd+shift+d).")
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "foo+d"),
            "Unknown modifier. Use cmd, shift, alt, or ctrl.")
    }
}
