import Foundation

/// What one cleanup generation cost, split the way the latency actually
/// splits: reading the prompt suffix (prefill) versus writing the answer
/// (decode), plus the speculative-decoding counters once that path exists.
///
/// Pure data so `NativeEngine` can fold it into `history.timings_json` and the
/// engine log line without touching MLX. Every field is per-utterance; the
/// prefix cache's one-time prefill is not counted here.
struct CleanupGenStats: Equatable, Sendable {
    /// Tokens fed to the model this request (the suffix when the prefix cache
    /// engaged, the whole prompt otherwise).
    var promptTokens = 0
    var prefillMs = 0.0
    /// Tokens the model wrote (the cleaned text, not counting the stop token).
    var decodeTokens = 0
    var decodeMs = 0.0
    /// Whether the prompt-prefix KV cache served this request.
    var cached = false
    /// Speculative decoding: verification rounds run, draft tokens proposed,
    /// draft tokens the model agreed with. All zero on the plain path.
    var specRounds = 0
    var specDrafted = 0
    var specAccepted = 0

    /// Draft tokens accepted per drafted token — the number that says whether
    /// speculation is paying for itself on real dictation. `nil` when nothing
    /// was drafted.
    var acceptRate: Double? {
        guard specDrafted > 0 else { return nil }
        return Double(specAccepted) / Double(specDrafted)
    }

    var decodeTokensPerSecond: Double {
        guard decodeMs > 0 else { return 0 }
        return Double(decodeTokens) / (decodeMs / 1000)
    }

    var prefillTokensPerSecond: Double {
        guard prefillMs > 0 else { return 0 }
        return Double(promptTokens) / (prefillMs / 1000)
    }

    /// The flat keys merged into `history.timings_json` (see
    /// `EngineTimings.note`). Names are stable: dashboards query them.
    func timingNotes() -> [(String, Double)] {
        var notes: [(String, Double)] = [
            ("cleanup_prefill_ms", prefillMs),
            ("cleanup_prefill_tok", Double(promptTokens)),
            ("cleanup_decode_ms", decodeMs),
            ("cleanup_decode_tok", Double(decodeTokens)),
            ("cleanup_cached", cached ? 1 : 0),
        ]
        if let rate = acceptRate {
            notes.append(("spec_accept_rate", rate))
            notes.append(("spec_rounds", Double(specRounds)))
        }
        return notes
    }
}
