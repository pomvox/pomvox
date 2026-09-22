# Cleanup engine SDK integration (branch `feat/cleanup-engine-sdk`)

This branch runs Pomvox's dictation cleanup through the external
[`pomvox-cleanup-engine`](https://github.com/pomvox/pomvox-cleanup-engine) package
instead of the in-app `CleanupEngine`, with a config switch to go back. It exists
to answer the SDK's own open question — *does this work inside the real app?* —
and to produce the gap list in [cleanup-engine-sdk-gaps.md](cleanup-engine-sdk-gaps.md).

Nothing here is a release. The branch is an integration harness.

## Getting the branch to build

The SDK is a submodule, because its MLX runtime depends on its own package root
by relative path (`../..`) and so cannot be consumed as a versioned remote
dependency:

```sh
git submodule update --init            # vendor/pomvox-cleanup-engine at 00bd4d8
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
cd Pomvox && xcodegen generate && cd ..
xcodebuild build -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -derivedDataPath /tmp/pomvox-sdk-dd -clonedSourcePackagesDirPath /tmp/pomvox-spm \
  -destination 'platform=macOS'
```

Keep **both** `-derivedDataPath` and `-clonedSourcePackagesDirPath` outside the
iCloud-synced working copy. SwiftPM runs `git status` over every checkout during
resolution; against `.spm/` on the iCloud Desktop that hangs indefinitely rather
than failing, so a build appears to stall forever at "Resolve Package Graph".

CI needs `submodules: recursive` on its checkout, which this branch adds to the
two jobs that build the app. Without it `xcodegen` rejects the spec outright —
`Invalid local package "PomvoxCleanupMLX"` — because the submodule directory is
empty, which is a clearer failure than the package-resolution error you might
expect. This only works now that `pomvox-cleanup-engine` is public; against a
private submodule the checkout itself fails, and CI would need a deploy key.

## Choosing a backend

`~/.pomvox/config.toml`:

```toml
[cleanup]
backend = "sdk"     # or "inapp" for the engine that shipped through v0.2.8
# pack_dir = "~/.pomvox/packs/simplewords-v3"
```

Restart-required, like every other `[cleanup]` key: the backend is snapshotted at
arm so a config edit cannot swap implementations under an in-flight dictation.
An unrecognized value logs and falls back to `sdk` rather than refusing to arm.

What changes with `backend = "sdk"`:

| | `inapp` | `sdk` |
| --- | --- | --- |
| Generation, prompt, guards | `CleanupEngine` + `CleanupLogic` | the SDK's own copies |
| Model source | HF snapshot, loaded in place | verified pack installed from that snapshot |
| `[cleanup] style` | honoured | ignored (frozen prompt, SDK rejects style settings) |
| `[cleanup] speculative` | honoured | ignored (SDK always speculates on the pinned baseline) |
| Dictionary | baked into the cached prompt prefix | sent per request as `vocabulary`, capped at 64 terms / 2,048 bytes |
| Variant suggestions (dictionary page) | in-app engine | in-app engine (loads a second copy of the model on demand) |
| `history.timings_json` | `cleanup_prefill_ms`, `cleanup_decode_ms`, `cleanup_cached`, `spec_*` | the first three plus `sdk_queue_ms`, `sdk_validation_ms`, `sdk_total_ms`; no token counts |

Everything else — watchdog, deadline widening, raw fallback, eval capture,
history, spoken formatting, dictionary substitution, signature — is unchanged and
runs identically for both backends.

## The pack

The SDK opens a *verified pack*: a flat directory holding `pack.json` and exactly
the seven pinned artifacts as regular files, nothing else. An HF cache snapshot is
not that (symlinks into `blobs/`), so `CleanupPackInstaller` copies and verifies
one on first use into `~/.pomvox/packs/simplewords-v3` (~2 GB, in addition to the
~2 GB snapshot the app already has).

Install it ahead of time with the SDK's own script if you prefer:

```sh
python3 vendor/pomvox-cleanup-engine/scripts/prepare-local-pack.py \
  ~/.cache/huggingface/hub/models--abhiram3040--simplewords-dictation-cleanup-v3/snapshots/<sha> \
  ~/.pomvox/packs/simplewords-v3
```

A stray file in that directory — a `.DS_Store` from opening it in Finder is
enough — makes the SDK refuse the pack. The installer treats such a directory as
incomplete and refuses rather than repairing it in place.

## Running the suites

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
DD=/tmp/pomvox-sdk-dd
base="xcodebuild test -project Pomvox/Pomvox.xcodeproj -scheme Pomvox \
  -derivedDataPath $DD -clonedSourcePackagesDirPath /tmp/pomvox-spm -destination platform=macOS"

# Pure tests (no model). Runs in CI.
$base

# Real model: corpus + in-app/SDK byte differential.
TEST_RUNNER_POMVOX_E2E=1 $base -only-testing:PomvoxTests/SDKBackendE2ETests

# Real model, plus a private corpus of your own transcripts (never committed):
TEST_RUNNER_POMVOX_E2E=1 TEST_RUNNER_POMVOX_PARITY_CORPUS=/tmp/corpus.jsonl \
  $base -only-testing:PomvoxTests/SDKBackendE2ETests/testInAppAndSDKProduceIdenticalText

# Latency, same harness as CleanupBenchTests so the two are comparable.
TEST_RUNNER_POMVOX_LLM_BENCH=1 $base -only-testing:PomvoxTests/SDKBenchTests

# Edge-behaviour probes; their printed output is the gap-report evidence.
TEST_RUNNER_POMVOX_SDK_PROBE=1 $base -only-testing:PomvoxTests/SDKProbeTests
```

`POMVOX_CLEANUP_PACK` overrides the pack location for a single run without
touching config.

The corpus file is JSONL, one `{"raw": "…"}` per line. Keep real transcripts out
of the repository.

### The SDK's own suites

```sh
cd vendor/pomvox-cleanup-engine
python3 scripts/check.py --sanitizers --repeat 20 --build-dir /tmp/sdk-check
xcodegen generate --spec Examples/Consumer/project.yml
xcodebuild -project Examples/Consumer/CleanupConsumer.xcodeproj -scheme Consumer \
  -configuration Debug -derivedDataPath /tmp/sdk-consumer-dd \
  -destination 'platform=macOS,arch=arm64' build-for-testing
POMVOX_TEST_PACK=~/.pomvox/packs/simplewords-v3 \
  sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  xcrun xctest /tmp/sdk-consumer-dd/Build/Products/Debug/ModelTests.xctest
```

## What is deliberately not here

- No CI change. The private submodule would fail resolution.
- No removal of `CleanupEngine`. Deleting it is a follow-up once parity and the
  gaps are settled; until then it is both the fallback and the differential
  reference.
- No cloud transport. `PomvoxCleanupCloud` is not linked; nothing in this branch
  can make a network request for cleanup.
