# Changelog

All notable changes to Pomvox are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.4] — 2026-08-10

### Changed

- **The native engine now arms on first launch instead of requiring an
  explicit opt-in.** New installs get Pomvox's native Swift dictation engine
  by default — hold Fn, speak, release, and the transcript pastes on-device.
  Existing installs that already have `[engine] native` set in `config.toml`
  are unaffected either way; only the fallback for a fresh config changed.
  The frozen Python engine remains available as a fallback and is unaffected
  by this change.

## [0.2.3] — 2026-08-04

### Performance

- **Cleanup is about 2.5× faster — roughly 1.5 s down to 0.6 s per dictation.**
  Before writing a word, the model had to read its ~256-token instruction sheet,
  and it re-read the whole thing from scratch on every single dictation even
  though the text never changes. That reading was ~1.09 s of a measured 1.48 s.
  Pomvox now reads it once when cleanup starts up and reuses the result, so each
  dictation only processes what you actually said. Measured end-to-end through
  the real dictation path on an M1: p50 1.48 s → 0.58 s.

  This was previously believed impossible for this model. Its layers are of two
  kinds, and the older code assumed one kind — it asked a layer that structurally
  cannot count tokens how many it had seen, and it built the saved state with a
  tool that overshoots by a token in a way that kind of layer can't undo. Reading
  without that overshoot, and asking every layer instead of the first, fixes
  both. Verified by running the same transcripts with and without reuse and
  requiring character-for-character identical output.

### Changed

- **The cleanup model is now SimpleWords v3, which understands corrections you
  make in a *later* sentence.** Saying "Let's meet Thursday. No, no, wait, we'll
  meet Friday." now pastes "Let's meet Friday." Previously the correction only
  registered inside a single sentence ("tuesday wait no friday at noon") — start
  a new sentence and the superseded day survived, so you got the wrong day
  pasted silently. Measured on the model author's held-out sets: cross-sentence
  corrections 122/122 (was 15/77), must-not-correct negatives 30/30 (was 25/30),
  real human disfluency 231/300 (was 27/300). The previous model is still
  published if you pin it in `config.toml`.

  One known trade, documented on the model card: a *chained triple* correction
  in lowercase unpunctuated form ("red one no the blue one actually the green
  one") now comes back unchanged. It could not be fixed alongside the
  cross-sentence cases that were causing real mispastes.

### Fixed

- **A correction that shortened your sentence a lot could paste the raw,
  disfluent text.** Cleanup rejects suspiciously short output as over-trimming,
  but a self-correction legitimately deletes the whole superseded clause — so
  the correct "Let's meet Friday." was thrown out for being too short while the
  *wrong* "Let's meet Thursday." squeaked past. The length floor now recognizes
  spoken correction markers ("wait", "no, no", "scratch that", "I mean", …) and
  allows the larger cut on exactly those utterances. Ordinary speech is
  unaffected: a bare "no" ("There's no rush.") deliberately does not qualify.

## [0.2.2] — 2026-07-30

### Changed

- **Cleanup now runs a model trained specifically for dictation cleanup.** On
  16 GB+ Macs the default cleanup model moved from the general-purpose
  Qwen3-4B to
  [`abhiram3040/simplewords-dictation-cleanup-v2`](https://huggingface.co/abhiram3040/simplewords-dictation-cleanup-v2),
  a fine-tune that ships its own frozen prompt alongside its weights. Machines
  with 8 GB or less keep the compact general model, and any Hugging Face model
  id remains valid in `[cleanup] model`.

## [0.2.1] — 2026-07-29

### Fixed

- **Spoken lists now actually format — including numbered ones.** Saying
  "here's a list of to dos, one… two… three…" now comes out as a numbered
  list (`1.` `2.` `3.`), and announcing a list ("we have a shopping list and
  I'll get…") formats it as bullets — both previously pasted as run-on prose.
  Plain speech without a list cue still never gets bulleted.
- **Dictating *about* Pomvox can no longer confuse the cleanup into
  answering.** A dictation that talked about transcripts, rules, and lists
  flipped the model into assistant mode — it pasted the text back wrapped in
  an "Analysis" instead of cleaning it. New guards reject any output that
  echoes the input with commentary, contains markdown headers, or runs away
  past the generation cap; all of them fall back to your exact words.
- **The first dictation right after launching now gets cleaned too.** On a
  cold launch the first dictation waited ~13 seconds behind prompt prefills
  for the wrong style and then pasted raw. The engine now prefills the style
  you actually use first, and background prefills yield the GPU to a
  dictation in progress — the first post-launch dictation cleans in ~10
  seconds, inside the on-device budget.
- **Pasting into a slow app can no longer insert your previous copy instead
  of the dictation.** The transcript briefly sits on the clipboard for the
  synthesized ⌘V, and the old clipboard used to come back on a fixed 0.5-second
  timer — an app that was still busy when the timer fired (mid-launch,
  heavy Electron window) would paste the *restored previous clipboard* rather
  than what you said. The restore is now keyed to consumption: Pomvox can tell
  when the paste has actually read the transcript, restores on the usual
  timeline when it has, and otherwise holds the transcript for up to 3 seconds
  before giving the clipboard back. It never restores earlier than before, and
  a real copy you make in between still wins.

- **Dictating no longer eats a copied image, file, or formatted text.** The
  paste briefly borrows the clipboard for the transcript and then puts your
  copy back — but the restore only saved plain text, so a copied screenshot
  or file was permanently replaced by the transcript, and rich text came back
  stripped of its formatting. The restore now snapshots and puts back every
  item and flavor on the clipboard.

- **Dictating after a break gets cleaned text again.** The cleanup model is
  evicted after 5 idle minutes to give back its ~2.3 GB of memory, but the
  next dictation only *started* the reload and pasted the raw transcript
  without waiting for it — on one machine, 16 of 60 dictations (every single
  one after a >5-minute pause) pasted raw this way, which also made spoken
  list commands appear broken. Cleanup now waits out an in-flight reload
  within the utterance's existing timeout, and the prompt's prefilled prefix
  caches (~100 MB) survive eviction, so the wait is the ~1-second weight
  reload instead of a ~10-second re-prefill: a post-break dictation cleans in
  under 3 seconds, inside even the default 5-second budget. The
  never-lose-words fallback is unchanged — it's just no longer taken
  prematurely.

- **Cleanup can no longer swap your words for its own.** On-device history
  showed the cleanup model occasionally *answering* a dictated question
  ("Should I test manually one by one?" pasted as "Yes, test manually one by
  one.") or substituting a short phrase wholesale ("Go ahead." pasted as
  "Okay."). New output guards reject any cleanup that turns a spoken question
  into a non-question, shares no words with a short utterance, or bullets text
  that never asked for a list — rejected cleanups fall back to the raw
  transcript, so nothing is ever lost. New few-shot examples also teach the
  model to leave questions and short phrases as spoken, and to derive a
  dictated list's header from what was said instead of parroting the prompt's
  example ("Things to pack:" no longer shows up on your shopping list).

## [0.2.0] — 2026-07-16

### Added

- **In-app updates — one click instead of uninstall/reinstall.** Pomvox now
  checks GitHub once a day (at launch + every 24 h) for new versions — a plain
  anonymous fetch of a public `appcast.xml`; nothing about you is sent. When
  an update exists, a quiet banner appears on Home (Update / Later / Skip
  this version, with a release-notes link) — never a popup. Updates install
  **only when you click Update**: the download is EdDSA-signature-verified and
  Apple-notarization-checked *before extraction*, the app swaps itself in
  place and relaunches (waiting out any in-flight dictation), and because the
  update is signed by the same Developer ID, your microphone / Input
  Monitoring / Accessibility grants survive — no re-granting. Settings ▸
  General gains the "Automatically check for updates" toggle (on by default,
  disclosed in the README), a visible "last checked" time, and **Check Now**.
  Powered by Sparkle 2, fully headless. Installs of v0.1.10 and earlier need
  one final manual download of this release; updates flow in-app from here on.

- **Dictionary v2: a real editor for words and misheard-term fixups.** A new
  **Dictionary** page in the Hub replaces the old config-file-only workflow:
  words the cleanup model should spell your way, plus many-to-one fixup rules
  ("pom box" → "Pomvox") with per-rule enable/disable and hit counts, a live
  test box that shows exactly what your rules do to any text, variant
  suggestions when you add a rule, and a banner (with line number) if you
  hand-edit `dictionary.toml` into something invalid. Rules always apply, even
  with cleanup off, and both words and rules hot-apply to an already-armed
  engine — no restart. Add a rule straight from **History**'s "Fix this…" on a
  mistake, or from anywhere with a configurable quick-add hotkey (`[hotkey]
  quick_add`, e.g. `cmd+shift+d`; off by default). Words and rules import/export as plain `.txt` /
  `.csv` from the Dictionary page. Existing `config.toml` `[dictionary]`
  entries are auto-migrated into the new `~/.pomvox/dictionary.toml` on first
  launch.

- **Say "make a list" and your items come out as bullet points.** When you
  explicitly ask for a list while dictating — with phrases like "make a list of",
  "list down", "give me a list of", "here's a list", or "bullet points" —
  cleanup now formats the items that follow as a bulleted list, one `- ` item
  per line, instead of a run-on sentence. The rule applies in both the light and
  polish cleanup styles, and (per the local-first rule) falls back to your raw
  words if cleanup is off or fails.

### Changed

- **The default speech model is English-only again (`parakeet-tdt-0.6b-v2`).**
  The multilingual v3 that had become the default transcribes English
  noticeably less accurately; v2 is back as the shipped default and the
  fallback for unrecognized `[stt] model` values. The multilingual v3 stays
  one setting away (Settings ▸ Models). If you never set `stt.model`, the v2
  weights (~1.2 GB) download on the next arm; an explicitly configured model
  is left alone.

- **Cleanup is now more conservative — it leans toward leaving your words as
  spoken.** The cleanup system prompt was rewritten around an explicit
  "when in doubt, under-clean" principle: filler words are removed only when
  they're true disfluencies (so "like" survives in "it works like a charm"),
  the model must not summarize/shorten/expand or reorder/reformat your content,
  and it no longer guesses at possible mishearings or homophones. Spoken
  self-corrections are resolved only when the follow-up clearly *replaces*
  something in the same slot ("Tuesday wait no Friday" → "Friday"); a phrase
  that *adds or narrows* is kept ("send it Tuesday, I mean before noon" keeps
  both), and "actually" used for emphasis is left alone. The prompt stays
  byte-for-byte identical across the Python and Swift engines.

### Fixed

- **Dictation no longer intermittently pastes the text you copied earlier.** The
  synthesized ⌘V is asynchronous — the target app reads the clipboard only when
  it gets around to handling the keystroke — but Pomvox restored your prior
  clipboard just 0.15 s later. A busy or slow-to-focus app (launching, Electron,
  system under load) could still be mid-paste when that restore fired, so it read
  the restored clipboard and pasted your previously-copied text instead of the
  transcript. The restore now waits long enough to outlast a slow paste; it's off
  the paste latency path and the change-count guard still lets a real copy win, so
  your clipboard is preserved as before.

- **Quitting Pomvox now fully shuts it down.** "Quit Pomvox" (and ⌘Q) went
  straight to `NSApp.terminate`, which never ran the engine's teardown — so a
  quit could leave the lock file (`~/.pomvox/engine.pid`) on disk, the global
  hotkey tap still installed, and the HUD pill on screen until macOS happened to
  reap the process. Because Pomvox lives in the menu bar, it also doesn't appear
  in the Force Quit window, so a lingering instance was hard to kill. Quit now
  releases the hotkey tap, the mic, the HUD, and the lock file synchronously
  (matching the Python engine's exit cleanup), without disturbing your "arm on
  launch" preference — so quit, Force Quit, and the HUD stay in sync.

## [0.1.10] — 2026-07-12

### Added

- **The first dictation no longer looks frozen while the model warms up.** The
  very first dictation after the engine turns on pays a one-time model spin-up
  cost, during which the HUD used to sit on a static "finishing…". It now shows a
  subtle shimmering placeholder so the wait reads as "working", replaced by your
  real text the moment it's ready. Every later dictation in the session is
  already warm and shows the plain label. (#71)

- **Cleanup now picks a model size that fits your Mac, and asks before skipping
  it.** A fresh install defaults the cleanup model to a size that fits comfortably
  in memory — the compact Qwen3-1.7B on Macs with ≤ 8 GB of RAM, Qwen3-4B on
  16 GB+ (the 8B preset is still available, just never auto-selected). And on a
  low-memory Mac, instead of silently leaving cleanup off (as in 0.1.9), the Hub
  now shows a one-time prompt explaining the memory tradeoff so you can turn it on
  if you want it, rather than wondering why the feature is missing. (#70)

- **Your first dictation is warmed up during setup, not on first use.** On a
  fresh install the models are now warmed the first time the engine arms — while
  you're still reading the Setup screen — by running a throwaway pass through
  both the speech and cleanup models. That moves the one-time cold-start cost off
  your very first real dictation, so it feels fast instead of slow. Later
  launches keep the lazy behavior. (#69)

- **The cleanup model no longer sits in memory when you're not using it.** The
  ~2.3 GB cleanup LLM used to load at launch and stay resident. Now the small,
  always-used speech model loads eagerly while the cleanup model loads lazily —
  on your first dictation or a short delay after launch, whichever comes first —
  so app startup isn't blocked. It's also evicted after ~5 minutes idle and
  reloaded on next use, so bursty, occasional use doesn't cost ~2.3 GB of
  resident memory around the clock. Both timings are configurable
  (`[cleanup] preload_delay_s` / `idle_evict_s`). (#68)

- **Cold-start latency is now instrumented.** The first dictation after launch
  can feel slow, and it was never clear which stage dominated. The native engine
  now measures the four cold-start stages separately — STT weight load, CoreML
  compile/load, Neural Engine warmup, and cleanup-LLM load — and logs a
  breakdown. It also verifies the CoreML compile cache actually persists across
  launches (the ~37 s compile should happen once, not every launch): each load
  logs whether a compiled `.mlmodelc` was already on disk and whether it changed
  since the previous launch. When usage stats are enabled, an anonymous,
  content-free `cold_start` event carries the numeric per-stage timings and the
  cache hit/miss (telemetry schema v2). (#67)

### Fixed

- **The "Words dictated" number no longer shrinks over time.** The Home
  dashboard's totals were summed from the rows currently in your history, so the
  7-day retention purge (and any manual delete) quietly erased them — a rolling
  window labeled like a lifetime total. Lifetime counts are now stored
  separately: deleting history never rewrites the past, and the cards honestly
  say "all-time on this Mac". Pre-upgrade databases seed the counters from the
  surviving rows (the best on-disk truth). (#76)

## [0.1.9] — 2026-07-09

### Added

- **Low-memory Macs now work out of the box.** On a fresh install on a Mac with
  ≤ 8 GB of RAM, the native engine defaults transcript cleanup off — raw
  on-device dictation (~600 MB) instead of the ~2.5 GB armed+cleanup cost that
  would swap on an 8 GB machine. The choice is written to your config and can be
  turned on any time in Settings ▸ Models. Existing configs and machines with
  more memory are unaffected. (#65)

### Fixed

- **The `[stt] model` setting did nothing.** The native engine always loaded the
  v3 speech model regardless of the configured value. It now honors the setting
  (v2 or v3), and falls back to v3 (with a log line) for an unrecognized value,
  so a typo never stops the engine from arming. Settings ▸ Models now notes that
  the native engine supports Parakeet v2/v3 (other ids fall back to v3). (#64)

## [0.1.8] — 2026-07-07

### Fixed

- **The dictation hotkey was locked to Fn.** Changing the push-to-talk key in
  Settings ▸ Hotkeys had no effect — the native engine ignored the `[hotkey]`
  configuration entirely, leaving no workaround for keyboards that handle Fn in
  hardware. The engine now honors the configured key, and degrades safely back
  to the Fn defaults (with a log line) if the configuration is invalid, so
  dictation never breaks. (#61)

- **Dictation looked broken when your Dictionary rules removed every word.** If
  your replacement rules deleted all of the recognized text, the app pasted
  nothing and gave no hint why — indistinguishable from not being heard. It now
  flashes "your replacement rules removed every word — check Settings ▸
  Dictionary" instead of failing silently. Long HUD messages also wrap to two
  lines instead of being truncated. (#62)

## [0.1.7] — 2026-07-06

### Fixed

- **Dictation could die silently after deep sleep.** A long sleep could leave
  the microphone engine delivering a dead (all-zero) stream — recordings
  captured audio but transcribed to nothing, with no explanation. The audio
  engine is now rebuilt after sleep and whenever the input device
  configuration changes. (#60)

- **Fresh installs had a silent dead zone during the first-run download.**
  The dictation hotkey only became active after the ~460 MB speech-model
  download, so pressing Fn right after installing did nothing at all. The
  hotkey now works immediately: a press during the download shows
  "not ready yet — downloading NN%" on the HUD. (#60)

- **A hotkey press racing engine startup could corrupt the engine state.**
  Stop/cancel/hands-free events arriving before the engine was ready could
  flip it to "ready" mid-download or fake a transcription cycle; every
  terminal transition is now status-guarded. A wake during the download can
  no longer strand a dead hotkey tap or crash on the next keypress. (#60)

### Added

- **Every "nothing happened" now explains itself.** The HUD logs its
  show/hide lifecycle and verifies against the window server that the pill
  is actually on screen; empty transcripts are classified (mic captured
  silence vs transcription failure vs genuinely no words) and the two hard
  failures flash the reason on the HUD. (#60)

- **Setup shows a live hotkey heartbeat.** A new row in the Setup checklist
  turns green when Fn actually reaches Pomvox — separating "permission not
  effective until relaunch" and "this keyboard handles Fn in hardware" from
  everything else. (#60)

- **`scripts/verify-hud.sh`** — an end-to-end check that synthesizes an Fn
  press and asks the window server whether the HUD pill really appeared. (#60)

## [0.1.6] — 2026-07-05

### Added

- **First-run model downloads now show progress.** The first time the native
  engine turns on it fetches a ~460 MB speech model (and, in the background, a
  larger cleanup model). Until now the menu bar just read a static
  "Preparing…", so the first use looked like a hang. It now shows a live
  "Downloading the speech model… NN%" in the menu bar and Settings, and a
  background note while the cleanup model finishes.

- **First launch guides you to Setup.** Pomvox needs Microphone, Input
  Monitoring, and Accessibility before it can do anything, but a fresh install
  opened to an empty dashboard with no hint. The Hub now opens straight to the
  Setup checklist whenever a grant is still missing, the menu bar offers
  "Finish setup — grant permissions…", and the sidebar flags the Setup row.

### Fixed

- **A Mac with no microphone got the wrong advice.** A capture failure always
  suggested granting Microphone permission — useless on a machine with no input
  device at all. Pomvox now tells those apart and shows "No microphone found —
  connect one and try again." when no device is present.

## [0.1.5] — 2026-07-05

### Fixed

- **Home greeting showed a hardcoded name.** The Hub's greeting had the
  maintainer's first name baked in, so every install read "Good morning, Abhi."
  It now uses the Mac account's own name (`NSFullUserName`), falling back to a
  name-less greeting when the account has no full name set.

## [0.1.4] — 2026-07-05

### Changed

- **Telemetry is now an explicit first-run choice, not on-by-default.** On first
  launch Pomvox shows a screen with two equal-weight buttons — **Share anonymous
  stats** / **No thanks** — with no pre-selected default. Nothing is sent (or even
  queued) unless you choose to share; the choice is stored as a tri-state
  (`granted` / `denied` / `undecided`) and is changeable anytime in Settings →
  Privacy. Existing installs from 0.1.3 (which defaulted on) are reset to
  undecided and shown the choice screen. Supersedes the 0.1.3 opt-out behavior.

## [0.1.3] — 2026-07-05

### Changed

- **Anonymous usage stats are now on by default (opt-out).** Previously opt-in.
  They remain anonymous and content-free (a random install ID plus counters —
  never audio, transcripts, or any free text), and **nothing is sent until the
  first-run disclosure has been shown** (the `maySend` gate). The disclosure has
  an equal-weight one-tap **Turn off**, and you can turn it off anytime in
  Settings → Privacy. Docs and the in-app copy updated to match.

## [0.1.2] — 2026-07-05

### Fixed

- **Dictation hotkey dead after a long sleep.** The 0.1.1 fix handled short
  sleeps but not deep sleep/standby: macOS stops delivering events to the global
  event tap even though it still reports "enabled", so re-enabling it wasn't
  enough — the hotkey stayed dead (no HUD, no dictation) until the app was
  restarted. Pomvox now **rebuilds the event tap from scratch on wake** (on both
  `didWake` and `screensDidWake`, after a short settle), which is the only
  reliable recovery. Verified on-device.

## [0.1.1] — 2026-07-04

### Fixed

- **Stuck recording across system sleep/wake.** After the Mac slept and woke,
  the microphone could stay "recording" with no HUD, recoverable only by
  restarting the app. macOS disables the global event tap across sleep and the
  push-to-talk key-up that stops recording could be dropped, stranding the
  hotkey state machine. Pomvox now resets to a clean armed-idle state around
  sleep/wake (stopping any live capture and hiding the HUD) and re-asserts the
  event tap on wake.

## [0.1.0] — 2026-07-03

First public release. A fully local, privacy-first voice-dictation app for macOS
on Apple Silicon, shipping as a signed, notarized `Pomvox.dmg`.

### Added

- **Native SwiftUI menu-bar app** (`Pomvox.app`) — runs from the menu bar, can
  launch at login, and arms the dictation hotkey with zero clicks.
- **On-device speech-to-text** on the Neural Engine (parakeet-tdt-0.6b-v3 via
  FluidAudio) — voice and transcripts never leave the machine.
- **Optional local cleanup pass** — a small LLM runs on the GPU (mlx-swift) to
  fix fillers and punctuation (`light`) or smooth rambles (`polish`); on timeout
  the raw transcript is inserted, so words are never lost.
- **Push-to-talk and hands-free** dictation — hold `Fn` to talk, or `Fn+Space`
  for hands-free with auto-stop on a natural pause; `Esc` cancels.
- **Live two-tone HUD** — settled words bright, newest chunk dimmed, then a
  "finishing…" state during cleanup.
- **The Hub window** — Home (words / dictations / WPM stats and a 30-day activity
  strip), History (raw vs. cleaned, search, copy / re-insert / delete), Settings
  (models, hotkeys, cleanup, HUD, launch-at-login), and a Setup walkthrough for
  the three permissions with a live insertion self-test.
- **Local, transcripts-only history** at `~/.pomvox/history.db` — audio is never
  stored; rows auto-delete after a configurable retention window.
- **Comment-preserving TOML config** at `~/.pomvox/config.toml` — models,
  hotkeys, cleanup, and history are all configurable; anything model-shaped is a
  config value, never a constant.
- **Opt-in, anonymous, content-free telemetry** — off by default, with a one-time
  in-app prompt and a Privacy pane that spells out exactly what's sent. It can
  never carry audio, transcripts, or free text.
- **Custom dictionary** — user-defined words and misheard-term fixups.
- **Signed & notarized distribution** — Developer ID signing, hardened runtime,
  and Apple notarization; the `Pomvox.dmg` opens with no right-click bypass.
- **App icon** — an ember waveform on an espresso background.
- **Python reference engine** (`src/pomvox/`) — the original app, now frozen as a
  runnable reference whose pure-logic modules are the cross-checked test spec.

[Unreleased]: https://github.com/abhiram304/pomvox/compare/v0.2.3...HEAD
[0.2.3]: https://github.com/abhiram304/pomvox/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/abhiram304/pomvox/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/abhiram304/pomvox/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/abhiram304/pomvox/compare/v0.1.10...v0.2.0
[0.1.10]: https://github.com/abhiram304/pomvox/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/abhiram304/pomvox/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/abhiram304/pomvox/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/abhiram304/pomvox/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/abhiram304/pomvox/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/abhiram304/pomvox/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/abhiram304/pomvox/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/abhiram304/pomvox/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/abhiram304/pomvox/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/abhiram304/pomvox/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/abhiram304/pomvox/releases/tag/v0.1.0
