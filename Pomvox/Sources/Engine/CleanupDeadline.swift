import Foundation

/// How long a cleanup pass is allowed to take.
///
/// `cleanup.timeout_s` was a FIXED wall-clock budget, but the work is linear in
/// the transcript: the model decodes at a roughly constant rate, so a long
/// dictation deterministically blows any fixed deadline — and burns the whole
/// budget before falling back, so the user waits the maximum and still gets raw
/// text. On-device history (2026-09-02, 219 dictations, `~/.pomvox/history.db`)
/// fits cleanup latency almost perfectly as a line in output length:
///
///     warm      (gap < 5 min):  ms ≈  564 + 9.07 · chars
///     post-idle (gap ≥ 5 min):  ms ≈ 2362 + 8.94 · chars
///
/// The SLOPES are identical — there is no post-idle throughput regression, and
/// the prompt-prefix caches are reused across idle eviction exactly as designed
/// (`cleanup: reusing retained prefix caches` on every reload in the log). The
/// only post-idle difference is the ~1.8 s intercept, which is the weight
/// reload the utterance waits out inside its own deadline (`cleanup: loaded …
/// in 1.3–2.2s`). That is what `reloadCreditCapS` gives back.
///
/// Those fits predict the budget is exhausted at ~1316 chars warm / ~1134
/// post-idle, and that is exactly where the observed failures sit: the longest
/// SUCCESSFUL cleanup was 1050 chars (9.7 s), while the recorded timeouts were
/// 1189, 1512, 1548, 1783 and 2053 chars. Two of them followed gaps under
/// 300 s, so eviction was never the discriminator — length was.
///
/// A deadline is a CEILING, not a sleep: a generous one costs nothing when
/// generation finishes early, and only binds on a genuinely slow or runaway
/// pass. So the policy errs generous and bounds the worst case with
/// `ceilingS` instead of squeezing the common case.
enum CleanupDeadline {
    /// Cleanup decode throughput in output characters per second.
    ///
    /// 110 ch/s is the reciprocal of the 9.07 ms/char fit above, measured on an
    /// M1 — the slowest supported tier, so it is a floor. Over-estimating
    /// throughput under-budgets and pastes raw; under-estimating only widens a
    /// ceiling that a faster machine never reaches.
    static let throughputCharsPerS: Double = 110

    /// Per-pass cost that does not scale with length: suffix prefill, tokenize,
    /// and the `Memory.clearCache()` before generation. The intercept of the
    /// warm fit (564 ms), rounded up.
    static let fixedOverheadS: Double = 0.6

    /// Multiplier over the point estimate. The fit is a mean; individual passes
    /// vary (a 961-char cleanup took 10.4 s where the fit predicts 9.3 s), and
    /// `clean()` caps output at 2× the input tokens, so a polish pass that
    /// restructures rather than trims can outrun the estimate.
    static let headroom: Double = 1.4

    /// Absolute ceiling on a single cleanup, however long the transcript. Past
    /// this the pass is abandoned before it starts (see `isHopeless`) so the
    /// raw text pastes immediately instead of after a minute of waiting.
    static let ceilingS: Double = 60.0

    /// Most of a post-eviction weight reload that `clean()` will credit back to
    /// its deadline. The measured reload is 1.3–2.2 s; the cap keeps a
    /// pathological load (a cold page cache, a stalled Hub listing) from
    /// extending the deadline without bound.
    static let reloadCreditCapS: Double = 5.0

    /// Extra wall clock the `cleanupWithWatchdog` race allows beyond the
    /// deadline, for a Metal kernel that hangs without ever yielding a chunk.
    static let watchdogGraceS: Double = 2.0

    /// Point estimate of how long cleaning `chars` characters takes.
    static func estimateS(chars: Int) -> Double {
        fixedOverheadS + Double(max(0, chars)) / throughputCharsPerS
    }

    /// The deadline a transcript of `chars` characters actually gets, given the
    /// configured `cleanup.timeout_s`.
    ///
    /// Never below `base`: a short utterance keeps exactly today's budget, so
    /// this cannot regress the common case. Never above `ceilingS`.
    static func effectiveTimeoutS(base: Double, chars: Int) -> Double {
        min(ceilingS, max(base, estimateS(chars: chars) * headroom))
    }

    /// Whether the pass provably cannot fit even its widened deadline — i.e.
    /// `ceilingS` binds. Then raw pastes at once rather than after the ceiling
    /// elapses: the outcome is the same, the wait is not.
    static func isHopeless(base: Double, chars: Int) -> Bool {
        estimateS(chars: chars) > effectiveTimeoutS(base: base, chars: chars)
    }

    /// Deadline credit for time `clean()` spent waiting out an in-flight model
    /// reload. The utterance did not spend that time generating, and charging
    /// it is what made a post-idle dictation ~1.8 s likelier to paste raw than
    /// an identical warm one.
    static func reloadCreditS(waited: Double) -> Double {
        min(max(0, waited), reloadCreditCapS)
    }

    /// The outer watchdog's wall-clock limit for a pass budgeted `effective`.
    /// It must clear the deadline plus every credit `clean()` may award itself,
    /// or the race would cancel a pass that is still inside its own budget.
    static func watchdogTimeoutS(effective: Double) -> Double {
        effective + reloadCreditCapS + watchdogGraceS
    }
}
