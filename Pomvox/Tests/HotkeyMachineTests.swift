import XCTest
@testable import Pomvox

/// 1:1 port of `tests/test_hotkey_machine.py` — table/test-vector parity with
/// the Linux-tested Python spec, not re-derived.
final class HotkeyMachineTests: XCTestCase {
    let FN = HotkeyMachine.keycodes["fn"]!
    let SPACE = HotkeyMachine.keycodes["space"]!
    let ESC = HotkeyMachine.keycodes["esc"]!
    let RIGHT_OPT = HotkeyMachine.keycodes["right_option"]!
    let LETTER_A = 0  // any non-hotkey keycode

    private func make() -> HotkeyMachine { try! HotkeyMachine() }

    func testPttPressAndRelease() {
        let m = make()
        var d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .startPTT); XCTAssertFalse(d.swallow)
        XCTAssertEqual(m.state, .ptt)

        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .stop); XCTAssertFalse(d.swallow)
        XCTAssertEqual(m.state, .busy)

        m.done()
        XCTAssertEqual(m.state, .idle)
    }

    func testFnSpaceEntersToggleAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .enterToggle); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .toggle)

        // Releasing Fn no longer stops the recording.
        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .none)
        XCTAssertEqual(m.state, .toggle)
    }

    func testEscCancelsToggleAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .cancel); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .busy)
    }

    func testEscCancelsPttAndSwallows() {
        let m = make()
        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .cancel); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .busy)

        // The trailing Fn release must not emit a second STOP.
        d = m.onModifier(FN, false)
        XCTAssertEqual(d.action, .none)
    }

    func testConfiguredStopKeyStillStopsToggle() {
        let m = try! HotkeyMachine(stop: "right_command")
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onKeyDown(HotkeyMachine.keycodes["right_command"]!)
        XCTAssertEqual(d.action, .stop); XCTAssertTrue(d.swallow)
    }

    func testCancelDisabledWhenUnset() {
        let m = try! HotkeyMachine(cancel: "")
        _ = m.onModifier(FN, true)
        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testEscWhileBusyPassesThrough() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onModifier(FN, false)  // STOP → BUSY; a late Esc is too late to cancel
        let d = m.onKeyDown(ESC)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testFnTapStopsToggle() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        let d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .stop)
        XCTAssertEqual(m.state, .busy)
    }

    func testSecondFnSpaceStopsToggleWithoutTypingASpace() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)

        // Fn going down already stops; the trailing space must be swallowed so
        // it isn't typed into the document.
        var d = m.onModifier(FN, true)
        XCTAssertEqual(d.action, .stop)
        d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .none); XCTAssertTrue(d.swallow)
    }

    func testUnrelatedKeysPassThrough() {
        let m = make()
        XCTAssertEqual(m.onKeyDown(LETTER_A).action, .none)

        _ = m.onModifier(FN, true)
        var d = m.onKeyDown(LETTER_A)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)

        _ = m.onKeyDown(SPACE)  // toggle mode
        d = m.onKeyDown(LETTER_A)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testSpaceWithoutFnPassesInToggleEntry() {
        let m = make()
        // Space in IDLE is never a hotkey.
        let d = m.onKeyDown(SPACE)
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    func testEventsWhileBusyAreIgnored() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onModifier(FN, false)  // → BUSY (transcribing)

        XCTAssertEqual(m.onModifier(FN, true).action, .none)
        XCTAssertEqual(m.onKeyDown(SPACE).action, .none)
        XCTAssertEqual(m.onKeyDown(ESC).action, .none)
        XCTAssertEqual(m.state, .busy)

        m.done()
        XCTAssertEqual(m.onModifier(FN, true).action, .startPTT)
    }

    func testRemappedPttKey() {
        let m = try! HotkeyMachine(ptt: "right_option")
        XCTAssertEqual(m.onModifier(FN, true).action, .none)
        XCTAssertEqual(m.onModifier(RIGHT_OPT, true).action, .startPTT)
        XCTAssertEqual(m.onModifier(RIGHT_OPT, false).action, .stop)
    }

    func testInvalidKeyNamesRaise() {
        XCTAssertThrowsError(try HotkeyMachine(ptt: "hyperkey"))
        XCTAssertThrowsError(try HotkeyMachine(toggle: "space"))  // missing modifier
    }

    func testResetAbortsRecording() {
        let m = make()
        _ = m.onModifier(FN, true)
        m.reset()
        XCTAssertEqual(m.state, .idle)
    }

    // The sleep/wake panic reset (NativeEngine) unsticks a recording state that
    // was stranded across sleep — e.g. a push-to-talk key-up dropped while the
    // CGEventTap was disabled — by calling reset(). These guard the contract it
    // relies on: reset() from any recording state leaves the machine able to
    // dictate again, exactly like a fresh one.
    func testResetFromPttRecoversToAFreshCycle() {
        let m = make()
        _ = m.onModifier(FN, true)          // stranded mid push-to-talk
        XCTAssertEqual(m.state, .ptt)
        m.reset()                           // panic reset
        XCTAssertEqual(m.state, .idle)

        XCTAssertEqual(m.onModifier(FN, true).action, .startPTT)
        XCTAssertEqual(m.onModifier(FN, false).action, .stop)
        m.done()
        XCTAssertEqual(m.state, .idle)
    }

    func testResetFromToggleRecoversToAFreshCycle() {
        let m = make()
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)              // hands-free
        _ = m.onModifier(FN, false)
        XCTAssertEqual(m.state, .toggle)
        m.reset()                           // panic reset from hands-free
        XCTAssertEqual(m.state, .idle)
        XCTAssertEqual(m.onModifier(FN, true).action, .startPTT)
    }

    func testExternalStopOnlyFiresInToggle() {
        let m = make()
        // VAD endpoint while hands-free: stops exactly like the stop hotkey.
        _ = m.onModifier(FN, true)
        _ = m.onKeyDown(SPACE)
        _ = m.onModifier(FN, false)
        XCTAssertTrue(m.externalStop())
        XCTAssertEqual(m.state, .busy)

        // And never anywhere else: BUSY (a second stale endpoint), PTT
        // (the finger is the endpoint), IDLE.
        XCTAssertFalse(m.externalStop())
        m.done()
        XCTAssertFalse(m.externalStop())
        _ = m.onModifier(FN, true)  // PTT
        XCTAssertFalse(m.externalStop())
        XCTAssertEqual(m.state, .ptt)
    }

    func testExposesThePttKeycodeForTheHeartbeat() throws {
        XCTAssertEqual(try HotkeyMachine().pttKeycode, 63)                       // fn
        XCTAssertEqual(try HotkeyMachine(ptt: "right_option").pttKeycode, 61)
    }

    // MARK: - config resolution (#58: [hotkey] honored, bad values degrade)

    func testResolvedHonorsValidConfig() {
        let r = HotkeyMachine.resolved(ptt: "right_option", toggle: "right_option+space",
                                       stop: "", cancel: "esc")
        XCTAssertFalse(r.fellBack)
        XCTAssertEqual(r.machine.pttKeycode, 61)
    }

    func testResolvedFallsBackOnUnknownKey() {
        let r = HotkeyMachine.resolved(ptt: "hyper", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertTrue(r.fellBack)
        XCTAssertEqual(r.machine.pttKeycode, 63)   // Fn defaults — never a dead engine
    }

    func testResolvedFallsBackOnBadToggle() {
        let r = HotkeyMachine.resolved(ptt: "fn", toggle: "space", stop: "", cancel: "esc")
        XCTAssertTrue(r.fellBack)
        XCTAssertEqual(r.machine.pttKeycode, 63)
    }

    func testDisplayNames() {
        XCTAssertEqual(HotkeyMachine.displayName("fn"), "Fn (🌐)")
        XCTAssertEqual(HotkeyMachine.displayName("right_option"), "Right Option (⌥)")
        XCTAssertEqual(HotkeyMachine.displayName("weird"), "weird")  // unknown: echo as-is
        XCTAssertEqual(HotkeyMachine.displayName("mouse4"), "Mouse Button 4")
        XCTAssertEqual(HotkeyMachine.displayName("mouse5"), "Mouse Button 5")
    }

    /// The hands-free combo for the sidebar status card (#212): each part named
    /// like `displayName`, joined with " + "; a bare key or an unknown part
    /// behaves exactly as `displayName` does.
    func testComboDisplayNames() {
        XCTAssertEqual(HotkeyMachine.comboDisplayName("fn+space"), "Fn (🌐) + Space")
        XCTAssertEqual(HotkeyMachine.comboDisplayName("mouse4+space"), "Mouse Button 4 + Space")
        XCTAssertEqual(HotkeyMachine.comboDisplayName("right_option+space"), "Right Option (⌥) + Space")
        XCTAssertEqual(HotkeyMachine.comboDisplayName("fn"), "Fn (🌐)")          // no "+": single name
        XCTAssertEqual(HotkeyMachine.comboDisplayName("weird+space"), "weird + Space")  // unknown echoes
    }

    // MARK: - mouse side buttons as PTT (#191, Swift-only; not in the Python spec)

    let MOUSE4 = HotkeyMachine.keycodes["mouse4"]!
    let MOUSE5 = HotkeyMachine.keycodes["mouse5"]!

    /// Synthetic codes sit past the 7-bit keyboard range (never a key), and
    /// CGEvent button numbers (left 0, right 1, middle 2, side 3/4) map onto them.
    func testMouseKeycodesNeverCollideWithKeyboardKeys() {
        XCTAssertGreaterThan(HotkeyMachine.mouseKeycodeBase, 127)
        XCTAssertGreaterThanOrEqual(min(MOUSE4, MOUSE5), HotkeyMachine.mouseKeycodeBase)
        XCTAssertEqual(HotkeyMachine.mouseButtonKeycode(3), MOUSE4)
        XCTAssertEqual(HotkeyMachine.mouseButtonKeycode(4), MOUSE5)
        for other: Int64 in [0, 1, 2, 5] { XCTAssertNil(HotkeyMachine.mouseButtonKeycode(other)) }
    }

    /// Same cycle as Fn (startPTT on down, stop on up), but the button's own
    /// clicks are swallowed in *every* state so the app underneath never gets
    /// a Back/Forward per dictation or an unbalanced down/up.
    func testMouseButtonPttCycleIsSwallowedInEveryState() {
        let m = try! HotkeyMachine(ptt: "mouse4")
        XCTAssertTrue(m.pttIsMouseButton); XCTAssertEqual(m.pttKeycode, MOUSE4)
        var d = m.onModifier(MOUSE4, true)
        XCTAssertEqual(d.action, .startPTT); XCTAssertTrue(d.swallow)
        d = m.onModifier(MOUSE4, false)
        XCTAssertEqual(d.action, .stop); XCTAssertTrue(d.swallow)
        XCTAssertEqual(m.state, .busy)
        d = m.onModifier(MOUSE4, true)                  // click while busy: inert, still ours
        XCTAssertEqual(d.action, .none); XCTAssertTrue(d.swallow)
        m.done()

        _ = m.onModifier(MOUSE4, true)
        XCTAssertEqual(m.onKeyDown(ESC).action, .cancel)
        d = m.onModifier(MOUSE4, false)                 // trailing release after Esc
        XCTAssertEqual(d.action, .none); XCTAssertTrue(d.swallow)
        d = m.onModifier(MOUSE5, true)                  // the other button is not ours
        XCTAssertEqual(d.action, .none); XCTAssertFalse(d.swallow)
    }

    /// Fn is untouched: never swallowed, and inert on a mouse-mapped machine.
    func testFnIsUnchangedByMouseSupport() {
        let fn = make()
        XCTAssertFalse(fn.pttIsMouseButton)
        XCTAssertEqual(fn.onModifier(FN, true), .init(action: .startPTT, swallow: false))
        XCTAssertEqual(fn.onModifier(FN, false), .init(action: .stop, swallow: false))
        XCTAssertEqual(fn.onModifier(MOUSE4, true), HotkeyMachine.pass)
        XCTAssertEqual(try! HotkeyMachine(ptt: "mouse4").onModifier(FN, true), HotkeyMachine.pass)
    }

    /// Hands-free from a side button: hold mouse4, tap Space; a second click stops.
    func testMouseButtonAsToggleModifier() {
        let m = try! HotkeyMachine(ptt: "mouse4", toggle: "mouse4+space")
        _ = m.onModifier(MOUSE4, true)
        XCTAssertEqual(m.onKeyDown(SPACE), .init(action: .enterToggle, swallow: true))
        XCTAssertEqual(m.onModifier(MOUSE4, false).action, .none)
        XCTAssertEqual(m.state, .toggle)
        XCTAssertEqual(m.onModifier(MOUSE4, true), .init(action: .stop, swallow: true))
    }

    /// Mouse names are only observed as a down/up pair (PTT, toggle modifier).
    /// In a keyDown role they would be silently inert, so they are rejected.
    func testMouseNamesRejectedForKeyDownRoles() {
        XCTAssertThrowsError(try HotkeyMachine(cancel: "mouse4"))
        XCTAssertThrowsError(try HotkeyMachine(stop: "mouse5"))
        XCTAssertThrowsError(try HotkeyMachine(toggle: "fn+mouse4"))
        XCTAssertThrowsError(try HotkeyMachine(ptt: "mouse6"))
    }

    func testResolvedHonorsMouseButtonPttAndFallsBackOnUnknownButton() {
        var r = HotkeyMachine.resolved(ptt: "mouse5", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertFalse(r.fellBack); XCTAssertEqual(r.machine.pttKeycode, MOUSE5)
        r = HotkeyMachine.resolved(ptt: "mouse6", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertTrue(r.fellBack); XCTAssertEqual(r.machine.pttKeycode, 63)
        XCTAssertFalse(r.machine.pttIsMouseButton)
    }
}
