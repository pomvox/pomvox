import XCTest
@testable import Pomvox

/// SettingsSchema mirrors src/pomvox/config.py: which keys need a restart
/// (config.py `restart_required`), what a valid model id is, and the hotkey
/// conflict rules. Any drift here is a cross-process contract break — the
/// two sides must change together.
final class SettingsSchemaTests: XCTestCase {

    // MARK: restart-required parity with config.py

    func testRestartRequiredKeysMatchConfigPy() {
        // restart_required(): hotkey.*, stt.model, cleanup.model, audio.device, log.*
        XCTAssertTrue(SettingsSchema.isRestartRequired("hotkey", "ptt"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("hotkey", "cancel"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("stt", "model"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "model"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("audio", "device"))
    }

    /// `NativeEngine.cleanupEnabled`, `.cleanupStyle`, and `.cleanupTimeoutS`
    /// are each assigned in exactly one place — `loadEngineConfig()`
    /// (NativeEngine.swift) — which itself runs from exactly one place,
    /// `arm()`. The per-dictation path only ever reads the cached property,
    /// so toggling any of these three in Settings while already armed does
    /// nothing until the next arm: the running engine keeps using whatever
    /// was true 27 minutes ago. Until someone makes these hot-apply (i.e.
    /// makes the per-dictation path re-read config.toml instead of a cached
    /// field), they must warn "needs a restart" — remove an entry here only
    /// after doing that work for the corresponding field.
    func testCleanupRuntimeSnapshotKeysRequireRestart() {
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "enabled"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "style"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "timeout_s"))
    }

    func testHotAppliableKeysAreNotRestartRequired() {
        XCTAssertFalse(SettingsSchema.isRestartRequired("vad", "silence_ms"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("hud", "position"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("history", "retention_days"))
    }

    // MARK: model-id validation (the only free-text field — blocks save)

    func testValidModelIDs() {
        XCTAssertEqual(SettingsSchema.validateModelID("mlx-community/Qwen3-4B-4bit"), .ok)
        XCTAssertEqual(SettingsSchema.validateModelID("my-org/Custom-Model"), .ok)
    }

    func testEmptyModelIDIsInvalid() {
        if case .invalid = SettingsSchema.validateModelID("") {} else {
            XCTFail("empty model id must be invalid")
        }
        if case .invalid = SettingsSchema.validateModelID("   ") {} else {
            XCTFail("whitespace-only model id must be invalid")
        }
    }

    // MARK: allowed enum values mirror the config.py dataclasses

    func testEnumValuesMatchConfigPy() {
        XCTAssertEqual(SettingsSchema.cleanupStyles, ["light", "polish"])
        XCTAssertEqual(SettingsSchema.hudPositions, ["bottom-center", "top-center", "notch"])
    }

    // MARK: hotkey conflicts (advisory warnings, never block save)

    func testDefaultHotkeysHaveNoConflict() {
        let c = HotkeyChoice(ptt: "fn", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertTrue(SettingsSchema.hotkeyConflicts(c).isEmpty)
    }

    func testToggleModifierDifferentFromPTTWarns() {
        let c = HotkeyChoice(ptt: "fn", toggle: "right_option+space", stop: "", cancel: "esc")
        XCTAssertFalse(SettingsSchema.hotkeyConflicts(c).isEmpty)
    }

    func testCancelSameAsPTTWarns() {
        let c = HotkeyChoice(ptt: "fn", toggle: "fn+space", stop: "", cancel: "fn")
        XCTAssertFalse(SettingsSchema.hotkeyConflicts(c).isEmpty)
    }

    func testStopSameAsCancelWarns() {
        let c = HotkeyChoice(ptt: "fn", toggle: "fn+space", stop: "esc", cancel: "esc")
        XCTAssertFalse(SettingsSchema.hotkeyConflicts(c).isEmpty)
    }

    // MARK: cleanup model presets

    func testTheDefaultCleanupModelIsOfferedAsAPreset() {
        XCTAssertEqual(
            SettingsSchema.cleanupModelPresets.first, MemoryTier.standardCleanupModel,
            "the shipped default should head the list the user picks from")
    }

    /// Open-source-first: swapping the default must not remove the Qwen3
    /// options a user may already be running.
    func testTheQwen3PresetsRemainSelectable() {
        for id in [
            "mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3-1.7B-4bit",
            "mlx-community/Qwen3-8B-4bit",
        ] {
            XCTAssertTrue(SettingsSchema.cleanupModelPresets.contains(id), id)
        }
    }
}
