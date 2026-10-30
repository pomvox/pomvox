import Foundation

/// Hotkey handling: a pure state machine that consumes (keycode, down) events
/// and emits a `Decision` per event. Platform-free and unit-tested — the
/// CGEventTap that feeds it lives in `EventTap.swift`.
///
/// Faithful port of `src/pomvox/hotkey.py` (the Linux-tested spec); the test
/// vectors in `tests/test_hotkey_machine.py` are reproduced 1:1 in
/// `HotkeyMachineTests.swift`. Scheme (config-driven, defaults shown):
/// - push-to-talk: hold `fn` → record while held; release → stop.
/// - toggle: `fn+space` while recording switches to hands-free; a second
///   `fn+space`, a tap of the PTT key, or the optional `stop` key stops.
/// - cancel: `esc` while recording discards the utterance.
/// Toggle/stop/cancel keypresses are swallowed; everything else passes through.
///
/// Swift-only extension (#191): `ptt` also accepts the mouse side buttons
/// `mouse4` / `mouse5`, which ride the modifier path (a down/up pair) under
/// synthetic keycodes and are swallowed so the app never sees a Back/Forward.
/// The Python spec and its vectors stay keyboard-only; Fn is unchanged.
enum HotkeyError: Error, Equatable {
    case unknownKey(String)
    case badToggle(String)
}

final class HotkeyMachine {
    /// What the controller should do in response to an event.
    enum Action {
        case none
        case startPTT
        case enterToggle  // ptt → hands-free; recording continues
        case stop         // finalize: transcribe + insert
        case cancel       // discard: nothing transcribed, nothing inserted
    }

    /// The caller (EventTap) swallows the OS event when `swallow`, and forwards
    /// non-`.none` actions to the controller.
    struct Decision: Equatable {
        var action: Action = .none
        var swallow: Bool = false
    }

    enum State {
        case idle
        case ptt
        case toggle
        case busy  // transcribing; hotkeys inert until done()
    }

    /// Virtual keycodes for the remappable keys (HIToolbox Events.h).
    static let keycodes: [String: Int] = [
        "fn": 63,
        "space": 49,
        "esc": 53,
        "right_option": 61,
        "left_option": 58,
        "right_command": 54,
        "right_shift": 60,
        "right_control": 62,
        // Mouse side buttons: synthetic codes, see `mouseKeycodeBase`.
        "mouse4": mouseKeycodeBase + 3,
        "mouse5": mouseKeycodeBase + 4,
    ]

    /// Keycodes that arrive as flagsChanged rather than keyDown (used by EventTap).
    static let modifierKeycodes: Set<Int> = [63, 61, 58, 54, 55, 60, 56, 62, 59]

    /// Mouse buttons share the keycode space with keys, offset past the 7-bit
    /// virtual keycode range so they can never collide. CGEvent numbers
    /// buttons from 0 (left, right, middle), so "button 4/5" are 3 and 4.
    static let mouseKeycodeBase = 1000

    /// The machine keycode for a CGEvent `mouseEventButtonNumber`; nil for a
    /// button we don't bind (EventTap passes those through untouched).
    static func mouseButtonKeycode(_ button: Int64) -> Int? {
        switch button {
        case 3, 4: return mouseKeycodeBase + Int(button)
        default: return nil
        }
    }

    static func isMouseButton(_ keycode: Int) -> Bool { keycode >= mouseKeycodeBase }

    /// Human-readable names for the Setup heartbeat and log lines. Unknown
    /// names echo through so a log never hides what the config actually said.
    static let displayNames: [String: String] = [
        "fn": "Fn (🌐)", "space": "Space", "esc": "Esc",
        "right_option": "Right Option (⌥)", "left_option": "Left Option (⌥)",
        "right_command": "Right Command (⌘)", "right_shift": "Right Shift (⇧)",
        "right_control": "Right Control (⌃)",
        "mouse4": "Mouse Button 4", "mouse5": "Mouse Button 5",
    ]

    static func displayName(_ configName: String) -> String {
        let key = configName.trimmingCharacters(in: .whitespaces).lowercased()
        return displayNames[key] ?? configName
    }

    /// The same, for a `modifier+key` combo such as the hands-free toggle:
    /// each part is named on its own and joined with " + " (#212). A combo
    /// without a "+" is a single name; unknown parts echo through as above.
    static func comboDisplayName(_ configCombo: String) -> String {
        configCombo.split(separator: "+", omittingEmptySubsequences: false)
            .map { displayName(String($0)) }
            .joined(separator: " + ")
    }

    /// Build from `[hotkey]` config, degrading to the Fn defaults on any invalid
    /// value (#58): dictation must never brick over a typo in config.toml. The
    /// `fellBack` flag lets the caller log which bindings were rejected.
    static func resolved(ptt: String, toggle: String, stop: String, cancel: String)
        -> (machine: HotkeyMachine, fellBack: Bool)
    {
        if let m = try? HotkeyMachine(ptt: ptt, toggle: toggle, stop: stop, cancel: cancel) {
            return (m, false)
        }
        // The default bindings are statically valid; `try!` is safe here.
        return (try! HotkeyMachine(), true)
    }

    static let pass = Decision()

    let pttKey: Int
    /// The PTT virtual keycode, exposed for the Setup heartbeat ("is your key
    /// reaching Pomvox at all?" — hardware Fn keys on third-party keyboards
    /// often never generate an event).
    var pttKeycode: Int { pttKey }
    /// Whether PTT is a mouse side button: EventTap subscribes to mouse
    /// events only then, so a keyboard setup pays nothing for the feature.
    var pttIsMouseButton: Bool { Self.isMouseButton(pttKey) }
    let toggleMod: Int
    let toggleKey: Int
    let stopKey: Int?
    let cancelKey: Int?

    private(set) var state: State = .idle
    private var modsDown: Set<Int> = []

    init(ptt: String = "fn", toggle: String = "fn+space",
         stop: String = "", cancel: String = "esc") throws {
        // Mouse buttons arrive as a down/up pair (the modifier path), so they
        // are valid for PTT and the toggle modifier only; in a keyDown role
        // they would be silently inert, so there they fall back like a typo.
        self.pttKey = try Self.keycode(ptt, mouseButtons: true)
        // Python uses str.partition('+'); a missing separator is an error.
        guard let plus = toggle.firstIndex(of: "+") else {
            throw HotkeyError.badToggle(toggle)
        }
        let mod = String(toggle[..<plus])
        let key = String(toggle[toggle.index(after: plus)...])
        self.toggleMod = try Self.keycode(mod, mouseButtons: true)
        self.toggleKey = try Self.keycode(key)
        // Both optional: fn tap / fn+space already stop hands-free, and
        // cancel="" disables the discard gesture entirely.
        self.stopKey = stop.isEmpty ? nil : try Self.keycode(stop)
        self.cancelKey = cancel.isEmpty ? nil : try Self.keycode(cancel)
    }

    private static func keycode(_ name: String, mouseButtons: Bool = false) throws -> Int {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard let code = keycodes[key], mouseButtons || !isMouseButton(code) else {
            throw HotkeyError.unknownKey(name)
        }
        return code
    }

    /// A flagsChanged event (modifier key went down or up), or a mouse side
    /// button under its synthetic keycode.
    func onModifier(_ keycode: Int, _ isDown: Bool) -> Decision {
        var decision = modifierDecision(keycode, isDown)
        // A side button mapped to PTT belongs to Pomvox while armed: swallowed
        // in every state, so the app underneath never gets a Back/Forward per
        // dictation or an unbalanced down/up. Keyboard modifiers pass as before.
        if keycode == pttKey, pttIsMouseButton { decision.swallow = true }
        return decision
    }

    private func modifierDecision(_ keycode: Int, _ isDown: Bool) -> Decision {
        if isDown { modsDown.insert(keycode) } else { modsDown.remove(keycode) }

        if state == .idle, keycode == pttKey, isDown {
            state = .ptt
            return Decision(action: .startPTT)
        }
        if state == .ptt, keycode == pttKey, !isDown {
            state = .busy
            return Decision(action: .stop)
        }
        if state == .toggle, keycode == pttKey, isDown {
            // Tapping the PTT key again is the most discoverable way out of
            // hands-free mode (Esc and the toggle combo also work).
            state = .busy
            return Decision(action: .stop)
        }
        return Self.pass
    }

    func onKeyDown(_ keycode: Int) -> Decision {
        switch state {
        case .ptt:
            if keycode == toggleKey, modsDown.contains(toggleMod) {
                state = .toggle
                return Decision(action: .enterToggle, swallow: true)
            }
            if let cancelKey, keycode == cancelKey {
                state = .busy
                return Decision(action: .cancel, swallow: true)
            }
            return Self.pass
        case .toggle:
            if let cancelKey, keycode == cancelKey {
                state = .busy
                return Decision(action: .cancel, swallow: true)
            }
            if (stopKey != nil && keycode == stopKey!)
                || (keycode == toggleKey && modsDown.contains(toggleMod)) {
                state = .busy
                return Decision(action: .stop, swallow: true)
            }
            return Self.pass
        case .busy:
            // The PTT key already stopped the recording on its way down; eat
            // the trailing toggle key of a fn+space stop so it isn't typed.
            if keycode == toggleKey, modsDown.contains(toggleMod) {
                return Decision(swallow: true)
            }
            return Self.pass
        case .idle:
            return Self.pass
        }
    }

    /// Stop initiated by something other than a key (VAD endpoint). Valid only
    /// while hands-free: PTT's endpoint is the user's finger, and a stale
    /// endpoint arriving in BUSY/IDLE must be a no-op.
    @discardableResult
    func externalStop() -> Bool {
        if state == .toggle {
            state = .busy
            return true
        }
        return false
    }

    /// Transcription + insertion finished; accept hotkeys again.
    func done() { state = .idle }

    /// Abort whatever is in flight (e.g. recording failed to start).
    func reset() { state = .idle }
}
