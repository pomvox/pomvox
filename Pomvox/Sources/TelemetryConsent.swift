import SwiftUI

/// Observable wrapper over `TelemetryStore` for the Privacy-pane toggle and the
/// one-time Home disclosure banner. Sharing is on by default, but nothing sends
/// until the banner has rendered (the `maySend` gate); turning it off stops all
/// sending immediately (the client re-reads the gate on every flush).
@MainActor
final class TelemetryModel: ObservableObject {
    @Published private(set) var consent: TelemetryConsent
    /// The banner is owed at launch and stays up for this session after it has
    /// rendered, until dismissed. The persisted flag is what makes it one-time.
    @Published private(set) var showsDisclosureBanner: Bool
    private var store: TelemetryStore
    private let client: TelemetryClient

    init(store: TelemetryStore = TelemetryStore(), client: TelemetryClient = .shared) {
        self.store = store
        self.client = client
        self.consent = store.consent
        self.showsDisclosureBanner = store.needsDisclosure
    }

    /// The banner has actually rendered: persist the flag, which opens the
    /// `maySend` gate, then replay the `app_launch` that arm() emitted while the
    /// gate was shut. Called from the banner's `onAppear`, never earlier.
    func disclosureRendered() {
        guard !store.disclosed else { return }
        store.disclosed = true
        NSLog("pomvox-telemetry: disclosure banner rendered — sending enabled")
        Task { await client.releaseSkippedAppLaunch() }
    }

    func dismissDisclosure() { showsDisclosureBanner = false }

    /// Privacy-pane toggle binding — on = granted, off = denied. Toggles either
    /// direction at any time.
    var binding: Binding<Bool> {
        Binding(get: { self.consent == .granted },
                set: { self.choose($0 ? .granted : .denied) })
    }

    /// The user's choice from the Privacy toggle. Turning it on there counts as
    /// disclosure: the pane shows the full "what we send" list next to it.
    func choose(_ decision: TelemetryConsent) {
        guard decision != store.consent else { return }
        store.consent = decision
        consent = decision
        if decision == .granted { store.disclosed = true }
        showsDisclosureBanner = false
        // Record the change only when granting (a denied→event would itself be a
        // send the user just declined; the gate blocks it anyway). Withdrawing
        // consent also drops whatever is still queued, on disk included — events
        // buffered while granted must not outlive the choice that allowed them.
        if decision == .granted {
            // arm() may have emitted app_launch while sharing was off. Replay
            // that one launch now; it was never queued, only remembered as a flag.
            Task { await client.releaseSkippedAppLaunch() }
            client.emit(.settingChanged)
        } else {
            Task { await client.forget() }
        }
    }
}

/// The exact, plain-language "here's what we send" disclosure shown in the
/// Privacy pane.
enum TelemetryCopy {
    static let banner =
        "Pomvox sends anonymous usage stats. Nothing you say. Turn off in Settings → Privacy."

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

/// The one-time disclosure on Home, in the `UpdateBanner` pattern: quiet,
/// non-blocking, no equal-weight choice. Rendering it is what opens the send
/// gate, so it must appear before anything flushes.
struct TelemetryDisclosureBanner: View {
    @EnvironmentObject var telemetry: TelemetryModel
    var openPrivacy: () -> Void = {}

    var body: some View {
        if telemetry.showsDisclosureBanner {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.system(size: 17)).foregroundStyle(Palette.ember)
                Text(TelemetryCopy.banner)
                    .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                HStack(spacing: 10) {
                    Button("Got it") { telemetry.dismissDisclosure() }
                        .buttonStyle(.plain)
                        .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
                    Button {
                        telemetry.dismissDisclosure()
                        openPrivacy()
                    } label: {
                        Text("Privacy settings")
                            .font(Typo.ui(12.5, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Palette.ember))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
            .onAppear { telemetry.disclosureRendered() }
        }
    }
}
