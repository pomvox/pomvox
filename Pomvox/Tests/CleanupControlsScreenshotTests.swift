import AppKit
import SwiftUI
import XCTest

@testable import Pomvox

/// Renders the cleanup controls that change with the backend, for the PR's
/// before/after screenshots. Skipped unless `POMVOX_SCREENSHOT_DIR` is set:
///   TEST_RUNNER_POMVOX_SCREENSHOT_DIR=/path TEST_RUNNER_POMVOX_SCREENSHOT_LABEL=after \
///   xcodebuild test … -only-testing:PomvoxTests/CleanupControlsScreenshotTests
@MainActor
final class CleanupControlsScreenshotTests: XCTestCase {

    func testRenderCleanupControls() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["POMVOX_SCREENSHOT_DIR"], !dir.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_POMVOX_SCREENSHOT_DIR to render screenshots")
        }
        let label = env["POMVOX_SCREENSHOT_LABEL"] ?? "shot"
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let model = SettingsModel(path: scratch.appendingPathComponent("config.toml").path, inputDevices: [])

        let states: [(String, CleanupBackendKind, String?, String?)] = [
            ("sdk", .sdk, nil, "simplewords-v3 0.1.0-preview · rules pomvox-guards-v0.2.8"),
            ("sdk-problem", .sdk,
             "The cleanup pack at ~/Library/Application Support/Pomvox/CleanupPacks/simplewords-v3-… "
                 + "is not the one this app trusts. It is left untouched; remove it to reinstall.", nil),
            ("inapp", .inapp, nil, nil),
        ]
        for (name, backend, problem, summary) in states {
            let view = CleanupSettingsGroup(
                model: model, backend: backend,
                controls: CleanupControls.forBackend(backend, capabilities: backend == .sdk ? ["vocabulary"] : []),
                problem: problem, packSummary: summary,
                availability: CleanupAvailabilityState(
                    enabled: true, phase: summary == nil ? .loading : .ready,
                    downloadInFlight: false, downloadCancelled: false))
                .padding(20).frame(width: 620)
                .background(Palette.pane)
            try render(view, to: URL(fileURLWithPath: dir).appendingPathComponent("\(label)-settings-\(name).png"))
        }

        let store = DictionaryStore(path: scratch.appendingPathComponent("dictionary.toml").path,
                                    configPath: scratch.appendingPathComponent("config.toml").path)
        let rule = DictionaryRule(sources: ["pom box"], target: "Pomvox", enabled: true, origin: "manual")
        let sheet = RuleEditorSheet(state: RuleEditorState(editing: rule))
            .environmentObject(store)
            .background(Palette.pane)
        try render(sheet, to: URL(fileURLWithPath: dir).appendingPathComponent("\(label)-dictionary-sheet.png"))
    }

    private func render<V: View>(_ view: V, to url: URL) throws {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .aqua)
        host.layoutSubtreeIfNeeded()
        // Let onAppear/state updates land before capturing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        window.setContentSize(host.frame.size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw XCTSkip("could not allocate a bitmap")
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
