# Contributing to Pomvox

Thanks for helping build local, privacy-first dictation. Start with
[README.md](README.md) (setup), [ARCHITECTURE.md](ARCHITECTURE.md) (how the
pieces fit), and [SPEC.md](SPEC.md) (where the project is going).

## Ground rules

1. **Local-first is the product.** Your voice and transcripts never leave the
   machine — that is non-negotiable. The only network calls are the model
   download from Hugging Face and anonymous, content-free usage stats the user
   explicitly opts into via a first-run choice screen (native app only; the
   Python engine stays no-network) — nothing sends unless they pick "Share" (the
   `maySend` gate = `consent == .granted`). Any new network feature must clear
   that same bar: anonymous, no content, an explicit choice, and clearly
   disclosed in-app.
2. **Models are config, not constants.** Anything model-shaped (STT model,
   cleanup model, prompts' tunables, deadlines) must be reachable from
   `~/.pomvox/config.toml`. Hard-coding a model id outside `config.py`
   defaults will be asked to change in review.
3. **Never lose the user's words.** New pipeline stages must fall back to the
   previous stage's output on any failure, bounded by a deadline. See
   `cleanup.run_cleanup` for the pattern.
4. **Measure before optimizing, on-device.** Latency claims in PRs come with
   numbers from a real Apple Silicon run (the `bench:` and `cleanup: gen` log
   lines, or a script under `scripts/`). The repo's history has several
   examples of plausible optimizations that measurement refuted — keep that
   tradition.

## Development setup

Pomvox is two codebases that share `config.toml` and `history.db`: the native
Swift app (`Pomvox/`, the daily driver) and the Python reference engine
(`src/pomvox/`, whose pure-logic modules are the cross-checked test spec). Build
the app from source per [README → Install](README.md#install-build-from-source).

The Python side drives the spec suite and is runnable as a reference engine:

```sh
uv sync
uv run pytest                        # pure-logic spec suite, runs anywhere (incl. Linux)
uv run python scripts/preflight.py   # macOS only: STT model end-to-end check
uv run pomvox                        # macOS only: the Python reference engine
```

- **Apple Silicon Mac** is required to run either engine and anything touching
  `mlx`/`parakeet-mlx`/`pyobjc` or FluidAudio/mlx-swift.
- **Any platform (including Linux)** can work on pure-logic modules — `config`,
  the `hotkey`/`hud`/`vad` state machines, `bench`, `history`, `onboarding`, and
  the prompt/guard half of `cleanup` — the test suite covers them without mlx
  installed, and the Swift ports are checked against the same vectors.
- Permissions: the native app keys TCC grants to its own code identity (see
  below); under `uv run`, grants attach to your *terminal app* instead.

### Building the native app (Swift)

The app (`Pomvox/`) is a SwiftUI menu-bar app generated with XcodeGen:

```sh
brew install xcodegen                                 # one-time
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer  # not CommandLineTools
cd Pomvox && xcodegen generate                        # after editing project.yml / adding files
xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS'                       # build to /tmp, never iCloud Desktop
```

The native engine (Settings ▸ *Native engine*, on by default) uses the
Microphone, Input Monitoring, and Accessibility TCC permissions. macOS keys those
grants to the app's *code identity*, so the build is signed with a stable, free,
self-signed certificate rather than ad-hoc — otherwise every rebuild resets the
grants. Create it once:

```sh
scripts/dev-signing-cert.sh          # makes the "Murmur Dev" Code Signing cert
```

`project.yml` then signs with `CODE_SIGN_IDENTITY: "Murmur Dev"`. The native and
Python engines never hold the event tap / mic at the same time — a pidfile
(`~/.pomvox/engine.pid`, see `src/pomvox/pidfile.py` and
`Pomvox/Sources/Engine/Pidfile.swift`) enforces it; arming one while the other
runs is refused with a message. Distribution signing (Developer ID +
notarization) is a later milestone.

## Code style

- Match what's there: type hints, dataclasses for config, deferred imports
  for heavy/macOS-only modules, module docstrings that explain threading and
  ownership.
- Pure logic at module level, side-effectful engines in classes — keeps the
  testable surface large on non-Mac machines (`cleanup.py` and `stt.py` are
  the reference split).
- Logging: one `log.info` line per user-visible event, with stage timings.
  No print().

## Tests

- `uv run pytest` must pass; new pure logic gets unit tests next to the
  existing ones in `tests/`.
- mlx-dependent behavior can't run in CI on Linux — cover it with a script
  the reviewer can run on-device, and paste the output in the PR.

## Pull requests

- One concern per PR, smallest reviewable change.
- Conventional commits (`feat:`, `fix:`, `perf:`, `docs:`…), subject ≤ 72
  chars, body explains *why* with measurements where relevant — read a few
  recent commits for the voice.
- PR description: what changed, what you measured (before/after for
  latency/quality claims), how you verified on-device.
- Phases land in order (SPEC §5); don't start a phase before the previous
  one's acceptance criteria pass.

## Good first areas

- The Phase 4 stubs: `context.py` (per-app tone profiles) and `dictionary.py`
  (custom words) — docstring-only seams waiting to be built on both sides.
- Cleanup quality: the few-shot examples and guards in `cleanup.py` /
  `CleanupLogic.swift` are data-driven — failing transcripts make great issues,
  with the raw text and what you expected.
- Latency: speculative decoding for the cleanup model is measured-but-unbuilt
  territory.
