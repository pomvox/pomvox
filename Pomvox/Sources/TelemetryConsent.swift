import SwiftUI

/// Observable wrapper over `TelemetryStore` for the Privacy-pane toggle. Sharing
/// is on by default; turning it off stops all sending immediately (the client
/// re-reads consent on every flush).
@MainActor
final class TelemetryModel: ObservableObject {
    @Published private(set) var consent: TelemetryConsent
    private var store: TelemetryStore

    init(store: TelemetryStore = TelemetryStore()) {
        self.store = store
        self.consent = store.consent
    }

    /// Privacy-pane toggle binding — on = granted, off = denied. Toggles either
    /// direction at any time.
    var binding: Binding<Bool> {
        Binding(get: { self.consent == .granted },
                set: { self.choose($0 ? .granted : .denied) })
    }

    /// The user's choice from the Privacy toggle.
    func choose(_ decision: TelemetryConsent) {
        guard decision != store.consent else { return }
        store.consent = decision
        consent = decision
        // Record the change only when granting (a denied→event would itself be a
        // send the user just declined; the gate blocks it anyway). Withdrawing
        // consent also drops whatever is still queued, on disk included — events
        // buffered while granted must not outlive the choice that allowed them.
        if decision == .granted {
            // arm() may have emitted app_launch while sharing was off. Replay
            // that one launch now; it was never queued, only remembered as a flag.
            Task { await TelemetryClient.shared.releaseSkippedAppLaunch() }
            TelemetryClient.shared.emit(.settingChanged)
        } else {
            Task { await TelemetryClient.shared.forget() }
        }
    }
}

/// The exact, plain-language "here's what we send" disclosure shown in the
/// Privacy pane.
enum TelemetryCopy {
    static let sends: [String] = [
        "A random install ID — anonymous, not tied to you or your Mac.",
        "App and macOS version, architecture.",
        "That a dictation happened: its duration, which models ran, whether "
            + "cleanup was used and how it finished.",
        "Error codes (a fixed list — never messages or stack traces).",
    ]

    static let neverSends: [String] = [
        "Your voice or any audio — ever.",
        "Any transcript or cleaned-up text — ever.",
        "No account, no name, no email, no file paths, no free text.",
    ]
}
