import Foundation

/// Memory-aware defaults for low-RAM Macs (e.g. an 8 GB MacBook).
///
/// The armed native engine keeps the Parakeet STT models resident (~600 MB) and,
/// when cleanup is on, also loads the cleanup LLM (~2.2 GB) — ~2.5 GB total.
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
    ///   low-memory user with the ~2.3 GB load before they've been asked.
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
    /// The standard cleanup model for 16 GB+ Macs (~2.2 GB resident): the
    /// SimpleWords dictation fine-tune, 8-bit fused. It ships its own frozen
    /// prompt (see `CleanupPromptProfile`) and beat Qwen3-4B on a 28-case eval
    /// with zero meaning corruptions at roughly 4x the speed.
    static let standardCleanupModel = "abhiram3040/simplewords-dictation-cleanup-v2"

    /// The `[cleanup] model` default for the current machine when the key is
    /// absent: the smallest model that fits comfortably. A low-memory Mac gets
    /// the 1.7B model; 16 GB+ gets the SimpleWords fine-tune. The
    /// 8B preset is offered in Settings but never auto-selected — it only fits
    /// higher-RAM machines, so the user opts into it explicitly.
    static func firstRunCleanupModel(physicalMemoryBytes: UInt64) -> String {
        isLowMemory(physicalMemoryBytes) ? compactCleanupModel : standardCleanupModel
    }
}
