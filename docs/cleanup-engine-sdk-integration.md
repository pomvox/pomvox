# Cleanup engine SDK integration

Pomvox can run dictation cleanup through the external
[`pomvox-cleanup-engine`](https://github.com/pomvox/pomvox-cleanup-engine) SDK
instead of the in-app `CleanupEngine`. `[cleanup] backend = "sdk"` (the default on
this branch) selects it; `"inapp"` restores the engine that shipped through v0.2.8.
The backend applies on save, like the other `[cleanup]` keys: a change while
armed closes the old backend's model before the new one prepares. Both backends
download through one shared, detached Hugging Face fetch per repo, so disarm or
a memory-pressure eviction mid-download never cancels the transfer.

The SDK owns model loading, the frozen prompt, the prefix cache, speculative
decoding, admission, quarantine and output guards. The app keeps audio/STT, UI,
spoken formatting, the dictionary, the signature, history, the clipboard and
insertion.

This is a developer-preview integration, not a release. See
[Release gates still open](#release-gates-still-open).

## SDK checkout

The SDK is consumed as the `vendor/pomvox-cleanup-engine` submodule through Xcode
(`Runtime/MLX` as a local package in `Pomvox/project.yml`), so MLX's Metal
resources are packaged into the app. Remote SwiftPM is **not** supported: the MLX
runtime depends on its package root by relative path.

The host needs `PackInstaller`, `PackSource.validated`, `Cleaner.closeAndWait()`
and `RuntimeFactory.mlx(vocabulary:)`. **No SDK commit contains them yet** —
`00bd4d8`, the submodule pin, does not. Development uses the SDK's updated
*working tree*, uncommitted, byte-identical to the maintainer's checkout (69 files
compared by SHA-256; 14 modified, 11 untracked, including `PackInstaller.swift`).
The submodule pointer stays at `00bd4d8` and shows as dirty. Pin a containing
commit once one exists; do not substitute an older revision — it will not compile.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Pomvox && xcodegen generate && cd ..
xcodebuild build-for-testing -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -derivedDataPath /tmp/pomvox-sdk-dd -clonedSourcePackagesDirPath /tmp/pomvox-spm \
  -destination 'platform=macOS'
```

Keep the working copy, derived data and package clones off iCloud Drive: SwiftPM's
`git status` over an evicted checkout hangs at "Resolve Package Graph".

## Architecture

| Piece | File | Role |
| --- | --- | --- |
| `SDKPackProvisioner` | `Engine/SDKPackProvisioner.swift` | Trusted manifest (bundled, SHA-256-pinned), install location, explicit snapshot acquisition, `PackInstaller` off-actor |
| `SDKCleanupHost` | `Engine/SDKCleanupHost.swift` | Serialized state machine: one shared preparation, one cleaner, retirement, eviction, quarantine wait, per-utterance request |
| `SDKVocabulary`, `CleanupBudget`, `AsyncLatch`, `CleanupMemoryPolicy` | `Engine/SDKCleanupSupport.swift` | Bounded vocabulary, one fixed budget per utterance, cancellable deadline-bounded waits, reopen policy |
| `UtteranceSessions`, `deliverUtterance`, `runSDKCleanup` | `Engine/UtteranceDelivery.swift` | Session identity, the host pipeline applied once with the final currency check |
| `MLXBufferPool` | `Engine/MLXBufferPool.swift` | Clears MLX's buffer pool once after a cleaner's resources are released |
| `CleanupControls` | `Engine/CleanupBackendKind.swift` | Which controls the running backend honours |

### Installation and trust

Trust comes only from `Resources/simplewords-v3.pack.json`, a verbatim copy of the
SDK's `packs/simplewords-v3/pack.json`, checked against
`SDKPackProvisioner.bundledManifestSHA256`. Snapshot-provided manifest bytes are
never used (a `pack.json` planted in the snapshot is ignored).

The pack installs once into
`~/Library/Application Support/Pomvox/CleanupPacks/<id>-<version>-<digest12>/`
via `PackInstaller.install(snapshot:manifestData:destination:)` on a detached task.
The installer resolves the Hugging Face snapshot's symlinks and publishes
independent regular files; on APFS they are clones, so the 2 GB weights are not
stored twice. An existing directory is reused only if its `pack.json` equals the
trusted bytes, and is then fully validated on open; a different one is refused and
left untouched (surfaced as a configuration problem). Nothing is overwritten. The
installer's `ValidatedPack` is passed as `.validated(pack)` to the first open.
After every open the host checks `cleaner.pack.digest` against the trusted digest.

The pre-existing `~/.pomvox/packs/simplewords-v3` from the earlier branch is no
longer read; it can be deleted.

### Preparation, sessions, cancellation

- Preparation starts at arm when cleanup is enabled (no 20 s timer), and after an
  eviction only when an utterance needs cleanup and `CleanupMemoryPolicy` permits.
  It is one unstructured task; callers wait on its `AsyncLatch`, cancellably and
  within their budget, so cancelling one utterance never cancels preparation.
- Every utterance gets a `UtteranceSessions` id. Sleep, disarm and quit retire it
  and cancel its task. `deliverUtterance` checks cancellation and the id before and
  after spoken formatting → dictionary → signature, then inserts synchronously on
  the main actor. `CancellationError` is never turned into a raw insertion.
- Disabling or evicting bumps an epoch; a preparation finishing into a stale epoch
  closes its cleaner instead of publishing it.
- The budget is fixed once per utterance (the existing length-scaled
  `CleanupDeadline.effectiveTimeoutS`) and never extended — the old post-eviction
  reload credit is gone. Each request gets the remaining budget capped at 60 s; with
  nothing left the request is skipped.
- Transcripts over 16,384 UTF-8 bytes keep the whole original (`unsupportedLength`).
  No truncation, no chunking, never a cloud fallback (`PomvoxCleanupCloud` is not
  linked).

### Eviction and reopen

Memory pressure and idle eviction stop admission and retire the cleaner with
`closeAndWait()` in an untracked-by-callers but host-tracked task; the next opener
waits for it. Idle eviction is refused while a request is in flight. The pack
handle (`cleaner.pack`) is kept and reused as `.validated(savedPack)`; if file
identities changed the host provisions and validates the directory afresh. A reopen
still reloads the weights and warms the prefix. The handle never outlives the
process.

After release the host calls `Memory.clearCache()` once (the in-app engine already
did this on unload). Without it the process footprint stays ~2.4 GB after close —
measured below. The SDK's per-generation `clearBufferCache: true` is not used.

### Quarantine

Before a request the host reads `await cleaner.availability`. If quarantined it
polls for up to 1.5 s within the utterance's remaining budget, then makes one
attempt or falls back. It never opens a second model to bypass quarantine.

### Results, metrics, controls

- `cleaned`/`unchanged` use `result.text`; every fallback keeps the original
  byte-for-byte. The app's own `acceptOutput` pass is not run on SDK results.
- History keeps the app's four statuses; the SDK reason is a content-free
  `sdk_fallback_<reason>` / `sdk_rejected_<reason>` / `sdk_configuration_failure`
  key in `timings_json`. Observed metrics only: nil SDK fields are omitted,
  `cleanup_cached` comes from `prefixCacheUsed`, speculative acceptance only when
  drafted > 0, preparation wait separate from request total.
- Setup failures (manifest, pack, compatibility, invalid request) are a
  configuration problem shown in Settings ▸ General ▸ Cleanup; runtime failures
  fall back silently to the original transcript.
- Under the SDK the pack advertises `["vocabulary"]` only: the Style control is
  replaced by "Fixed", `[cleanup] style`/`speculative` are logged as ignored, and
  the dictionary editor's model-generated variant suggestions are disabled (no
  second model). Settings shows the pack and `CleanupLogic.rulesVersion`.
- Vocabulary: dictionary words in order, ≤64 terms, ≤128 bytes each, ≤2,048 bytes
  total, no line breaks, deduplicated by exact UTF-8 (Swift `==` is canonical and
  would merge "é" forms). Omissions are logged as counts. The selection is sent on
  every request; the replacement rules still use the whole dictionary.

The output ceiling stays 1,024 tokens and the conservative list guards remain:
this does not fix arbitrarily long dictations or implicit list formatting.

## Tests

```sh
base="xcodebuild test -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -derivedDataPath /tmp/pomvox-sdk-dd -clonedSourcePackagesDirPath /tmp/pomvox-spm -destination platform=macOS"

$base -only-testing:PomvoxTests/SDKCleanupHostTests          # no model; real SDK lifecycle, fake runtime

TEST_RUNNER_POMVOX_SDK_REAL=1 TEST_RUNNER_POMVOX_SDK_REAL_OUT=/tmp/sdk-real.jsonl \
TEST_RUNNER_POMVOX_SDK_REAL_WAVS=/tmp/wavs \
  $base -only-testing:PomvoxTests/SDKHostRealModelTests     # real pack, temp install root

TEST_RUNNER_POMVOX_SCREENSHOT_DIR=/tmp/shots \
  $base -only-testing:PomvoxTests/CleanupControlsScreenshotTests
```

`SDKCleanupHostTests` runs the SDK's real `Cleaner`, `CleanupSession`,
`PackInstaller` and `PackLoader` against a tiny valid pack and a fake runtime that
emulates the device lease. The soak's WAVs can be synthesized with
`say -o u01.wav --data-format=LEI16@16000 "…"`; keep real transcripts and history
out of the repository.

## Measured results (2026-09-23)

M1, 16 GB, macOS 15.6, Debug test build, the installed Pomvox idle (~106 MB, no model
resident). One run each; diagnostic observations, not a controlled benchmark.
Transcripts in the long-input and soak runs are synthetic.

| What | Result |
| --- | --- |
| Cold install + open (clone + hash 2 GB + load + prefix + warmup) | 3.7 s and 5.8 s (two runs) |
| Open existing installation (full validation) | 2.8–4.1 s |
| Reopen after eviction (`.validated` handle) | 1.63–1.78 s; first request after it 0.37–0.40 s, cache used |
| Warm cleanup, 5 sentences × 3, p50 total | 0 terms 483 ms · 1 term 532 ms · 2 terms 482 ms · 64 terms 495 ms; cache used 15/15 each |
| First request after a dictionary change (single prefix rebuild) | 0: 548 ms · 1: 1,398 ms · 2: 1,366 ms · 64: 2,266 ms |
| Public corpus (`CleanupE2ETests.cases`, 24) | 22 cleaned, 1 unchanged ("already clean"), 1 rejected (`rejectedBy:lowerLengthRatio`, "near-empty filler", expected); 0 unexpected |
| Long, non-repetitive input under the app budget policy | 615 B 3.8 s · 1.2 KB 8.4 s · 2.4 KB 17.8 s cleaned; 4.8 KB 18.0 s cleaned **but output 1,917 of 4,807 bytes**; 9.6/15/17 KB → `hostCeiling`, original kept whole |
| Soak: 40 sessions, cleanup overlapping real Parakeet STT on synthesized speech, every 9th cancelled | 36 inserted, 4 suppressed, 0 stale inserts, 1 open, p50 cleanup 423 ms, p50 STT 160 ms, availability `ready` at end |
| Footprint after `closeAndWait()` | SDK default: stays ~2.4 GB. With the host's post-release `Memory.clearCache()`: 1.4–1.9 GB |
| Footprint across the real-model suite in one process | without the clear it had grown to ~8.9 GB; with it the soak ran at 2.5–2.8 GB |

The 4.8 KB case is a real problem: the guards accepted output that dropped ~60% of
the input's bytes (405 decode tokens, below the 1,024-token ceiling). Long
dictations are not safe to clean with this baseline yet.

## Release gates still open

See the PR description for measured results. Still owed before any release:
an SDK commit containing these APIs (then re-pin), a live-microphone dictation
pass and soak in the running app, real memory-pressure and sleep/wake on device,
the private-corpus quality comparison, and CI (which cannot build this until the
submodule points at a pushed commit containing the APIs).
