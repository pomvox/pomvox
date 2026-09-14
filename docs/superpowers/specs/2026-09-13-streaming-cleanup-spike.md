# Spike: clean while the user is still speaking — verdict NO-GO (for now)

**Date:** 2026-09-13 · **Branch:** `spike/streaming-cleanup` · **Script:** `scripts/spike_streaming_cleanup.py`

## Question

Long dictations (30–130 s of speech, 500–3500 chars) wait 5–30 s at key-up for cleanup. Could the settled sentences be cleaned while the user is still talking, so the wait at key-up is only the last block?

Exit criterion set before measuring: key-up latency ≥ 2× better on ≥ 500-char dictations **without changing the output**.

## Method

Replay 21 real dictations from `~/.pomvox/history.db` (`cleanup_status = ok`, ≥ 400 chars) through the shipped v3 model with its frozen prompt, greedy, from the local snapshot. Split each into blocks of ≥ 200 chars on sentence boundaries; the last block is the tail.

- **Variant A** — every block cleaned on its own; tail cleaned at key-up; outputs joined.
- **Variant B** — every block cleaned with the previous raw block as leading context; the output is aligned against the previous block's cleaned text and only the part past it is kept.

Compared against cleaning the whole transcript at once (today's behaviour): word-level similarity (`difflib`), and the tail's cleanup time versus the whole's.

## Result

| | identical | similarity ≥ 0.95 | median similarity | worst | key-up p50 |
|---|---|---|---|---|---|
| whole transcript (today) | — | — | — | — | 6.9 s |
| A: independent blocks | 0 / 21 | 8 / 21 | 0.946 | 0.144 | **3.9 s (2.0×)** |
| B: context + alignment | 3 / 21 | 7 / 21 | 0.882 | 0.088 | 6.2 s (1.0×) |

The latency half of the criterion is met by A; the output half is met by neither. The model's sentence segmentation, punctuation and filler decisions depend on the whole utterance: every dictation came back different when split. Most differences are small (a comma, a merged sentence), but a short block can flip the model into a different reading entirely (the 0.144 case). B, which was supposed to give the model the seam, loses the alignment often enough to be worse, and the longer inputs cost back the latency.

## Why this is a no-go today, not a "needs more work"

`#145` (prompt-lookup speculative decoding) already delivers **1.8–2× on the whole path with zero text change** — the same order as A's key-up win, without the drift. Streaming would have to beat the new baseline, and A does not: its tail still runs at the same tok/s, so the gap it closes is the same gap #145 closed for free.

## When to reopen

1. **A model trained on block-shaped inputs** (v4 corpus item): if the fine-tune sees blocks with an explicit context marker in training, the drift in A should collapse. Re-run this script; the bar is identical ≥ 90 % and similarity ≥ 0.98 on the rest.
2. **Opt-in for very long dictations only** (≥ 1500 chars): the 3504-char case went 29.0 s → 3.6 s at similarity 0.905. A user dictating a page might prefer that trade behind a switch — but it is a product decision, not an engineering one.

## Facts for whoever builds it (from the engine, 2026-09-13)

- Live drafts re-transcribe the whole buffer every ~1 s (`NativeEngine.startDraftLoop`) and are **not** a stable prefix of the final transcript; `HudLogic.splitStablePrefix` is display-only. A "settled" block must be defined as text identical across ≥ 2 consecutive drafts and at least one sentence behind the tail.
- The VAD fires one endpoint per session and only in hands-free mode; there is no sentence-pause event to key blocks off. `EndpointDetector.silenceFraction` is the closest live signal.
- STT (`Transcriber`, ANE) and cleanup (`CleanupEngine`, GPU) are separate actors serialized only by the `finishing` flag; `Memory.clearCache()` inside `clean()` would drop the STT model's MLX buffers mid-recording and must be skipped in a streaming mode.
- Whole-string paste hazards in #140 apply doubly to a spliced result.
