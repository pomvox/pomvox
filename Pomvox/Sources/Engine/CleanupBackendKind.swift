import Foundation

/// Which cleanup implementation `NativeEngine` runs. `[cleanup] backend`,
/// snapshotted at arm (restart-required in Settings).
enum CleanupBackendKind: String, CaseIterable, Sendable {
    /// The external `pomvox-cleanup-engine` package (`SDKCleanupHost`).
    case sdk
    /// The in-app `CleanupEngine` that shipped through v0.2.8.
    case inapp

    /// Unknown values fall back to the default with a log line rather than
    /// refusing to arm — a typo must not cost dictation.
    static func parse(_ raw: String?) -> CleanupBackendKind {
        guard let raw, !raw.isEmpty else { return .defaultKind }
        guard let kind = CleanupBackendKind(rawValue: raw.lowercased()) else {
            NSLog("pomvox-engine: unknown [cleanup] backend %@ — using %@",
                  raw, CleanupBackendKind.defaultKind.rawValue)
            return .defaultKind
        }
        return kind
    }

    /// SDK by default — for the model it serves (see `resolve`).
    static let defaultKind = CleanupBackendKind.sdk

    /// The model the SDK's bundled pack serves.
    static let sdkModelID = MemoryTier.standardCleanupModel

    /// The backend for this arm. An explicit `[cleanup] backend` always wins.
    /// Without one, the SDK is used only when the configured cleanup model is
    /// the one its pack serves: an 8 GB Mac on the compact default, or anyone
    /// who chose another model, keeps the in-app engine instead of being
    /// silently moved to a different (larger) model on update.
    static func resolve(configured raw: String?, modelID: String) -> CleanupBackendKind {
        if let raw, !raw.isEmpty { return parse(raw) }
        return modelID == sdkModelID ? .sdk : .inapp
    }
}

/// Which cleanup controls the running backend actually honours. Settings and
/// the dictionary editor read this instead of offering controls that would be
/// silently ignored.
struct CleanupControls: Equatable, Sendable {
    /// Light/Polish style selection.
    let style: Bool
    /// `[cleanup] speculative`.
    let speculativeToggle: Bool
    /// Model-generated dictionary variant suggestions (a second, differently
    /// prompted generation). The SDK is cleanup-only; loading the in-app
    /// engine beside it would be a second resident model.
    let modelVariantSuggestions: Bool

    static func forBackend(_ kind: CleanupBackendKind, capabilities: [String]) -> CleanupControls {
        switch kind {
        case .inapp:
            return CleanupControls(style: true, speculativeToggle: true, modelVariantSuggestions: true)
        case .sdk:
            // The baseline pack declares ["vocabulary"] only: no style, no
            // decoder configuration, no auxiliary generation.
            return CleanupControls(style: capabilities.contains("style"),
                                   speculativeToggle: capabilities.contains("decoding"),
                                   modelVariantSuggestions: false)
        }
    }
}
