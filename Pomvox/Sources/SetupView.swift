import AppKit
import SwiftUI

/// The Setup pane (M7a) — port of the Python Setup Assistant's checklist, now
/// for Pomvox.app's own TCC grants. Three permission rows with a plain-language
/// *why*, live status polling (the documented failure mode of permission-heavy
/// mac apps is checking once at launch), System Settings deep links, the
/// stale-TCC hint, and a real insertion self-test (the silent-Accessibility
/// "paste does nothing" failure gets diagnosed here, not in the user's Slack).
///
/// Pure logic lives in OnboardingFlow (vector-parity tested); this view is the
/// dumb renderer. The 1 Hz poll exists only while this pane is on screen and
/// the app is active — three cheap probe calls, no footprint cost at rest.
struct SetupView: View {
    @EnvironmentObject var engine: NativeEngine
    @Environment(\.controlActiveState) private var activeState

    @State private var statuses: [String: Bool?] = [:]
    @State private var selfTestText = ""
    @FocusState private var testFieldFocused: Bool
    // One silent arm() per Setup visit, fired the tick the last grant lands —
    // closes the fresh-install gap where Fn stays dead after granting because
    // nothing re-arms until the menu-bar toggle or a relaunch (M3 report).
    @State private var autoArmAttempted = false

    private let flow = OnboardingFlow()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var rows: [OnboardingFlow.Row] {
        flow.rows(statuses: statuses, tapInstalled: engine.tapInstalled,
                  location: Permissions.appLocation())
    }
    private var complete: Bool {
        flow.complete(statuses: statuses, tapInstalled: engine.tapInstalled)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                permissionsCard
                heartbeatCard
                selfTestCard
            }
            .padding(28)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { refresh() }
        // Live re-check: returning from System Settings flips a row green
        // without a relaunch.
        .onReceive(tick) { _ in
            if activeState != .inactive { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in refresh() }
    }

    private func refresh() {
        statuses = Permissions.statuses()
        if flow.readyToAutoArm(statuses: statuses, engineArmed: engine.isArmed,
                               alreadyAttempted: autoArmAttempted) {
            autoArmAttempted = true
            NSLog("pomvox-engine: setup poll — grants landed, silent auto-arm")
            Task { await engine.arm(interactive: false) }
        }
    }

    // MARK: - sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(complete ? "You're set — try the self-test" : "Pomvox setup")
                .font(Typo.display(24)).foregroundStyle(Palette.ink)
            Text("Local dictation — your voice and words never leave this Mac.")
                .font(Typo.ui(13)).foregroundStyle(Palette.muted)
        }
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.key) { index, row in
                PermissionRow(row: row)
                if index < rows.count - 1 {
                    Divider().overlay(Palette.hair).padding(.leading, 16)
                }
            }
            Divider().overlay(Palette.hair)
            Text(OnboardingFlow.staleTccHint)
                .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
    }

    // Hotkey heartbeat: proves the dictation key physically reaches the app.
    // Green within 10 s of a press; the hint covers the two known silent
    // worlds (hardware Fn keys, missing relaunch after a grant).
    private var heartbeatCard: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let seen = engine.lastPttSeenAt.map {
                context.date.timeIntervalSince($0) < 10.0 } ?? false
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: seen ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(seen ? .green : Palette.muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(seen ? "Hotkey working — \(engine.pttDisplayName) reaches Pomvox"
                              : "Press \(engine.pttDisplayName) to test your dictation key")
                        .font(Typo.ui(13.5, .semibold)).foregroundStyle(Palette.ink)
                    if !seen {
                        Text("No key event? Some keyboards handle this key in hardware and never send it to macOS — pick a different key in Settings ▸ Hotkeys (turn the engine off and on to apply). Just granted Input Monitoring? Relaunch Pomvox.")
                            .font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
                    }
                }
                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(seen ? "Hotkey working, \(engine.pttDisplayName) reaches Pomvox"
                                     : "Press \(engine.pttDisplayName) to test your dictation key")
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
    }

    private var selfTestCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Self-test").font(Typo.ui(14, .semibold)).foregroundStyle(Palette.ink)
            Text("Click the button, then watch Pomvox type into this box — the same ⌘V path a dictation uses.")
                .font(Typo.ui(12)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                TextField("test text lands here", text: $selfTestText)
                    .textFieldStyle(.roundedBorder)
                    .focused($testFieldFocused)
                    .accessibilityLabel("Self-test field")
                Button("Test insertion") { runSelfTest() }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.pane))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
    }

    /// Make the field first responder, then fire once focus has settled — the
    /// synthesized ⌘V lands wherever focus is (onboarding.py's 0.6 s dance).
    private func runSelfTest() {
        selfTestText = ""
        testFieldFocused = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            _ = Paster.paste(OnboardingFlow.selfTestText)
        }
    }
}

private struct PermissionRow: View {
    let row: OnboardingFlow.Row

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusDot
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(Typo.ui(13.5, .semibold)).foregroundStyle(Palette.ink)
                Text(row.why).font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
                if !row.note.isEmpty {
                    Text(row.note).font(Typo.ui(11.5, .medium)).foregroundStyle(Palette.ember)
                }
            }
            Spacer(minLength: 12)
            Button("Grant…") { Permissions.request(row.key) }
                .disabled(row.granted == true)
                .accessibilityLabel("Grant \(row.title)")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title): \(statusText). \(row.why). \(row.note)")
    }

    private var statusDot: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(dotColor.opacity(0.3), lineWidth: 4).scaleEffect(1.5))
    }

    private var dotColor: Color {
        switch row.granted {
        case true: .green
        case false: Palette.ember
        case nil: Palette.muted
        default: Palette.muted
        }
    }

    private var statusText: String {
        switch row.granted {
        case true: "granted"
        case false: "not granted"
        default: "unknown"
        }
    }
}
