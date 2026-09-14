import Foundation

/// Prompt-lookup drafting for speculative decoding — the "draft model" is the
/// transcript itself.
///
/// Cleanup is a rewrite: most output tokens are copies of input tokens, in
/// order. So instead of a second network guessing what comes next, look up the
/// last few generated tokens in the input (plus everything generated so far)
/// and propose the tokens that followed them there. The model then verifies
/// the whole proposal in ONE forward pass — a k-token read costs about the
/// same as a one-token write on a bandwidth-bound M1 — and keeps the longest
/// prefix it agrees with. Greedy verification makes the output byte-identical
/// to plain greedy decoding; a bad guess costs one wasted pass, never a wrong
/// token.
///
/// Pure logic, no MLX: `draft` is a table lookup over `[Int]`, unit-tested on
/// its own. On the shipped model, drafts of 4 are accepted ~70 % of the time
/// on real dictation, which turns ~27 tok/s of decode into ~47–50.
struct PromptLookupDrafter: Equatable, Sendable {
    /// How many trailing generated tokens must match before a proposal is made.
    /// 3 is the sweet spot on dictation: 2 over-matches common bigrams
    /// ("of the"), 4 misses too often after a punctuation edit.
    static let defaultNgram = 3
    /// Longest proposal per round: one pending token plus this fills the
    /// 5-token pass that `SpeculativeDecoder.DraftPolicy` measured as the last
    /// cheap one on an M1. Drafting more only feeds tokens the round cannot
    /// verify.
    static let defaultMaxDraft = 4

    let ngram: Int
    let maxDraft: Int

    init(ngram: Int = PromptLookupDrafter.defaultNgram, maxDraft: Int = PromptLookupDrafter.defaultMaxDraft) {
        self.ngram = max(1, ngram)
        self.maxDraft = max(0, maxDraft)
    }

    /// Propose up to `maxDraft` tokens to follow `generated`.
    ///
    /// `input` is the transcript's tokens; `generated` is what the model has
    /// written so far. The search key is the last `ngram` generated tokens,
    /// falling back to shorter keys (down to 1) when the full n-gram has no
    /// earlier occurrence. The pool is `input + generated`; the most recent
    /// occurrence wins, but the trailing key itself never matches — a
    /// proposal must be *followed* by something. A proposal never crosses
    /// from the input into the generated text (the end of the transcript
    /// followed by the start of the answer is not a continuation of
    /// anything), and a key straddling that seam is ignored for the same
    /// reason. Empty when nothing was generated yet or no key occurs anywhere.
    func draft(input: [Int], generated: [Int]) -> [Int] {
        guard maxDraft > 0, !generated.isEmpty else { return [] }
        let pool = input + generated
        let seam = input.count
        for n in stride(from: min(ngram, generated.count), through: 1, by: -1) {
            let key = Array(generated.suffix(n))
            // Candidate starts run from the last position where a key match
            // still leaves at least one token to propose.
            var start = pool.count - n - 1
            while start >= 0 {
                defer { start -= 1 }
                let from = start + n
                // Which segment the match lives in decides where the
                // proposal may run to; a match across the seam is skipped.
                let end: Int
                if from <= seam {
                    end = seam
                } else if start >= seam {
                    end = pool.count
                } else {
                    continue
                }
                guard from < end, pool[start ..< from].elementsEqual(key) else { continue }
                return Array(pool[from ..< min(end, from + maxDraft)])
            }
        }
        return []
    }
}
