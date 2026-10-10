import AppKit
import ApplicationServices
import Foundation

/// What `paste` did with the transcript.
enum PasteOutcome: Equatable {
    case pasted             // editable field reported focus; ⌘V posted, not OS-acknowledged
    case copiedToClipboard  // no event posted — left on the clipboard for recovery
    case pasteUnverified    // best-effort event posted; keep text, but avoid encouraging a duplicate
}

/// The text-insertion recipe shared by the native engine (fresh dictation) and
/// History re-insert: stage the text on the pasteboard marked concealed,
/// synthesize ⌘V, then restore the prior clipboard. Faithful port of
/// `src/pomvox/insert.py` (KEYCODE_V=9, concealed type, changeCount-guarded
/// restore). The synthesized ⌘V needs Accessibility.
///
/// Recovery beyond the Python port: `insert.py` always restores the clipboard,
/// so a dictation with no focused text field is silently lost (the Python app
/// recovers via a "copy last transcript" menu item). The native engine has no
/// menu bar, so instead — when no editable field is focused — it leaves the
/// transcript on the clipboard and reports `.pasteUnverified` (the HUD asks
/// the user to check the paste before recovering from the clipboard). The ⌘V is *always* synthesized regardless, so
/// the focus probe can never break the normal paste in apps where AX focus
/// reporting is unreliable.
///
/// Fidelity beyond the Python port: the restore snapshots every item and
/// flavor (`ClipboardSnapshot`), not just the plain string — `insert.py`'s
/// string-only save meant a copied image or file vanished after a dictation
/// and rich text came back stripped to plain.
@MainActor
enum Paster {
    private static let coordinator = PasteCoordinator()

    /// Acquired before the utterance currency check. Insertion consumes it;
    /// stale/empty callers must release unused ownership with `cancelUnused`.
    @MainActor
    final class Request {
        private var lease: PasteCoordinator.Lease?
        fileprivate let targetIsCurrent: () -> Bool

        fileprivate init(lease: PasteCoordinator.Lease, targetIsCurrent: @escaping () -> Bool) {
            self.lease = lease
            self.targetIsCurrent = targetIsCurrent
        }

        func cancelUnused() {
            lease?.release()
            lease = nil
        }

        fileprivate func takeLease() -> PasteCoordinator.Lease {
            precondition(lease != nil, "Paste request already consumed")
            let result = lease!
            lease = nil
            return result
        }
    }

    /// Remember the foreground app and (when AX reports it) the focused field
    /// before waiting. A delayed request must not paste into a different field.
    private struct Target {
        let pid: pid_t?
        let element: AXUIElement?

        static func capture() -> Target {
            var focused: AnyObject?
            let result = AXUIElementCopyAttributeValue(
                AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &focused)
            return Target(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          element: result == .success ? (focused as! AXUIElement?) : nil)
        }

        func isCurrent() -> Bool {
            let current = Target.capture()
            guard pid == current.pid else { return false }
            switch (element, current.element) {
            case (nil, nil): return true  // AX unavailable: retain the existing best-effort fallback.
            case let (old?, new?): return CFEqual(old, new)
            default: return false
            }
        }
    }

    static func prepare() async -> Request? {
        let target = Target.capture()
        return await prepare(using: coordinator, targetIsCurrent: target.isCurrent)
    }

    /// Injection seam: tests use named pasteboards and never inspect real focus.
    static func prepare(using owner: PasteCoordinator,
                        targetIsCurrent: @escaping () -> Bool) async -> Request? {
        guard let lease = await owner.acquire() else { return nil }
        return Request(lease: lease, targetIsCurrent: targetIsCurrent)
    }

    static let keyV: CGKeyCode = 9
    /// nspasteboard.org convention: clipboard managers (Maccy, Paste, Alfred…)
    /// that honor it skip items carrying this type, so dictations don't pile up
    /// in clipboard history.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// The restore checkpoint after the ⌘V posts. The synthesized ⌘V is
    /// asynchronous — the target app reads the clipboard only when it processes
    /// the keystroke on its own main thread — and a fixed timer here raced slow
    /// apps twice (0.15 s originally, then 0.5 s in #82): if the restore fired
    /// first, the app pasted the *restored prior clipboard* instead of the
    /// transcript. The transcript's string is therefore staged through a data
    /// provider. A read is only a heuristic: a clipboard manager can also read
    /// it, and macOS provides no target acknowledgement. Read → restore now;
    /// unread → hold
    /// the transcript until `unreadRestoreDelay`. Keep this at ≥ 0.5 s so a
    /// clipboard manager's early read can never make the restore fire sooner
    /// than it used to.
    static let restoreDelay: TimeInterval = 0.5

    /// When the transcript was never read by the checkpoint (an app that's
    /// mid-launch or seconds-busy — the #82 failure mode), how long after the
    /// ⌘V to give the clipboard back regardless. Bounded so the user's copy
    /// always returns even if no paste ever landed; the changeCount guard
    /// still lets a real user copy win.
    static let unreadRestoreDelay: TimeInterval = 3.0

    /// Stage `text` on `pb` marked concealed; return the resulting changeCount.
    @discardableResult
    static func stage(_ pb: NSPasteboard, _ text: String) -> Int {
        pb.declareTypes([.string, concealedType], owner: nil)
        pb.setString(text, forType: .string)
        pb.setString("1", forType: concealedType)
        return pb.changeCount
    }

    /// Paste `text` at the cursor via a synthesized ⌘V. If an editable field is
    /// focused the previous clipboard is restored once the paste has consumed
    /// the transcript (unless a real user copy lands first); otherwise the
    /// transcript is left on the clipboard so it isn't lost. Returns what
    /// happened.
    @discardableResult
    static func paste(_ text: String, request: Request) -> PasteOutcome {
        perform(text, request: request, to: .general,
                focusedAcceptsText: focusedElementAcceptsText(),
                synthesizePaste: { synthesizeCommandV() },
                schedule: { delay, body in
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: body)
                })
    }

    /// All production clipboard writes, including copy-only recovery, go through
    /// an acquired request. Ownership transfers to the terminal restore callback.
    @discardableResult
    static func perform(_ text: String, request: Request, to pb: NSPasteboard,
                        focusedAcceptsText: Bool, copyOnly: Bool = false,
                        synthesizePaste: () -> Void,
                        schedule: @escaping (Double, @escaping () -> Void) -> Void) -> PasteOutcome {
        let lease = request.takeLease()
        if copyOnly || !request.targetIsCurrent() {
            stage(pb, text)
            lease.release()
            return .copiedToClipboard
        }
        return deliver(text, to: pb, focusedAcceptsText: focusedAcceptsText,
                       synthesizePaste: synthesizePaste, schedule: schedule,
                       completed: lease.release)
    }

    static func copy(_ text: String, request: Request) {
        _ = perform(text, request: request, to: .general, focusedAcceptsText: false,
                    copyOnly: true, synthesizePaste: {}, schedule: { _, _ in })
    }

    /// Lazily provides the transcript's string flavor and records whether it
    /// was ever read. This is not proof the target consumed the transcript;
    /// clipboard managers may resolve it too. It keys the bounded restore heuristic. Thread-safe:
    /// AppKit may resolve promises off the main thread.
    private final class TranscriptProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
        private let text: String
        private let lock = NSLock()
        private var read = false
        init(text: String) { self.text = text }
        var wasRead: Bool {
            lock.lock(); defer { lock.unlock() }
            return read
        }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                        provideDataForType type: NSPasteboard.PasteboardType) {
            lock.lock(); read = true; lock.unlock()
            item.setString(text, forType: type)
        }
    }

    /// Testable core: stages the text, runs the (injected) ⌘V, and decides the
    /// clipboard outcome. `schedule` is `(delay, body)` — invoked only when
    /// restoring is wanted; every restore is changeCount-guarded so a real
    /// user copy wins.
    @discardableResult
    static func deliver(_ text: String, to pb: NSPasteboard, focusedAcceptsText: Bool,
                        synthesizePaste: () -> Void,
                        schedule: @escaping (Double, @escaping () -> Void) -> Void,
                        completed: @escaping () -> Void = {}) -> PasteOutcome {
        guard focusedAcceptsText else {
            // No editable field — stage eagerly (nothing will restore, so the
            // data must not depend on this call's provider staying relevant)
            // and keep the (concealed) transcript on the clipboard so it's
            // recoverable rather than silently lost.
            stage(pb, text)
            synthesizePaste()
            // Even without a reliable AX focus signal the key event is queued.
            // Protect that payload through the existing maximum restore window.
            schedule(unreadRestoreDelay, completed)
            return .pasteUnverified
        }
        let saved = snapshot(pb)
        pb.clearContents()
        let item = NSPasteboardItem()
        let provider = TranscriptProvider(text: text)
        item.setDataProvider(provider, forTypes: [.string])
        item.setString("1", forType: concealedType)
        pb.writeObjects([item])
        let ourChange = pb.changeCount
        synthesizePaste()
        let restoreIfUnchanged = {
            defer { completed() }
            if !saved.isEmpty, pb.changeCount == ourChange {
                restore(saved, to: pb)
            }
        }
        schedule(restoreDelay) {
            if provider.wasRead {
                // A read was observed — retain the existing bounded heuristic.
                restoreIfUnchanged()
            } else {
                // No string read has been observed (possibly a busy target,
                // the #82 failure mode). Restoring now could
                // make its eventual paste insert the PRIOR clipboard, so hold
                // the transcript, then give the clipboard back regardless.
                schedule(unreadRestoreDelay - restoreDelay, restoreIfUnchanged)
            }
        }
        return .pasted
    }

    /// One clipboard item's full contents, keyed by flavor. A dictation must
    /// give back *whatever* was on the clipboard — an image, files, rich text —
    /// not just a plain string: saving only `string(forType: .string)` meant a
    /// copied screenshot was permanently replaced by the transcript, and a
    /// rich-text copy silently degraded to plain text.
    typealias ClipboardSnapshot = [[NSPasteboard.PasteboardType: Data]]

    /// Capture every item and flavor currently on `pb`. Reading resolves any
    /// lazily-promised flavors into memory — that's the point (the promising
    /// app may be gone by restore time) and clipboard items are small compared
    /// to the models this process already holds.
    static func snapshot(_ pb: NSPasteboard) -> ClipboardSnapshot {
        (pb.pasteboardItems ?? []).map { item in
            var flavors: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { flavors[type] = data }
            }
            return flavors
        }
        .filter { !$0.isEmpty }
    }

    /// Write a snapshot back. The restore path deliberately does not re-mark
    /// the user's original clipboard as concealed — it wasn't ours to conceal.
    static func restore(_ saved: ClipboardSnapshot, to pb: NSPasteboard) {
        pb.clearContents()
        pb.writeObjects(saved.map { flavors in
            let item = NSPasteboardItem()
            for (type, data) in flavors { item.setData(data, forType: type) }
            return item
        })
    }

    /// Synthesize ⌘V. Flags set explicitly to ⌘ alone so a still-held Fn (the PTT
    /// release races the paste) can't contaminate the synthetic chord.
    private static func synthesizeCommandV() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: src, virtualKey: keyV, keyDown: down)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Best-effort AX probe: does the system-wide focused element accept text
    /// (settable AXValue, or a text-field/area role)? Needs Accessibility; if the
    /// query fails (untrusted, or an app that doesn't report focus) it returns
    /// false and the caller falls back to leaving the text on the clipboard.
    static func focusedElementAcceptsText() -> Bool {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused else { return false }
        let element = focused as! AXUIElement

        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        var role: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
           let role = role as? String,
           role == (kAXTextFieldRole as String) || role == (kAXTextAreaRole as String) {
            return true
        }
        return false
    }
}
