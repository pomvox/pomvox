import SwiftUI

/// Observable wrapper over `TelemetryStore` for the consent UI — the first-run
/// choice screen and the Privacy-pane toggle both drive this, so they always
/// agree. Honest by construction: nothing sends until the user explicitly picks
/// "Share" (the `maySend` gate, `.granted`); the choice is honored, and denying
/// stops all sending immediately (the client re-reads consent on every flush).
@MainActor
final class TelemetryModel: ObservableObject {
    @Published private(set) var consent: TelemetryConsent
    private var store: TelemetryStore

    init(store: TelemetryStore = TelemetryStore()) {
        self.store = store
        self.consent = store.consent
    }

    /// The first-run choice screen is owed until the user has decided.
    var needsConsentPrompt: Bool { consent == .undecided }

    /// Privacy-pane toggle binding — on = granted, off = denied. Toggles either
    /// direction at any time.
    var binding: Binding<Bool> {
        Binding(get: { self.consent == .granted },
                set: { self.choose($0 ? .granted : .denied) })
    }

    /// The user's explicit choice — from the first-run screen's two buttons or
    /// the Privacy toggle. Nothing sends until this is `.granted`.
    func choose(_ decision: TelemetryConsent) {
        guard decision != store.consent else { return }
        store.consent = decision
        consent = decision
        // Record the change only when granting (a denied→event would itself be a
        // send the user just declined; the gate blocks it anyway). Withdrawing
        // consent also drops whatever is still queued, on disk included — events
        // buffered while granted must not outlive the choice that allowed them.
        if decision == .granted {
            TelemetryClient.shared.emit(.settingChanged)
        } else {
            Task { await TelemetryClient.shared.forget() }
        }
    }
}

/// The exact, plain-language "here's what we send" disclosure — shared by the
/// first-run choice screen and the Privacy pane so the two can never drift apart.
enum TelemetryCopy {
    static let headline = "Share anonymous usage stats?"
    static let blurb =
        "Pomvox can send anonymous usage events so the maintainer can see how it's "
        + "used and what's breaking — never your audio, your transcribed text, or "
        + "anything identifying. Your choice, changeable anytime in Settings → Privacy."

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

    static let footer = "Your choice — change it anytime in Settings → Privacy."
}

/// First-run choice screen. No pre-selected default and no dark pattern: "No
/// thanks" and "Share anonymous stats" are visually identical buttons — neither
/// is styled as the primary/destructive path. Nothing sends until one is pressed;
/// dismissing without choosing leaves the choice `.undecided` (re-asked next time).
struct TelemetryConsentSheet: View {
    @EnvironmentObject var telemetry: TelemetryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.bar.doc.horizontal")
                        .font(.system(size: 20)).foregroundStyle(Palette.ember)
                    Text(TelemetryCopy.headline)
                        .font(Typo.display(22)).foregroundStyle(Palette.ink)
                }
                Text(TelemetryCopy.blurb)
                    .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 16) {
                disclosure(title: "What it sends", symbol: "checkmark.circle.fill",
                           tint: Palette.muted, lines: TelemetryCopy.sends)
                disclosure(title: "What it never sends", symbol: "lock.fill",
                           tint: Palette.ember, lines: TelemetryCopy.neverSends)
            }

            Text(TelemetryCopy.footer)
                .font(Typo.ui(11.5)).foregroundStyle(Palette.muted)

            // Equal-weight choice: same style, no pre-selected/primary button.
            HStack(spacing: 12) {
                Spacer()
                choiceButton("No thanks") { answer(.denied) }
                choiceButton("Share anonymous stats") { answer(.granted) }
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Palette.pane)
        .interactiveDismissDisabled()   // the choice must be made explicitly
    }

    /// Both buttons share this style so neither reads as the default/primary path.
    private func choiceButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            .padding(.horizontal, 18).padding(.vertical, 8)
            .background(Capsule().fill(Palette.pane2))
            .overlay(Capsule().stroke(Palette.hair, lineWidth: 0.5))
    }

    private func disclosure(title: String, symbol: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Typo.ui(10.5, .semibold)).tracking(0.5).foregroundStyle(Palette.muted)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
                        .padding(.top, 2)
                    Text(line).font(Typo.ui(11.5)).foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hair, lineWidth: 0.5))
    }

    private func answer(_ decision: TelemetryConsent) {
        telemetry.choose(decision)
        dismiss()
    }
}
