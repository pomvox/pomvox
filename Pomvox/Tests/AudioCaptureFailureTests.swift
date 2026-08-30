import AVFoundation
import XCTest
@testable import Pomvox

/// Capture-start failure classification: a Mac with no microphone at all must
/// not be told to "grant Microphone access" (that pane is empty and useless
/// with no device). No-device wins over a missing permission; both win over a
/// generic engine error.
final class AudioCaptureFailureTests: XCTestCase {

    func testNoInputDeviceWinsRegardlessOfPermission() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: false, permissionGranted: false),
            .noInputDevice)
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: false, permissionGranted: true),
            .noInputDevice)
    }

    func testDevicePresentButPermissionDenied() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: true, permissionGranted: false),
            .permissionDenied)
    }

    func testDevicePresentAndGrantedIsAGenericEngineError() {
        XCTAssertEqual(
            AudioCapture.StartFailure.classify(hasInputDevice: true, permissionGranted: true),
            .engineError)
    }

    func testNoMicrophoneHasItsOwnMessageAndCode() {
        let f = AudioCapture.StartFailure.noInputDevice
        XCTAssertTrue(f.message.lowercased().contains("no microphone"))
        XCTAssertFalse(f.message.lowercased().contains("grant"))  // not a permission nag
        XCTAssertEqual(f.errorCode, "no_microphone")
    }

    func testPermissionDeniedKeepsTheGrantMessageAndCode() {
        let f = AudioCapture.StartFailure.permissionDenied
        XCTAssertTrue(f.message.contains("Microphone"))
        XCTAssertEqual(f.errorCode, "microphone_unavailable")
    }

    func testEveryErrorCodeMatchesTheTelemetryContract() {
        // The wire contract forbids anything but ^[a-z0-9_]{1,40}$.
        for f: AudioCapture.StartFailure in [.noInputDevice, .permissionDenied, .engineError] {
            XCTAssertEqual(TelemetrySanitizer.errorCode(f.errorCode), f.errorCode)
        }
    }

    // MARK: - stale-engine rebuild (post-sleep dead stream)

    /// The rebuild tests drive a real `AVAudioEngine`, so they need a device we
    /// are actually allowed to open — not merely a device that exists.
    ///
    /// `hasInputDevice()` only asks whether CoreAudio lists an input. A CI
    /// runner is an Apple Virtual Machine that lists a virtual one, so the old
    /// device-only guard never skipped; `start()` then touched
    /// `engine.inputNode` with no microphone grant and CoreAudio sat there for
    /// tens of minutes before failing. `try?` swallowed the error and the
    /// assertions still held, so the tests *passed* — at 990 s, 1560 s and
    /// 1590 s. Those three were the entire ~69-minute CI test phase, hidden
    /// behind green checkmarks.
    ///
    /// `authorizationStatus` is non-prompting, so this is safe to call from a
    /// test bundle.
    private func requireOpenableInput() throws {
        try XCTSkipUnless(AudioCapture.hasInputDevice(),
                          "no audio input device on this machine")
        try XCTSkipUnless(
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            "microphone access not granted — opening inputNode would block for minutes")
    }

    func testMarkStaleForcesRebuildOnNextStart() throws {
        try requireOpenableInput()
        let capture = AudioCapture()
        capture.markStale()
        // start() may still throw (device busy, format mismatch) — the rebuild
        // happens before that and must be counted either way.
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 1)
        capture.stop()
    }

    func testStartWithoutStaleDoesNotRebuild() throws {
        try requireOpenableInput()
        let capture = AudioCapture()
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 0)
        capture.stop()
    }

    func testMarkStaleIsIdempotentPerStart() throws {
        try requireOpenableInput()
        let capture = AudioCapture()
        capture.markStale()
        capture.markStale()
        _ = try? capture.start()
        XCTAssertEqual(capture.rebuildCount, 1)
        capture.stop()
    }
}
