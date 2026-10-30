import SwiftUI

struct Sidebar: View {
    @Binding var selection: NavItem
    @EnvironmentObject var model: HubModel

    var body: some View {
        // Flag the Setup row while any engine grant is still missing, so the
        // checklist is discoverable even if the user has navigated to Home.
        let setupNeeded = !Permissions.allGranted()
        return VStack(alignment: .leading, spacing: 0) {
            // brand
            HStack(spacing: 9) {
                Waveform()
                Text("Pomvox").font(Typo.display(22)).foregroundStyle(Palette.ink)
            }
            .padding(.leading, 10).padding(.top, 6).padding(.bottom, 18)

            // nav
            VStack(spacing: 2) {
                ForEach(NavItem.allCases) { item in
                    NavRow(item: item, selected: selection == item,
                           attention: item == .setup && setupNeeded) { selection = item }
                }
            }

            Spacer(minLength: 12)

            StatusChip()
            PrivacyFooter()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

private struct NavRow: View {
    let item: NavItem
    let selected: Bool
    var attention: Bool = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: item.symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(item.title).font(Typo.ui(13.5, .medium))
                Spacer()
                if attention {
                    // Amber "action needed" dot — grants are still missing.
                    Circle().fill(Palette.ember).frame(width: 7, height: 7)
                        .accessibilityLabel("action needed")
                }
            }
            .foregroundStyle(selected ? Palette.ember : Palette.inkSoft)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Palette.sel : (hovering ? Palette.pane2 : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : [.isButton])
    }
}

/// The engine status card at the foot of the sidebar. A pure function of the
/// engine's published state (`StatusCardCopy`): it names the keys the engine
/// actually armed with, and only claims "Ready to dictate" while it is (#212).
private struct StatusChip: View {
    @EnvironmentObject var engine: NativeEngine

    var body: some View {
        let copy = StatusCardCopy.make(
            status: engine.status, speechLoad: engine.speechLoad,
            ptt: engine.pttDisplayName, toggle: engine.toggleDisplayName)
        HStack(spacing: 9) {
            Circle().fill(dot(copy.tone)).frame(width: 8, height: 8)
                .overlay(Circle().stroke(dot(copy.tone).opacity(0.35), lineWidth: 4).scaleEffect(1.6))
            VStack(alignment: .leading, spacing: 1) {
                Text(copy.title).font(Typo.ui(12, .semibold)).foregroundStyle(Palette.ink)
                Text(copy.detail).font(Typo.ui(11)).foregroundStyle(Palette.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.hair, lineWidth: 0.5))
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(copy.title). \(copy.detail)")
    }

    private func dot(_ tone: StatusCardCopy.Tone) -> Color {
        switch tone {
        case .live:      Color.green
        case .idle:      Palette.muted
        case .attention: Palette.ember
        }
    }
}

/// Copy for the sidebar status card, derived from the engine's published
/// state so the card can never promise a key the tap isn't listening for.
/// `ptt`/`toggle` are the engine's display-name mirrors (`pttDisplayName`,
/// `toggleDisplayName`), which `loadEngineConfig` sets from `[hotkey]` at
/// every arm — so the hotkey line is only shown while the engine is armed.
enum StatusCardCopy {
    enum Tone: Equatable { case live, idle, attention }

    struct Copy: Equatable {
        let title: String
        let detail: String
        let tone: Tone
    }

    /// "Hold <ptt> · or <toggle>" — the one line the card used to hard-code.
    static func hotkeyLine(ptt: String, toggle: String) -> String {
        "Hold \(ptt) · or \(toggle)"
    }

    static func make(status: NativeEngine.Status, speechLoad: String?,
                     ptt: String, toggle: String) -> Copy {
        // While the speech model loads it stands in for the status, as in the
        // menu bar: a live percentage beats "Preparing…".
        if let speechLoad {
            return Copy(title: speechLoad, detail: "Dictation starts when the model is ready.", tone: .idle)
        }
        let keys = hotkeyLine(ptt: ptt, toggle: toggle)
        return switch status {
        case .off:
            Copy(title: "Engine off", detail: "Turn it on in Settings or from the menu bar.", tone: .idle)
        case .preparing:
            Copy(title: "Preparing the speech model…",
                 detail: "Dictation starts when the model is ready.", tone: .idle)
        case .ready:        Copy(title: "Ready to dictate", detail: keys, tone: .live)
        case .recording:    Copy(title: "Recording…", detail: keys, tone: .live)
        case .transcribing: Copy(title: "Transcribing…", detail: keys, tone: .live)
        case .blocked:
            Copy(title: "Another engine is running",
                 detail: "Quit it, then turn the engine on again.", tone: .attention)
        case .failed:
            Copy(title: "Needs attention", detail: "Open Setup to see what's missing.", tone: .attention)
        }
    }
}

private struct PrivacyFooter: View {
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Palette.muted)
            Text("Everything stays on this Mac.").font(Typo.ui(11)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 6)
    }
}

/// The signature mark — a small live waveform that ties the Hub to the
/// dictation HUD. Five bars breathing on a staggered loop.
///
/// The loop freezes whenever the app isn't frontmost (`controlActiveState ==
/// .inactive`): a `repeatForever` animation otherwise keeps redrawing at the
/// display refresh rate even when backgrounded, which blows the "~0% CPU
/// backgrounded" footprint budget. Pausing it drops idle CPU to near zero.
struct Waveform: View {
    @Environment(\.controlActiveState) private var activeState
    @State private var animate = false
    private let heights: [CGFloat] = [7, 15, 20, 11, 6]

    private var running: Bool { activeState != .inactive }

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(heights.indices, id: \.self) { i in
                Capsule()
                    .fill(Palette.ember)
                    .frame(width: 2.5, height: heights[i])
                    .scaleEffect(y: animate ? 1 : 0.5, anchor: .center)
                    .animation(
                        animate
                            ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                .delay(Double(i) * 0.12)
                            : .default,   // settle once, no repeat, when paused
                        value: animate)
            }
        }
        .frame(height: 20)
        .onAppear { animate = running }
        .onChange(of: activeState) { _, _ in animate = running }
        .accessibilityHidden(true)
    }
}
