import Foundation

/// Memory-aware defaults for low-RAM Macs (e.g. an 8 GB MacBook).
///
/// The armed native engine keeps the Parakeet STT models resident (~600 MB) and,
/// when cleanup is on, also loads the cleanup LLM, which runs ~1.4 GB
/// (Qwen3-1.7B-4bit) to ~2.3 GB (Qwen3-4B-4bit) depending on the configured
/// model — call it ~2-3 GB armed in total.
/// On an 8 GB machine that risks memory pressure and swap, and GPU cleanup is the
/// slowest path there. So on a *fresh install* (no config yet) on a low-memory
/// Mac we default cleanup off: raw on-device dictation (~600 MB) that just works,
/// which the user can turn on in Settings ▸ Models.
///
/// Pure logic (RAM in → decision out) so it's unit-testable and can't regress an
/// existing user: it only ever supplies a *default* for an absent config key.
enum MemoryTier {
    /// Physical-RAM cutoff (bytes) at or below which cleanup is off by default.
    /// An 8 GB Mac reports exactly 8 × 1024³ bytes; the 8.5 GB cutoff catches any
    /// that report marginally under while staying well below the 16 GB tier.
    static let lowMemoryMaxBytes: UInt64 = 8 * 1024 * 1024 * 1024 + 512 * 1024 * 1024

    /// Whether this machine's physical RAM is in the low-memory tier.
    static func isLowMemory(_ physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes <= lowMemoryMaxBytes
    }

    /// The default for `[cleanup] enabled` when the key is absent.
    ///
    /// - A 16 GB+ Mac defaults to `true` (unchanged).
    /// - A low-memory Mac defaults to `false` *until the one-time low-memory
    ///   prompt has been answered* (`lowMemPrompted`), then follows the normal
    ///   `true` default — the off default only exists to avoid surprising a
    ///   low-memory user with a multi-GB model load before they've been asked.
    ///
    /// Keyed on prompt state, deliberately **not** on config-file existence: the
    /// engine writes `config.toml` via `persist(true)` at the end of every
    /// successful `arm()`, so a file-existence heuristic flipped the low-memory
    /// default back **on** at the second arm (and the model default to 4B),
    /// eagerly loading the cleanup LLM on exactly the low-RAM Macs this guards —
    /// even while the unanswered prompt still claimed cleanup was off. Because
    /// engine and Hub share one process, the engine reads the same
    /// `LowMemoryCleanupModel.promptedKey` the prompt writes.
    static func firstRunCleanupDefault(isLowMemory: Bool, lowMemPrompted: Bool) -> Bool {
        if !isLowMemory { return true }
        return lowMemPrompted
    }

    // MARK: - Memory-aware cleanup model size (item 6)

    /// The compact cleanup model for low-memory Macs (~1.4 GB resident).
    static let compactCleanupModel = "mlx-community/Qwen3-1.7B-4bit"
    /// The standard cleanup model for 16 GB+ Macs: the SimpleWords dictation
    /// fine-tune, 8-bit fused. It ships its own frozen prompt (see
    /// `CleanupPromptProfile`).
    ///
    /// Why v3 (2026-08-03): v2 handled a self-correction only INSIDE one sentence
    /// ("tuesday wait no friday"). Across a sentence boundary — "Let's meet
    /// Thursday. No, no, wait, we'll meet Friday." — it kept the superseded
    /// clause and pasted the wrong day. v3 was trained on a corpus built for that
    /// gap. Both share one frozen prompt, so the corpus is the only variable.
    ///
    /// What is measured, by the MODEL author's held-out sets — NOT by anything in
    /// this repo, which has no v3 harness (`scripts/eval_cleanup_v2.py` is pinned
    /// to v2 and is the v2 gate's record): cross-sentence self-correction 122/122
    /// vs v2's 15/77; must-not-correct negatives 30/30 vs 25/30; real human
    /// disfluency (Disfl-QA, never trained on) 231/300 vs 27/300. What this repo
    /// measures is `CleanupE2ETests`, which runs the shipped default through the
    /// production path.
    ///
    /// Known regression, shipped deliberately: a chained triple correction in
    /// lowercase unpunctuated form ("red one no the blue one actually the green
    /// one") comes back unchanged — 43/44 on the intra-sentence set vs v2's
    /// 44/44. It was anti-correlated with the cross-sentence gate across every
    /// training checkpoint.
    ///
    /// What is NOT measured, and must not be claimed until it is: its resident
    /// footprint (the only recorded figure, 1.9 GB, is the on-disk snapshot size,
    /// which is not a footprint — no `vmmap` reading has been taken), and any
    /// speed or quality ratio against Qwen3-4B. Per CONTRIBUTING.md, a latency
    /// claim here needs an on-device number behind it.
    ///
    /// Rollback is this one line back to `-v2`, which is still published and
    /// still listed in `CleanupPromptProfile.frozenPromptIDs`.
    static let standardCleanupModel = "abhiram3040/simplewords-dictation-cleanup-v3"

    /// The `[cleanup] model` default for the current machine when the key is
    /// absent: the smallest model that fits comfortably. A low-memory Mac gets
    /// the 1.7B model; 16 GB+ gets the SimpleWords fine-tune. The
    /// 8B preset is offered in Settings but never auto-selected — it only fits
    /// higher-RAM machines, so the user opts into it explicitly.
    static func firstRunCleanupModel(physicalMemoryBytes: UInt64) -> String {
        isLowMemory(physicalMemoryBytes) ? compactCleanupModel : standardCleanupModel
    }
}
