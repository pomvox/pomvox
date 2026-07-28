import Foundation

/// The chosen hotkey bindings, mirroring config.py's `[hotkey]` table.
struct HotkeyChoice: Equatable {
    let ptt: String      // single key held to talk (e.g. "fn")
    let toggle: String   // "modifier+key" to enter hands-free (e.g. "fn+space")
    let stop: String     // optional extra stop key; "" = none
    let cancel: String   // discard key; "" = disabled
}

/// Result of validating a free-text field. `.invalid` blocks the save and is
/// shown inline; the file is left untouched.
enum FieldValidation: Equatable {
    case ok
    case invalid(String)
}

/// Declarative mirror of `src/pomvox/config.py`. The Swift Hub and the Python
/// engine share `config.toml` as their only contract, so the schema here must
/// track the dataclasses there — restart-required keys, allowed enum values,
/// and what makes a value valid. Drift is a contract break.
enum SettingsSchema {

    // MARK: - Restart-required (parity with config.py `restart_required`)

    /// Keys the running engine can't hot-apply: models and the hotkey/event
    /// tap (built once at startup), the input device (InputStream built at
    /// startup), and log routing. Everything else hot-applies within ~1 s.
    static let restartRequiredKeys: Set<String> = [
        "hotkey.ptt", "hotkey.toggle", "hotkey.stop", "hotkey.cancel",
        "stt.model", "cleanup.model", "audio.device", "log.file",
    ]

    static func isRestartRequired(_ section: String, _ key: String) -> Bool {
        restartRequiredKeys.contains("\(section).\(key)")
    }

    // MARK: - Allowed enum values (mirror the dataclass `__post_init__` guards)

    static let cleanupStyles = ["light", "polish"]
    static let hudPositions = ["bottom-center", "top-center", "notch"]

    // Curated suggestions only — the field stays free text so any MLX model id
    // works (open-source-first; never lock out an arbitrary id).
    static let sttModelPresets = [
        "mlx-community/parakeet-tdt-0.6b-v2",
        "mlx-community/parakeet-tdt-0.6b-v3",
    ]
    static let cleanupModelPresets = [
        MemoryTier.standardCleanupModel,
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3-8B-4bit",
    ]

    // MARK: - Validation

    /// A model id is free text (never lock out arbitrary Hugging Face ids), so
    /// the only rule is that it isn't empty — an empty id would crash the
    /// loader. Blank → invalid; the file is left untouched.
    static func validateModelID(_ id: String) -> FieldValidation {
        id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .invalid("Model id can't be empty")
            : .ok
    }

    // MARK: - Hotkey presets (validated choices, no key-capture recorder)

    /// Single keys that can hold-to-talk. Names match config.py `KEYCODES`.
    static let pttPresets = [
        "fn", "right_option", "left_option", "right_command", "right_control", "right_shift",
    ]
    /// "modifier+key" combos for hands-free toggle.
    static let togglePresets = ["fn+space", "right_option+space", "left_option+space"]
    /// Cancel key; "" disables the discard gesture.
    static let cancelPresets = ["esc", ""]
    /// Optional extra stop key; "" = none (fn tap / the toggle combo always stop).
    static let stopPresets = ["", "right_command", "right_shift"]

    /// Human label for a key token in a dropdown ("" shows as "None").
    static func keyLabel(_ token: String) -> String {
        token.isEmpty ? "None" : token.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Hotkey conflict warnings (advisory — never block the save)

    /// Flags binding choices that fight the engine's state machine. These are
    /// warnings, not errors: the user can still save, but we say why it's odd.
    static func hotkeyConflicts(_ c: HotkeyChoice) -> [String] {
        var out: [String] = []

        // ENTER_TOGGLE fires only while the PTT key is held AND the toggle's
        // modifier is down (hotkey.py on_key_down). If the modifier isn't the
        // PTT key, you can't reach hands-free one-handed.
        let toggleMod = c.toggle.split(separator: "+").first.map(String.init) ?? ""
        if !toggleMod.isEmpty, toggleMod != c.ptt {
            out.append(
                "Toggle uses \(keyLabel(toggleMod)) but push-to-talk is \(keyLabel(c.ptt)) — "
                + "you can't switch to hands-free without also pressing \(keyLabel(toggleMod)).")
        }

        // The discard key can't double as the key that starts dictation.
        if !c.cancel.isEmpty, c.cancel == c.ptt {
            out.append("Cancel and push-to-talk are both \(keyLabel(c.ptt)).")
        }

        // A separate stop key that's also the cancel key is ambiguous.
        if !c.stop.isEmpty, c.stop == c.cancel {
            out.append("Stop and cancel are both \(keyLabel(c.stop)).")
        }

        return out
    }
}
