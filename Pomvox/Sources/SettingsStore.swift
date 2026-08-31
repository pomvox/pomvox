import Foundation
import SwiftUI

// SettingsValues is a plain data mirror of config.py's UI-owned keys (a
// config-like struct). SettingsIO below is the logic, stubbed first (TDD).

/// Every config.toml key the Settings UI owns, with config.py's defaults.
struct SettingsValues: Equatable {
    // General
    var cleanupEnabled: Bool
    var cleanupStyle: String
    var cleanupTimeoutS: Double
    var hudEnabled: Bool
    var hudShowDraft: Bool
    var hudPosition: String
    var hudSounds: Bool
    // Dictation mark
    var signatureEnabled: Bool
    var signatureMark: String
    // Models
    var sttModel: String
    var cleanupModel: String
    // Hotkeys
    var ptt: String
    var toggle: String
    var stop: String
    var cancel: String
    var quickAdd: String
    // Voice
    var vadEnabled: Bool
    var vadSilenceMs: Int
    var vadAggressiveness: Int
    var audioDevice: String
    // Privacy
    var historyEnabled: Bool
    var retentionDays: Int

    static let defaults = SettingsValues(
        cleanupEnabled: true, cleanupStyle: "polish", cleanupTimeoutS: 5.0,
        hudEnabled: true, hudShowDraft: true, hudPosition: "bottom-center", hudSounds: true,
        signatureEnabled: false, signatureMark: Signature.defaultMark,
        sttModel: "mlx-community/parakeet-tdt-0.6b-v2",
        cleanupModel: MemoryTier.standardCleanupModel,
        ptt: "fn", toggle: "fn+space", stop: "", cancel: "esc", quickAdd: "",
        vadEnabled: true, vadSilenceMs: 2000, vadAggressiveness: 2, audioDevice: "",
        historyEnabled: true, retentionDays: 7)
}

/// Reads/writes `SettingsValues` through a `ConfigDocument`. The write path
/// only touches keys the user actually changed, so untouched comments and
/// sections survive byte-for-byte (the M2 acceptance test).
enum SettingsIO {
    static func read(_ doc: ConfigDocument) -> SettingsValues {
        let d = SettingsValues.defaults
        return SettingsValues(
            cleanupEnabled: doc.bool("cleanup", "enabled") ?? d.cleanupEnabled,
            cleanupStyle: doc.string("cleanup", "style") ?? d.cleanupStyle,
            cleanupTimeoutS: doc.double("cleanup", "timeout_s") ?? d.cleanupTimeoutS,
            hudEnabled: doc.bool("hud", "enabled") ?? d.hudEnabled,
            hudShowDraft: doc.bool("hud", "show_draft") ?? d.hudShowDraft,
            hudPosition: doc.string("hud", "position") ?? d.hudPosition,
            hudSounds: doc.bool("hud", "sounds") ?? d.hudSounds,
            signatureEnabled: doc.bool("signature", "enabled") ?? d.signatureEnabled,
            signatureMark: doc.string("signature", "mark") ?? d.signatureMark,
            sttModel: doc.string("stt", "model") ?? d.sttModel,
            cleanupModel: doc.string("cleanup", "model") ?? d.cleanupModel,
            ptt: doc.string("hotkey", "ptt") ?? d.ptt,
            toggle: doc.string("hotkey", "toggle") ?? d.toggle,
            stop: doc.string("hotkey", "stop") ?? d.stop,
            cancel: doc.string("hotkey", "cancel") ?? d.cancel,
            quickAdd: doc.string("hotkey", "quick_add") ?? d.quickAdd,
            vadEnabled: doc.bool("vad", "enabled") ?? d.vadEnabled,
            vadSilenceMs: doc.int("vad", "silence_ms") ?? d.vadSilenceMs,
            vadAggressiveness: doc.int("vad", "aggressiveness") ?? d.vadAggressiveness,
            audioDevice: doc.string("audio", "device") ?? d.audioDevice,
            historyEnabled: doc.bool("history", "enabled") ?? d.historyEnabled,
            retentionDays: doc.int("history", "retention_days") ?? d.retentionDays)
    }

    /// Field-path → message for anything that would break the engine. Only the
    /// free-text model ids can be invalid (everything else is a constrained
    /// control); an invalid set blocks the write and leaves the file untouched.
    static func validate(_ v: SettingsValues) -> [String: String] {
        var errs: [String: String] = [:]
        if case let .invalid(m) = SettingsSchema.validateModelID(v.sttModel) { errs["stt.model"] = m }
        if case let .invalid(m) = SettingsSchema.validateModelID(v.cleanupModel) { errs["cleanup.model"] = m }
        return errs
    }

    /// Write every UI-owned key (used for a from-scratch document / tests).
    static func applyAll(_ v: SettingsValues, to doc: inout ConfigDocument) {
        apply(v, to: &doc, changedFrom: nil)
    }

    /// Validate, then write only the keys that differ from what's on disk.
    /// Returns false (no write) when validation fails.
    static func writeIfValid(_ v: SettingsValues, path: String) -> Bool {
        guard validate(v).isEmpty else { return false }
        var doc = ConfigDocument.load(path: path)
        apply(v, to: &doc, changedFrom: read(doc))
        do {
            try doc.write(to: path)
            return true
        } catch {
            return false
        }
    }

    /// Apply `v` to `doc`. When `current` is given, a key is written only if it
    /// changed — so unchanged keys (and the bytes around them) are left as-is.
    private static func apply(_ v: SettingsValues, to doc: inout ConfigDocument, changedFrom current: SettingsValues?) {
        func setBool(_ s: String, _ k: String, _ new: Bool, _ old: Bool?) {
            if old != new { doc.set(s, k, bool: new) }
        }
        func setString(_ s: String, _ k: String, _ new: String, _ old: String?) {
            if old != new { doc.set(s, k, string: new) }
        }
        func setInt(_ s: String, _ k: String, _ new: Int, _ old: Int?) {
            if old != new { doc.set(s, k, int: new) }
        }
        func setDouble(_ s: String, _ k: String, _ new: Double, _ old: Double?) {
            if old != new { doc.set(s, k, double: new) }
        }
        let c = current
        setBool("cleanup", "enabled", v.cleanupEnabled, c?.cleanupEnabled)
        setString("cleanup", "style", v.cleanupStyle, c?.cleanupStyle)
        setDouble("cleanup", "timeout_s", v.cleanupTimeoutS, c?.cleanupTimeoutS)
        setBool("hud", "enabled", v.hudEnabled, c?.hudEnabled)
        setBool("hud", "show_draft", v.hudShowDraft, c?.hudShowDraft)
        setString("hud", "position", v.hudPosition, c?.hudPosition)
        setBool("hud", "sounds", v.hudSounds, c?.hudSounds)
        setBool("signature", "enabled", v.signatureEnabled, c?.signatureEnabled)
        setString("signature", "mark", v.signatureMark, c?.signatureMark)
        setString("stt", "model", v.sttModel, c?.sttModel)
        setString("cleanup", "model", v.cleanupModel, c?.cleanupModel)
        setString("hotkey", "ptt", v.ptt, c?.ptt)
        setString("hotkey", "toggle", v.toggle, c?.toggle)
        setString("hotkey", "stop", v.stop, c?.stop)
        setString("hotkey", "cancel", v.cancel, c?.cancel)
        setString("hotkey", "quick_add", v.quickAdd, c?.quickAdd)
        setBool("vad", "enabled", v.vadEnabled, c?.vadEnabled)
        setInt("vad", "silence_ms", v.vadSilenceMs, c?.vadSilenceMs)
        setInt("vad", "aggressiveness", v.vadAggressiveness, c?.vadAggressiveness)
        setString("audio", "device", v.audioDevice, c?.audioDevice)
        setBool("history", "enabled", v.historyEnabled, c?.historyEnabled)
        setInt("history", "retention_days", v.retentionDays, c?.retentionDays)
    }
}

/// View-model behind the Settings panes: the live edit buffer (`values`), the
/// last-saved snapshot (`saved`), and validation errors. Mirrors HistoryReader's
/// path convention (`POMVOX_CONFIG_PATH` override for tests).
@MainActor
final class SettingsModel: ObservableObject {
    @Published var values: SettingsValues = .defaults
    @Published private(set) var saved: SettingsValues = .defaults
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var justSaved = false

    let path: String
    let inputDevices: [String]

    init(path: String = SettingsModel.defaultPath(), inputDevices: [String]? = nil) {
        self.path = path
        self.inputDevices = inputDevices ?? AudioDevices.inputDeviceNames()
        load()
    }

    nonisolated static func defaultPath() -> String {
        if let o = ProcessInfo.processInfo.environment["POMVOX_CONFIG_PATH"], !o.isEmpty { return o }
        return NSString(string: "~/.pomvox/config.toml").expandingTildeInPath
    }

    func load() {
        let v = SettingsIO.read(ConfigDocument.load(path: path))
        values = v
        saved = v
        errors = [:]
        justSaved = false
    }

    var isDirty: Bool { values != saved }

    func revert() {
        values = saved
        errors = [:]
        justSaved = false
    }

    /// Friendly names of the restart-required fields among the pending edits —
    /// drives the "needs a restart" banner.
    var pendingRestart: [String] {
        var out: [String] = []
        if values.sttModel != saved.sttModel { out.append("STT model") }
        if values.cleanupModel != saved.cleanupModel { out.append("Cleanup model") }
        if [values.ptt, values.toggle, values.stop, values.cancel, values.quickAdd]
            != [saved.ptt, saved.toggle, saved.stop, saved.cancel, saved.quickAdd] { out.append("Hotkeys") }
        if values.audioDevice != saved.audioDevice { out.append("Input device") }
        return out
    }

    func save() {
        errors = SettingsIO.validate(values)
        guard errors.isEmpty else { return }
        if SettingsIO.writeIfValid(values, path: path) {
            saved = values
            justSaved = true
            // The engine snapshots most keys at arm(), but hot-applies the
            // dictation mark off this.
            NotificationCenter.default.post(name: .pomvoxSettingsDidChange, object: self)
            // Anonymous: that *a* setting changed, never which one or its value.
            TelemetryClient.shared.emit(.settingChanged)
        }
    }
}
