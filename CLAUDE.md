# CLAUDE.md — pomvox/pomvox

Every session, human or agent, starts here. This file is condensed from the
owner's vault (`pomvox/pomvox_obsidian_vault`); the vault wins over this file,
and this file wins over an issue's text. Read `Home.md`, `00 Overview/Repo Map.md`
and the `20 Code Review/` notes there before touching the repo.

## What this repo is

Pomvox is a fully local, privacy-first macOS dictation app: hold Fn, speak,
release, and your cleaned-up words appear in any app, with nothing leaving the Mac.
This repo holds the native Swift app (`Pomvox/`, the daily driver) and the frozen
Python reference engine (`src/pomvox/`), whose pytest suite is the executable spec.

**What it is not: the cleanup engine.** Engine-first rule (pomvox/pomvox#173):
any change to cleanup behaviour (prompts, guards, deadlines, packs, decoding,
post-transforms, pack install) lands in `pomvox/pomvox-cleanup-engine` or
`pomvox/pomvox-cleanup-mlx`, never here. The app adopts it only as a pin bump
titled `chore(cleanup): engine vX.Y.Z`. If an app issue turns out to need engine
behaviour, file it on the engine and stop.

## Build and test

The Swift side needs Apple Silicon and Xcode; the Python spec suite runs
anywhere, including Linux CI. In a cloud session do not attempt the Swift side.

```sh
# Python spec suite — required CI check `python-spec`
uv sync && uv run pytest

# Native app — required CI check `swift-tests`
brew install xcodegen                                             # one-time
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer   # not CommandLineTools
cd Pomvox && xcodegen generate                                    # after editing project.yml or adding files
xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-dd \
  -clonedSourcePackagesDirPath /tmp/pomvox-spm -destination 'platform=macOS'
```

`Pomvox/project.yml` is the source of truth; the `.xcodeproj` is gitignored.
Derived data goes to `/tmp`, never iCloud. CI covers pure logic only: no mic, no
TCC, no models, no HUD on runners. An on-device claim needs on-device evidence
(vault: `20 Code Review/Verification Playbook.md`); "compiles and tests pass" is
not evidence for a TCC bug.

## Invariants that block a PR

Violations are always blocking (vault: `20 Code Review/Review Philosophy.md`).

1. **Never lose words.** Every failure path ends in some text reaching the user:
   cleanup falls back to raw, no-focus paste falls back to clipboard, history and
   telemetry failures are swallowed. A new failure path that can eat a transcript
   is a bug however unlikely.
2. **Never block the latency path.** Under 300 ms key-up to paste (raw) is a
   product constraint. Nothing new goes between key-up and paste; history,
   telemetry and UI updates come after.
3. **Never break local-first.** No network in the dictation path, ever. A new
   network feature meets the CONTRIBUTING bar: anonymous, content-free,
   disclosed, off by default or explicitly consented. A free-text field in a
   telemetry prop is a privacy bug even if nobody writes to it today.
4. **Never steal focus, never brick on config.** The HUD stays non-activating;
   bad config degrades to defaults with a log line, never a crash or a dead hotkey.
5. **Parity with the Python vectors, until #173 lands.** Swift ports match the
   Python vectors; deliberate divergence is stated in the PR and reflected in
   both suites. Prompt bytes to the cleanup LLM never drift between engines.
   #173 retires the cleanup vectors; the rest of the parity suite stays.

Where the bugs actually live: the shells (AppKit controllers, OS-facing shims, the
glue), not the pure `*Logic.swift` state machines. A diff touching
`NativeEngine.swift`, `HudPanel.swift`, `EventTap.swift` or `AudioCapture.swift`
gets triple the scrutiny. "Enabled", "running" or "granted" from an API is a
claim, not a fact. A `try?` on a path a user depends on is a finding. Numbers
over adjectives: measure on the reference machine (M1, 16 GB).

## Areas not to touch

| Area | Status | Why |
|---|---|---|
| `Pomvox/Sources/Engine/CleanupEngine.swift` and siblings: `CleanupLogic`, `SpeculativeDecoder`, `PromptLookupDrafter`, `CleanupGenStats`, `CleanupPromptProfile`, `CleanupBackendKind` | frozen, to be deleted | pomvox/pomvox#173, engine-only cleanup. In-app cleanup bugs are won't-fix here; file against the engine. |
| `src/pomvox/cleanup.py` | frozen | pomvox/pomvox#105: the Python engine has no prompt-profile seam. Its cleanup vectors go when #173 lands. |
| `src/pomvox/` | reference engine, frozen | The executable spec and acceptance oracle. Do not add features or "clean it up" (vault: `10 Architecture/Legacy Python Engine.md`). |
| `PomvoxCleanupMLX` pin in `Pomvox/project.yml` | pinned package | The engine is `pomvox-cleanup-mlx` (which pins `pomvox-cleanup-engine`) as a remote package pinned `exact:`. Change it only as a bump titled `chore(cleanup): engine vX.Y.Z`; `scripts/check-cleanup-pack-manifest.sh` must pass. |
| `~/.pomvox/history.db` schema | frozen at `user_version = 1` | Half of the cross-engine contract; a schema change is a cross-engine migration PR (vault: `Checklist - Config and Settings.md`). |

## Where the lessons are

Something broken weirdly? Search the vault's `60 Lessons/60 Lessons MOC.md` by
symptom before tracing a mechanism. It is grouped as: the HUD saga; the OS revokes
what it grants (event tap after deep sleep, TCC, CoreML warmup, HF snapshot
globs); locks and things that outlive a process (the recycled PID); telemetry and
the numbers we trust; tooling and process (CI red for three weeks, iCloud,
notarization, stacked PR merges); the cleanup-speed work; brand and website.
Then pull the matching `20 Code Review/Checklist -` note for the subsystem:
Audio Path, HUD and Windows, Permissions and TCC, Concurrency, SwiftUI
Performance and A11y, Release and Signing, Config and Settings.

## PR checklist (vault: `Reviewing a Pomvox PR.md` §5)

- CHANGELOG entry for user-visible changes; version bump if this cuts a release
  (the v0.1.7 cut nearly shipped with a stale MARKETING_VERSION).
- Docs that the diff invalidates are fixed in the diff.
- Commit style: conventional commits, 72-char subject at most, GPG-signed.
- Follow-ups discovered during review get filed as issues in the PR thread, not
  silently remembered.

Process rules that go with it: one concern per PR; PRs only, never merge, never
`--delete-branch`, no stacking unless the issue says to; request review from
Abhi; at most two open PRs per repo; no fabricated numbers (a latency, memory,
WER or accuracy figure comes from a command run in this session on stated
hardware, or from the CHANGELOG, with the source named, else "not measured
here"); closing an issue needs Abhi's go.
