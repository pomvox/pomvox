import SwiftUI
import AppKit
import ApplicationServices

/// Re-inserting a past dictation means pasting into whatever app you were just
/// using — pasteboard + a synthesized ⌘V. That keystroke needs Accessibility,
/// and the ad-hoc-signed Hub usually doesn't have it (TCC grants live with the
/// Python engine until M7). So we check the grant and degrade honestly rather
/// than firing a paste that silently lands nowhere.
enum ReinsertMode: Equatable {
    case paste     // Accessibility granted — real countdown + synthesized ⌘V
    case copyOnly  // not granted — copy to clipboard, you paste it yourself

    static func decide(trusted: Bool) -> ReinsertMode { trusted ? .paste : .copyOnly }
}

@MainActor
final class ReinsertController: ObservableObject {
    /// What the History overlay is currently showing.
    enum Phase: Equatable {
        case idle
        case countdown(Int)   // seconds left before the synthesized paste
        case waiting(copyOnly: Bool) // clipboard owned by an earlier operation; cancellable
        case copied(needsAccessibility: Bool)  // no paste event posted
        case pasteUnverified                  // event posted; check before pasting again

        static func afterPaste(_ outcome: PasteOutcome) -> Phase {
            switch outcome {
            case .pasted: return .idle
            case .copiedToClipboard: return .copied(needsAccessibility: false)
            case .pasteUnverified: return .pasteUnverified
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let prepareRequest: @MainActor () async -> Paster.Request?
    private let copyText: @MainActor (String, Paster.Request) -> Void

    init(prepareRequest: @escaping @MainActor () async -> Paster.Request? = { await Paster.prepare() },
         copyText: @escaping @MainActor (String, Paster.Request) -> Void = { Paster.copy($0, request: $1) }) {
        self.prepareRequest = prepareRequest
        self.copyText = copyText
    }

    /// Re-insert `text`. Picks the real-paste or copy-only path by the live grant.
    func start(text: String) {
        start(text: text, mode: ReinsertMode.decide(trusted: AXIsProcessTrusted()))
    }

    /// Explicit mode plus injected copy/ownership keep UI lifecycle tests off
    /// the general clipboard and away from permission probes and real events.
    func start(text: String, mode: ReinsertMode) {
        switch mode {
        case .paste:    beginCountdown(text: text)
        case .copyOnly: copyOnly(text: text)
        }
    }

    /// Cancel an in-flight countdown / dismiss the fallback banner.
    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        phase = .idle
    }

    func openAccessibilitySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - paste path (granted)

    /// 3-2-1 so focus can leave the Hub and land in your target field — then the
    /// ⌘V posts to whatever is frontmost. Port of app.py:_reinsert + insert.py.
    private func beginCountdown(text: String) {
        cancel()
        let current = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for remaining in stride(from: 3, through: 1, by: -1) {
                self.phase = .countdown(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, self.generation == current else { return }
            }
            // Capture focus after the countdown, before waiting for ownership.
            self.phase = .waiting(copyOnly: false)
            guard let request = await self.prepareRequest() else { return }
            defer { request.cancelUnused() }
            guard !Task.isCancelled, self.generation == current else { return }
            let outcome = Paster.paste(text, request: request)
            self.phase = .afterPaste(outcome)
        }
    }

    // MARK: - copy-only path (not granted)

    private func copyOnly(text: String) {
        cancel()
        phase = .waiting(copyOnly: true)
        let current = generation
        task = Task { @MainActor [weak self] in
            guard let self, let request = await self.prepareRequest() else { return }
            defer { request.cancelUnused() }
            guard !Task.isCancelled, self.generation == current else { return }
            self.copyText(text, request)
            self.phase = .copied(needsAccessibility: true)
            // Auto-dismiss only this request's prompt; clipboard text stays.
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, self.generation == current { self.phase = .idle }
        }
    }
}
