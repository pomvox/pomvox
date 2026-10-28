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
            QuickAddHotkey.inlineError(for: "foo+d"),
            "Unknown modifier “foo”. Use cmd, shift, alt, or ctrl.")
    }

    /// The unknown-key message names the offending key, so "cmd+shift" (a
    /// modifier where the key should be) and "cmd+µ" each say what was read.
    func testUnknownKeyErrorNamesTheKey() {
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "cmd+µ"),
            "Unknown key “µ”. Use a letter or digit (e.g. cmd+shift+d).")
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "cmd+shift"),
            "Unknown key “shift”. Use a letter or digit (e.g. cmd+shift+d).")
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "Cmd+F1"),
            "Unknown key “f1”. Use a letter or digit (e.g. cmd+shift+d).")
    }

    func testTrailingPlusSaysTheKeyIsMissing() {
        XCTAssertEqual(
            QuickAddHotkey.inlineError(for: "cmd+"),
            "Missing key after “+”. Use a letter or digit (e.g. cmd+shift+d).")
    }
}

/// The controller owns its NSEvent monitor tokens: `start` arms exactly once
/// (a second call replaces, never stacks) and `stop` removes them — what a
/// live-reloadable binding will need, and what keeps a re-read of config.toml
/// from double-firing the panel.
@MainActor
final class QuickAddControllerTests: XCTestCase {

    func testEmptyOrInvalidBindingArmsNothing() {
        let c = QuickAddController()
        c.start(bindingString: "")
        XCTAssertFalse(c.isArmed)
        c.start(bindingString: "d")
        XCTAssertFalse(c.isArmed)
    }

    func testStartRetainsMonitorsAndStopRemovesThem() {
        let c = QuickAddController()
        c.start(bindingString: "cmd+shift+d")
        XCTAssertTrue(c.isArmed)
        let first = c.monitorCount
        XCTAssertGreaterThan(first, 0)

        c.start(bindingString: "cmd+shift+e")   // re-arm replaces, never stacks
        XCTAssertEqual(c.monitorCount, first)

        c.stop()
        XCTAssertFalse(c.isArmed)
        XCTAssertEqual(c.monitorCount, 0)
    }
}
