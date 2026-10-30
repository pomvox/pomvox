import XCTest
@testable import Pomvox

/// arm() snapshots `[hotkey]` into the machine *and* into the two mirrors the
/// Setup heartbeat reads (`pttDisplayName`, `pttIsMouseButton`) before the tap
/// installs. A live arm needs the on-disk lock, three TCC grants and a
/// CGEventTap, so the engine is built with those gates substituted: the lock
/// lives in a temp dir, the grants read as present, and the tap fails the way
/// it does on a runner without Input Monitoring. That is where arm() stops on
/// CI anyway — after the hotkey snapshot, before any model is touched.
@MainActor
final class NativeEngineArmTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-arm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// Cleanup is off so the arm never schedules a pack or weights download.
    private func engine(ptt: String, toggle: String = "fn+space") throws -> NativeEngine {
        let path = dir.appendingPathComponent("config.toml").path
        try "[hotkey]\nptt = \"\(ptt)\"\ntoggle = \"\(toggle)\"\n\n[cleanup]\nenabled = false\n"
            .write(toFile: path, atomically: true, encoding: .utf8)
        return NativeEngine(
            configPath: path,
            pidfile: Pidfile(url: dir.appendingPathComponent("engine.pid")),
            permissionsGranted: { true },
            startTap: { _ in throw EventTapError.notPermitted })
    }

    /// `ptt = "mouse4"` reaches Setup as a mouse button (#196): the copy says
    /// "button" and drops the hardware-Fn advice only if this mirror is true.
    func testArmMirrorsMouseButtonPttForSetup() async throws {
        let e = try engine(ptt: "mouse4")
        XCTAssertFalse(e.pttIsMouseButton)   // pre-arm default is Fn
        await e.arm(interactive: false)
        XCTAssertTrue(e.pttIsMouseButton)
        XCTAssertEqual(e.pttDisplayName, HotkeyMachine.displayName("mouse4"))
        // Stopped at the tap, as on CI: nothing installed, lock released.
        XCTAssertFalse(e.isArmed)
        XCTAssertFalse(e.tapInstalled)
        guard case .failed = e.status else { return XCTFail("expected .failed, got \(e.status)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("engine.pid").path))
    }

    func testArmKeepsKeyboardPttAsKey() async throws {
        let e = try engine(ptt: "fn")
        await e.arm(interactive: false)
        XCTAssertFalse(e.pttIsMouseButton)
        XCTAssertEqual(e.pttDisplayName, HotkeyMachine.displayName("fn"))
    }

    /// An unknown button falls back to the Fn defaults (HotkeyMachine.resolved);
    /// the mirror follows the machine that was actually built, not the typed value.
    func testArmFallbackFromUnknownButtonIsNotMouse() async throws {
        let e = try engine(ptt: "mouse6", toggle: "mouse6+space")
        await e.arm(interactive: false)
        XCTAssertFalse(e.pttIsMouseButton)
        XCTAssertEqual(e.pttDisplayName, HotkeyMachine.displayName("fn"))
        // The whole [hotkey] table falls back together, so the toggle mirror
        // names the default combo too — not the "mouse6+space" the file said.
        XCTAssertEqual(e.toggleDisplayName, HotkeyMachine.comboDisplayName("fn+space"))
    }

    /// The sidebar status card reads the toggle mirror next to the PTT one
    /// (#212): `toggle = "mouse4+space"` reaches it as the configured combo.
    func testArmMirrorsToggleComboForSidebar() async throws {
        let e = try engine(ptt: "mouse4", toggle: "mouse4+space")
        XCTAssertEqual(e.toggleDisplayName, HotkeyMachine.comboDisplayName("fn+space"))  // pre-arm default
        await e.arm(interactive: false)
        XCTAssertEqual(e.toggleDisplayName, "Mouse Button 4 + Space")
        XCTAssertEqual(e.pttDisplayName, "Mouse Button 4")
    }

    /// A valid PTT with an invalid toggle still falls back as a whole (the
    /// machine is Fn/Fn+Space), and both mirrors say so.
    func testArmFallbackFromBadToggleResetsBothMirrors() async throws {
        let e = try engine(ptt: "mouse4", toggle: "space")   // no "+": badToggle
        await e.arm(interactive: false)
        XCTAssertFalse(e.pttIsMouseButton)
        XCTAssertEqual(e.pttDisplayName, HotkeyMachine.displayName("fn"))
        XCTAssertEqual(e.toggleDisplayName, HotkeyMachine.comboDisplayName("fn+space"))
    }
}
