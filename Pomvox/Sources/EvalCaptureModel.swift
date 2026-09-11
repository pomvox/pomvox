import AppKit
import SwiftUI

/// Observable wrapper over `EvalCaptureSetting` + `EvalCaptureStore` for the
/// Privacy-pane group and the menu-bar indicator, so the two always agree on
/// whether capture is on. The folder's count/size refresh on every write and
/// purge (the store posts `.pomvoxEvalCaptureDidChange`).
@MainActor
final class EvalCaptureModel: ObservableObject {
    @Published private(set) var isOn: Bool
    @Published private(set) var count = 0
    @Published private(set) var bytes: Int64 = 0

    private let setting: EvalCaptureSetting
    private let store: EvalCaptureStore
    private var observer: NSObjectProtocol?

    init(setting: EvalCaptureSetting = EvalCaptureSetting(), store: EvalCaptureStore = .shared) {
        self.setting = setting
        self.store = store
        self.isOn = setting.isOn
        observer = NotificationCenter.default.addObserver(
            forName: .pomvoxEvalCaptureDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Privacy-pane toggle binding. Takes effect on the next dictation — the
    /// engine reads the flag per finalize, no re-arm.
    var binding: Binding<Bool> {
        Binding(get: { self.isOn }, set: { self.set($0) })
    }

    func set(_ on: Bool) {
        setting.isOn = on
        isOn = on
    }

    func refresh() {
        count = store.count()
        bytes = store.bytes()
    }

    /// "12 files · 34 KB", or "None yet" before the first capture.
    var summary: String {
        guard count > 0 else { return "None yet." }
        let files = count == 1 ? "1 file" : "\(count) files"
        return "\(files) · \(StorageInspector.humanSize(bytes))"
    }

    /// Open the folder in Finder — created first so the button always works,
    /// even before the first dictation is captured.
    func revealInFinder() {
        store.ensureDirectory()
        NSWorkspace.shared.activateFileViewerSelecting([store.directoryURL])
    }

    func purge() {
        store.purge()
        refresh()
    }
}
