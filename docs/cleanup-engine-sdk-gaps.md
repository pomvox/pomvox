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

*Status: measurements land here as the campaign runs. Entries marked **measured**
have numbers behind them; entries marked **by inspection** are read from the
source and still need their probe run.*

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

**Severity: high if confirmed — it is the common case, not an edge case.**

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

*Result:* **pending**

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

*Result:* **pending**

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

*Result:* **pending**

*Suggested fix:* document the expected window; and consider letting a host opt
into a second cleaner instance (the process-wide lease currently forbids it) so a
quarantined worker does not take the feature down with it.

### 5. Output is capped at 1,024 tokens although 16,384 bytes are admitted

**Severity: medium — silent on short dictations, total on long ones.**

`CleanupRequest.validate()` accepts 16,384 UTF-8 bytes. `MLXRuntime.generate`
caps generation at `max(64, min(2 × inputTokens, 1024))`. Any transcript whose
cleanup needs more than 1,024 output tokens — roughly 3–4k characters — can only
end in `.fallback(.tokenLimit)`, after paying the full generation time first. The
host cannot tell in advance; there is no "this request cannot succeed" signal.

Pomvox's own history has transcripts up to 9,335 characters.

*Repro:* `SDKProbeTests.testLongInputsFindTheTokenCapCliff` — 500 … 8,000 chars.

*Result:* **pending**

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
| Byte parity on the E2E corpus | — | pending | `SDKBackendE2ETests` |
| Byte parity on 400 real transcripts | — | pending | `SDKBackendE2ETests` + private corpus |
| Warm p50 / p95 | pending | pending | `CleanupBenchTests` / `SDKBenchTests` |
| Cold prepare | pending | pending | same |
| Post-eviction reload | pending | pending | same |
| Dictionary on/off delta | pending | pending | `SDKBenchTests` |
| 200-request soak | — | pending | `SDKProbeTests` |
