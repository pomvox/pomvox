import XCTest
@testable import Pomvox

/// SettingsSchema mirrors src/pomvox/config.py: which keys need a restart
/// (config.py `restart_required`), what a valid model id is, and the hotkey
/// conflict rules. Any drift here is a cross-process contract break — the
/// two sides must change together.
final class SettingsSchemaTests: XCTestCase {

    // MARK: restart-required parity with config.py

    func testRestartRequiredKeysMatchConfigPy() {
        // restart_required(): hotkey.*, stt.model, audio.device, log.*
        // cleanup.model stays restart-required in config.py (the Python
        // process loads it once at startup). The native engine hot-applies
        // it — a save starts the download — so it is not in this set.
        XCTAssertTrue(SettingsSchema.isRestartRequired("hotkey", "ptt"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("hotkey", "cancel"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("stt", "model"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "model"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("audio", "device"))
    }

    /// Cleanup enabled / style / timeout / model are re-read on save
    /// (`NativeEngine.applyCleanupSettingsFromDisk`), not snapshotted until
    /// the next arm. They must not ask for a restart: that restart cancelled
    /// the model download.
    func testCleanupRuntimeKeysHotApply() {
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "enabled"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "style"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "timeout_s"))
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "model"))
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

    // MARK: push-to-talk presets (#191: side mouse buttons, Swift-only)

    /// Fn stays the default and the first choice; the two side buttons are
    /// offered after the keyboard keys and read as buttons, not keys.
    func testPttPresetsOfferTheSideMouseButtonsAfterFn() {
        XCTAssertEqual(SettingsSchema.pttPresets.first, "fn")
        XCTAssertEqual(SettingsSchema.pttPresets.suffix(2), ["mouse4", "mouse5"])
        XCTAssertEqual(SettingsSchema.keyLabel("mouse4"), "mouse button 4")
        XCTAssertEqual(SettingsSchema.keyLabel("mouse5"), "mouse button 5")
        XCTAssertEqual(SettingsSchema.keyLabel("right_option"), "right option")
        // Every preset must be a binding the engine accepts, or the picker
        // would offer a value that silently falls back to Fn.
        for p in SettingsSchema.pttPresets {
            XCTAssertNoThrow(try HotkeyMachine(ptt: p), p)
        }
    }

    // MARK: hands-free from a side button (#196)

    /// A side-button PTT needs a side-button toggle to go hands-free; the
    /// picker offers both so nobody has to hand-edit config.toml.
    func testTogglePresetsOfferTheSideMouseButtonCombos() {
        XCTAssertEqual(SettingsSchema.togglePresets.first, "fn+space")
        XCTAssertEqual(SettingsSchema.togglePresets.suffix(2), ["mouse4+space", "mouse5+space"])
        XCTAssertEqual(SettingsSchema.keyLabel("mouse4+space"), "mouse button 4+space")
        XCTAssertEqual(SettingsSchema.keyLabel("right_option+space"), "right option+space")
        XCTAssertEqual(SettingsSchema.keyLabel("fn+space"), "fn+space")
        // Every preset must be a toggle the engine accepts with its matching
        // PTT, or the picker would offer a value that falls back to Fn.
        for t in SettingsSchema.togglePresets {
            let mod = String(t.split(separator: "+")[0])
            XCTAssertNoThrow(try HotkeyMachine(ptt: mod, toggle: t), t)
            XCTAssertTrue(SettingsSchema.hotkeyConflicts(
                HotkeyChoice(ptt: mod, toggle: t, stop: "", cancel: "esc")).isEmpty, t)
        }
    }

    /// The picker keeps a value the file already had, so a hand-edited combo
    /// such as `right_command+space` is never silently replaced.
    func testPickerPreservesAHandEditedValue() {
        let presets = SettingsSchema.togglePresets
        XCTAssertEqual(SettingsSchema.pickerOptions(presets: presets, selection: "mouse4+space"),
                       presets)
        XCTAssertEqual(SettingsSchema.pickerOptions(presets: presets, selection: "right_command+space"),
                       ["right_command+space"] + presets)
    }

    /// The conflict warning stays accurate for a mouse PTT and now says
    /// what to do: pick the matching side-button toggle.
    func testToggleModifierDifferentFromMousePTTSuggestsTheMouseToggle() {
        let c = HotkeyChoice(ptt: "mouse4", toggle: "fn+space", stop: "", cancel: "esc")
        let warnings = SettingsSchema.hotkeyConflicts(c)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Toggle uses fn but push-to-talk is mouse button 4"),
                      warnings[0])
        XCTAssertTrue(warnings[0].contains("mouse button 4+space"), warnings[0])
        let c5 = HotkeyChoice(ptt: "mouse5", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertTrue(SettingsSchema.hotkeyConflicts(c5)[0].contains("mouse button 5+space"))
    }

    /// The suggestion is for side-button PTTs only (#213): a keyboard PTT
    /// keeps the plain mismatched-toggle warning it had before #196, even
    /// though `fn+space` is a preset the picker offers.
    func testToggleModifierDifferentFromKeyboardPTTHasNoSuggestion() {
        let c = HotkeyChoice(ptt: "fn", toggle: "right_option+space", stop: "", cancel: "esc")
        let warnings = SettingsSchema.hotkeyConflicts(c)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("Toggle uses right option but push-to-talk is fn"),
                      warnings[0])
        XCTAssertFalse(warnings[0].contains("Try"), warnings[0])
        let option = HotkeyChoice(ptt: "right_option", toggle: "fn+space", stop: "", cancel: "esc")
        XCTAssertFalse(SettingsSchema.hotkeyConflicts(option)[0].contains("Try"))
    }

    /// Only a toggle the picker offers is suggested; a PTT with no matching
    /// preset keeps the plain warning rather than inventing a combo.
    func testNoSuggestionWhenNoMatchingTogglePresetExists() {
        let c = HotkeyChoice(ptt: "right_command", toggle: "fn+space", stop: "", cancel: "esc")
        let warnings = SettingsSchema.hotkeyConflicts(c)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertFalse(warnings[0].contains("Try"), warnings[0])
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
