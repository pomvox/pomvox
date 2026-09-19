import Foundation

/// The whole surface `NativeEngine` needs from a cleanup implementation.
///
/// Until the SDK branch there was exactly one implementation, `CleanupEngine`,
/// and `NativeEngine` simply held it. `feat/cleanup-engine-sdk` adds a second
/// one backed by the external `pomvox-cleanup-engine` package, so the calls
/// `NativeEngine` makes — load, evict, hint, per-utterance clean, timing notes
/// — move behind this protocol and the engine picks an implementation at
/// `loadEngineConfig()` time from `[cleanup] backend`.
///
/// It deliberately extends `CleanupCleaning` (the generation seam `runCleanup`
/// and `cleanupWithWatchdog` already take) rather than replacing it: those two
/// free functions, their tests and their fakes stay exactly as they are.
protocol CleanupBackend: CleanupCleaning, Actor {
    /// Model resident right now.
    var isLoaded: Bool { get }
    /// Bumped on every successful load; see `CleanupEngine.loadGeneration`.
    var generation: Int { get }
    /// The model that actually loaded (vs the configured id), for eval provenance.
    var loadedModel: String? { get }

    /// Load + warm. Idempotent; `.skipped` when nothing loaded this call.
    func prepare(modelID: String, onProgress: (@Sendable (Double) -> Void)?) async -> CleanupPrepareOutcome
    /// Drop the resident model. Cheap state (prefixes, hints) may be retained.
    func unload()
    /// Idle-evict variant: only if no load completed since `expected`.
    @discardableResult func unload(ifGeneration expected: Int) -> Bool

    /// Dictionary spelling rule for the prompt. Set before `prepare()`.
    func setTermsHint(_ hint: String)
    /// Hot-apply a dictionary edit on a resident model.
    func updateTermsHint(_ hint: String) async
    /// Configured style, set before `prepare()`.
    func setPreferredStyle(_ style: String)
    /// Whether the fast decoding path is enabled.
    func setSpeculativeDecoding(_ enabled: Bool)

    /// Stage timings of the most recent generation, for `history.timings_json`.
    /// Empty when the last pass never reached the model.
    func timingNotes() -> [(String, Double)]
}

/// Which cleanup implementation `NativeEngine` runs.
enum CleanupBackendKind: String, CaseIterable, Sendable {
    /// The external `pomvox-cleanup-engine` package (verified pack + SDK cleaner).
    case sdk
    /// The in-app `CleanupEngine` that shipped through v0.2.8.
    case inapp

    /// `[cleanup] backend`. Unknown values fall back to the default with a log
    /// line rather than refusing to arm — a typo must not cost dictation.
    static func parse(_ raw: String?) -> CleanupBackendKind {
        guard let raw, !raw.isEmpty else { return .defaultKind }
        guard let kind = CleanupBackendKind(rawValue: raw.lowercased()) else {
            NSLog("pomvox-engine: unknown [cleanup] backend %@ — using %@",
                  raw, CleanupBackendKind.defaultKind.rawValue)
            return .defaultKind
        }
        return kind
    }

    /// SDK by default on this branch; that is the thing under test.
    static let defaultKind = CleanupBackendKind.sdk
}

/// Why a backend could not produce a candidate, when "no candidate" is not the
/// same as "deadline".
///
/// `CleanupCleaning.clean` returns `nil` for deadline/model-not-ready, which
/// `runCleanup` maps to `.timeout`. The SDK distinguishes more failure kinds
/// than that, and the one that matters for observability is `rejected`: its
/// guards refused the model's output, which is the app's `.rejected` status,
/// not an error. Everything else stays `.error`.
enum CleanupBackendFailure: Error, Equatable {
    /// The output guards refused the candidate. Raw transcript pastes.
    case rejected
    /// Admission refused the request (worker busy / queue full).
    case busy
    /// No usable cleaner (closed, quarantined worker, setup failure).
    case unavailable
    /// Generation hit the output token cap.
    case tokenLimit
    /// Any other labelled fallback the backend reported.
    case other(String)
}

extension CleanupEngine: CleanupBackend {
    func timingNotes() -> [(String, Double)] {
        lastGenStats?.timingNotes() ?? []
    }
}
