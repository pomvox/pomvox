import CoreGraphics
import XCTest
@testable import Pomvox

/// A live CGEventTap needs Input Monitoring and a window server, so CI can't
/// create one. The pure parts are covered: what is subscribed, and which
/// closure each event reaches with what keycode.
final class EventTapTests: XCTestCase {
    let FN = HotkeyMachine.keycodes["fn"]!
    let MOUSE4 = HotkeyMachine.keycodes["mouse4"]!
    let MOUSE5 = HotkeyMachine.keycodes["mouse5"]!

    private func bit(_ t: CGEventType) -> CGEventMask { CGEventMask(1 << t.rawValue) }
    private func route(_ t: CGEventType, key: Int64 = 0, flags: CGEventFlags = [], button: Int64 = 0)
        -> EventTap.Route { EventTap.route(type: t, keycode: key, flags: flags, button: button) }

    /// Keyboard-only setups keep the exact mask they always had; side buttons
    /// are subscribed only when asked, and never left/right clicks.
    func testMaskSubscribesMouseButtonsOnlyWhenAsked() {
        let keyboard = EventTap.eventMask(mouseButtons: false)
        XCTAssertEqual(keyboard, bit(.flagsChanged) | bit(.keyDown))
        let mouse = EventTap.eventMask(mouseButtons: true)
        XCTAssertEqual(mouse, keyboard | bit(.otherMouseDown) | bit(.otherMouseUp))
        XCTAssertEqual(mouse & (bit(.leftMouseDown) | bit(.rightMouseDown)), 0)
    }

    func testKeyboardRoutingIsUnchanged() {
        XCTAssertEqual(route(.flagsChanged, key: Int64(FN), flags: .maskSecondaryFn),
                       .modifier(keycode: FN, isDown: true))
        XCTAssertEqual(route(.flagsChanged, key: Int64(FN)), .modifier(keycode: FN, isDown: false))
        XCTAssertEqual(route(.flagsChanged, key: 57, flags: .maskAlphaShift), .pass)  // Caps Lock
        XCTAssertEqual(route(.keyDown, key: 49), .key(keycode: 49))
    }

    /// Side buttons are a down/up pair like a modifier, under the synthetic
    /// codes; middle and unknown buttons pass, and a stray 0 in the keycode or
    /// button field of the other event kind is never read as a binding.
    func testSideButtonsRouteToTheModifierPathOnly() {
        XCTAssertEqual(route(.otherMouseDown, button: 3), .modifier(keycode: MOUSE4, isDown: true))
        XCTAssertEqual(route(.otherMouseUp, button: 3), .modifier(keycode: MOUSE4, isDown: false))
        XCTAssertEqual(route(.otherMouseDown, button: 4), .modifier(keycode: MOUSE5, isDown: true))
        XCTAssertEqual(route(.otherMouseDown, button: 2), .pass)
        XCTAssertEqual(route(.otherMouseUp, button: 7), .pass)
        XCTAssertEqual(route(.keyDown, key: 3), .key(keycode: 3))  // "F", never side button 3
        for t: CGEventType in [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .mouseMoved] {
            XCTAssertEqual(route(t), .pass, "\(t.rawValue)")
        }
    }
}
