# Pomvox architecture

This documents the system **as implemented**. [SPEC.md](SPEC.md) is the product
spec and phased roadmap; when they disagree about the future, SPEC wins — when
they disagree about the present, this file wins.

Guiding constraints, in priority order:

1. **Local-first.** Your voice and transcripts never leave the machine. The only
   network calls are the one-time model download from Hugging Face and, when the
   user opts in, anonymous content-free usage stats (off by default, native app
   only — `Telemetry.swift`; the Python engine makes no network calls at all).
2. **Latency is a feature.** Hotkey-release → inserted text is a real-time
   budget, instrumented per stage on every utterance.
3. **Degrade gracefully.** Any failure in a quality stage (cleanup) falls back
   to the previous stage's output. Text may arrive uncleaned; it must never
   arrive late-forever or not at all. The HUD and history are best-effort and
   can never block or break dictation.
4. **Open-source first.** Anything model-shaped is a config value
   (`~/.pomvox/config.toml`), not a constant. Users swap STT and cleanup models
   to trade speed for quality on their hardware.

## Two implementations, one contract

Pomvox exists twice in this repo:

- **`Pomvox.app`** (`Pomvox/`, Swift + SwiftUI) — the daily driver. A menu-bar
  app that is both the dictation **engine** and the **Hub** (history, settings,
  setup) in one process.
- **The Python engine** (`src/pomvox/`) — the original app, now frozen as a
  runnable reference. Its **pure-logic** modules (the state machines, endpoint
  detector, history store, onboarding flow, config schema, cleanup prompt/guard)
  are Linux-tested and are the **spec**: each was ported to Swift vector-for-
  vector, and the Python tests still gate the Swift behavior in CI.

The two share two files as their only contract — no IPC:

- `~/.pomvox/config.toml` — comment-preserving TOML; both read it, the Hub
  writes only UI-owned keys.
- `~/.pomvox/history.db` — WAL sqlite, `PRAGMA user_version = 1`. Schema changes
  require touching both sides in one PR (the contract is frozen at v1).

Only one engine runs at a time. A pidfile (`~/.pomvox/engine.pid`, line 1 = pid,
line 2 = owner) enforces mutual exclusion, so there is always a single writer to
`history.db` and a single owner of the event tap.

## Native pipeline (`Pomvox/Sources/Engine/`)

```
[Fn or mouse4/5 held / Fn+Space]          EventTap (CGEventTap, flagsChanged + side buttons)
   │                                       → HotkeyMachine (pure, unit-tested)
   ▼
[Mic capture] ── 16 kHz mono Float ──►     AudioCapture (AVAudioEngine)
   │                 │                       │ ~1 s cadence
   │                 │                       ▼
   │                 │                 [live re-transcribe] ──► HUD two-tone draft
   ▼                 ▼
[release / VAD pause / Esc]          [STT finalize]            Transcriber
                                       FluidAudio Parakeet TDT v3 on the
                                       Neural Engine (ANE)
                                             │  raw transcript
                                             ▼
                                     [LLM cleanup]             CleanupEngine
                                       mlx-swift Qwen3-4B-4bit on the GPU,
                                       deadline + guards, raw-text fallback
                                             │  cleaned (or raw) text
                                             ▼
                                     [Insertion]               Paster
                                       NSPasteboard (ConcealedType) + ⌘V
                                             │
                                             ▼
                                     [History write]           HistoryStore
                                       single INSERT off the latency path
```

**The ANE/GPU split is the architectural win.** STT runs on the Neural Engine
and the cleanup LLM on the GPU, so the two never contend — the GPU-buffer-pool
juggling the Python engine needed (both stages shared the GPU) is gone. The live
draft is incremental re-transcription on a ~1 s cadence (a full ANE re-transcribe
is ~0.13–0.27 s, faster than the old chunked stream), gated so it never overlaps
the finalize pass.

`HotkeyMachine` (pure, unit-tested) holds the authoritative
`IDLE → RECORDING(ptt|toggle) → TRANSCRIBING → IDLE` state; `NativeEngine`
reacts to its decisions.

## App shape: menu-bar first

`PomvoxApp` is a `MenuBarExtra` + a single `Window` (the Hub), wired through an
`AppDelegate`:

- **Launch posture.** A login-item launch (detected via the
  `kAEOpenApplication` / `keyAELaunchedAsLogInItem` Apple Event) comes up
  menu-bar-only — no window. A Finder/Dock launch shows the Hub. The Dock icon
  is dynamic: present while the Hub window is open (`.regular`), gone when it
  closes (`.accessory`).
- **Auto-arm.** When `[engine] native` is enabled, the engine arms at launch via
  a **silent, non-prompting** path: it gates on non-prompting permission probes
  (`AVCaptureDevice.authorizationStatus`, `AXIsProcessTrusted`,
  `IOHIDCheckAccess`) and, if a grant is missing, degrades to a menu-bar
  "needs attention" badge routing to Setup — never a dialog storm at login. The
  interactive toggle (Settings / menu bar) keeps the prompting path.
- **Launch at login** is `SMAppService.mainApp` (its status is the source of
  truth; no config key), toggled in Settings → General.

The `MenuBarExtra` uses the static `.menu` style (zero timers) so the resident
footprint stays under budget (~40 MB idle, engine off).

## Concurrency model

`NativeEngine` is a `@MainActor` object. Resource ownership:

| context | owns | notes |
|---|---|---|
| event-tap thread | `HotkeyMachine` | serialized by a lock; posts actions to the main actor |
| audio callback | mic blocks | posts level/VAD via the thread-safe `HudBus`; one main-actor hop for auto-stop |
| main actor | HUD, AppKit, `@Published` state, arm/disarm | the only place that touches AppKit/SwiftUI |
| detached `Task` | finalize transcribe → cleanup → paste → history | runs off the main actor; the paste hops back to the main actor |

All UI flows through one spine (`HudBus`, a port of `uibus.py`): producers on any
thread call `post` (a per-event latest-wins mailbox + at most one main-thread
wake-up per burst); only the main thread drains and renders. The first failure
in the render path can never reach the dictation path — posting is decoupled
from rendering.

## STT stage (`Transcriber.swift`)

FluidAudio runs Parakeet TDT 0.6b v3 as CoreML on the Neural Engine. First-ever
load does a one-time ~37 s ANE compile; thereafter the model stays resident for
fast re-arm and ~0.3 s warm calls. Stop-to-final is roughly one transcribe of the
buffered audio — measured at or better than the Python `bench.py` gate
([docs/native-swift-path.md](docs/native-swift-path.md), Result 3).

## Cleanup stage (`CleanupEngine.swift` + `CleanupLogic.swift`)

Split like the Python original:

- **Pure logic** (`CleanupLogic`) — `buildMessages` (system rules + few-shot,
  `light`/`polish`), `acceptOutput` (guards: empty, `<think>` leakage, role
  prefixes, length ratios), `runCleanup` (fallback wrapper → `(text, status)`).
  Vector-parity tested against `cleanup.py`.
- **`CleanupEngine`** — owns the mlx-swift model; loads + warms in the background
  on arm so arm→ready never waits on the ~2.3 GB LLM.

Design rule: **never block, never trust.** Every failure path — deadline,
exception, model not loaded yet, suspicious output — returns the raw transcript.
A watchdog `TaskGroup` (`timeout_s + 2 s`) ensures even a hung Metal kernel can't
hold the paste hostage. Statuses (`ok | timeout | rejected | error`) are recorded
per utterance.

**Prefix KV cache** is required on the base M1 (not an optimization): GPU prefill
is only ~130 tok/s, so the ~330-token static prefix would cost ~2.6 s uncached.
mlx-swift's cache primitives map 1:1 to Python mlx-lm (`newCache` ≙
`make_prompt_cache`, copy ≙ deepcopy, trim ≙ `trim_prompt_cache`); Swift and
Python tokenizers discover identical prefixes. The prefix (system + few-shot) is
prefilled once per style at warmup and copied per call; only the user's words are
prefilled per utterance.

## Latency budget (measured, M1 16 GB)

```
path                       typical      notes
─────────────────────────  ───────────  ───────────────────────────────
raw (cleanup off)          < 300 ms     STT finalize + paste
cleaned (cleanup on)       ~1.4–2.5 s   + Qwen3 polish on the GPU
warm arm (toggle / login)  ~0.6 s       model resident
first build's model load   ~37 s        one-time ANE compile
─────────────────────────  ───────────  ───────────────────────────────
idle footprint (engine off)  ~40 MB
armed + cleanup LLM loaded   ~2.5 GB (peak ~3.4 GB)
```

Per-utterance log lines (`bench:`, `cleanup: gen`) and the `timings_json` column
in history carry the live numbers; trust them over this table.

## History (`HistoryStore.swift`)

A faithful port of `history.py`: same schema, WAL, `user_version = 1`, 0600 file,
retention/search math. The engine writes one row per dictation **strictly off the
latency path** — after the paste and the ready-state flip, on the now-idle
finalize task: `ts`, raw + final text, cleanup status, `app_hint` (frontmost app
at paste), `duration_s`, and `timings_json`. An insert-time purge mirrors Python;
a launch-time purge covers a native-only user whose engine seldom inserts. The
Hub reads the same file through a separate read-only connection and refreshes on
a post-insert notification. Every store error is log-and-continue — history must
never cost a word.

## Permissions & code identity

The engine needs Microphone, Input Monitoring, and Accessibility. macOS keys
those TCC grants to the app's **code identity**, so `Pomvox.app` is built with a
stable self-signed "Murmur Dev" certificate (`scripts/dev-signing-cert.sh`) —
grants then survive rebuilds. Input Monitoring and Accessibility only take effect
after a relaunch (a running process is denied at launch), which is why the Setup
checklist surfaces a relaunch note. A Developer ID + notarized pipeline is the
next milestone.

## Pure-logic ports (the spec)

Each engine stage splits Linux-testable pure logic from a thin platform shell,
and the Python tests are the source of truth the Swift ports are measured
against: `HotkeyMachine`, `EndpointDetector`/`LevelHistory`, `HudStateMachine` +
`splitStablePrefix`, `OnboardingFlow`, `HistoryStore`, the config schema, and the
cleanup prompt/guard. The `Pomvox/Tests` XCTest suites reproduce
`tests/test_*.py` vector-for-vector; `uv run pytest` and `xcodebuild test` both
gate every change.

## Custom dictionary (SPEC Phase 4)

Implemented in **both engines** (`src/pomvox/dictionary.py`,
`Pomvox/Sources/Engine/PomvoxDictionary.swift`), pure-logic and vector-parity
tested against `tests/test_dictionary.py`. Two config-driven (`[dictionary]`)
mechanisms:

- **`words`** — proper nouns / jargon injected as one extra rule into the
  cleanup system prompt so the LLM spells them the user's way. It is constant
  for the engine's lifetime, so it rides inside the cached prompt prefix and
  costs nothing per utterance (changing it is re-arm/restart-required). The
  Swift and Python prompt hints are byte-identical, so the cached prefix the two
  engines build matches.
- **`replacements`** — literal misheard→correct fixups (whole-word,
  case-insensitive, longest-key-first) applied to the final text just before
  insertion. Because it runs *after* cleanup, a name comes out right whether
  cleanup polished the text, fell back to raw, timed out, or is off — the
  never-lose-words contract holds. (`ConfigDocument` grows read-only
  `stringArray` / `stringTable` helpers for `words` and the
  `[dictionary.replacements]` sub-table; the scalar write path is unchanged.)

## Stubs (planned phases)

`context.py` (per-app tone profiles) is a docstring-only placeholder for the
rest of SPEC Phase 4 — the seam exists so the pipeline shape doesn't change
when it lands.
