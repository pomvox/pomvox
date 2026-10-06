# Pomvox privacy policy

Effective: September 11, 2026.

Pomvox is dictation that stays on your Mac. This page is the short version of
what that means, based on what the app actually does.

## What never leaves this Mac

Your microphone audio, raw transcripts, and cleaned text never leave this Mac.
Speech-to-text and the optional cleanup model both run on-device. There is no
account, no cloud workspace, and no field in any network payload that can carry
audio or text.

## What is stored locally

Pomvox writes only to your disk:

- **Dictation history** — SQLite at `~/.pomvox/history.db`. Transcripts only;
  audio is never stored. Rows auto-delete after `[history] retention_days`
  (default **7**). `0` keeps nothing; `enabled = false` writes nothing.
  Delete one row or all of them from **History**, or erase everything from
  **Settings → Privacy → Erase all history**. You can also delete the file
  itself.
- **Settings** — `~/.pomvox/config.toml`. Edit it in Settings or in a text
  editor; delete the file to start over.

Also on this Mac, not sent anywhere: `~/.pomvox/dictionary.toml` (your
dictionary words and fixup rules), an optional log at `~/.pomvox/pomvox.log`,
downloaded models under `~/.cache/huggingface/hub`, the installed cleanup pack
under `~/Library/Application Support/Pomvox/CleanupPacks` (copy-on-write
clones of those downloaded weights), and (if you opted in)
an anonymous install ID in macOS UserDefaults. Erasing history leaves settings
and models in place.

## Network calls

The native app makes three kinds of network request. None of them include
audio or transcripts.

1. **Hugging Face model downloads** — on first use of a speech or cleanup
   model (and again if you switch models). Bytes land in
   `~/.cache/huggingface/hub` and then run locally.
2. **Sparkle update check** — once a day, an anonymous fetch of the public
   `appcast.xml` from GitHub
   (`https://raw.githubusercontent.com/pomvox/pomvox/main/appcast.xml`).
   On by default. Turn it off in **Settings → General**. Updates install only
   when you click **Update**; that download also comes from GitHub Releases
   and must pass EdDSA signature verification and Apple notarization before
   anything is trusted.
3. **Anonymous usage stats** — on by default, and only after a one-time
   notice on Home has told you. Turn it off in **Settings → Privacy**. See
   below.

The Python reference engine has no telemetry and no updater. Loading its
speech or cleanup model still talks to Hugging Face if the weights are not
already cached.

Hugging Face, GitHub, and the stats service may see your IP address when
those requests happen. That is how HTTPS works; Pomvox does not send a name,
email, or account with them.

## Anonymous usage stats

Anonymous usage stats are on by default. Nothing is sent, or even queued,
until a one-time banner on Home has shown you: "Pomvox sends anonymous usage
stats. Nothing you say. Turn off in Settings → Privacy." If you upgraded from a
version that asked and you never answered, you see the same banner once before
anything sends. Turn stats off anytime in **Settings → Privacy**; a `maySend`
gate then stops all sending immediately, and anything still queued is dropped.
If you turned it off in an earlier version, that choice is kept and you are
never shown the banner.

Stats are on by default everywhere, including the EU, UK and EEA. The random
install ID is a persistent identifier, which GDPR can treat as personal data,
and EU ePrivacy rules generally expect consent before non-essential analytics.
We have decided to accept that risk at Pomvox's current scale, on the strength
of a payload that has no field for content, the notice before the first send,
and a one-click off switch. If installs grow or anyone raises a complaint, the
named fallback is to make stats ask first in the EU, UK and EEA, keyed on your
Mac's region setting.

While on, events go to Pomvox's own ingest service on Google Cloud Run:
`https://murmur-ingest-w5tvsus5ia-uc.a.run.app`. There is no third-party
analytics SDK. Events are queued as they happen (launch, a finished
dictation, and similar) and flushed about two seconds later, in batches.

Each POST is JSON with:

- `schema_version`
- `install_id` — a random UUID, generated once per install, not tied to you
- `app_version`
- `os_version`
- `arch`
- `events` — each event has `event`, `ts` (epoch milliseconds), and optional
  `props`

`event` is one of: `app_launch`, `dictation_completed`, `cleanup_used`,
`cold_start`, `error`, `setting_changed`, `dictionary_edited`.

`props` can only hold these fields (and only some events set them):

- `duration_ms`
- `stt_model` — model basename only (`parakeet-tdt-0.6b-v2`, never a path)
- `cleanup` — true/false
- `cleanup_status` — `ok`, `timeout`, `rejected`, `error`, or `off`
- `error_code` — a short enum token, never a message or stack trace
- `stt_weight_load_ms`, `coreml_compile_ms`, `ane_warmup_ms`,
  `cleanup_load_ms`, `coreml_cache_hit`
- `dictionary_fired` — a count of rules that fired, not the words

There is no free-text field. The encoder in
[`Telemetry.swift`](Pomvox/Sources/Telemetry.swift) is the source of truth.

## What we don't do

No accounts. No ads. No selling or sharing your data. The stats payload, unless
you turn it off, is the only usage data Pomvox ever sends, and it cannot carry
your voice or your words.

## Contact

Questions about this policy: <maanasavamsi09@gmail.com>.
