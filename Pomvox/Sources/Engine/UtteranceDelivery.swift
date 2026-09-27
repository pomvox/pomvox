import Foundation

/// The utterance that currently owns insertion. Beginning a new one, or
/// retiring the current one (cancel, sleep, disarm, backend retired),
/// supersedes whatever is still in flight: its result is discarded, never
/// inserted.
@MainActor
final class UtteranceSessions {
    private(set) var current: UUID?

    @discardableResult
    func begin() -> UUID {
        let id = UUID()
        current = id
        return id
    }

    func retire() { current = nil }

    func isCurrent(_ id: UUID) -> Bool { current == id }
}

enum UtteranceDelivery: Equatable {
    case inserted(String)
    /// Cancelled or superseded; nothing was inserted.
    case suppressed
}

/// The host pipeline after the cleanup boundary, applied exactly once and in
/// this order: spoken formatting → dictionary → signature → insertion.
///
/// The session and task cancellation are checked before the transforms and
/// again after them, immediately before the synchronous `insert` on the main
/// actor. A transform can retire the session synchronously (without an await),
/// so a check only before the transforms would still insert stale text.
@MainActor
func deliverUtterance(
    _ text: String, id: UUID, sessions: UtteranceSessions,
    spokenFormatting: (String) -> String,
    dictionary: (String) -> String,
    signature: (String) -> String,
    insert: (String) -> Void
) -> UtteranceDelivery {
    guard !Task.isCancelled, sessions.isCurrent(id) else { return .suppressed }
    let final = signature(dictionary(spokenFormatting(text)))
    guard !Task.isCancelled, sessions.isCurrent(id) else { return .suppressed }
    insert(final)  // No suspension or host callback between the check and this.
    return .inserted(final)
}

/// Run the SDK backend for one utterance: the host's explicit length policy,
/// one fixed budget for the whole operation, and the SDK call. Throws only
/// `CancellationError` — a cancelled utterance is never turned into a raw
/// insertion.
func runSDKCleanup(_ host: SDKCleanupHost, raw: String, baseTimeoutS: Double,
                   reopenPermitted: Bool) async throws -> SDKCleanupOutcome {
    let chars = raw.count
    if raw.utf8.count > SDKCleanupPolicy.maxCleanedBytes {
        NSLog("cleanup: %d bytes is over the %d-byte long-dictation limit — original transcript",
              raw.utf8.count, SDKCleanupPolicy.maxCleanedBytes)
        return .fallback(raw, .longDictation)
    }
    if CleanupDeadline.isHopeless(base: baseTimeoutS, chars: chars) {
        NSLog("cleanup: %d chars is past the host's %.0fs ceiling — original transcript",
              chars, CleanupDeadline.ceilingS)
        return .fallback(raw, .hostCeiling)
    }
    // Sized once from the transcript, never extended afterwards.
    let budget = CleanupBudget(seconds: CleanupDeadline.effectiveTimeoutS(base: baseTimeoutS, chars: chars))
    let available = await host.requestPreparation(reopenPermitted: reopenPermitted)
    return try await host.clean(raw, budget: budget,
                                unprepared: available || reopenPermitted ? .notPrepared : .memoryPolicy)
}

/// Host policy for the SDK backend's current baseline.
enum SDKCleanupPolicy {
    /// Dictations longer than this paste the original, untouched. Measured on
    /// the simplewords-v3 baseline: 615 B–2.4 KB inputs cleaned faithfully, but
    /// a 4.8 KB input came back at 40 % of its bytes and the SDK's guards
    /// (length ratio ≥ 0.30) accepted it. ~3–4 minutes of speech. Raise only
    /// with long-input evidence against a new rules version.
    static let maxCleanedBytes = 3_000
}
