import XCTest
@testable import Pomvox

/// The sidebar status card (#212) used to hard-code "Ready to dictate / Hold
/// Fn · or Fn + Space" whatever `[hotkey]` said and whatever the engine was
/// doing. The card is now a pure function of published engine state; these
/// pin the copy for the configured keys and for every status.
@MainActor
final class StatusCardCopyTests: XCTestCase {
    private let fn = HotkeyMachine.displayName("fn")
    private let fnSpace = HotkeyMachine.comboDisplayName("fn+space")

    /// Default config: the Fn copy, as before.
    func testReadyWithDefaultsReadsFnCopy() {
        let copy = StatusCardCopy.make(status: .ready, speechLoad: nil, ptt: fn, toggle: fnSpace)
        XCTAssertEqual(copy.title, "Ready to dictate")
        XCTAssertEqual(copy.detail, "Hold Fn (🌐) · or Fn (🌐) + Space")
        XCTAssertEqual(copy.tone, .live)
    }

    /// `ptt = "mouse4"`, `toggle = "mouse4+space"`: the card names the button,
    /// one inch below the Hotkeys pane that says the same thing.
    func testReadyWithMouseButtonNamesTheConfiguredKeys() {
        let copy = StatusCardCopy.make(
            status: .ready, speechLoad: nil,
            ptt: HotkeyMachine.displayName("mouse4"),
            toggle: HotkeyMachine.comboDisplayName("mouse4+space"))
        XCTAssertEqual(copy.detail, "Hold Mouse Button 4 · or Mouse Button 4 + Space")
        XCTAssertFalse(copy.detail.contains("Fn"))
    }

    func testRightOptionPttIsNamed() {
        let copy = StatusCardCopy.make(
            status: .ready, speechLoad: nil,
            ptt: HotkeyMachine.displayName("right_option"),
            toggle: HotkeyMachine.comboDisplayName("right_option+space"))
        XCTAssertEqual(copy.detail, "Hold Right Option (⌥) · or Right Option (⌥) + Space")
    }

    /// Not armed: no "Ready to dictate", and no hotkey line either — the
    /// mirrors still hold the pre-arm Fn defaults, not the user's config.
    func testNotArmedNeverClaimsReady() {
        let notArmed: [NativeEngine.Status] = [
            .off, .preparing, .blocked("python"), .failed("permissions missing"),
        ]
        for status in notArmed {
            let copy = StatusCardCopy.make(status: status, speechLoad: nil, ptt: fn, toggle: fnSpace)
            XCTAssertNotEqual(copy.title, "Ready to dictate", "\(status)")
            XCTAssertFalse(copy.detail.hasPrefix("Hold "), "\(status): \(copy.detail)")
            XCTAssertNotEqual(copy.tone, .live, "\(status)")
        }
    }

    func testOffSaysHowToTurnOn() {
        let copy = StatusCardCopy.make(status: .off, speechLoad: nil, ptt: fn, toggle: fnSpace)
        XCTAssertEqual(copy.title, "Engine off")
        XCTAssertEqual(copy.tone, .idle)
    }

    func testBlockedAndFailedAskForAttention() {
        let blocked = StatusCardCopy.make(status: .blocked("python"), speechLoad: nil, ptt: fn, toggle: fnSpace)
        XCTAssertEqual(blocked.tone, .attention)
        XCTAssertTrue(blocked.title.lowercased().contains("another engine"))
        let failed = StatusCardCopy.make(status: .failed("no grant"), speechLoad: nil, ptt: fn, toggle: fnSpace)
        XCTAssertEqual(failed.tone, .attention)
        XCTAssertTrue(failed.detail.contains("Setup"))
    }

    /// A model download in flight stands in for the status, as in the menu bar.
    func testSpeechLoadStandsInForStatus() {
        let copy = StatusCardCopy.make(
            status: .preparing, speechLoad: "Downloading speech model… 42%", ptt: fn, toggle: fnSpace)
        XCTAssertEqual(copy.title, "Downloading speech model… 42%")
        XCTAssertEqual(copy.tone, .idle)
        XCTAssertFalse(copy.detail.hasPrefix("Hold "))
    }

    /// Mid-dictation the card follows the engine and keeps the key names, so
    /// the user can see what to release or tap.
    func testRecordingAndTranscribingKeepTheHotkeyLine() {
        for status in [NativeEngine.Status.recording, .transcribing] {
            let copy = StatusCardCopy.make(status: status, speechLoad: nil, ptt: fn, toggle: fnSpace)
            XCTAssertNotEqual(copy.title, "Ready to dictate", "\(status)")
            XCTAssertEqual(copy.detail, StatusCardCopy.hotkeyLine(ptt: fn, toggle: fnSpace))
            XCTAssertEqual(copy.tone, .live)
        }
    }
}
