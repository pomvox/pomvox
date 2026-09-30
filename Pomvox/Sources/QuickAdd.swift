import AppKit
import SwiftUI

/// `[hotkey] quick_add` parser: "cmd+shift+d" → (modifier flags, ANSI
/// keycode). At least one modifier is required — a bare key would fire on
/// every keystroke of normal typing. Separate from HotkeyMachine on purpose:
/// dictation keys are modifier-state machines on a CGEventTap; this is a
/// plain chord on an NSEvent monitor, active even when the engine is off.
enum QuickAddHotkey {
    private static let modifiers: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command,
        "shift": .shift,
        "alt": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control,
    ]

    /// ANSI virtual keycodes (HIToolbox Events.h) for letters and digits.
    private static let keycodes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
        "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37,
        "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26,
        "8": 28, "9": 25, "0": 29,
    ]

    static func parse(_ s: String) -> (flags: NSEvent.ModifierFlags, keyCode: UInt16)? {
        let parts = s.lowercased().components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 2, let keyName = parts.last,
              let keyCode = keycodes[keyName] else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for mod in parts.dropLast() {
            guard let f = modifiers[mod] else { return nil }
            flags.insert(f)
        }
        guard !flags.isEmpty else { return nil }
        return (flags, keyCode)
    }

    static func matches(_ event: NSEvent,
                        _ binding: (flags: NSEvent.ModifierFlags, keyCode: UInt16)) -> Bool {
        event.keyCode == binding.keyCode
            && event.modifierFlags.intersection([.command, .shift, .option, .control])
                == binding.flags
    }
}

/// Borderless non-activating panel: it takes key status for its text fields
/// without activating Pomvox, so closing it lands focus back in the app the
/// user was in — the whole point of quick-add.
final class QuickAddPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Owns the global/local key monitors and the panel. Constructed once in
/// AppDelegate; inert when the binding is empty or unparseable. The global
/// monitor only delivers events while the app has an input-monitoring grant —
/// the same grant Setup already requires for dictation.
@MainActor
final class QuickAddController {
    private var binding: (flags: NSEvent.ModifierFlags, keyCode: UInt16)?
    private var panel: QuickAddPanel?
    private let store = DictionaryStore.shared

    func start(bindingString: String) {
        guard !bindingString.isEmpty else { return }
        guard let parsed = QuickAddHotkey.parse(bindingString) else {
            NSLog("quick-add: invalid [hotkey] quick_add %@ — disabled", bindingString)
            return
        }
        binding = parsed
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            var swallowed = false
            MainActor.assumeIsolated {
                if let self, let b = self.binding, QuickAddHotkey.matches(event, b) {
                    self.togglePanel(); swallowed = true
                }
            }
            return swallowed ? nil : event
        }
        NSLog("quick-add: armed on %@", bindingString)
    }

    private func handle(_ event: NSEvent) {
        guard let b = binding, QuickAddHotkey.matches(event, b) else { return }
        togglePanel()
    }

    private func togglePanel() {
        if let panel, panel.isVisible {
            panel.close()
            return
        }
        let p = panel ?? makePanel()
        panel = p
        p.center()
        p.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> QuickAddPanel {
        let p = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 196),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = NSHostingView(rootView:
            QuickAddView(store: store, close: { [weak p] in p?.close() }))
        return p
    }
}

/// Word field + optional "misheard as" field. Return saves; word-only goes to
/// the words list, both fields make a fixup rule. Escape closes.
private struct QuickAddView: View {
    @ObservedObject var store: DictionaryStore
    let close: () -> Void
    @State private var word = ""
    @State private var misheard = ""
    @State private var errorText: String?
    @FocusState private var wordFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add to Pomvox dictionary").font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            if !store.featureEnabled {
                Text("Dictionary is off in config.toml. This will be saved, but it won’t change dictation until you turn it back on.")
                    .font(Typo.ui(11)).foregroundStyle(Palette.ember)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Word or phrase (how it should be written)", text: $word)
                .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                .focused($wordFocused)
                .onSubmit(save)
            TextField("Misheard as… (optional — makes a fixup rule)", text: $misheard)
                .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                .onSubmit(save)
            if let errorText {
                Text(errorText).font(Typo.ui(11)).foregroundStyle(.red)
            }
            HStack {
                Text("↩ save · esc close").font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            store.refreshFeatureEnabled()
            wordFocused = true
        }
        .onExitCommand(perform: close)
    }

    private func save() {
        guard store.parseError == nil else {
            errorText = "Dictionary file has an error — fix it in the Dictionary page first."
            return
        }
        let w = word.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        let heard = misheard.trimmingCharacters(in: .whitespaces)
        if heard.isEmpty {
            store.addWord(w)
        } else {
            store.upsert(DictionaryRule(sources: [heard], target: w,
                                        enabled: true, origin: "manual"),
                         replacingID: nil)
        }
        word = ""; misheard = ""; errorText = nil
        close()
    }
}
