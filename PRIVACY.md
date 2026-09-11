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
downloaded models under `~/.cache/huggingface/hub`, and (if you opted in)
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
3. **Anonymous usage stats** — only if you choose to share. See below.

The Python reference engine has no telemetry and no updater. Loading its
speech or cleanup model still talks to Hugging Face if the weights are not
already cached.

Hugging Face, GitHub, and the stats service may see your IP address when
those requests happen. That is how HTTPS works; Pomvox does not send a name,
email, or account with them.

## Anonymous usage stats

Nothing is sent until you pick **Share anonymous stats** on first launch.
There is no default and no pre-checked box. A `maySend` gate holds all sending
until that choice is `.granted`. Change it later in **Settings → Privacy**.
Turning it off drops anything still queued.

If you share, events go to Pomvox's own ingest service on Google Cloud Run:
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

No accounts. No ads. No selling or sharing your data. The stats payload, if
you opt in, is the only usage data Pomvox ever sends, and it cannot carry
your voice or your words.

## Contact

Questions about this policy: <maanasavamsi09@gmail.com>.
