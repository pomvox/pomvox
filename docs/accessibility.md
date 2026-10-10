# Speech accessibility

Pomvox's optional cleanup is on-device, model-dependent text processing after
speech recognition. For someone who stutters or stammers, repeats words, or uses
spoken self-corrections, it may make recognized text easier to read. It does not
change how speech is recognized, guarantee that words are captured, or guarantee
correction of disfluency. Review important text before using it.

## What cleanup can help with

The [README](../README.md#configuration) and [v0.2.3 changelog](../CHANGELOG.md)
illustrate SimpleWords v3 handling a correction across sentences:

> Let's meet Thursday. No, no, wait, we'll meet Friday.

The documented cleaned result is:

> Let's meet Friday.

This is an illustration from the project's documentation, not a new measurement
or a promised result for your speech. Cleanup receives the recognized
transcript, not an opportunity to recover everything the recognizer missed.
Repetitions or correction markers may remain, and a model may change text
incorrectly.

## Choose existing cleanup settings

In the Hub, open Settings → General for the cleanup switch and timeout, and
Settings → Models to choose the cleanup model. The same settings live under
`[cleanup]` in `~/.pomvox/config.toml`: `enabled`, `model`, and `timeout_s`
control whether cleanup runs, the selected model, and its deadline. See the
[configuration example](../config.example.toml) before editing individual keys;
its Python reference-engine defaults are not identical to the native app's
defaults.

The native app defaults to SimpleWords v3 on 16 GB+ Macs. Low-memory Macs
instead default to the compact `mlx-community/Qwen3-1.7B-4bit` model. With no
explicit enabled setting, cleanup stays off on a low-memory Mac until its
one-time prompt has been answered. Explicit configuration overrides these
defaults; an existing choice is not automatically replaced. Compact-model
behavior should not be inferred from the SimpleWords example.

Unless `[cleanup] backend` is explicitly set, the native SDK backend is selected
for its supported SimpleWords v3 model; other models use the in-app backend. The
existing `style` settings apply to the in-app backend and are ignored by the
SDK. There is no separate stutter or stammer mode to enable.

## Fallback is different from cancellation

- **Disabled:** recognition proceeds without model cleanup.
- **Timeout:** cleanup falls back to the recognized transcript rather than waiting indefinitely.
- **Unavailable model:** a model still being prepared, or a setup problem, can leave cleanup unavailable; the recognized transcript is used.
- **Rejected output:** when cleanup output fails acceptance guards, the recognized transcript is retained at the cleanup boundary.
- **Cancellation:** cancelling an utterance discards its pending output; nothing is inserted. This is not a raw-text fallback.

Fallback preserves recognized words at the cleanup boundary, not necessarily the
exact final text. Spoken layout commands and dictionary replacement rules can
still transform it, including when cleanup is disabled. An enabled dictation
mark is added afterward.

## Read historical results in context

The v0.2.3 changelog reported a SimpleWords v3 gap for the lowercase,
unpunctuated chained correction “red one no the blue one actually the green
one”: it remained unchanged. The later [SDK integration
report](cleanup-engine-sdk-gaps.md) records that the corresponding
chained-triple fixture passed through the SDK backend. Neither report
establishes universal behavior for chained corrections or speech differences.

## Review and recover with History

Open Hub → History, search for the dictation, and compare the raw and final
text. Use copy to recover available text, or re-insert it into your destination
field. History is local text, not audio, and availability depends on retention
and whether history was enabled.

For re-insertion, focus the intended field during the countdown and keep it
focused while waiting. Without Accessibility permission, Pomvox offers copy-only
recovery: switch to your app and press ⌘V. A changed or unverifiable destination
can also result in copied text. A “Paste attempted” banner is not destination
acknowledgement: check the field before pasting again to avoid duplicates.
Review the recovered wording too; History does not establish that recognition or
cleanup was correct.
