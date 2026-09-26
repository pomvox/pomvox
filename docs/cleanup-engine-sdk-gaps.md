# Gaps found integrating the cleanup engine SDK into Pomvox

Findings from building `feat/cleanup-engine-sdk` — the Pomvox app running its
dictation cleanup through `pomvox-cleanup-engine` at `00bd4d8` — and testing it
against the in-app engine it was extracted from.

Each entry is written to be filed as-is in the SDK repository: what the host hits,
how to reproduce it, what the evidence says, and what would fix it. Severity is
from the host's point of view — a dictation app on a user's Mac — not from the
SDK's test suite, which passes.

Environment for every measurement: Apple M1, 16 GiB, macOS 15.7.4, Xcode 26.3,
Swift 6.2.3, Debug builds, SimpleWords v3 pack `b1f7ac82…`, no network.

Machine load matters on a 16 GB Mac running a 2 GB model, and it bit twice in
this campaign — a cold-launch benchmark failed at 21.1 s immediately after a
200-request soak and passed at 12.0 s once things settled (12.3 s on `main` for
comparison), and one parity row diverged during a throttled stretch and agreed
on rerun. Both are recorded here rather than quietly re-run, because they are
the reason each number below says which run it came from.

*Entries marked **measured** have numbers behind them; entries marked **by
inspection** are read from the source. Where a probe measured something other
than what it set out to, that is said rather than papered over.*

**The short version:** the SDK reproduces the engine it was extracted from, on
real dictation, byte for byte. What stops the app moving onto it is not fidelity
— it is that a single dictionary word costs 3.4× on every request, that memory
pressure costs a 3.5 s full re-validation, that there is no way to install a
pack from an app, and that a rejection reports neither its reason nor its cost.

Ranked by what would change a user's experience soonest:

| # | Gap | Evidence |
| --- | --- | --- |
| 2 | Vocabulary misses the prefix cache | +650 ms on **every** real dictation, 2-word dictionary |
| 4b | A rejection says only "rejected" | 2,122 ms spent, zero diagnostics, 11 guards collapsed into 1 case |
| 4c | Spoken lists never survive; cue set too narrow | "shopping cart" rejected, "shopping list" would pass |
| 3 | No eviction/resume — reopen re-validates 2 GB | 3,378–3,617 ms per cycle |
| 1 | No installation API | ~200 lines reimplemented, second 2 GB copy on disk |
| 4 | Cancel/timeout quarantine | next utterance pastes raw for 1,323 ms |
| 4d | First dictation pays the full open | 3,312 ms of a 4,654 ms first request |
| 7 | No decoder statistics | `spec_accept_rate` absent from every SDK history row |

---

## What already works

Worth saying first, because it is the larger part of the result:

- **Dependency resolution intersects cleanly.** The SDK's `exact:` pins
  (mlx-swift-lm 3.31.4, mlx-swift 0.31.4, swift-tokenizers-mlx 0.3.0,
  swift-tokenizers 0.5.0) sit inside the app's existing ranges, so linking the
  package needed no change to the app's own pins and `scripts/check-package-pins.sh`
  still passes. **measured** — the app builds against both graphs at once.
- **The guards are byte-identical.** `Sources/CleanupCore/CleanupLogic.swift`
  and `Pomvox/Sources/Engine/CleanupLogic.swift` differ only in access modifiers
  at this commit — same prompt bytes, same thresholds, same regexes. **measured**
  (`diff` ignoring `public`).
- **The SDK's own suite reproduces.** 99 tests × Debug/Release/TSan/ASan, 9
  installer tests, 20 lifecycle repeats, all green on this machine. **measured**
- **Its real-model differential reproduces too**, network-denied: 15 model tests,
  zero skips, all 24 fixtures byte-identical across library / greedy / cached
  speculative / uncached speculative, 184 accepted draft tokens per speculative
  mode. Medians 713 / 818 / 525 / 1471 ms — slightly faster than the SDK's own
  recorded run (762 / 889 / 554 / 1555 ms). **measured**
- **It cleans correctly inside the app.** The app's own 24-case behaviour corpus
  run through the SDK backend: 23 accepted, 1 refused by the guards, no
  regressions against the expectations the in-app engine is held to — and the
  one case marked a known v3 gap (chained triple self-correction) now passes.
  **measured** (`SDKBackendE2ETests.testCorpusThroughTheSDKBackend`)
- **A dictation racing the open still gets cleaned**, because the adapter
  re-implements the in-app engine's wait-and-credit. Worth stating because the
  SDK alone would have pasted raw. **measured**
- **It reproduces the engine it was extracted from, on real dictation.** 424
  transcripts — the app's 24 behaviour cases plus 400 taken from a real
  `history.db` — through both engines in one process, one after the other:
  **423 byte-identical**. The single difference is not a fidelity divergence:
  on the fourth-longest transcript (2,053 characters) the *in-app* engine hit
  its 60 s deadline and pasted raw while the SDK completed the cleanup. The
  surrounding log shows the machine degraded at that moment (decode 9.1 tok/s
  and prefill 32 tok/s, against 20–40 and ~200 in the same run), so this reads
  as machine state rather than an engine difference. **Re-running that exact
  transcript through both engines confirmed it: 25/25 identical, the two engines
  agreeing on it exactly.** **measured** (no transcript text left the machine;
  the corpus is not in the repository)

---

## On-device evidence (2026-09-19)

The app ran on the SDK backend on a real Mac, with a real microphone, a real
two-word dictionary (`pomvox`, `abhi`) and real dictation. Seven utterances:
**six cleaned, one guard-rejected.** Everything below is from that session's
`history.db` rows and `log show` output, not from a harness.

    engine   status    cleanup   prefill   decode   cached
    SDK      ok          4654*      1185      286        0     * includes 3312 ms cold open
    SDK      ok          1775       1352      360        0
    SDK      ok          1639       1349      230        0
    SDK      ok          1856       1357      417        0
    SDK      rejected    2122          —        —        —
    SDK      ok          2987       1569     1346        0
    in-app   ok          1157        704      431        1     same machine, same dictionary
    in-app   ok          1689        726      941        1

Read the last two rows against the rest. The in-app engine reuses its prefix
(`cached 1`) and prefills in ~700 ms; the SDK reuses nothing (`cached 0`) and
prefills in ~1,350 ms — **every single dictation, on a dictionary of two
words.** That is gap 2, no longer a lab result.

The user's own words after the session were "formatting was not there, it was a
little slow." Both are explained below, and neither is subjective.

---

## Gaps

### 1. No installation path, and the pack duplicates the model on disk

**Severity: high — blocks shipping to users.**

`Cleaner.open` takes a directory that already contains `pack.json` and exactly
the seven pinned artifacts as regular files. What a host actually has is a
Hugging Face snapshot: symlinks into a shared blob store, in a directory the SDK
refuses. The only bridge shipped is `scripts/prepare-local-pack.py`, which a
desktop app cannot run on a user's machine.

So every host must reimplement the installer. This branch did
(`Pomvox/Sources/Engine/CleanupPackInstaller.swift`, ~200 lines including
staging, chunked SHA-256, atomic publish and failure cleanup) and the result is a
**second 2 GB copy** of weights the app already had — 4 GB for one model, on a
16 GB Mac with 17 GB of free disk.

*Suggested fix:* a `PackInstaller` in `CleanupPacks` that takes a source
directory and a destination and does what the Python script does, plus an option
to open a pack whose artifacts are symlinks into a caller-trusted cache (the
threat model for a local HF cache is the same as for the pack directory itself —
both are already "caller-trusted and immutable").

### 2. The vocabulary is rendered outside the cached prefix

**Severity: high — confirmed, and it is the common case, not an edge case.**

The prefix cache is built at `open` from the frozen prompt alone
(`MLXRuntime.buildPrefix`), but the dictionary hint is inserted *between* the
frozen text and the transcript on every request
(`CleanupLogic.buildSimpleWordsMessages`, `MLXRuntime.generate`). If that changes
the token stream inside the cached prefix, every request from a user who has a
dictionary runs uncached and pays a full prefill.

The in-app engine avoids this by baking the hint into the prefix at load and
rebuilding it when the dictionary changes (`CleanupEngine.updateTermsHint`).

The SDK's own differential only asserts that a vocabulary request does not
*poison* the prefix for later requests — not that it can use it.

*Repro:* `SDKProbeTests.testVocabularySizeVersusPrefixCacheReuse` — 0/1/10/64
terms, five requests each, reporting `prefix-cache-not-used` warnings and median
latency.

*Result:* **confirmed, and it is total.** One term is enough to lose the cache:

    terms   prefix reused   median
        0         5 of 5     778 ms
        1         0 of 5   2,667 ms     3.4× slower
       10         0 of 5   2,606 ms
       64         0 of 5   4,031 ms     5.2× slower

Not a partial or occasional miss — **every** request with a nonempty vocabulary
ran uncached and warned `prefix-cache-not-used`. The SDK's own differential
prices the same effect independently: its 24 fixtures run at a 525 ms median
cached and 1,471 ms uncached.

Anyone who has ever added a word to their dictionary pays this on every
dictation, which in Pomvox is most users.

*Suggested fix:* accept the vocabulary at `open` (it is constant for a cleaner's
life in every host that has one) and prefill it into the prefix; or expose
`Cleaner.updateVocabulary` that rebuilds the prefix in the background.

### 3. No eviction API: memory pressure costs a full re-validation

**Severity: high — the app evicts on memory pressure today.**

The SDK's only way to release the model is `close()`, and the only way back is
`Cleaner.open`, which re-hashes all 2 GB of artifacts, reloads the weights,
re-prefills the prefix and re-runs a warmup generation. The in-app engine drops
only the weights and keeps its prefix caches, precisely so a post-eviction
dictation can still make its deadline.

Pomvox evicts on `DispatchSource.memoryPressure` warnings and (on low-memory
Macs) after 300 s idle. Under the SDK backend each of those events costs the next
dictation a full reopen.

*Repro:* `SDKProbeTests.testCloseReopenCycleCost` (five cycles),
`SDKBenchTests.testPostEvictionReloadLatency`.

*Result:* **3,411 / 3,378 / 3,617 / 3,539 / 3,384 ms** over five close→open
cycles — steady, and every one of them re-hashes 2 GB, reloads the weights,
re-prefills the prefix and re-runs a warmup. The in-app engine's equivalent is a
weight read, because it keeps its prefix caches across an eviction.

A close immediately followed by an open does succeed, but only because this
integration waits for the previous cleaner to release the SDK's process-wide
device lease before opening (`SDKCleanupBackend.closing`). Without that wait the
reopen races the lease — which is exactly what a memory-pressure eviction
followed by the next dictation looks like.

*Suggested fix:* `Cleaner.evict()` / `Cleaner.resume()` that keep the validated
pack identity and the prefix tokens, so a resume is a weight load; or let `open`
skip re-hashing a pack whose manifest digest and file identities are unchanged
since this process validated them.

### 4. A cancelled or timed-out request quarantines the cleaner

**Severity: high for dictation — it makes the *next* utterance paste raw.**

`CleanupSession` deliberately refuses to start replacement work while an
abandoned worker is still running: new requests get `.fallback(.unavailable)`,
and queued ones are failed the same way. For a batch API that is correct. For
dictation it means the utterance *after* a cancel — the retry the user just
made because they cancelled — is the one that loses its cleanup.

*Repro:* `SDKProbeTests.testQuarantineWindowAfterCancellation` and
`…AfterDeadline` — cancel/expire a long request, then poll every 100 ms until a
short request succeeds.

*Result:* **measured, and narrower than feared.** The cleaner became usable again
**1,323 ms** after a cancellation and **699 ms** after a deadline expiry. So it
is bounded by the abandoned generation's remaining work, not indefinite — but a
user who cancels and immediately re-dictates still loses that dictation's
cleanup, and nothing in the API lets a host distinguish "briefly quarantined"
from "broken".

*Suggested fix:* document the expected window; and consider letting a host opt
into a second cleaner instance (the process-wide lease currently forbids it) so a
quarantined worker does not take the feature down with it.

### 4b. A rejection tells the host nothing — not why, not what it cost

**Severity: high for anyone improving the model or the corpus.**

The single rejected dictation of the on-device session spent **2,122 ms** and
produced: `.fallback(.rejected)`. That is the whole diagnostic. The result
carries no stage timings (the generation that ran is invisible), no warning, and
above all **no indication of which guard fired**.

`CleanupLogic.acceptOutput` has eleven distinct rejection paths — empty output,
think tags, role prefix, upper length bound, lower length ratio, question
preservation, short-raw word overlap, echo-with-commentary, markdown header,
list-not-invited, list-invents-content. All eleven collapse into one enum case.

For a host that is trying to *improve* the cleanup — which is the whole point of
owning a fine-tune and a corpus — this is the difference between "the list guard
refuses 'shopping cart'" and "something went wrong sometimes". I could not tell
you with certainty which guard rejected that utterance without re-running it and
capturing the model's candidate, and the host has no way to capture it at all.

*Suggested fix:* carry the reason —
`.fallback(.rejected(guard: .listNotInvited))` or a `rejectedBy: String` in
`warnings` — and keep the stage timings on a fallback result. A rejection is the
most expensive outcome there is (full generation, nothing to show); it should be
the best instrumented, not the worst.

*Related host-side bug this exposed:* because a fallback carries neither timings
nor warnings, this integration's `timingNotes()` inferred "prefix cache used"
from an empty warning list and wrote a fabricated `cleanup_cached: 1` into the
history row. Fixed here by only reporting the flag when a generation was
actually observed — but the SDK made the wrong answer the easy one.

### 4c. Spoken-list formatting never survives, and the cue list is too narrow

**Severity: medium — the user noticed this unprompted, as "formatting was not
there".**

Two consecutive dictations in the session, both shopping lists:

- *"Here's the shopping cart: bananas, um, two mangoes, uh, and oranges."*
  → accepted, but as one inline sentence: fillers gone, no list.
- *"Here's the shopping cart, we'll get oranges, bananas, mangoes."*
  → **rejected**, raw pasted.

The cause is `rawInvitesList`: a list is only accepted when the speaker used a
cue word — `list / listing / bullet(s) / bullet point(s) / points / steps /
items / to-do(s)` — or counted at least two enumeration markers. **"cart" is not
a cue.** Verified directly: the same sentence with "shopping list" instead of
"shopping cart" passes the cue test; with "cart" it fails.

So a user who says "shopping cart", "grocery run", "things to pick up", "here's
what I need" gets either an inline sentence or, when the model does format a
list, the raw transcript — the worst of both.

This guard is inherited verbatim from the app, so it is not an SDK regression —
but it now lives in `CleanupCore` and ships to every SDK consumer, which makes
it the SDK's problem to own.

*Suggested fix:* widen the cue set with the obvious shopping/task phrasings, and
— more durably — treat a model that formats a list as evidence the speaker
invited one, gated on `listPreservesContent` (which already proves the items are
the speaker's own words). The current design asks a regex to out-guess a
fine-tune that was trained on exactly this.

### 4d. The first dictation after arming pays the whole open

**Severity: medium.**

The first utterance of the session cost **4,654 ms**, of which **3,312 ms** was
`Cleaner.open` — hash-validating 2 GB, loading weights, prefilling, warming up —
because the dictation arrived before the host's 20-second preload timer fired.
The in-app engine's equivalent cold load is ~2,600 ms and, crucially, it can be
re-entered cheaply afterwards (gap 3).

The host can paper over this with an eager preload, and does. But a 3.3 s open
that must complete before *any* request is served is a hard floor on
"time from launch to useful", and the re-validation is the largest part of it.

*Suggested fix:* the same as gap 3 — let a process that has already validated a
pack reopen it without re-hashing every byte.

### 5. Output is capped at 1,024 tokens although 16,384 bytes are admitted

**Severity: medium — by inspection; the probe that was meant to confirm it
measured something else (below).**

`CleanupRequest.validate()` accepts 16,384 UTF-8 bytes. `MLXRuntime.generate`
caps generation at `max(64, min(2 × inputTokens, 1024))`. Any transcript whose
cleanup needs more than 1,024 output tokens — roughly 3–4k characters — can only
end in `.fallback(.tokenLimit)`, after paying the full generation time first. The
host cannot tell in advance; there is no "this request cannot succeed" signal.

Pomvox's own history has transcripts up to 9,335 characters.

*Repro:* `SDKProbeTests.testLongInputsFindTheTokenCapCliff` — 500 … 8,000 chars.

*Result:* **not reached — the guards refuse first.** At 541 / 1,052 / 2,001 /
4,045 / 8,060 characters of synthetic repeated speech, every result came back
`rejected`, after 1.8 / 2.5 / 3.5 / 5.3 / 9.7 seconds of work. The raw
transcript survived intact each time, which is the contract that matters, but
the probe was built on repetitive text the output guards were always going to
refuse, so it does not establish where the token cap actually bites. The cap is
still there in the source; finding its edge needs a long *non*-repetitive
fixture. Re-run before filing this one.

What the run does show is the cost of failing: nearly ten seconds spent on an
8,000-character transcript that could only ever paste raw.

*Suggested fix:* either raise the cap with the input, or reject over-long
requests at `validate()` so the host can skip straight to its fallback instead of
burning the deadline. The app already has this logic (`CleanupDeadline.isHopeless`).

### 6. Vocabulary limits are far below a real dictionary

**Severity: medium.**

≤64 terms, ≤128 bytes each, ≤2,048 bytes total, no newlines — and exceeding any
of them throws `invalidRequest`, costing that dictation its cleanup entirely
rather than degrading. A user dictionary is unbounded; this branch trims to fit
and logs what it dropped (`SDKCleanupBackend.bounded`).

*Suggested fix:* document the limits as *the host's* responsibility explicitly
(they are currently only in a table), or truncate with a warning in
`CleanupResult.warnings` rather than throwing.

### 7. No load/warmup split and no decoder statistics

**Severity: low — observability, not behaviour.**

`Cleaner.preparationMS` is one number covering hash validation, weight load,
prefix prefill and warmup, so a host cannot attribute a slow cold start. Per
request, `CleanupGenStats` (prompt/decode token counts, speculative accept rate,
rounds) is internal, so the `spec_accept_rate` and token counts Pomvox writes into
`history.timings_json` simply disappear under the SDK backend — the exact
telemetry that made the speculative-decoding work measurable.

*Suggested fix:* break `preparationMS` into validation/load/prefix/warmup, and
surface token counts and speculative statistics on `CleanupTimings` (or a
`CleanupResult.diagnostics`).

### 8. `Memory.clearCache()` runs before every request

**Severity: low, but it is a process-global side effect.**

`MLXRuntime.generate` drops the whole MLX buffer pool on every call. In Pomvox
that pool is shared with nothing today (STT is CoreML/ANE), but any host that
runs a second MLX workload pays for it, and the SDK documents no such effect.

*Suggested fix:* make it a policy on the runtime factory rather than
unconditional.

### 9. `Runtime/MLX` cannot be consumed remotely

**Severity: medium for adoption.**

`Runtime/MLX/Package.swift` depends on the package root by relative path
(`.package(name: "PomvoxCleanup", path: "../..")`). SwiftPM refuses path
dependencies inside a remote package, so the only way to use the MLX runtime is a
local checkout or submodule — which is what this branch does, and which is why
the app's CI cannot build this branch while the repo is private.

*Suggested fix:* publish the MLX runtime as a target of the root package behind a
trait, or as its own repository depending on a tagged root version.

### 10. Two copies of the guards with nothing pinning them together

**Severity: medium — latent.**

The SDK's `CleanupLogic` and the app's are byte-identical today (verified). The
manifest labels the rules `pomvox-guards-v0.2.8`, but nothing checks that label
against the code on either side, and the app still runs its own `acceptOutput`
over the SDK's already-guarded output. The first divergence will be silent: two
guard passes with different thresholds, where the stricter one wins and nobody
notices which.

*Suggested fix:* expose the guard version as a value (`CleanupLogic.rulesVersion`)
that the pack manifest is validated against, so a host can assert the two agree.

### 11. Style and speculative-decoding settings are silently inert

**Severity: low.**

`[cleanup] style` and `[cleanup] speculative` are real user-facing settings in
Pomvox. Under the SDK they do nothing: the frozen prompt has no style control (the
SDK throws `.incompatible` if you even pass a setting), and the decoder mode is
internal. The host has to decide between lying to the user and removing controls.

*Suggested fix:* a capability query on `ValidatedPack` — which settings this pack
honours — so a host can hide what does not apply.

### 12. No auxiliary-generation API (dictionary variant suggestions)

**Severity: low, but it forces a second model copy.**

Pomvox's dictionary page asks the model for likely mishearings of a term
(`CleanupEngine.suggestVariants`). The SDK exposes only `clean` on the frozen
prompt. This branch keeps the in-app engine alive purely for that feature, which
means a user who opens the dictionary page loads a *second* 2 GB model — and
cannot, because the SDK holds a process-wide lease on the device.

*Suggested fix:* either a general `generate(prompt:)` escape hatch on the runtime,
or drop the lease to one-model-per-*cleaner* rather than per process.

---

## Measurements

| Measurement | in-app | SDK | Source |
| --- | --- | --- | --- |
| Byte parity, 24 behaviour cases + 400 real transcripts | reference | **423/424 identical**; the 424th agreed on rerun | `SDKBackendE2ETests` + private corpus |
| Warm median / p95, 15 requests | pending | 688 ms / 1,896 ms | `CleanupBenchTests` / `SDKBenchTests` |
| Cold prepare | pending | ~3.0–5.2 s | `SDKBackendE2ETests`, `SDKProbeTests` |
| Close→open cycle | keeps prefix | 3,378–3,617 ms | `SDKProbeTests` |
| Dictionary: 0 vs 1 term | prefix rebuilt at load | 778 → 2,667 ms | `SDKProbeTests` |
| Dictionary delta, independent run | — | 614 → 2,059 ms (cached 5/5 → 0/5) | `SDKBenchTests` |
| Post-eviction reload + first request | — | 3,171 ms + 463 ms | `SDKBenchTests` |
| Quarantine after cancel / deadline | n/a | 1,323 ms / 699 ms | `SDKProbeTests` |
| 200-request soak | — | p50 723 ms, p95 1,868 ms, 192/200 cleaned, RSS 3,214 → 3,086 MB | `SDKProbeTests` |
| 4 concurrent requests | — | 3 cleaned, 1 refused (busy) | `SDKProbeTests` |
| Pack refusals (stray file / corrupt byte / incomplete) | — | all three correctly refused | `SDKProbeTests` |

The soak is the reassuring one: two hundred warm requests with no leak (resident
size ended *below* where it started) and no degradation. The eight refusals are
the guards doing their job on deliberately hard fixtures, not failures.
