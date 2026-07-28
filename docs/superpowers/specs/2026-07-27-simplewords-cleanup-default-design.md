# SimpleWords v2 as the default cleanup model

**Date:** 2026-07-27
**Status:** approved, ready for implementation
**Branch:** `feat/simplewords-cleanup-default`

## Goal

Make `abhiram3040/simplewords-dictation-cleanup-v2` — the fused 8-bit MLX
fine-tune that passed the 28-case ship gate on 2026-07-27 (24/28, zero meaning
inversions, ~4× faster than Qwen3-4B) — the default cleanup LLM for 16 GB+ Macs,
running under the exact recipe it was trained on.

The recipe is load-bearing and comes from the model repo, not from this codebase:

1. The frozen system prompt ships with the weights as `system_v2.txt` and is read
   from disk at runtime — never retyped here, so it cannot drift from what the
   weights expect.
2. It is folded into a single **user** turn (`"{system}\n\n{raw}"`) — not a
   system-role message, and with **no** few-shot examples.
3. Greedy decoding (`temperature: 0`) with `enable_thinking: false`.

Item 3 already holds on the existing generate path. Items 1 and 2 are new and
must not disturb the prompt bytes of any other model.

## Findings that shaped the design

Everything below was verified against the code, not assumed.

### `persist(true)` does not pin `[cleanup] model` — no migration is needed

`NativeEngine.persist(_:)` (`NativeEngine.swift:1204`) writes exactly one key,
`[engine] native`. It never touches `[cleanup] model`. The other two writers are
also safe:

- `SettingsIO.writeIfValid` diffs against `read(doc)`, which substitutes
  defaults for absent keys, so an absent `cleanup.model` is never written back
  (`SettingsStore.swift:105-127`).
- `LowMemoryCleanupModel.writeChoice` seeds `cleanup.model` only when the key is
  absent, only on ≤ 8 GB Macs, and only with the compact model
  (`LowMemoryCleanup.swift:70-77`) — unchanged by this work.

So the only users carrying an explicit `[cleanup] model` are those who chose one
in Settings deliberately. Changing the built-in default migrates everyone else
correctly and silently, and leaves deliberate choices alone. **No migration code
ships.**

### The frozen prompt is never downloaded by the stock loader

```swift
// mlx-swift-lm/Libraries/MLXLMCommon/ModelFactory.swift:6-7
package let tokenizerDownloadPatterns = ["*.json", "*.jinja"]
package let modelDownloadPatterns = ["*.safetensors"] + tokenizerDownloadPatterns
```

`system_v2.txt` matches none of these, so `ModelConfiguration(id:)` never brings
it to disk. Reading it from the snapshot requires an explicit fetch.

### `adapter/` is not ignorable — it is a probable hard load failure

Two independent paths make the adapter subfolder load-bearing:

1. **Download.** The snapshot filter is `fnmatch(glob, entry.path, 0)`
   (`HubClient+Files.swift:1291`). With flags `0`, `*` crosses `/`, so
   `*.safetensors` matches `adapter/adapters.safetensors` (67 MB) and `*.json`
   matches `adapter/adapter_config.json`.
2. **Load.** `loadWeights` (`Load.swift:22-33`) walks
   `FileManager.default.enumerator(at: modelDirectory)` — recursive — merges every
   `.safetensors` it finds, then calls `model.update(parameters:verify: [.all])`.
   `.all` includes `.noUnusedKeys`, which throws on leftover keys
   (`Module.swift:547`). The adapter holds 372 LoRA tensors
   (`language_model.model.layers.N.linear_attn.*.lora_a` / `lora_b`) that have no
   home in the fused graph, and `Qwen35Model.sanitize` filters only `mtp.` keys
   and `lm_head.weight` — not LoRA keys.

This was settled empirically, by an env-gated `XCTestCase`
(`CleanupModelLoadProbeTests.testStockRepoIDPath`) in the app target alongside
`CleanupBenchTests`. It cannot be a `native/` SPM harness: mlx-swift's
`default.metallib` is an Xcode build-phase artifact, so `swift run
pomvox-bench-llm` dies with `Failed to load the default metallib` before
reaching the loader — which is why `CleanupBenchTests` was relocated into the
Xcode target in the first place.

The stock loader does **not** survive the `adapter/` subfolder. Against a local
Hugging Face cache that already held `adapter/adapters.safetensors`,
`LLMModelFactory.shared.loadContainer(from:using:configuration:)` threw before
returning a container:

```
PROBE stock: FAILED unhandledKeys(path: ["language_model", "model", "layers", "0", "linear_attn", "in_proj_qkv"], modules: ["Qwen35Model", "Qwen35TextModel", "Qwen35TextModelInner", "Qwen35DecoderLayer", "Qwen35GatedDeltaNet", "QuantizedLinear"], keys: ["lora_a", "lora_b"])
```

This confirms the mechanism above: `loadWeights` merged the adapter's LoRA
tensors into the fused graph, and `model.update(parameters:verify: [.all])`
rejected `lora_a`/`lora_b` as unused keys on the very first decoder layer's
`QuantizedLinear` before even reaching layer 1. The design below is correct as
specified.

### Download hygiene is otherwise already correct

`CleanupEngine.swift:175` is the only `loadContainer` call site, and it is driven
by `cleanupModelID`. `suggestVariants` hard-guards on `container != nil`, so
suggestion chips can never trigger a load. STT resolves through
`SttModel.default == .parakeetV2`. A fresh install therefore fetches exactly one
STT model and at most one cleanup model.

### Pre-existing bug, noted not fixed

`SettingsValues.defaults.cleanupModel` is a hardcoded string and is not
memory-tier aware, so a ≤ 8 GB Mac with an absent key *runs* Qwen3-1.7B while
Settings *displays* Qwen3-4B. Same family as #92. Out of scope here; belongs in
its own PR.

## Design

### 1. `CleanupPromptProfile` — a new pure-logic seam

New file `Pomvox/Sources/Engine/CleanupPromptProfile.swift`, with no MLX import so
it unit-tests the way `CleanupLogic` does.

```swift
enum CleanupPromptProfile: Equatable {
    case legacy        // few-shot styled chat — every Qwen3 preset and any other id
    case simpleWords   // frozen single-turn prompt that ships with the weights

    static func forModel(_ id: String) -> CleanupPromptProfile
    var prefixKeys: [String]
    func prefixKey(forStyle style: String) -> String
}
```

- `forModel` matches an **exact id set**, lowercased and whitespace-trimmed — not
  a prefix. `abhiram3040/simplewords-dictation-cleanup` (v1) is adapter-only and
  ships no `system_v2.txt`; a prefix match would route it down the frozen path and
  break at load. A future v3 gets its own explicit entry.
- `prefixKeys` is `["light", "polish"]` for `.legacy` and `["*"]` for
  `.simpleWords`.
- `prefixKey(forStyle:)` is the identity for `.legacy` and constant `"*"` for
  `.simpleWords` — both configured styles collapse onto the one frozen prompt.

### 2. Prompt builder

`CleanupLogic` gains one function; `buildMessages` and every byte of the existing
prompt text are untouched.

```swift
static func buildSimpleWordsMessages(
    text: String, system: String, termsHint: String = ""
) -> [ChatMessage]
```

It returns exactly one `.user` message:

```
{system trimmed}
{termsHint}          ← only when non-empty

{raw}
```

The dictionary `termsHint` is already formatted as a `- …` bullet
(`PomvoxDictionary.swift:18-23`), so it reads as one more rule appended after the
frozen text — never before it, never interleaved. With an empty hint the result is
byte-identical to `example.py`'s `f"{system}\n\n{raw}"`; that identity is a unit
test.

### 3. Loading

`CleanupEngine.prepare(modelID:onProgress:)` branches on the profile.

`.legacy` keeps today's call **unchanged**:

```swift
try await LLMModelFactory.shared.loadContainer(
    from: HubClient.default, using: TokenizersLoader(),
    configuration: ModelConfiguration(id: modelID), progressHandler: …)
```

`.simpleWords` fetches an explicit file set, reads the frozen prompt, then loads
from that directory:

```swift
let dir = try await HubClient.default.downloadSnapshot(
    of: repo,
    matching: ["model*.safetensors", "*.json", "*.jinja", "system_v2.txt"],
    progressHandler: { onProgress?($0.fractionCompleted) })
frozenSystem = try String(contentsOf: dir.appending(path: "system_v2.txt"), encoding: .utf8)
let loaded = try await LLMModelFactory.shared.loadContainer(
    from: HubClient.default, using: TokenizersLoader(),
    configuration: ModelConfiguration(directory: dir), progressHandler: …)
```

- `model*.safetensors` is deliberately narrow: a LoRA subfolder can never be
  merged into the graph even if one reappears in the repo.
- `*.json` stays broad so a future `generation_config.json` is not silently
  dropped.
- Revision stays `main`, matching how the Qwen3 presets resolve today, so a
  prompt fix can ship without an app release.
- `downloadSnapshot` has a cache fast path and falls back to the cached snapshot
  when the file listing fails (`HubClient+Files.swift:1236`, `1271`), so
  offline-after-first-run behaves as it does today.

`frozenSystem` is stored on the actor and consumed by `renderTokens`.

**Failure mode.** A missing or unreadable `system_v2.txt` returns
`.failed(reason)`. The engine stays unloaded, `clean()` returns `nil`, and
`runCleanup` pastes the raw transcript with a loud log line. It must **never**
fall back to the legacy few-shot prompt on fused weights — that combination is
untested and the guards would not reliably catch its output.

### 4. Prefix cache: one entry instead of two

`prepare()` and `buildPrefixCaches` switch from `CleanupLogic.styles` to
`profile.prefixKeys`; `clean()` looks up
`prefixCaches[profile.prefixKey(forStyle: style)]`. `PrefixCacheKey` and
`CleanupResidency.styleBuildOrder(preferred:all:)` are reused as-is, with
`all: profile.prefixKeys` and `preferred: profile.prefixKey(forStyle: preferredStyle)`.

For the v2 model this means one prefill instead of two, and the prefix itself
drops from roughly 1100 tokens to roughly 330 (the frozen prompt carries no
few-shot block) — a large cold-launch win on top of halving the count.

The `[cleanup] style` setting therefore becomes a no-op for users on the default
model. It keeps working for anyone on a Qwen3 preset. No UI change in this work;
it is flagged in the PR as a UX follow-up.

### 5. Defaults and presets

- `MemoryTier.standardCleanupModel` → `"abhiram3040/simplewords-dictation-cleanup-v2"`,
  with the surrounding doc comments corrected for the 8-bit ~2.2 GB footprint.
- `MemoryTier.compactCleanupModel` unchanged (`mlx-community/Qwen3-1.7B-4bit`) —
  the v2 model is 8-bit and defeats the compact tier's purpose.
- `SettingsSchema.cleanupModelPresets` gains the new id at the head; all three
  Qwen3 presets stay selectable.
- `SettingsValues.defaults.cleanupModel` → the new id, so Settings displays what
  the engine actually runs.

### 6. Hugging Face repo hygiene

`adapter/` moves off `main` in the model repo, into
`abhiram3040/simplewords-dictation-cleanup-v2-adapter`. Weights and the
`system_v2.txt` bytes are untouched, so the 28-case eval result stands.

This is what stops a full `snapshot_download` — which anyone running the repo's
own `example.py` performs — from repolluting a shared cache with LoRA
safetensors and breaking the directory load. The Swift-side glob narrowing and
this cleanup are complementary: the globs protect a fresh install, the repo
cleanup protects a cache that some other tool populated.

### 7. Explicitly untouched

- `runCleanup` and `acceptOutput` — not one byte. They are the safety net, and
  they correctly rejected this model's two edge-case failures during the eval.
- `CleanupLogic.buildMessages`, `systemTemplate`, `lightExtra`, `polishExtra`,
  `examples` — the legacy path stays byte-for-byte identical.
- CI configuration.
- Cache eviction for superseded models — already filed as issue #100; the PR
  references it rather than implementing it.

### Accepted model behaviour (not to be worked around in Swift)

Numbered-when-counted lists come out as bullets; `their were` → `there were`
homophone fixes happen, diverging from the old prompt's leave-homophones-alone
policy; one observed subtle trim dropped a trailing `…or maybe wait`. These are
model-side and belong to a future data pass.

## Testing

| Area | Test |
| --- | --- |
| Legacy path | `CleanupLogicTests` passes untouched — the regression gate |
| Model detection | Exact id matches; v1 id, Qwen3 ids and empty string resolve `.legacy`; case and whitespace tolerance |
| Style mapping | `light` and `polish` both map to `"*"`; `.legacy` maps each style to itself |
| Prompt bytes | One `.user` message; empty-hint output equals `system + "\n\n" + raw`; hint lands after the frozen text; frozen text is trimmed |
| Defaults | `MemoryTierTests` updated for the new standard model; compact model unchanged |
| Build | `xcodebuild test -scheme Pomvox` with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` |

**Python parity harness.** `scripts/eval_cleanup_v2.py`, adapted from the
scratchpad ship-gate script and committed, so Swift output can be spot-checked
against known-good Python outputs for a handful of the 28 cases.

**On-device**, from a Release build (a Debug/self-signed swap invalidates the mic
TCC grant — expect one re-grant per install regardless), armed through the UI,
watched with a live `/usr/bin/log stream` (not `log show`; `log` is a shadowed
builtin):

1. The v2 model downloads once and loads.
2. A dictation cleans through the new prompt path, with the model id in the log.
3. `"let's meet tuesday wait no friday at noon"` pastes **Friday**.
4. Raw fallback still works with cleanup off.

**`suggestVariants` check.** The dictionary suggestion chips reuse the cleanup
model with their own prompt. v2 is a narrow cleanup fine-tune and may be worse at
that task. Tested once; degradation is acceptable (chips are opportunistic
garnish) but is reported in the PR.

## Delivery

Two stacked PRs, conventional commits, GPG-signed:

- **A — `feat(cleanup): prompt-profile seam and frozen-prompt loader`.** The
  profile, the loader branch, the single-prefix generalization, and all tests.
  Behaviour is unchanged for every existing user; the model becomes selectable by
  hand.
- **B — `feat(cleanup): default to the SimpleWords fine-tune`.** The default flip,
  Settings presets, `SettingsValues.defaults`, and `scripts/eval_cleanup_v2.py`.
  Its description carries the migration finding, the #100 reference, the accepted
  model nits, and the `suggestVariants` result.
