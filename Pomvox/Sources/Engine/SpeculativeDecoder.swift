import Foundation
import MLX
import MLXLMCommon

/// Greedy generation with optional prompt-lookup speculative decoding, written
/// against the model's plain forward pass so it works on a HYBRID model.
///
/// Why not `MLXLMCommon.SpeculativeTokenIterator`: it throws unless every
/// cache is trimmable, and Qwen3.5's linear-attention layers keep a running
/// recurrence (`MambaCache`, never trimmable). Rejected draft tokens have
/// already been blended into that state, so there is nothing to drop off the
/// end. This loop sidesteps trimming entirely with SNAPSHOT + REPLAY:
///
///   1. copy every cache (a few short K/V tensors and 18 small recurrent
///      states — cheap),
///   2. run `[last] + draft` through the model in ONE pass and argmax every
///      position,
///   3. keep the longest prefix the model agrees with; if it agreed with all
///      of them the caches are already correct, otherwise restore the copies
///      and carry the accepted tokens into the NEXT pass, which reads them
///      again ahead of the next draft — so both cache kinds land on exactly
///      the state a token-at-a-time decode would have had.
///
/// Architecture-agnostic — it never asks a cache what kind it is. A miss costs
/// a slightly longer next pass, never an extra one.
///
/// Greedy only: the accepted tokens are exactly what argmax would have
/// produced one at a time, so the text is byte-identical to the non-speculative
/// loop. `CleanupSpeculativeDifferentialTests` pins that against the real
/// model; if it ever fails, `CleanupPromptProfile.usesSpeculativeDecoding` goes
/// back to `false`.
enum SpeculativeDecoder {

    /// Why generation stopped.
    enum Stop: Equatable, Sendable {
        /// A stop token (EOS) was produced — the normal end.
        case eos
        /// `maxTokens` tokens were produced without an EOS.
        case cap
        /// The deadline passed between rounds.
        case deadline
    }

    struct Result {
        let tokens: [Int]
        let stop: Stop
        let stats: CleanupGenStats
    }

    /// Pass-length policy, from the measured cost of one forward pass on the
    /// v3 model on this Swift stack on an M1 (300-token cache, 8-bit weights,
    /// `CleanupPassCostProbeTests`):
    ///
    ///     tokens in the pass   1     2     3     4     5     6     8    16    32
    ///     ms                  53    52    55    62    75   154   161   175   171
    ///
    /// A pass is bandwidth-bound up to 5 tokens (the quantized matmul stays
    /// on its few-rows kernel), then jumps ~2.5× at 6 and stays flat to 32.
    /// So every round carries at most 5 tokens: the backlog plus a draft of up
    /// to 4, which at the measured ~70 % acceptance yields ~3.8 tokens per
    /// pass. A "big" 32-token pass after a streak of full acceptances was
    /// tried and LOST on every bench fixture (long: 2.25 s vs 1.96 s) — it
    /// costs ~2.8 cheap passes and needs ~9 accepted tokens to break even,
    /// which real dictation rarely offers. If MLX's small-M quantized matmul
    /// ever gets cheaper, re-run the probe and revisit.
    struct DraftPolicy: Equatable, Sendable {
        var passLength = 5

        /// How many tokens the next round may draft on top of `pending`.
        func draftRoom(pending: Int) -> Int { max(0, passLength - pending) }
    }

    /// Generate greedily from `prompt` (fed on top of `cache`, or a fresh cache
    /// when nil), returning the generated token ids (stop token excluded).
    ///
    /// - `lookup`: the transcript's tokens for the drafter; `drafter` nil means
    ///   plain one-token-per-pass greedy decoding through the same code path
    ///   (the differential reference).
    /// - `stopTokens`: every id that ends generation.
    /// - `deadline`: absolute `CFAbsoluteTimeGetCurrent()` instant; checked
    ///   once per round.
    ///
    /// Rollback without a replay pass: the loop keeps a `pending` list of
    /// tokens that are already part of the output but not yet inside the
    /// caches. After a full acceptance that is just the bonus token, as in a
    /// plain step. After a rejection the caches go back to the snapshot and the
    /// accepted tokens JOIN `pending`, so the next pass re-reads them together
    /// with the next draft — one pass instead of a replay plus a verify. The
    /// price of a miss is therefore a fuller next pass, not an extra one, and
    /// because the backlog counts against the pass length a run of misses
    /// degrades into plain draft-free passes rather than longer ones.
    static func generate(
        model: any LanguageModel,
        prompt: [Int],
        cache initial: [KVCache]?,
        lookup: [Int],
        drafter: PromptLookupDrafter?,
        maxTokens: Int,
        stopTokens: Set<Int>,
        deadline: Double,
        cached: Bool,
        policy: DraftPolicy = DraftPolicy()
    ) -> Result {
        var stats = CleanupGenStats()
        stats.cached = cached
        stats.promptTokens = prompt.count
        var cache = initial ?? model.newCache(parameters: nil)

        // Prefill: one pass over the whole prompt (suffix or full), keeping
        // only the last position's argmax. Same op the model's own prefill
        // runs per chunk; the prompt here is at most a few hundred tokens.
        let tPrefill = CFAbsoluteTimeGetCurrent()
        let first = argmaxAll(model(ids(prompt), cache: cache)).last!
        stats.prefillMs = (CFAbsoluteTimeGetCurrent() - tPrefill) * 1000

        let tDecode = CFAbsoluteTimeGetCurrent()
        var generated: [Int] = []
        generated.reserveCapacity(maxTokens)

        func finish(_ stop: Stop) -> Result {
            stats.decodeTokens = generated.count
            stats.decodeMs = (CFAbsoluteTimeGetCurrent() - tDecode) * 1000
            return Result(tokens: generated, stop: stop, stats: stats)
        }

        /// Accept one produced token into the output. Returns the stop reason
        /// if this token ends generation.
        func emit(_ token: Int) -> Stop? {
            if stopTokens.contains(token) { return .eos }
            generated.append(token)
            return generated.count >= maxTokens ? .cap : nil
        }

        if let stop = emit(first) { return finish(stop) }
        // Output tokens the caches have not read yet; always at least one.
        var pending: [Int] = [first]

        while true {
            if CFAbsoluteTimeGetCurrent() > deadline { return finish(.deadline) }

            var draft: [Int] = []
            if let drafter {
                let room = policy.draftRoom(pending: pending.count)
                if room > 0 {
                    draft = Array(drafter.draft(input: lookup, generated: generated).prefix(room))
                }
            }

            if draft.isEmpty {
                // Plain step over the backlog: the last position's argmax is
                // the next token, and the caches now hold everything emitted.
                let next = argmaxAll(model(ids(pending), cache: cache)).last!
                if let stop = emit(next) { return finish(stop) }
                pending = [next]
                continue
            }

            stats.specRounds += 1
            stats.specDrafted += draft.count
            let snapshot = copyCaches(cache)
            let preds = argmaxAll(model(ids(pending + draft), cache: cache))
            // preds[i] answers after input[0...i]; the backlog's last token is
            // at index pending.count-1, so its successor prediction is
            // preds[pending.count-1], which draft[0] must match, and so on.
            let base = pending.count - 1
            var accepted = 0
            while accepted < draft.count, preds[base + accepted] == draft[accepted] {
                accepted += 1
            }
            stats.specAccepted += accepted
            let bonus = preds[base + accepted]

            for token in draft.prefix(accepted) {
                if let stop = emit(token) { return finish(stop) }
            }
            if let stop = emit(bonus) { return finish(stop) }

            if accepted == draft.count {
                // Every drafted token stood: the caches read the backlog and
                // the whole draft, so only the bonus is outstanding.
                pending = [bonus]
            } else {
                // The rejected tail is inside the recurrent states. Back to the
                // snapshot; the accepted tokens and the bonus wait for the next
                // pass together with whatever it drafts. The backlog counts
                // against the pass length, so a miss can never make the next
                // pass longer — at worst it is draft-free.
                cache = snapshot
                pending = pending + Array(draft.prefix(accepted)) + [bonus]
            }
        }
    }

    // MARK: - helpers

    private static func ids(_ tokens: [Int]) -> MLXArray {
        MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
    }

    /// Argmax at every position of a `[1, T, vocab]` logits tensor, evaluated.
    private static func argmaxAll(_ logits: MLXArray) -> [Int] {
        argMax(logits[0], axis: -1).asType(.int32).asArray(Int32.self).map(Int.init)
    }

    /// Deep-copy every cache. The copies stay lazy: MLX arrays are immutable
    /// values, so the live caches' next update produces NEW arrays and the
    /// snapshot keeps referencing the old ones — materializing ~20 MB of
    /// copies every round would only add kernel launches to a path that is
    /// taken on one round in two. (The prefix cache relies on the same
    /// `copy()` isolation per request.)
    private static func copyCaches(_ caches: [KVCache]) -> [KVCache] {
        caches.map { $0.copy() }
    }
}
