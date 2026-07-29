import Foundation

/// Which prompt recipe a cleanup model expects.
///
/// The Qwen3 presets are instruction-tuned generalists steered at runtime by
/// `CleanupLogic.buildMessages` — a system prompt plus ten few-shot examples.
/// The SimpleWords model is a fine-tune: its training data used ONE frozen
/// prompt, folded into a single user turn, with no examples. Handing it the
/// few-shot prompt (or the frozen text as a system-role message) is
/// off-distribution and degrades the output. Prompt shape is therefore a
/// property of the model, not a global — and this enum is that seam.
///
/// Pure logic (model id in → recipe out), no MLX import, so it unit-tests the
/// way `CleanupLogic` does.
enum CleanupPromptProfile: Equatable {
    /// System prompt + few-shot examples; one prompt prefix per style.
    case legacy
    /// The frozen prompt that ships alongside the weights; one prefix for all
    /// styles.
    case simpleWords

    /// Model ids that ship a frozen prompt.
    ///
    /// Deliberately an EXACT set rather than a prefix match:
    /// `abhiram3040/simplewords-dictation-cleanup` (v1) is an adapter-only repo
    /// with no fused weights and no `system_v2.txt`, so a prefix match would
    /// route it here and fail at load. A future v3 gets its own entry.
    private static let frozenPromptIDs: Set<String> = [
        "abhiram3040/simplewords-dictation-cleanup-v2"
    ]

    /// The frozen prompt's filename inside the model snapshot. The bytes are
    /// read from there at load, never copied into this repo, so they cannot
    /// drift from the weights that were trained on them.
    static let frozenPromptFilename = "system_v2.txt"

    /// The one prefix-cache key every style shares on the frozen path.
    static let sharedPrefixKey = "*"

    /// The recipe for a configured `[cleanup] model` value. Unknown ids get
    /// `.legacy`, the safe default — it works with any instruction-tuned model.
    static func forModel(_ id: String) -> CleanupPromptProfile {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return frozenPromptIDs.contains(normalized) ? .simpleWords : .legacy
    }

    /// The prompt-prefix caches to prefill for this profile.
    var prefixKeys: [String] {
        switch self {
        case .legacy: return CleanupLogic.styles
        case .simpleWords: return [Self.sharedPrefixKey]
        }
    }

    /// Whether this profile's prompt prefix can be prefilled into a reusable
    /// KV cache.
    ///
    /// `false` for the fine-tune: it is Qwen3.5, whose `newCache` hands back a
    /// `MambaCache` for every linear-attention layer, and `ArraysCache` never
    /// advances `offset` — so the prefill's offset check can't pass and the
    /// layers aren't trimmable either. It doesn't matter: the frozen prompt is
    /// ~276 tokens against the legacy path's few-shot prefix, and an uncached
    /// cleanup measures ~0.9 s on an M1. Attempting the prefill anyway costs
    /// ~2.8 s per residency and can never succeed.
    var usesPrefixCache: Bool {
        switch self {
        case .legacy: return true
        case .simpleWords: return false
        }
    }

    /// The prefix-cache key a configured style uses.
    ///
    /// `light` and `polish` collapse onto one key on the frozen path: the prompt
    /// is frozen, so the style knob has nothing left to vary and two keys would
    /// only ever name the same bytes. No prefill is saved by the collapse —
    /// `usesPrefixCache` is `false` here, so the frozen path prefills nothing at
    /// all; the single key exists to keep the prefix-key plumbing total over
    /// both profiles.
    func prefixKey(forStyle style: String) -> String {
        switch self {
        case .legacy: return style
        case .simpleWords: return Self.sharedPrefixKey
        }
    }
}
