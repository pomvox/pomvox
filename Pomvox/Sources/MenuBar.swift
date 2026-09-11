import AppKit
import ServiceManagement
import SwiftUI

/// The status item (M7a): Pomvox's resident face once the Hub window closes.
/// `.menu` style — a static menu, no timers, no run-loop cost; the icon is
/// driven purely by the engine's @Published status.
struct MenuBarIcon: View {
    let status: NativeEngine.Status

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("Pomvox — \(shortStatus)")
    }

    private var symbol: String {
        switch status {
        case .recording, .transcribing: "mic.fill"
        case .blocked, .failed:         "waveform.badge.exclamationmark"
        default:                        "waveform"
        }
    }

    private var shortStatus: String {
        switch status {
        case .off:          "engine off"
        case .preparing:    "preparing"
        case .ready:        "ready"
        case .recording:    "recording"
        case .transcribing: "transcribing"
        case .blocked:      "blocked"
        case .failed:       "needs attention"
        }
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var engine: NativeEngine
    @EnvironmentObject var evalCapture: EvalCaptureModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)
        // Eval capture is opt-in and writes every dictation to disk: while
        // it's on, say so somewhere the user sees between dictations.
        if evalCapture.isOn {
            Label("Saving transcription pairs for evaluation", systemImage: "doc.text.magnifyingglass")
                .accessibilityLabel("Saving transcription pairs for evaluation — on")
        }
        // The background polish-model fetch: a note so the first raw-only
        // dictations don't look like cleanup is broken.
        if let polishLoad = engine.polishLoad {
            Text(polishLoad)
        }
        Button("Open Hub…") { openHub() }
        if setupNeeded {
            Button(setupButtonLabel) {
                openHub()
                NotificationCenter.default.post(name: .pomvoxShowSetup, object: nil)
            }
        }
        Divider()
        Toggle("Use the native engine", isOn: engineBinding)
        Divider()
        Button("Quit Pomvox") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Same live-control semantics as the Settings toggle (user-initiated, so
    /// the interactive arm path with its permission prompt is right here).
    private var engineBinding: Binding<Bool> {
        Binding(
            get: { engine.isArmed },
            set: { on in
                if on { Task { await engine.arm() } } else { engine.disarm() }
            })
    }

    private func openHub() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: HubWindow.id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var engineNeedsAttention: Bool {
        switch engine.status {
        case .blocked, .failed: true
        default: false
        }
    }

    /// Show a setup entry while any grant is missing (fresh install) or the
    /// engine is reporting a problem it routes to Setup.
    private var setupNeeded: Bool {
        SetupNudge.needed(
            engineNeedsAttention: engineNeedsAttention,
            allPermissionsGranted: Permissions.allGranted())
    }

    /// A first-run user needs the stronger nudge; an already-set-up user hitting
    /// an engine error just needs the door.
    private var setupButtonLabel: String {
        Permissions.allGranted() ? "Open Setup…" : "Finish setup — grant permissions…"
    }

    private var statusLine: String {
        // While the speech model loads it stands in for the status — it's the
        // one thing gating dictation, and a live percentage beats "Preparing…".
        if let speechLoad = engine.speechLoad { return speechLoad }
        return switch engine.status {
        case .off:          "Engine off"
        case .preparing:    "Preparing the speech model…"
        case .ready:        "Ready — hold Fn to dictate"
        case .recording:    "Recording…"
        case .transcribing: "Transcribing…"
        case .blocked:      "Blocked — another engine is running"
        case .failed:       "Needs attention — open Setup"
        }
    }
}

extension Notification.Name {
    /// Deep link from the menu bar into the Hub's Setup pane.
    static let pomvoxShowSetup = Notification.Name("app.pomvox.showSetup")
}

/// Launch-at-login via SMAppService — the service's status is the source of
/// truth (no config key). Registration follows the app's code identity, so it
/// must be exercised from the stable `~/Applications` copy, not DerivedData.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var enabled = SMAppService.mainApp.status == .enabled

    var binding: Binding<Bool> {
        Binding(get: { self.enabled }, set: { self.set($0) })
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("login-item: %@ failed: %@",
                  on ? "register" : "unregister", String(describing: error))
        }
        refresh()
    }

    func refresh() {
        enabled = SMAppService.mainApp.status == .enabled
    }
}
