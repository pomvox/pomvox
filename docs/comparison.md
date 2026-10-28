# Who Pomvox is for

Dated 2026-10-27. Every row below was checked against the shipped build,
v0.2.9 (released 2026-09-27), and the source behind it. When the build
changes, this page changes with it; if the date is old, trust the
[README](../README.md) and [CHANGELOG](../CHANGELOG.md) over this table.

Pomvox is a narrow tool on purpose: hold a key, speak, release, and the words
land in whatever text field is focused, with nothing leaving the Mac. This
page says what it does and does not do so you can decide in a minute.

## Capability table

| Capability | Pomvox |
|---|---|
| Platform | Apple Silicon Mac, macOS 14 or later. Reference machine: M1, 16 GB. |
| Where speech-to-text runs | On-device, on the Apple Neural Engine (FluidAudio, Parakeet TDT 0.6B v2). |
| Where cleanup runs | On-device, on the GPU via MLX. Optional; on by default on 16 GB+ Macs with SimpleWords v3, a compact Qwen3-1.7B-4bit on 8 GB Macs. |
| Offline / local | Yes. Audio and transcripts never leave the Mac. Three network calls exist: the one-time model download from Hugging Face; a once-a-day update check (on by default, off in Settings → General); anonymous, content-free usage stats (on by default, off in Settings → Privacy). See [PRIVACY.md](../PRIVACY.md). |
| Push-to-talk | Yes. Hold `Fn`, speak, release. |
| Hands-free | Yes. `Fn+Space` starts; it stops on a natural pause, on `Fn+Space` again, or on a tap of `Fn`. `Esc` cancels. |
| Custom dictionary | Yes. Words the cleanup model should spell your way, plus misheard-term fixup rules that apply even with cleanup off. Edits hot-apply to a running engine. Import and export as `.txt` / `.csv`. |
| History | Local SQLite at `~/.pomvox/history.db`, transcripts only, never audio. Rows auto-delete after 7 days by default; `0` keeps nothing; `enabled = false` writes nothing. |
| Languages | English out of the box (Parakeet v2). A multilingual Parakeet v3 is one setting away (`[stt] model`), with lower English accuracy. |
| File transcription | No. Microphone input only. Tracked as [#124](https://github.com/pomvox/pomvox/issues/124). |
| Meeting capture / speaker diarization | No. A stated non-goal in [SPEC.md](../SPEC.md#out-of-scope-documented-not-built). |
| Voice commands | No, by design (see below). Spoken layout cues ("new line", "new paragraph", "bullet") become formatting inside the transcript; nothing you say controls the app or the Mac. |
| In-app updates | Yes. Sparkle 2, EdDSA-signed appcast, Apple notarization checked on every download. Installs only when you click **Update**. |
| License | MIT. Downloaded models and bundled libraries keep their own licenses ([THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)). |
| Distribution | Notarized `Pomvox.dmg` on [GitHub Releases](https://github.com/pomvox/pomvox/releases/latest), or `brew install --cask pomvox/pomvox/pomvox`. |

## Pomvox is probably not for you if…

- Your Mac is not Apple Silicon, or runs a macOS older than 14.
- You need Linux or Windows. There is no port and none planned.
- You want to control your Mac by voice. Pomvox inserts text; it does not run
  commands.
- You need to know who said what. There is no speaker diarization and no
  meeting capture.
- You need to transcribe existing audio or video files. Pomvox listens to the
  microphone only ([#124](https://github.com/pomvox/pomvox/issues/124)).
- You dictate in a language other than English and want that to work without
  changing a setting.

## Why no voice commands

A command grammar would sit on top of a cleanup model that already rewrites
short utterances, and short utterances are exactly what commands are. The
known short-rewrite defect, where "Go ahead." came back as "Okay.", is caught
today by an output guard that pastes your raw words instead; with commands in
the loop the same misfire would run an action rather than paste a word. Voice
commands are not planned.

## Not compared yet

This page describes Pomvox only. Pomvox has no third-party accuracy or latency
comparison, and the project rule is no comparative claims without one.
Per-model word error rate is tracked in
[#125](https://github.com/pomvox/pomvox/issues/125) and the benchmarks page in
[#121](https://github.com/pomvox/pomvox/issues/121); until both land, nothing
here says how Pomvox stacks up against any other product.
