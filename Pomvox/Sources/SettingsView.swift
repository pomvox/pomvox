import SwiftUI

/// The Settings surface (M2b). Five panes behind a pill tab row — General,
/// Models, Hotkeys, Voice, Privacy (decision #6) — editing `config.toml`
/// through `SettingsModel`. Saves are a comment-preserving, only-changed-keys
/// write; the Python engine's watcher applies them within ~1 s.
struct SettingsView: View {
    @EnvironmentObject var model: SettingsModel
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Settings") { saveControls }
            tabBar
            if model.isDirty && !model.pendingRestart.isEmpty { restartBanner }
            ScrollView {
                pane
                    .frame(maxWidth: 660, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 34).padding(.top, 24).padding(.bottom, 44)
            }
        }
    }

    @ViewBuilder private var pane: some View {
        switch tab {
        case .general: GeneralPane()
        case .models:  ModelsPane()
        case .hotkeys: HotkeysPane()
        case .voice:   VoicePane()
        case .privacy: PrivacyPane()
        }
    }

    private var saveControls: some View {
        HStack(spacing: 12) {
            if model.justSaved && !model.isDirty {
                Label("Saved", systemImage: "checkmark.circle.fill")
                    .font(Typo.ui(12, .medium)).foregroundStyle(Palette.gold)
            } else if model.isDirty {
                Text("Applies live").font(Typo.ui(12)).foregroundStyle(Palette.muted)
            }
            if model.isDirty {
                Button("Revert") { model.revert() }
                    .buttonStyle(.plain).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
            }
            Button(action: { model.save() }) {
                Text("Save").font(Typo.ui(13, .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                    .background(Capsule().fill(model.isDirty ? Palette.ember : Palette.muted.opacity(0.4)))
            }
            .buttonStyle(.plain).disabled(!model.isDirty)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(SettingsTab.allCases) { t in
                SettingsPill(tab: t, selected: tab == t) { tab = t }
            }
            Spacer()
        }
        .padding(.horizontal, 30).padding(.vertical, 12)
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
    }

    private var restartBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 12)).foregroundStyle(Palette.gold)
            Text("Saving applies most changes live; these take effect after a Pomvox restart: \(model.pendingRestart.joined(separator: ", ")).")
                .font(Typo.ui(12)).foregroundStyle(Palette.inkSoft)
            Spacer()
        }
        .padding(.horizontal, 30).padding(.vertical, 10)
        .background(Palette.gold.opacity(0.12))
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, hotkeys, voice, privacy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"; case .models: "cpu"
        case .hotkeys: "keyboard"; case .voice: "waveform"; case .privacy: "lock.shield"
        }
    }
}

private struct SettingsPill: View {
    let tab: SettingsTab
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tab.symbol).font(.system(size: 11.5))
                Text(tab.title).font(Typo.ui(12.5, .medium))
            }
            .foregroundStyle(selected ? .white : Palette.inkSoft)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(selected ? Palette.ember : (hovering ? Palette.pane2 : .clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
    }
}

// MARK: - Panes

private struct GeneralPane: View {
    @EnvironmentObject var model: SettingsModel
    @EnvironmentObject var engine: NativeEngine
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NativeEngineGroup()
            LoginItemGroup()
            SettingsGroup("Cleanup") {
                SettingRow(title: "Clean up transcripts",
                           desc: "Run the local LLM pass after speech-to-text.") {
                    SettingToggle(isOn: $model.values.cleanupEnabled, label: "Clean up transcripts")
                }
                RowDivider()
                SettingRow(title: "Style") {
                    SegmentControl(options: [("light", "Light"), ("polish", "Polish")],
                                   selection: $model.values.cleanupStyle,
                                   accessibilityLabel: "Cleanup style")
                }
                RowDivider()
                SettingRow(title: "Cleanup timeout",
                           desc: "On timeout the raw transcript is inserted instead.") {
                    SliderControl(value: $model.values.cleanupTimeoutS, range: 1...15, step: 0.5,
                                  label: "Cleanup timeout") {
                        String(format: "%.1f s", $0)
                    }
                }
            }
            SettingsGroup("On-screen HUD") {
                SettingRow(title: "Show HUD") {
                    SettingToggle(isOn: $model.values.hudEnabled, label: "Show HUD")
                }
                RowDivider()
                SettingRow(title: "Show live draft",
                           desc: "Off keeps live text out of screen shares.") {
                    SettingToggle(isOn: $model.values.hudShowDraft, label: "Show live draft")
                }
                RowDivider()
                SettingRow(title: "Position") {
                    SegmentControl(options: [("bottom-center", "Bottom"), ("top-center", "Top"), ("notch", "Notch")],
                                   selection: $model.values.hudPosition,
                                   accessibilityLabel: "HUD position")
                }
                RowDivider()
                SettingRow(title: "Sounds",
                           desc: "Start/stop cues for eyes-off dictation.") {
                    SettingToggle(isOn: $model.values.hudSounds, label: "Sounds")
                }
            }
            if UpdaterModel.isEnabled {
                UpdatesGroup()
            }
        }
    }
}

/// The native dictation engine toggle (M4). A live engine control, not a
/// batched setting — flipping it arms/disarms the CGEventTap + mic + STT and
/// persists `[engine] native` itself, so it sits outside the Save flow.
private struct NativeEngineGroup: View {
    @EnvironmentObject var engine: NativeEngine

    private var binding: Binding<Bool> {
        Binding(
            get: { engine.isArmed },
            set: { on in
                if on { Task { await engine.arm() } } else { engine.disarm() }
            })
    }

    var body: some View {
        SettingsGroup("Native engine (beta)") {
            SettingRow(
                title: "Use the native engine",
                desc: "On by default. Hold Fn, speak, release — the transcript pastes on-device; with cleanup enabled the polished text pastes (raw on timeout). The Python engine stays your daily driver."
            ) {
                SettingToggle(isOn: binding, label: "Use the native engine")
            }
            RowDivider()
            statusRow
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol).font(.system(size: 12)).foregroundStyle(statusColor)
                    .frame(width: 18)
                Text(statusText).font(Typo.ui(12.5)).foregroundStyle(Palette.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let ms = engine.lastPasteMs {
                    Text(String(format: "last paste %.0f ms", ms))
                        .font(Typo.ui(11.5, .medium)).monospacedDigit().foregroundStyle(Palette.muted)
                }
            }
            // The polish model finishes downloading in the background after the
            // engine is already usable — surfaced so raw-only early dictations
            // read as expected, not broken.
            if let polishLoad = engine.polishLoad {
                Text(polishLoad)
                    .font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
                    .padding(.leading, 26)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Engine status: \(statusText)")
    }

    private var statusText: String {
        if let speechLoad = engine.speechLoad { return speechLoad }
        return switch engine.status {
        case .off:               "Off — the Python engine is your daily driver."
        case .preparing:         "Preparing the speech model… (first run downloads it)."
        case .ready:             "Ready — hold Fn, speak, then release."
        case .recording:         "Recording… release Fn to transcribe."
        case .transcribing:      "Transcribing on the Neural Engine…"
        case let .blocked(msg):  msg
        case let .failed(msg):   msg
        }
    }

    private var statusSymbol: String {
        switch engine.status {
        case .off:          "moon.zzz"
        case .preparing:    "arrow.down.circle"
        case .ready:        "checkmark.circle.fill"
        case .recording:    "mic.fill"
        case .transcribing: "waveform"
        case .blocked:      "exclamationmark.triangle.fill"
        case .failed:       "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch engine.status {
        case .ready, .recording:  Palette.ember
        case .blocked:            Palette.gold
        case .failed:             Palette.ember
        default:                  Palette.muted
        }
    }
}

/// Launch-at-login (M7a). SMAppService is the source of truth — no config key,
/// no Save flow; the toggle registers/unregisters directly.
private struct LoginItemGroup: View {
    @StateObject private var loginItem = LoginItemModel()

    var body: some View {
        SettingsGroup("App") {
            SettingRow(
                title: "Launch at login",
                desc: "Pomvox starts in the menu bar — armed and ready to dictate, no window."
            ) {
                SettingToggle(isOn: loginItem.binding, label: "Launch at login")
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)
        ) { _ in loginItem.refresh() }  // System Settings can revoke it behind us
    }
}

// MARK: - updates (M8)

private struct UpdatesGroup: View {
    @EnvironmentObject var updater: UpdaterModel

    var body: some View {
        SettingsGroup("Updates") {
            SettingRow(title: "Automatically check for updates",
                       desc: "Once a day, Pomvox fetches a public version file from GitHub. "
                           + "Nothing about you or your dictations is sent.") {
                SettingToggle(isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }))
            }
            RowDivider()
            SettingRow(title: "Check for updates",
                       desc: UpdaterModel.lastCheckedLabel(updater.lastCheckDate)) {
                Button("Check Now") { updater.checkNow() }
                    .disabled(updater.state == .checking || updater.state.showsBanner)
            }
            if let status = statusLine {
                RowDivider()
                InfoRow(symbol: statusSymbol, text: status)
            }
            if case .error = updater.state {
                // Spec error contract: a failed/unverifiable update always
                // leaves a manual path open.
                RowDivider()
                SettingRow(title: "Download manually",
                           desc: "Get the latest release from GitHub.") {
                    Link("Releases", destination:
                        URL(string: "https://github.com/abhiram304/pomvox/releases")!)
                }
            }
            RowDivider()
            InfoRow(symbol: "app.badge", text: Bundle.main.pomvoxVersionLabel)
        }
    }

    /// Inline feedback for a manual check — never a popup.
    private var statusLine: String? {
        switch updater.state {
        case .checking:            "Checking…"
        case .upToDate:            "You're up to date."
        case let .error(message):  message
        default:                   nil
        }
    }

    private var statusSymbol: String {
        if case .error = updater.state { "exclamationmark.triangle.fill" }
        else { "checkmark.circle" }
    }
}

extension Bundle {
    /// "Pomvox 0.2.0 (9)" — marketing version + monotonic build.
    var pomvoxVersionLabel: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "Pomvox \(v) (\(b))"
    }
}

private struct ModelsPane: View {
    @EnvironmentObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Speech-to-text") {
                SettingRow(title: "Model", restart: true) {
                    ModelField(presets: SettingsSchema.sttModelPresets,
                               value: $model.values.sttModel, error: model.errors["stt.model"])
                }
            }
            PaneNote("The native engine runs Parakeet v2 (English, the default) or v3 (multilingual) on the Neural Engine; any other id falls back to v2.")
            SettingsGroup("Cleanup model") {
                SettingRow(title: "Model", restart: true) {
                    ModelField(presets: SettingsSchema.cleanupModelPresets,
                               value: $model.values.cleanupModel, error: model.errors["cleanup.model"])
                }
            }
            PaneNote("Any Hugging Face MLX model id works for cleanup — the dropdown is just suggestions. Models download on first use and stay local.")
        }
    }
}

private struct HotkeysPane: View {
    @EnvironmentObject var model: SettingsModel

    private var choice: HotkeyChoice {
        HotkeyChoice(ptt: model.values.ptt, toggle: model.values.toggle,
                     stop: model.values.stop, cancel: model.values.cancel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Push to talk") {
                SettingRow(title: "Hold to talk", restart: true) {
                    KeyPicker(presets: SettingsSchema.pttPresets, selection: $model.values.ptt)
                }
            }
            SettingsGroup("Hands-free") {
                SettingRow(title: "Toggle hands-free", restart: true) {
                    KeyPicker(presets: SettingsSchema.togglePresets, selection: $model.values.toggle)
                }
                RowDivider()
                SettingRow(title: "Extra stop key",
                           desc: "A push-to-talk tap or the toggle combo always stop too.",
                           restart: true) {
                    KeyPicker(presets: SettingsSchema.stopPresets, selection: $model.values.stop)
                }
            }
            SettingsGroup("Cancel") {
                SettingRow(title: "Discard while recording", restart: true) {
                    KeyPicker(presets: SettingsSchema.cancelPresets, selection: $model.values.cancel)
                }
            }
            SettingsGroup("Quick add") {
                SettingRow(title: "Quick-add to Dictionary",
                           desc: "e.g. cmd+shift+d — leave empty to disable. Needs at least one modifier.",
                           restart: true) {
                    QuickAddHotkeyField(value: $model.values.quickAdd)
                }
            }
            let conflicts = SettingsSchema.hotkeyConflicts(choice)
            if !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(conflicts, id: \.self) { c in
                        HStack(alignment: .top, spacing: 7) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11)).foregroundStyle(Palette.gold)
                            Text(c).font(Typo.ui(12)).foregroundStyle(Palette.inkSoft)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.gold.opacity(0.1)))
            }
        }
    }
}

private struct VoicePane: View {
    @EnvironmentObject var model: SettingsModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("Hands-free auto-stop") {
                SettingRow(title: "Auto-stop on a pause",
                           desc: "End the utterance after a natural silence.") {
                    SettingToggle(isOn: $model.values.vadEnabled, label: "Auto-stop on a pause")
                }
                RowDivider()
                SettingRow(title: "Silence to end") {
                    SliderControl(value: Binding(
                        get: { Double(model.values.vadSilenceMs) },
                        set: { model.values.vadSilenceMs = Int($0) }),
                        range: 400...4000, step: 100,
                        label: "Silence to end") { String(format: "%.0f ms", $0) }
                }
                RowDivider()
                SettingRow(title: "Aggressiveness",
                           desc: "Higher is stricter about ignoring non-speech.") {
                    SegmentControl(options: (0...3).map { ("\($0)", "\($0)") },
                                   selection: Binding(
                                    get: { "\(model.values.vadAggressiveness)" },
                                    set: { model.values.vadAggressiveness = Int($0) ?? 2 }),
                                   accessibilityLabel: "Voice detection aggressiveness")
                }
            }
            SettingsGroup("Microphone") {
                SettingRow(title: "Input device",
                           desc: "Wrong mic is the #1 cause of \"it doesn't work\".",
                           restart: true) {
                    DevicePicker(devices: model.inputDevices, selection: $model.values.audioDevice)
                }
            }
        }
    }
}

private struct PrivacyPane: View {
    @EnvironmentObject var model: SettingsModel
    @EnvironmentObject var hub: HubModel
    @EnvironmentObject var telemetry: TelemetryModel
    @State private var storage: [StorageItem] = []
    @State private var confirmingWipe = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroup("History") {
                SettingRow(title: "Keep history",
                           desc: "Transcripts only — audio is never stored.") {
                    SettingToggle(isOn: $model.values.historyEnabled, label: "Keep history")
                }
                RowDivider()
                SettingRow(title: "Keep for",
                           desc: "0 days keeps nothing — history clears on the next dictation.") {
                    SliderControl(value: Binding(
                        get: { Double(model.values.retentionDays) },
                        set: { model.values.retentionDays = Int($0) }),
                        range: 0...90, step: 1, label: "Keep history for") {
                            $0 == 0 ? "Off" : String(format: "%.0f days", $0)
                        }
                }
            }
            SettingsGroup("Stored on this Mac") {
                ForEach(Array(storage.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { RowDivider() }
                    StorageRow(item: item)
                }
            }
            SettingsGroup("Erase") {
                SettingRow(title: "Erase all history",
                           desc: "Deletes every dictation and shrinks the file on disk. Settings and downloaded models are left alone.") {
                    Button(role: .destructive) { confirmingWipe = true } label: {
                        Text("Erase…").font(Typo.ui(12.5, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(Capsule().fill(Palette.ember))
                    }
                    .buttonStyle(.plain)
                    .disabled(hub.rows.isEmpty)
                    .accessibilityLabel("Erase all dictation history")
                    .confirmationDialog("Erase all dictation history?",
                                        isPresented: $confirmingWipe, titleVisibility: .visible) {
                        Button("Erase All History", role: .destructive) {
                            hub.wipe(); storage = StorageInspector.scan()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Every transcript on this Mac is removed. This can't be undone.")
                    }
                }
            }
            SettingsGroup("Anonymous usage stats") {
                SettingRow(title: "Send anonymous usage stats",
                           desc: "Your choice, set on first launch. Anonymous usage events only — your voice and transcripts never leave this Mac. Toggle it either way, anytime.") {
                    SettingToggle(isOn: telemetry.binding, label: "Send anonymous usage stats")
                }
                RowDivider()
                UsageStatsDisclosure()
            }
            SettingsGroup("Verifiably local") {
                InfoRow(symbol: "lock.fill",
                        text: "No account, no cloud. Your voice and transcripts never leave this Mac.")
                RowDivider()
                InfoRow(symbol: "antenna.radiowaves.left.and.right.slash",
                        text: "The only network calls are the one-time model download and — when you turn the toggle above on — anonymous, content-free usage stats. Verify with Little Snitch or LuLu.")
            }
        }
        .onAppear { storage = StorageInspector.scan() }
    }
}

/// The "here's exactly what we send" disclosure, shown beneath the toggle so the
/// choice is informed. Copy is shared with the first-run screen (`TelemetryCopy`).
private struct UsageStatsDisclosure: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            column(title: "What it sends", symbol: "checkmark.circle.fill",
                   tint: Palette.muted, lines: TelemetryCopy.sends)
            column(title: "What it never sends", symbol: "lock.fill",
                   tint: Palette.ember, lines: TelemetryCopy.neverSends)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(title: String, symbol: String, tint: Color, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
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
    }
}

/// One artifact in the Privacy pane: label, real path, on-disk size, detail.
private struct StorageRow: View {
    let item: StorageItem
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label).font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
                Text(item.displayPath).font(Typo.ui(11.5)).monospaced().foregroundStyle(Palette.muted)
                Text(item.detail).font(Typo.ui(12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(item.sizeText).font(Typo.ui(12.5, .medium)).monospacedDigit()
                .foregroundStyle(Palette.inkSoft)
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(item.sizeText), at \(item.displayPath)")
    }
}

// MARK: - Reusable rows / controls

private struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(Typo.ui(11, .semibold)).tracking(0.5).foregroundStyle(Palette.muted)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 12).fill(Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.hair, lineWidth: 0.5))
        }
        .padding(.bottom, 24)
    }
}

private struct SettingRow<Control: View>: View {
    let title: String
    var desc: String? = nil
    var restart: Bool = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(title).font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
                    if restart { RestartTag() }
                }
                if let desc {
                    Text(desc).font(Typo.ui(12)).foregroundStyle(Palette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
    }
}

private struct RowDivider: View {
    var body: some View { Divider().overlay(Palette.hair).padding(.leading, 16) }
}

private struct RestartTag: View {
    var body: some View {
        Text("RESTART").font(Typo.ui(8.5, .semibold)).tracking(0.5).foregroundStyle(Palette.gold)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Palette.gold.opacity(0.14)))
    }
}

private struct InfoRow: View {
    let symbol: String
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 18)
            Text(text).font(Typo.ui(12.5)).foregroundStyle(Palette.inkSoft)
            Spacer()
        }
        .padding(.vertical, 11).padding(.horizontal, 16)
    }
}

private struct PaneNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typo.ui(12)).foregroundStyle(Palette.muted)
            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
    }
}

private struct SettingToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(Palette.ember)
            .accessibilityLabel(label)
    }
}

/// A segmented picker. Each option is a real `Button` (keyboard-focusable, with
/// the `.isSelected` trait) — not a tap-gesture on a `Text`, which VoiceOver and
/// the keyboard can't reach.
private struct SegmentControl: View {
    let options: [(value: String, label: String)]
    @Binding var selection: String
    var accessibilityLabel: String = ""
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { opt in
                let sel = selection == opt.value
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(Typo.ui(12.5, sel ? .semibold : .regular))
                        .foregroundStyle(sel ? Color.white : Palette.inkSoft)
                        .padding(.horizontal, 13).padding(.vertical, 5)
                        .background(sel ? Palette.ember : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(sel ? [.isSelected] : [])
            }
        }
        .background(Palette.pane2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct SliderControl: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var label: String = ""
    let format: (Double) -> String
    var body: some View {
        HStack(spacing: 12) {
            Slider(value: $value, in: range, step: step).frame(width: 190).tint(Palette.ember)
                .accessibilityLabel(label)
                .accessibilityValue(format(value))
            Text(format(value)).font(Typo.ui(12.5, .medium)).monospacedDigit()
                .foregroundStyle(Palette.ink).frame(width: 72, alignment: .trailing)
                .accessibilityHidden(true)
        }
    }
}

private struct KeyPicker: View {
    let presets: [String]
    @Binding var selection: String
    var body: some View {
        // Keep any non-preset value the file already had, so we never lose it.
        let options = presets.contains(selection) ? presets : [selection] + presets
        Menu {
            ForEach(options, id: \.self) { p in
                Button(SettingsSchema.keyLabel(p)) { selection = p }
            }
        } label: {
            HStack(spacing: 6) {
                Text(SettingsSchema.keyLabel(selection)).font(Typo.ui(12.5, .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct DevicePicker: View {
    let devices: [String]
    @Binding var selection: String  // "" = system default
    var body: some View {
        let label = selection.isEmpty ? "System Default" : selection
        let missing = !selection.isEmpty && !devices.contains(selection)
        Menu {
            Button("System Default") { selection = "" }
            if !devices.isEmpty { Divider() }
            ForEach(devices, id: \.self) { d in Button(d) { selection = d } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "mic").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
                Text(label).font(Typo.ui(12.5, .medium)).foregroundStyle(missing ? Palette.gold : Palette.ink)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Palette.inkSoft)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct ModelField: View {
    let presets: [String]
    @Binding var value: String
    let error: String?
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            HStack(spacing: 6) {
                TextField("model id", text: $value)
                    .textFieldStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
                    .frame(width: 250)
                    .padding(.horizontal, 9).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
                    .overlay(RoundedRectangle(cornerRadius: 7)
                        .stroke(error == nil ? Palette.hair : Palette.ember, lineWidth: error == nil ? 0.5 : 1))
                Menu {
                    ForEach(presets, id: \.self) { p in Button(p) { value = p } }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10)).foregroundStyle(Palette.inkSoft)
                        .frame(width: 28, height: 30)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            }
            if let error {
                Text(error).font(Typo.ui(11)).foregroundStyle(Palette.ember)
            }
        }
    }
}

/// Free-text chord field for `[hotkey] quick_add` — no preset menu (unlike
/// the other hotkey rows) since any modifier+key combo is valid. Mirrors
/// ModelField's text-field-plus-inline-error idiom; validity is judged with
/// the same parser QuickAddController uses, so what's shown as invalid here
/// is exactly what would be silently disabled at launch.
private struct QuickAddHotkeyField: View {
    @Binding var value: String
    private var error: String? {
        guard !value.isEmpty, QuickAddHotkey.parse(value) == nil else { return nil }
        return "Needs at least one modifier (e.g. cmd+shift+d)."
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            TextField("cmd+shift+d", text: $value)
                .textFieldStyle(.plain).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
                .frame(width: 160)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.pane2))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(error == nil ? Palette.hair : Palette.ember, lineWidth: error == nil ? 0.5 : 1))
            if let error {
                Text(error).font(Typo.ui(11)).foregroundStyle(Palette.ember)
            }
        }
    }
}
