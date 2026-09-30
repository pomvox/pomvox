import SwiftUI

enum NavItem: String, CaseIterable, Identifiable {
    case home, history, dictionary, settings, setup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Home"; case .history: "History"
        case .dictionary: "Dictionary"
        case .settings: "Settings"; case .setup: "Setup"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"; case .history: "clock.arrow.circlepath"
        case .dictionary: "character.book.closed"
        case .settings: "gearshape"; case .setup: "checkmark.shield"
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: HubModel
    @EnvironmentObject var lowMemCleanup: LowMemoryCleanupModel
    // Fresh installs land on Setup: Pomvox does nothing until Microphone,
    // Input Monitoring, and Accessibility are granted, and a first-time user
    // has no way to know that from an empty Home dashboard. Evaluated once at
    // window creation; the user is free to navigate away afterward.
    @State private var selection: NavItem = .firstRun(
        allPermissionsGranted: Permissions.allGranted())
    @State private var showLowMemCleanup = false

    var body: some View {
        NavigationSplitView {
            Sidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 224, ideal: 246, max: 300)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.pane)
        }
        .navigationTitle("")
        .toolbar(removing: .sidebarToggle)
        // The native engine writes rows in-process now — refresh on each insert.
        .onReceive(
            NotificationCenter.default.publisher(for: .pomvoxHistoryDidChange)
                .receive(on: RunLoop.main)
        ) { _ in model.reload() }
        // Menu bar "Open Setup…" deep link.
        .onReceive(NotificationCenter.default.publisher(for: .pomvoxShowSetup)) { _ in
            selection = .setup
        }
        // The one-time low-memory cleanup prompt (item 7). Shows on the first
        // manual open of the Hub; a login-item launch suppresses the window, so
        // it defers to the next time the window appears.
        .onAppear { presentFirstRunSheets() }
        .sheet(isPresented: $showLowMemCleanup) {
            LowMemoryCleanupSheet().environmentObject(lowMemCleanup)
        }
    }

    private func presentFirstRunSheets() {
        if lowMemCleanup.needsPrompt {
            showLowMemCleanup = true
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .home:       HomeView(goToHistory: { selection = .history })
        case .history:    HistoryView()
        case .dictionary: DictionaryView()
        case .settings:   SettingsView()
        case .setup:      SetupView()
        }
    }
}
