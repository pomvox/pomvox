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
    /// route it here and fail at load. Each new version earns its own entry.
    ///
    /// v2 stays listed after v3 became the default: it is still published and
    /// still serving, so a user who pinned it in `config.toml` — or a one-line
    /// rollback of `MemoryTier.standardCleanupModel` — must keep the frozen
    /// path. Both were trained on the same frozen prompt.
    private static let frozenPromptIDs: Set<String> = [
        "abhiram3040/simplewords-dictation-cleanup-v2",
        "abhiram3040/simplewords-dictation-cleanup-v3",
    ]

    /// The frozen prompt's filename inside the model snapshot. The bytes are
    /// read from there at load, never copied into this repo, so they cannot
    /// drift from the weights that were trained on them.
    ///
    /// The name does NOT track the model version, and `system_v2.txt` is correct
    /// for v3 — there is no `system_v3.txt` to point at. v3 was trained on the
    /// same frozen prompt as v2 so that the corpus is the only variable across
    /// versions, and it publishes that prompt under the name it was frozen
    /// under. Renaming this to match the model version breaks the load.
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
    /// `true` for both. It was `false` for the fine-tune until 2026-08-03, on
    /// the reading that Qwen3.5 made prefix caching impossible: `newCache` hands
    /// back a `MambaCache` for every linear-attention layer, `ArraysCache` never
    /// advances `offset`, and those layers aren't trimmable. Both observations
    /// are true; the conclusion drawn from them was not. Neither is a property
    /// of the architecture — they were properties of how `buildPrefixCaches`
    /// prefilled:
    ///
    /// - it read `cache.first?.offset` to validate the prefill, and layer 0 of
    ///   this model is linear (`layer_types[0] == "linear_attention"`, with a
    ///   full-attention layer only every 4th), so the check interrogated the one
    ///   layer that structurally cannot answer and always saw 0;
    /// - it prefilled with a `TokenIterator`, which SAMPLES a token as a side
    ///   effect and so overshoots the prefix by one — an overshoot a recurrent
    ///   layer cannot give back.
    ///
    /// Prefilling with a plain forward pass removes the overshoot entirely, and
    /// checking every layer's offset instead of layer 0's tolerates the hybrid.
    /// Reusing a linear-attention layer's recurrent state across requests is
    /// sound because that state IS the summary of the fixed prefix — it does not
    /// depend on what follows.
    ///
    /// This matters because the frozen prompt is ~265 of the ~279 tokens in a
    /// typical request: uncached, every dictation re-prefills it and spends
    /// ~1.09 s of a measured ~1.48 s doing so.
    var usesPrefixCache: Bool {
        switch self {
        case .legacy: return true
        case .simpleWords: return true
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
