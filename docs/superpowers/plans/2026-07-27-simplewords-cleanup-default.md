# SimpleWords v2 Default Cleanup Model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `abhiram3040/simplewords-dictation-cleanup-v2` the default cleanup LLM for 16 GB+ Macs, driven by the frozen single-turn prompt that ships with its weights, without changing one byte of the prompt any other model sees.

**Architecture:** A new pure-logic `CleanupPromptProfile` enum maps a configured model id to a prompt recipe. `CleanupLogic` gains a second builder for the frozen recipe; the existing few-shot builder is untouched. `CleanupEngine` branches on the profile in exactly two places — how it downloads/loads the model, and how it renders tokens — and generalizes its per-style prefix KV cache to per-*profile-key*, which collapses to one shared prefix on the frozen path.

**Tech Stack:** Swift 5.10, SwiftUI, XCTest, mlx-swift-lm 3.31.0, swift-huggingface (via `MLXLMHuggingFace`, which `@_exported import`s it), XcodeGen, Python 3 + `uv` for the parity harness.

**Design spec:** `docs/superpowers/specs/2026-07-27-simplewords-cleanup-default-design.md`

## Global Constraints

- Branch: `feat/simplewords-cleanup-default`, already created off `main` at `a16bf70`. The spec commit `3557621` is already on it.
- Repo root is `~/dev/murmur`. The `~/Desktop/projects/murmur` copy is stale and not a git repo — never touch it.
- Conventional commits; subject line under 72 chars. Commits are GPG-signed automatically (`commit.gpgsign=true`, key `E9B9CAE4F97F1BA2`). Verify with `git log -1 --pretty='%G? %s'` → must print `G`.
- Every `xcodebuild` invocation needs `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The `xcode-select` default is CommandLineTools, which `xcodebuild` rejects.
- Build to `/tmp`, never onto an iCloud path: `-derivedDataPath /tmp/pomvox-hub-dd`.
- Adding a new source file requires `cd Pomvox && xcodegen generate` before building — `project.yml` globs `Sources/` and `Tests/`, and the generated `.xcodeproj` is gitignored.
- Do not modify CI configuration.
- Do not modify `runCleanup` or `CleanupLogic.acceptOutput`. They are the safety net.
- Do not modify `MemoryTier.compactCleanupModel` — it stays `mlx-community/Qwen3-1.7B-4bit`.
- Do not modify `CleanupLogic.buildMessages`, `systemTemplate`, `lightExtra`, `polishExtra`, or `examples`. `CleanupLogicTests` must pass with zero edits; that is the regression gate for every other model.
- The frozen model id string, used verbatim everywhere: `abhiram3040/simplewords-dictation-cleanup-v2`
- The frozen prompt filename, used verbatim: `system_v2.txt`
- Two PRs, stacked. Tasks 1–7 are PR A; tasks 8–11 are PR B branched off PR A's head.

---

### Task 1: Empirically settle whether the stock loader survives `adapter/`

The design rests on a code-reading claim: `loadContainer(ModelConfiguration(id:))` against this model repo downloads `adapter/adapters.safetensors` (67 MB of LoRA tensors) and then throws, because `loadWeights` enumerates the model directory recursively and `model.update(parameters:verify: [.all])` rejects unused keys. Prove it before building on it.

This must be an XCTest in the app target. It cannot be a `native/` SPM harness: mlx-swift's `default.metallib` is an Xcode build-phase artifact, so `swift run pomvox-bench-llm` dies with `Failed to load the default metallib` before it reaches the loader. `CleanupBenchTests` lives in the app target for exactly this reason.

**Files:**
- Create: `Pomvox/Tests/CleanupModelLoadProbeTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: nothing later tasks depend on. This is a standalone, env-gated diagnostic. Task 6 extends it.

- [ ] **Step 1: Write the probe test**

```swift
import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers
import XCTest

@testable import Pomvox

/// Diagnostics for how the SimpleWords cleanup model reaches disk and memory.
/// Skipped unless POMVOX_MODEL_PROBE=1 — it downloads and loads ~2 GB:
///   TEST_RUNNER_POMVOX_MODEL_PROBE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
///     xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
///     -destination 'platform=macOS' -only-testing:PomvoxTests/CleanupModelLoadProbeTests
final class CleanupModelLoadProbeTests: XCTestCase {

    static let modelID = "abhiram3040/simplewords-dictation-cleanup-v2"

    private func skipUnlessEnabled() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["POMVOX_MODEL_PROBE"] == "1",
            "set TEST_RUNNER_POMVOX_MODEL_PROBE=1 to run the model load probe")
    }

    /// The stock mlx-swift-lm path. Expected to FAIL while the model repo keeps
    /// an adapter/ subfolder on main: the download globs let `*.safetensors`
    /// cross '/', and loadWeights merges every .safetensors it finds under the
    /// model directory into a fused graph that has no LoRA parameters.
    func testStockRepoIDPath() async throws {
        try skipUnlessEnabled()
        do {
            let container = try await LLMModelFactory.shared.loadContainer(
                from: HubClient.default,
                using: TokenizersLoader(),
                configuration: ModelConfiguration(id: Self.modelID))
            let dir = try await container.modelDirectory
            let fm = FileManager.default
            print("PROBE stock: LOADED dir=\(dir.path)")
            print("PROBE stock: system_v2.txt present="
                + "\(fm.fileExists(atPath: dir.appendingPathComponent("system_v2.txt").path))")
            print("PROBE stock: adapter present="
                + "\(fm.fileExists(atPath: dir.appendingPathComponent("adapter/adapters.safetensors").path))")
        } catch {
            print("PROBE stock: FAILED \(error)")
        }
    }
}
```

The test deliberately does not assert. Its job is to print the answer; the assertion lives in Task 6's test of the path we actually ship.

- [ ] **Step 2: Regenerate the project and run the probe**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && TEST_RUNNER_POMVOX_MODEL_PROBE=1 \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' \
  -only-testing:PomvoxTests/CleanupModelLoadProbeTests 2>&1 | grep -E "PROBE|Test Suite|error:"
```

Expected: a `PROBE stock:` line. Record which it is verbatim — it goes in PR A's description.

- [ ] **Step 3: Record the result in the spec**

Replace the "This is settled empirically" paragraph in
`docs/superpowers/specs/2026-07-27-simplewords-cleanup-default-design.md` with the observed outcome and the exact error text if it failed. If it unexpectedly **loaded**, note that the adapter-driven part of the rationale is wrong; the design does not change (the frozen prompt still needs fetching, and 67 MB is still wasted per install), but the PR description must not claim a failure that did not happen.

- [ ] **Step 4: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Tests/CleanupModelLoadProbeTests.swift \
        docs/superpowers/specs/2026-07-27-simplewords-cleanup-default-design.md
git commit -m "test(cleanup): probe how the SimpleWords model loads"
git log -1 --pretty='%G? %s'
```

---

### Task 2: Move `adapter/` off the model repo's main branch

Hugging Face-side work, outside this git repo. The Swift glob narrowing in Task 6 protects a fresh install, but anyone who runs the model repo's own `example.py` calls `snapshot_download(REPO)` with no filter and repopulates a shared cache with the LoRA weights — which then breaks the directory load. Removing them from `main` closes that.

**Files:**
- No files in this repo. Changes `abhiram3040/simplewords-dictation-cleanup-v2` on Hugging Face.

**Interfaces:**
- Consumes: the Task 1 probe result (informative only).
- Produces: a model repo whose `main` contains no `adapter/` path. Task 6's globs and Task 11's on-device run both assume this.

- [ ] **Step 1: Confirm write access**

```bash
cd ~/dev/murmur && uv run python -c "
from huggingface_hub import HfApi
print(HfApi().whoami()['name'])"
```

Expected: `abhiram3040`. If it errors with an auth failure, stop and ask the user to run `! uv run huggingface-cli login` — do not attempt to obtain a token any other way.

- [ ] **Step 2: Copy the adapter to its own repo**

```bash
cd ~/dev/murmur && uv run python -c "
from huggingface_hub import HfApi
api = HfApi()
src = 'abhiram3040/simplewords-dictation-cleanup-v2'
dst = 'abhiram3040/simplewords-dictation-cleanup-v2-adapter'
api.create_repo(dst, repo_type='model', exist_ok=True)
for f in ['adapter/adapter_config.json', 'adapter/adapters.safetensors', 'adapter/system_v2.txt']:
    p = api.hf_hub_download(src, f)
    api.upload_file(path_or_fileobj=p, path_in_repo=f.split('/', 1)[1], repo_id=dst)
print('copied')"
```

- [ ] **Step 3: Verify the copy, then delete the folder from the fused repo**

```bash
cd ~/dev/murmur && uv run python -c "
from huggingface_hub import HfApi
api = HfApi()
dst = 'abhiram3040/simplewords-dictation-cleanup-v2-adapter'
print('adapter repo:', sorted(api.list_repo_files(dst)))"
```

Expected: `['.gitattributes', 'adapter_config.json', 'adapters.safetensors', 'system_v2.txt']`. Only once that prints correctly:

```bash
cd ~/dev/murmur && uv run python -c "
from huggingface_hub import HfApi, CommitOperationDelete
HfApi().create_commit(
    repo_id='abhiram3040/simplewords-dictation-cleanup-v2',
    operations=[CommitOperationDelete(path_in_repo='adapter/')],
    commit_message='chore: move the LoRA adapter to its own repo')
print('deleted')"
```

- [ ] **Step 4: Verify the fused repo's file list**

```bash
cd ~/dev/murmur && uv run python -c "
from huggingface_hub import HfApi
print(sorted(HfApi().list_repo_files('abhiram3040/simplewords-dictation-cleanup-v2')))"
```

Expected exactly: `['.gitattributes', 'README.md', 'chat_template.jinja', 'config.json', 'example.py', 'model.safetensors', 'model.safetensors.index.json', 'system_v2.txt', 'tokenizer.json', 'tokenizer_config.json']`

No `adapter/` entries. `system_v2.txt` and `model.safetensors` must still be present — if either is missing, stop; the weights were damaged.

- [ ] **Step 5: Add a pointer to the model card**

Append to the repo's `README.md` (download it, append, re-upload):

```
## Adapter

The LoRA adapter this model was fused from lives at
[abhiram3040/simplewords-dictation-cleanup-v2-adapter](https://huggingface.co/abhiram3040/simplewords-dictation-cleanup-v2-adapter).
It is kept out of this repo so that `snapshot_download` here fetches only the
fused model — a loader that merges every `.safetensors` under the snapshot
directory would otherwise try to apply LoRA tensors to an already-fused graph.
```

- [ ] **Step 6: Purge the local cache so later tasks see a clean snapshot**

The dev machine's cache already holds `adapter/` from an earlier Python `snapshot_download`. Directory-based loading would still find it.

```bash
rm -rf ~/.cache/huggingface/hub/models--abhiram3040--simplewords-dictation-cleanup-v2
ls ~/.cache/huggingface/hub/ | grep simplewords
```

Expected: only `models--abhiram3040--simplewords-dictation-cleanup` (the v1 repo). No commit — nothing in this git repo changed.

---

### Task 3: `CleanupPromptProfile`

**Files:**
- Create: `Pomvox/Sources/Engine/CleanupPromptProfile.swift`
- Test: `Pomvox/Tests/CleanupPromptProfileTests.swift`

**Interfaces:**
- Consumes: `CleanupLogic.styles` (existing, `["light", "polish"]`).
- Produces, all used by Tasks 4–6:
  - `enum CleanupPromptProfile: Equatable { case legacy; case simpleWords }`
  - `static func forModel(_ id: String) -> CleanupPromptProfile`
  - `static let frozenPromptFilename: String` (`"system_v2.txt"`)
  - `static let sharedPrefixKey: String` (`"*"`)
  - `var prefixKeys: [String]`
  - `func prefixKey(forStyle style: String) -> String`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import Pomvox

final class CleanupPromptProfileTests: XCTestCase {

    func testSimpleWordsIDResolvesToTheFrozenProfile() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup-v2"),
            .simpleWords)
    }

    func testDetectionIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("  Abhiram3040/SimpleWords-Dictation-Cleanup-V2\n"),
            .simpleWords)
    }

    func testQwenPresetsAndUnknownIDsStayLegacy() {
        for id in [
            "mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3-1.7B-4bit",
            "mlx-community/Qwen3-8B-4bit", "someone/some-other-model", "",
        ] {
            XCTAssertEqual(CleanupPromptProfile.forModel(id), .legacy, id)
        }
    }

    /// v1 is an adapter-only repo: no fused weights, no system_v2.txt. A prefix
    /// match on "simplewords-dictation-cleanup" would route it down the frozen
    /// path and fail at load, so detection must be an exact-id match.
    func testTheV1AdapterRepoIsNotTreatedAsFrozen() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup"),
            .legacy)
    }

    func testLegacyKeepsOnePrefixPerStyle() {
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKeys, CleanupLogic.styles)
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKey(forStyle: "light"), "light")
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKey(forStyle: "polish"), "polish")
    }

    func testFrozenProfileCollapsesEveryStyleOntoOnePrefix() {
        let profile = CleanupPromptProfile.simpleWords
        XCTAssertEqual(profile.prefixKeys.count, 1)
        XCTAssertEqual(profile.prefixKey(forStyle: "light"), profile.prefixKey(forStyle: "polish"))
        XCTAssertEqual(profile.prefixKeys, [profile.prefixKey(forStyle: "polish")])
    }

    /// Every style the UI can produce must map to a key the engine will have
    /// prefilled — otherwise clean() waits on a cache that is never built.
    func testEveryConfigurableStyleMapsIntoPrefixKeys() {
        for profile in [CleanupPromptProfile.legacy, .simpleWords] {
            for style in CleanupLogic.styles {
                XCTAssertTrue(
                    profile.prefixKeys.contains(profile.prefixKey(forStyle: style)),
                    "\(profile) style=\(style)")
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' \
  -only-testing:PomvoxTests/CleanupPromptProfileTests 2>&1 | tail -20
```

Expected: compile failure, `cannot find 'CleanupPromptProfile' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Which prompt recipe a cleanup model expects.
///
/// The Qwen3 presets are instruction-tuned generalists steered at runtime by
/// `CleanupLogic.buildMessages` — a system prompt plus ten few-shot examples.
/// The SimpleWords model is a fine-tune: its training data used ONE frozen
/// prompt, folded into a single user turn, with no examples. Handing it the
/// few-shot prompt (or the frozen text as a system-role message) is
/// off-distribution and degrades the output. Prompt shape is therefore a
/// property of the model, not a global — and this enum is that seam.
///
/// Pure logic (model id in → recipe out), no MLX import, so it unit-tests the
/// way `CleanupLogic` does.
enum CleanupPromptProfile: Equatable {
    /// System prompt + few-shot examples; one prompt prefix per style.
    case legacy
    /// The frozen prompt that ships alongside the weights; one prefix for all
    /// styles.
    case simpleWords

    /// Model ids that ship a frozen prompt.
    ///
    /// Deliberately an EXACT set rather than a prefix match:
    /// `abhiram3040/simplewords-dictation-cleanup` (v1) is an adapter-only repo
    /// with no fused weights and no `system_v2.txt`, so a prefix match would
    /// route it here and fail at load. A future v3 gets its own entry.
    private static let frozenPromptIDs: Set<String> = [
        "abhiram3040/simplewords-dictation-cleanup-v2"
    ]

    /// The frozen prompt's filename inside the model snapshot. The bytes are
    /// read from there at load, never copied into this repo, so they cannot
    /// drift from the weights that were trained on them.
    static let frozenPromptFilename = "system_v2.txt"

    /// The one prefix-cache key every style shares on the frozen path.
    static let sharedPrefixKey = "*"

    /// The recipe for a configured `[cleanup] model` value. Unknown ids get
    /// `.legacy`, the safe default — it works with any instruction-tuned model.
    static func forModel(_ id: String) -> CleanupPromptProfile {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return frozenPromptIDs.contains(normalized) ? .simpleWords : .legacy
    }

    /// The prompt-prefix caches to prefill for this profile.
    var prefixKeys: [String] {
        switch self {
        case .legacy: return CleanupLogic.styles
        case .simpleWords: return [Self.sharedPrefixKey]
        }
    }

    /// The prefix-cache key a configured style uses.
    ///
    /// `light` and `polish` collapse onto one key on the frozen path: the
    /// prompt is frozen, so the style knob has nothing left to vary. That also
    /// halves the cold-launch prefill instead of prefilling two byte-identical
    /// prefixes.
    func prefixKey(forStyle style: String) -> String {
        switch self {
        case .legacy: return style
        case .simpleWords: return Self.sharedPrefixKey
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' \
  -only-testing:PomvoxTests/CleanupPromptProfileTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`, 7 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/CleanupPromptProfile.swift \
        Pomvox/Tests/CleanupPromptProfileTests.swift
git commit -m "feat(cleanup): add a per-model prompt-profile seam"
git log -1 --pretty='%G? %s'
```

---

### Task 4: The frozen-prompt builder

**Files:**
- Modify: `Pomvox/Sources/Engine/CleanupLogic.swift` — add one function after `buildMessages` (currently ends at line 147). Change nothing else in the file.
- Test: `Pomvox/Tests/CleanupSimpleWordsPromptTests.swift`

**Interfaces:**
- Consumes: `ChatMessage(role:content:)`, `dictionaryPromptHint(_:)` (in `PomvoxDictionary.swift`, returns e.g. `"- Keep these terms spelled exactly as written when you hear them (match phonetically, fix the spelling): Pomvox, Parakeet.\n"`).
- Produces, used by Task 6:
  `static func buildSimpleWordsMessages(text: String, system: String, termsHint: String = "") -> [ChatMessage]`

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest

@testable import Pomvox

/// The frozen path's byte contract. The fine-tune saw exactly
/// "{system}\n\n{raw}" in a single user turn during training (the model repo's
/// example.py), so these pin the SHAPE, never the wording — the wording lives
/// with the weights.
final class CleanupSimpleWordsPromptTests: XCTestCase {

    /// Stands in for system_v2.txt. Shaped like it (prose line, then rules) but
    /// deliberately not a copy: copying the real bytes here is the drift this
    /// design exists to prevent.
    private let system = """
        You clean up raw voice dictation into polished written text.

        - Remove fillers.
        - Never output markdown headers.
        """

    func testProducesASingleUserTurn() {
        let messages = CleanupLogic.buildSimpleWordsMessages(text: "um hello", system: system)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, "user")
    }

    func testFoldsTheSystemTextIntoTheUserTurn() {
        let messages = CleanupLogic.buildSimpleWordsMessages(text: "um hello", system: system)
        XCTAssertEqual(messages[0].content, system + "\n\num hello")
    }

    /// example.py reads the file with `.read_text().strip()`; matching that is
    /// what keeps the Swift prompt byte-identical to the Python one.
    func testTrimsTheFrozenTextTheWayExamplePyDoes() {
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: "\n\n" + system + "  \n")
        XCTAssertEqual(messages[0].content, system + "\n\num hello")
    }

    func testTermsHintFollowsTheFrozenTextAndPrecedesTheTranscript() {
        let hint = dictionaryPromptHint(["Pomvox", "Parakeet"])
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: system, termsHint: hint)
        let trimmedHint = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(messages[0].content, system + "\n" + trimmedHint + "\n\num hello")
    }

    /// The frozen bytes must stay a strict prefix of every prompt, so the
    /// prefilled KV cache still covers them when a dictionary hint is present.
    func testTheFrozenTextStaysAPrefixWithAHint() {
        let messages = CleanupLogic.buildSimpleWordsMessages(
            text: "um hello", system: system, termsHint: dictionaryPromptHint(["Pomvox"]))
        XCTAssertTrue(messages[0].content.hasPrefix(system))
    }

    func testAWhitespaceOnlyHintChangesNothing() {
        XCTAssertEqual(
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system, termsHint: "  \n"),
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system))
    }

    func testAnEmptyHintChangesNothing() {
        XCTAssertEqual(
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system, termsHint: ""),
            CleanupLogic.buildSimpleWordsMessages(text: "x", system: system))
    }

    /// Regression guard: the legacy builder is untouched — one system message,
    /// ten few-shot pairs, one user turn.
    func testTheLegacyBuilderIsUnchanged() {
        let messages = CleanupLogic.buildMessages(text: "um hello", style: "polish")
        XCTAssertEqual(messages.count, 22)
        XCTAssertEqual(messages.first?.role, "system")
        XCTAssertEqual(messages.last, ChatMessage(role: "user", content: "um hello"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' \
  -only-testing:PomvoxTests/CleanupSimpleWordsPromptTests 2>&1 | tail -20
```

Expected: compile failure, `type 'CleanupLogic' has no member 'buildSimpleWordsMessages'`.

- [ ] **Step 3: Write the implementation**

Insert immediately after `buildMessages` (after the closing brace on line 147 of `CleanupLogic.swift`):

```swift
    /// Chat messages for one cleanup request on the frozen-prompt path.
    ///
    /// The SimpleWords fine-tune was trained with its system text folded into
    /// the USER turn — `"{system}\n\n{raw}"` — with no system-role message and
    /// no few-shot examples (the model repo's `example.py` is the reference).
    /// Reproducing that shape byte-for-byte is what makes the fine-tune behave;
    /// a system-role message or the legacy examples put it off-distribution.
    ///
    /// `system` is the frozen text read from the model snapshot at load, never
    /// a copy kept in this repo — that is what stops it drifting from the
    /// weights that were trained on it. `termsHint` (see `dictionaryPromptHint`)
    /// is appended AFTER the frozen text: it is already shaped as one more "- "
    /// rule, and keeping it after leaves the frozen bytes a strict prefix of
    /// every prompt, so the prefilled KV cache still covers them.
    static func buildSimpleWordsMessages(
        text: String, system: String, termsHint: String = ""
    ) -> [ChatMessage] {
        var prompt = system.trimmingCharacters(in: .whitespacesAndNewlines)
        let hint = termsHint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hint.isEmpty { prompt += "\n" + hint }
        return [ChatMessage(role: "user", content: prompt + "\n\n" + text)]
    }
```

- [ ] **Step 4: Run both the new tests and the legacy regression suite**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' \
  -only-testing:PomvoxTests/CleanupSimpleWordsPromptTests \
  -only-testing:PomvoxTests/CleanupLogicTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. `CleanupLogicTests` must pass with zero edits to it.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/CleanupLogic.swift \
        Pomvox/Tests/CleanupSimpleWordsPromptTests.swift
git commit -m "feat(cleanup): build the frozen single-turn prompt"
git log -1 --pretty='%G? %s'
```

---

### Task 5: Generalize the prefix cache from styles to profile keys

Pure refactor — no behaviour change for any model, because `CleanupPromptProfile.legacy.prefixKeys == CleanupLogic.styles` and its `prefixKey(forStyle:)` is the identity. Doing it in its own task means a reviewer can confirm "nothing changed" before Task 6 introduces the branch that actually does.

**Files:**
- Modify: `Pomvox/Sources/Engine/CleanupEngine.swift` (lines 56–72 for state, 201–227 in `prepare`, 265–318 `buildPrefixCaches`, 351–367 in `clean`)

**Interfaces:**
- Consumes: `CleanupPromptProfile` from Task 3; existing `CleanupResidency.styleBuildOrder(preferred:all:)` and `PrefixCacheKey`.
- Produces: a `private var profile: CleanupPromptProfile` on the actor, defaulting to `.legacy`. Task 6 assigns it at load.

- [ ] **Step 1: Add the profile state**

After the `preferredStyle` declaration (line 68), add:

```swift
    /// The prompt recipe for the loaded model. Assigned in `prepare()` from the
    /// model id; `.legacy` until a model loads, which is also the right answer
    /// for every model but the SimpleWords fine-tune.
    private var profile: CleanupPromptProfile = .legacy
```

Update the `prefixCaches` doc comment (line 38-41) — it says "One style's static prompt prefix". Replace "style's" with "prefix key's" and add: `Keyed by CleanupPromptProfile.prefixKey(forStyle:), which is the style itself on the legacy path and one shared key on the frozen path.`

- [ ] **Step 2: Key `prepare()`'s prefill off the profile**

Replace lines 202–215 (`let current = …` through the closing `}` of the `else` branch) with:

```swift
        let current = PrefixCacheKey(modelID: modelID, hint: termsHint)
        let keys = profile.prefixKeys
        let order = CleanupResidency.styleBuildOrder(
            preferred: profile.prefixKey(forStyle: preferredStyle), all: keys)
        let rebuild = prefixKey != current || prefixCaches.count < keys.count
        if rebuild {
            prefixCaches = [:]
            prefixAttempted = []
            // The configured style's prefix first, WITHOUT yielding — the
            // racing first dictation is waiting on exactly this prefill.
            await buildPrefixCaches(Array(order.prefix(1)), yieldToCleans: false)
        } else {
            prefixAttempted = Set(keys)
            NSLog("cleanup: reusing retained prefix caches (same model + hint)")
        }
```

- [ ] **Step 3: Take prefix keys in `buildPrefixCaches`**

Change the signature (line 265–267) and loop variable:

```swift
    private func buildPrefixCaches(
        _ keys: [String]? = nil, yieldToCleans: Bool = false
    ) async {
        let keys = keys ?? profile.prefixKeys
        let hint = termsHint
        for key in keys {
```

Inside the loop, rename every remaining use of `style` to `key`: the `renderTokens(..., style: style, ...)` calls become `style: key`, `prefixCaches[style] = entry` becomes `prefixCaches[key] = entry`, `prefixAttempted.insert(style)` becomes `prefixAttempted.insert(key)`, and both `NSLog` format arguments take `key`. Leave the `style=%@` text in the log strings — it still reads correctly, and on the legacy path the key *is* the style.

- [ ] **Step 4: Look the cache up by key in `clean()`**

Immediately before the `while CleanupResidency.shouldAwaitStylePrefix(` loop (line 351), insert:

```swift
        let prefixKeyForStyle = profile.prefixKey(forStyle: style)
```

Then in that loop replace `cached: prefixCaches[style] != nil` with `cached: prefixCaches[prefixKeyForStyle] != nil` and `attempted: prefixAttempted.contains(style)` with `attempted: prefixAttempted.contains(prefixKeyForStyle)`. Replace `let cached = prefixCaches[style]` (line 364) with `let cached = prefixCaches[prefixKeyForStyle]`.

- [ ] **Step 5: Run the full suite**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' 2>&1 | tail -25
```

Expected: `** TEST SUCCEEDED **`. Nothing should change — `CleanupResidencyTests`, `CleanupLogicTests` and the rest all pass untouched.

- [ ] **Step 6: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/CleanupEngine.swift
git commit -m "refactor(cleanup): key prompt prefixes by profile, not style"
git log -1 --pretty='%G? %s'
```

---

### Task 6: Load the frozen model and render its prompt

**Files:**
- Modify: `Pomvox/Sources/Engine/CleanupEngine.swift` (state, `prepare`, `renderTokens`, plus two new private helpers)
- Modify: `Pomvox/Tests/CleanupModelLoadProbeTests.swift` (add the shipped-path test)

**Interfaces:**
- Consumes: `CleanupPromptProfile.forModel/frozenPromptFilename` (Task 3), `CleanupLogic.buildSimpleWordsMessages` (Task 4), `profile` state (Task 5), and from `MLXLMHuggingFace`'s `@_exported import HuggingFace`: `Repo.ID(rawValue:)` (failable) and `HubClient.downloadSnapshot(of:kind:revision:matching:localFilesOnly:maxConcurrentDownloads:progressHandler:) async throws -> URL`, whose `progressHandler` is `(@MainActor @Sendable (Progress) -> Void)?`.
- Produces: `var frozenPrompt: String?` on the actor, for the test.

- [ ] **Step 1: Add the frozen-prompt state and error type**

After the `profile` property added in Task 5, add:

```swift
    /// The frozen system text for `.simpleWords`, read from the model snapshot
    /// at load. `nil` on the legacy path. Retained across idle eviction for the
    /// same reason the prefix caches are: it belongs to the model id, not to
    /// the container instance.
    private var frozenSystem: String?

    /// The loaded model's frozen prompt, for tests and diagnostics.
    var frozenPrompt: String? { frozenSystem }
```

Alongside `PrefixCacheError` (line 51), add:

```swift
    private enum FrozenPromptError: LocalizedError {
        case badRepoID(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .badRepoID(let id):
                return "'\(id)' is not a namespace/name Hugging Face repo id"
            case .unreadable(let path):
                return "the model's frozen prompt is missing or empty at \(path)"
            }
        }
    }
```

- [ ] **Step 2: Add the snapshot helpers**

Add as `private static` members of the actor, next to `renderTokens`:

```swift
    /// Files to fetch for the frozen-prompt path.
    ///
    /// `ModelConfiguration(id:)` cannot be used here, for two reasons. Its
    /// globs (`*.safetensors`, `*.json`, `*.jinja`) never fetch `system_v2.txt`,
    /// so the frozen prompt would never reach disk. And the snapshot filter is
    /// `fnmatch(glob, path, 0)` — with flags 0, `*` crosses `/`, so
    /// `*.safetensors` also matches a repo's `adapter/adapters.safetensors`,
    /// which `loadWeights` then merges (it enumerates the model directory
    /// RECURSIVELY) into a fused graph that has no LoRA parameters, failing
    /// `update(parameters:verify: [.all])`.
    ///
    /// So: `model*.safetensors` cannot match a subfolder's adapter weights,
    /// while `*.json` stays broad enough that a future `generation_config.json`
    /// isn't silently dropped.
    private static let frozenSnapshotGlobs = [
        "model*.safetensors", "*.json", "*.jinja", CleanupPromptProfile.frozenPromptFilename,
    ]

    /// Download exactly the files the frozen path needs and return the snapshot
    /// directory. `downloadSnapshot` short-circuits on a complete cached
    /// snapshot and falls back to the cache when the remote listing fails, so
    /// this is no more network-dependent than the stock loader.
    private static func fetchFrozenSnapshot(
        modelID: String, onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: modelID) else {
            throw FrozenPromptError.badRepoID(modelID)
        }
        return try await HubClient.default.downloadSnapshot(
            of: repo, matching: frozenSnapshotGlobs,
            progressHandler: { progress in onProgress?(progress.fractionCompleted) })
    }

    /// Read the frozen prompt out of a snapshot directory.
    private static func readFrozenPrompt(in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(CleanupPromptProfile.frozenPromptFilename)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw FrozenPromptError.unreadable(url.path)
        }
        return text
    }
```

- [ ] **Step 3: Branch the load in `prepare()`**

Replace the `do` block's load (lines 172–188) with:

```swift
        let profile = CleanupPromptProfile.forModel(modelID)
        let loadMs: Double
        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let loaded: ModelContainer
            switch profile {
            case .legacy:
                loaded = try await LLMModelFactory.shared.loadContainer(
                    from: HubClient.default,
                    using: TokenizersLoader(),
                    configuration: ModelConfiguration(id: modelID),
                    progressHandler: { progress in onProgress?(progress.fractionCompleted) })
                frozenSystem = nil
            case .simpleWords:
                // Fetch first: a snapshot without the frozen prompt is unusable,
                // and failing before the weights load keeps the engine cleanly
                // unloaded rather than loaded-but-unpromptable.
                let directory = try await Self.fetchFrozenSnapshot(
                    modelID: modelID, onProgress: onProgress)
                frozenSystem = try Self.readFrozenPrompt(in: directory)
                loaded = try await LLMModelFactory.shared.loadContainer(
                    from: HubClient.default,
                    using: TokenizersLoader(),
                    configuration: ModelConfiguration(directory: directory),
                    progressHandler: { progress in onProgress?(progress.fractionCompleted) })
            }
            loadMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            NSLog("cleanup: loaded %@ in %.1fs (prompt profile: %@)",
                  modelID, loadMs / 1000,
                  profile == .simpleWords ? "frozen" : "few-shot")
            container = loaded
            loadedModelID = modelID
            self.profile = profile
            loadGeneration &+= 1
        } catch {
            NSLog("cleanup: model load FAILED: %@", String(describing: error))
            return .failed(String(describing: error))
        }
```

`self.profile = profile` must land **before** the prefill block below it — `buildPrefixCaches` reads `profile.prefixKeys` and `renderTokens` reads `self.profile`.

The `NSLog` here is what the on-device verification greps for: it prints the model id and which prompt path is live.

- [ ] **Step 4: Branch `renderTokens`**

Replace `renderTokens` (lines 466–473) with:

```swift
    /// Tokenize one cleanup request through the model's chat template.
    /// Qwen3 is a hybrid-thinking model: without enable_thinking=false it
    /// emits <think> blocks and blows the latency budget. The SimpleWords
    /// fine-tune inherits the same template and the same requirement.
    private static func renderTokens(
        _ context: ModelContext, text: String, style: String, termsHint: String,
        profile: CleanupPromptProfile, frozenSystem: String?
    ) async throws -> [Int] {
        let messages: [ChatMessage]
        switch profile {
        case .legacy:
            messages = CleanupLogic.buildMessages(
                text: text, style: style, termsHint: termsHint)
        case .simpleWords:
            // prepare() cannot leave the container loaded without this, but
            // throwing beats silently prompting the fine-tune with bare text:
            // runCleanup turns the throw into a raw paste.
            guard let frozenSystem else {
                throw FrozenPromptError.unreadable("<not loaded>")
            }
            messages = CleanupLogic.buildSimpleWordsMessages(
                text: text, system: frozenSystem, termsHint: termsHint)
        }
        let lmInput = try await context.processor.prepare(
            input: UserInput(
                chat: toChat(messages), additionalContext: ["enable_thinking": false]))
        return lmInput.text.tokens.asArray(Int.self)
    }
```

- [ ] **Step 5: Pass the profile at both `renderTokens` call sites**

In `buildPrefixCaches`, the two calls inside `container.perform` become:

```swift
                    let a = try await Self.renderTokens(
                        context, text: "placeholder one", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
                    let b = try await Self.renderTokens(
                        context, text: "a different text entirely", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
```

`container.perform`'s closure is `@Sendable`, so hoist the actor state into locals before the `for key in keys` loop, next to `let hint = termsHint`:

```swift
        let profile = self.profile
        let frozen = frozenSystem
```

In `clean()`, hoist the same two next to `let hint = termsHint` (line 365):

```swift
        let profile = self.profile
        let frozen = frozenSystem
```

and update the call inside `container.perform`:

```swift
            var tokens = try await Self.renderTokens(
                context, text: text, style: style, termsHint: hint,
                profile: profile, frozenSystem: frozen)
```

Note `clean()` already declares `let prefixKeyForStyle = profile.prefixKey(forStyle: style)` from Task 5 above these lines, using the actor's `self.profile`; that still resolves correctly since the local `profile` is declared after it. If the compiler complains about shadowing, move the `let profile = self.profile` line above `prefixKeyForStyle` and let both use it.

- [ ] **Step 6: Add the shipped-path test to the probe file**

Append inside `CleanupModelLoadProbeTests`:

```swift
    /// The path Pomvox actually ships: an explicit snapshot fetch that includes
    /// the frozen prompt and excludes any adapter subfolder, then a
    /// directory-based load. Asserts, unlike the stock-path diagnostic above.
    func testFrozenPathLoadsAndCarriesThePrompt() async throws {
        try skipUnlessEnabled()
        let engine = CleanupEngine()
        let outcome = await engine.prepare(modelID: Self.modelID)
        if case .failed(let reason) = outcome { XCTFail("prepare failed: \(reason)") }
        let loaded = await engine.isLoaded
        XCTAssertTrue(loaded, "the frozen model should be resident after prepare()")

        let prompt = await engine.frozenPrompt
        XCTAssertNotNil(prompt, "system_v2.txt should have been read from the snapshot")
        XCTAssertFalse(prompt?.isEmpty ?? true)

        // A cleanup the fine-tune is specifically trained for: a spoken
        // self-correction must keep only the revision.
        let cleaned = try await engine.clean(
            "let's meet on tuesday wait no friday at noon", style: "polish", timeoutS: 30)
        print("PROBE frozen: \(String(describing: cleaned))")
        let accepted = try XCTUnwrap(cleaned).lowercased()
        XCTAssertTrue(accepted.contains("friday"), accepted)
        XCTAssertFalse(accepted.contains("tuesday"), accepted)
    }
```

- [ ] **Step 7: Run the probe and the full offline suite**

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && TEST_RUNNER_POMVOX_MODEL_PROBE=1 \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' 2>&1 | grep -E "PROBE|Test Suite|error:|failed" | tail -30
```

Expected: `PROBE frozen:` shows a cleaned string containing "Friday" and not "Tuesday"; `** TEST SUCCEEDED **`.

Then confirm the download really was hygienic:

```bash
du -sh ~/.cache/huggingface/hub/models--abhiram3040--simplewords-dictation-cleanup-v2
find ~/.cache/huggingface/hub/models--abhiram3040--simplewords-dictation-cleanup-v2/snapshots -maxdepth 2 | sort
```

Expected: roughly 2.0 GB, and a snapshot listing containing `system_v2.txt` and **no** `adapter` directory.

- [ ] **Step 8: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/CleanupEngine.swift \
        Pomvox/Tests/CleanupModelLoadProbeTests.swift
git commit -m "feat(cleanup): load the fine-tune with its frozen prompt"
git log -1 --pretty='%G? %s'
```

---

### Task 7: Open PR A

**Files:**
- No source changes.

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: PR A on GitHub; Task 8 branches off this same branch head.

- [ ] **Step 1: Read CONTRIBUTING.md's PR section**

```bash
cd ~/dev/murmur && sed -n '/## /p' CONTRIBUTING.md
```

Follow whatever it says about PR content; the description below is a floor, not a ceiling.

- [ ] **Step 2: Run the whole suite one more time from clean**

```bash
cd ~/dev/murmur && rm -rf /tmp/pomvox-hub-dd && \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' 2>&1 | tail -15
```

Expected: `** TEST SUCCEEDED **`. Do not proceed on anything else.

- [ ] **Step 3: Push and open the PR**

```bash
cd ~/dev/murmur && git push -u origin feat/simplewords-cleanup-default
gh pr create --base main --title "feat(cleanup): prompt-profile seam and frozen-prompt loader" --body "$(cat <<'EOF'
Groundwork for making the SimpleWords v2 fine-tune the default cleanup model
(#100 is the related cache follow-up). **No behaviour changes for any existing
user** — the model becomes loadable by setting `[cleanup] model` by hand, and
every other model id keeps its current prompt bytes exactly.

## Why a per-model prompt path

The fine-tune was trained on one frozen prompt, folded into a single user turn,
with no few-shot examples. Feeding it Pomvox's few-shot styled prompt is
off-distribution. `CleanupPromptProfile` makes prompt shape a property of the
model id; `.legacy` stays byte-for-byte what it is today, and `CleanupLogicTests`
passes untouched as the regression gate.

The frozen prompt is read from `system_v2.txt` inside the downloaded model
snapshot — never copied into this repo, so it cannot drift from the weights.

## Two loader findings

The stock `ModelConfiguration(id:)` path could not be used:

1. Its download globs are `*.safetensors`, `*.json`, `*.jinja`, so `system_v2.txt`
   never reaches disk.
2. The snapshot filter is `fnmatch(glob, path, 0)` — flags `0`, so `*` crosses
   `/`. `*.safetensors` therefore also matched the model repo's
   `adapter/adapters.safetensors` (67 MB), and `loadWeights` enumerates the model
   directory *recursively* before `update(parameters:verify: [.all])`, which
   rejects unused keys. The adapter holds 372 LoRA tensors with no home in the
   fused graph.

So the frozen path fetches an explicit file set (`model*.safetensors`, `*.json`,
`*.jinja`, `system_v2.txt`) and loads via `ModelConfiguration(directory:)`. The
model repo's `adapter/` also moved to
`abhiram3040/simplewords-dictation-cleanup-v2-adapter`, so a plain
`snapshot_download` can no longer repopulate a cache with LoRA weights.

PROBE_RESULT_PLACEHOLDER

## Prefix cache

Prefix KV caches are now keyed by profile key rather than style. On the legacy
path that is the style, unchanged. On the frozen path both `light` and `polish`
collapse onto one key: one prefill instead of two, and the prefix itself drops
from ~1100 tokens to ~330 because there is no few-shot block.

Consequence: `[cleanup] style` becomes a no-op for anyone on the fine-tune. It
still works on the Qwen3 presets. Flagging as a UX follow-up rather than
changing Settings in this PR.

## Not touched

`runCleanup` and `acceptOutput` — the safety net stays exactly as it is; it
correctly caught this model's two edge-case failures during the eval.

## Test plan

- `CleanupLogicTests` passes with zero edits (legacy regression gate)
- New: `CleanupPromptProfileTests` (7), `CleanupSimpleWordsPromptTests` (8)
- `CleanupModelLoadProbeTests`, env-gated behind `POMVOX_MODEL_PROBE=1`, asserts
  the frozen path loads, carries the prompt, and resolves a spoken
  self-correction to "Friday"
- Full suite green: `xcodebuild test -scheme Pomvox -destination 'platform=macOS'`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Before running: replace `PROBE_RESULT_PLACEHOLDER` with a short paragraph stating what Task 1's probe actually printed. If the stock path loaded successfully, say so plainly and note that point 2 above is a download-waste finding rather than a load failure.

- [ ] **Step 4: Verify the PR**

```bash
cd ~/dev/murmur && gh pr view --json number,title,mergeable,statusCheckRollup
```

---

### Task 8: Flip the default model

**Files:**
- Modify: `Pomvox/Sources/Engine/MemoryTier.swift:6`, `:46-60`
- Test: `Pomvox/Tests/MemoryTierTests.swift:44-58`

**Interfaces:**
- Consumes: nothing from Tasks 3–6 (this is a plain constant change; the engine already routes any id through `CleanupPromptProfile`).
- Produces: `MemoryTier.standardCleanupModel == "abhiram3040/simplewords-dictation-cleanup-v2"`, read by `NativeEngine.swift:668` and `LowMemoryCleanup.swift:43`.

- [ ] **Step 1: Update the failing test first**

In `Pomvox/Tests/MemoryTierTests.swift`, change the two `standardCleanupModel` assertions:

```swift
        XCTAssertEqual(MemoryTier.standardCleanupModel,
                       "abhiram3040/simplewords-dictation-cleanup-v2")
```

and add:

```swift
    /// The 8-bit fine-tune is ~2.2 GB resident — it does not belong on the
    /// low-memory tier, whose whole point is the ~1.4 GB compact model.
    func testTheCompactTierIsUnaffectedByTheStandardDefault() {
        XCTAssertEqual(MemoryTier.compactCleanupModel, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertNotEqual(MemoryTier.compactCleanupModel, MemoryTier.standardCleanupModel)
    }

    /// The frozen-prompt path must actually engage for the shipped default —
    /// otherwise the fine-tune runs on the few-shot prompt it was not trained on.
    func testTheStandardDefaultUsesTheFrozenPromptProfile() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel(MemoryTier.standardCleanupModel), .simpleWords)
        XCTAssertEqual(
            CleanupPromptProfile.forModel(MemoryTier.compactCleanupModel), .legacy)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' -only-testing:PomvoxTests/MemoryTierTests 2>&1 | tail -20
```

Expected: FAIL — `XCTAssertEqual failed: ("mlx-community/Qwen3-4B-4bit") is not equal to ("abhiram3040/simplewords-dictation-cleanup-v2")`.

- [ ] **Step 3: Change the constant and its comments**

`MemoryTier.swift:51` becomes:

```swift
    /// The standard cleanup model for 16 GB+ Macs (~2.2 GB resident): the
    /// SimpleWords dictation fine-tune, 8-bit fused. It ships its own frozen
    /// prompt (see `CleanupPromptProfile`) and beat Qwen3-4B on a 28-case eval
    /// with zero meaning corruptions at roughly 4x the speed.
    static let standardCleanupModel = "abhiram3040/simplewords-dictation-cleanup-v2"
```

Line 6 of the file header currently reads "also loads the Qwen3 cleanup LLM (~2.3 GB) — ~2.5 GB total". Replace "the Qwen3 cleanup LLM (~2.3 GB)" with "the cleanup LLM (~2.2 GB)".

In the `firstRunCleanupModel` doc comment (lines 53-57), replace "16 GB+ gets 4B (the previous unconditional default)" with "16 GB+ gets the SimpleWords fine-tune".

- [ ] **Step 4: Run to verify it passes**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' -only-testing:PomvoxTests/MemoryTierTests 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/Engine/MemoryTier.swift Pomvox/Tests/MemoryTierTests.swift
git commit -m "feat(cleanup): default 16GB+ Macs to the SimpleWords fine-tune"
git log -1 --pretty='%G? %s'
```

---

### Task 9: Settings preset and displayed default

**Files:**
- Modify: `Pomvox/Sources/SettingsSchema.swift:49-53`
- Modify: `Pomvox/Sources/SettingsStore.swift:39`
- Test: `Pomvox/Tests/SettingsSchemaTests.swift`, `Pomvox/Tests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: `MemoryTier.standardCleanupModel` from Task 8.
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing tests**

Add to `Pomvox/Tests/SettingsSchemaTests.swift`:

```swift
    func testTheDefaultCleanupModelIsOfferedAsAPreset() {
        XCTAssertEqual(
            SettingsSchema.cleanupModelPresets.first, MemoryTier.standardCleanupModel,
            "the shipped default should head the list the user picks from")
    }

    /// Open-source-first: swapping the default must not remove the Qwen3
    /// options a user may already be running.
    func testTheQwen3PresetsRemainSelectable() {
        for id in [
            "mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3-1.7B-4bit",
            "mlx-community/Qwen3-8B-4bit",
        ] {
            XCTAssertTrue(SettingsSchema.cleanupModelPresets.contains(id), id)
        }
    }
```

Add to `Pomvox/Tests/SettingsStoreTests.swift`:

```swift
    /// Settings must display the model the engine will actually run when
    /// `[cleanup] model` is absent, or the panel lies about the active model.
    func testTheDisplayedDefaultMatchesTheEngineDefault() {
        XCTAssertEqual(SettingsValues.defaults.cleanupModel, MemoryTier.standardCleanupModel)
    }
```

- [ ] **Step 2: Run to verify failure**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' -only-testing:PomvoxTests/SettingsSchemaTests \
  -only-testing:PomvoxTests/SettingsStoreTests 2>&1 | tail -20
```

Expected: two failures on the new assertions.

- [ ] **Step 3: Implement**

`SettingsSchema.swift:49-53` becomes:

```swift
    static let cleanupModelPresets = [
        MemoryTier.standardCleanupModel,
        "mlx-community/Qwen3-4B-4bit",
        "mlx-community/Qwen3-1.7B-4bit",
        "mlx-community/Qwen3-8B-4bit",
    ]
```

`SettingsStore.swift:39` becomes:

```swift
        cleanupModel: MemoryTier.standardCleanupModel,
```

Referencing the constant rather than repeating the string keeps the three declaration sites from drifting.

- [ ] **Step 4: Run the whole suite**

```bash
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme Pomvox -derivedDataPath /tmp/pomvox-hub-dd \
  -destination 'platform=macOS' 2>&1 | tail -20
```

Expected: `** TEST SUCCEEDED **`. `SettingsStoreTests` has an existing round-trip test that sets `cleanupModel = ""`; it should be unaffected.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add Pomvox/Sources/SettingsSchema.swift Pomvox/Sources/SettingsStore.swift \
        Pomvox/Tests/SettingsSchemaTests.swift Pomvox/Tests/SettingsStoreTests.swift
git commit -m "feat(settings): offer the fine-tune as the default preset"
git log -1 --pretty='%G? %s'
```

---

### Task 10: Commit the Python parity harness

**Files:**
- Create: `scripts/eval_cleanup_v2.py`

**Interfaces:**
- Consumes: nothing in Swift.
- Produces: a `--json <path>` dump of `{case name: {raw, out, accepted}}` for spot-comparing Swift output.

- [ ] **Step 1: Copy the ship-gate script**

```bash
cp /private/tmp/claude-501/-Users-abhiram-Desktop-projects-murmur/c68b34f0-67b7-41f9-bbea-98e0343b23a7/scratchpad/eval_cleanup_v2.py \
   ~/dev/murmur/scripts/eval_cleanup_v2.py
```

If that path no longer exists, reconstruct it from the model repo's `example.py` (which carries the recipe) plus the 28 cases; the file's own docstring lists the gate.

- [ ] **Step 2: Adapt the header and add JSON output**

Replace the module docstring's last line with a usage block, and note the guard is a port:

```python
#!/usr/bin/env python
"""Ship-gate eval for simplewords-dictation-cleanup-v2 (fused, 8-bit).

All 28 cases from eval rounds 1-3, run with the repo's OWN recipe (frozen
system_v2.txt, greedy, enable_thinking=False), through a Python port of
Pomvox's acceptOutput guard (Pomvox/Sources/Engine/CleanupLogic.swift), with
auto-scored checks on the release-gate cases.

Gate: zero self-correction inversions, zero guard rejections on ordinary
speech, no regression on v1's wins.

    uv run python scripts/eval_cleanup_v2.py
    uv run python scripts/eval_cleanup_v2.py --json /tmp/eval-v2.json

The --json dump is the parity reference: run the same raw strings through the
Swift engine (CleanupModelLoadProbeTests) and compare outputs case by case.
Keep the accept_output port below in sync with CleanupLogic.acceptOutput —
the Swift version is the source of truth.
"""
```

Add argument handling and the dump. At the top of `main()`:

```python
def main():
    import argparse, json
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", dest="json_path", default=None,
                    help="write per-case raw/out/accepted to this path")
    opts = ap.parse_args()

    path = snapshot_download(REPO)
```

Collect as the loop runs — add `results = {}` next to `passed = failed = 0`, and inside the loop after `accepted = accept_output(raw, out)`:

```python
        results[name] = {"raw": raw, "out": out, "accepted": accepted}
```

And just before the final `print` of the gate summary:

```python
    if opts.json_path:
        with open(opts.json_path, "w") as fh:
            json.dump(results, fh, indent=2, sort_keys=True)
        print(f"wrote {opts.json_path}")
```

- [ ] **Step 3: Run it**

```bash
cd ~/dev/murmur && uv run python scripts/eval_cleanup_v2.py --json /tmp/eval-v2.json 2>&1 | tail -15
```

Expected: `TOTAL: 24/28 passed` (or better) and `GATE (self-correction) failures: NONE`. If the gate line names any case, stop — moving `adapter/` must not have disturbed the weights, and something is wrong.

- [ ] **Step 4: Spot-compare against Swift**

Compare the `PROBE frozen:` output captured in Task 6 against `/tmp/eval-v2.json`'s `"R1 GATE day-correction"` entry — same raw string, so the cleaned text should match modulo the guard. Record the comparison for PR B's description.

- [ ] **Step 5: Commit**

```bash
cd ~/dev/murmur
git add scripts/eval_cleanup_v2.py
git commit -m "test(cleanup): commit the v2 ship-gate eval harness"
git log -1 --pretty='%G? %s'
```

---

### Task 11: On-device verification and PR B

**Files:**
- No source changes unless verification turns something up.

**Interfaces:**
- Consumes: Tasks 8–10.
- Produces: PR B.

- [ ] **Step 1: Build and install a Release build**

Release, not Debug: a Debug/self-signed swap invalidates the mic TCC grant. Expect one re-grant per install regardless, and copy to `~/Applications` so TCC keys to a stable path.

```bash
cd ~/dev/murmur/Pomvox && xcodegen generate
cd ~/dev/murmur && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -scheme Pomvox -configuration Release \
  -derivedDataPath /tmp/pomvox-hub-dd build 2>&1 | tail -5
rm -rf ~/Applications/Pomvox.app
cp -R /tmp/pomvox-hub-dd/Build/Products/Release/Pomvox.app ~/Applications/
open ~/Applications/Pomvox.app
```

- [ ] **Step 2: Start the log stream**

In a second terminal — `log` is a shadowed shell builtin, so use the absolute path, and `log show` will not do (it reads the past, and these lines are live):

```bash
/usr/bin/log stream --predicate 'process == "Pomvox"' --style compact | grep -E "cleanup:|pomvox-engine:"
```

- [ ] **Step 3: Arm through the UI and watch the download**

Enable the native engine in Settings, then arm from the menu bar. Do not arm by editing config.toml — arming through the UI is what exercises the real path.

Expected in the stream, in order:
- `pomvox-engine: stt model — mlx-community/parakeet-tdt-0.6b-v2` and no second STT fetch
- `cleanup: loaded abhiram3040/simplewords-dictation-cleanup-v2 in N.Ns (prompt profile: frozen)`
- `cleanup: cached NNN-token prefix for style=*` exactly **once** (not twice)

Then confirm nothing fetched a second cleanup model:

```bash
du -sh ~/.cache/huggingface/hub/models--* | sort -h | tail -5
```

Expected: the parakeet v2 model and the SimpleWords model. The Qwen3 dirs may still exist from earlier work — that is issue #100, not a regression; note which ones predate today.

- [ ] **Step 4: Verify a self-correction cleans correctly**

Dictate: *"let's meet tuesday wait no friday at noon"*

Expected: the pasted text contains **Friday** and not Tuesday, and the stream shows a `cleanup: gen …s prefill=…tok@… decode=…tok@… cached=prefix` line — `cached=prefix` proves the shared prefix cache is being hit.

- [ ] **Step 5: Verify raw fallback with cleanup off**

Turn `[cleanup] enabled` off in Settings, re-arm, dictate anything. Expected: the raw transcript pastes, no `cleanup:` generation lines, and no cleanup model load.

- [ ] **Step 6: Test the suggestion chips once**

Re-enable cleanup, re-arm, open the dictionary rule editor and add a term (e.g. `Pomvox`). The chips reuse the cleanup model with their own prompt, and the fine-tune is narrow — degradation is acceptable, but record what it produces for the PR.

- [ ] **Step 7: Open PR B**

```bash
cd ~/dev/murmur && git push
gh pr create --base feat/simplewords-cleanup-default \
  --head feat/simplewords-cleanup-default-b \
  --title "feat(cleanup): default to the SimpleWords fine-tune" --body "$(cat <<'EOF'
Stacked on the prompt-profile PR. Flips the 16 GB+ cleanup default to
`abhiram3040/simplewords-dictation-cleanup-v2` and commits the eval harness.

## Migration: none needed, and here is why

The original concern was that `persist(true)` writes `config.toml` at every arm
and might pin `[cleanup] model`. It does not — `NativeEngine.persist(_:)` writes
exactly one key, `[engine] native`. The other two writers are also safe:

- `SettingsIO.writeIfValid` diffs against a read that substitutes defaults for
  absent keys, so an absent `cleanup.model` is never written back.
- `LowMemoryCleanupModel.writeChoice` seeds the key only when absent, only on
  ≤ 8 GB Macs, and only with the compact model.

So the only users carrying an explicit `[cleanup] model` chose it deliberately in
Settings, and they keep it. Everyone else picks up the new default at their next
arm. **No migration code ships** — nothing rewrites a value the user set.

## Scope

- `MemoryTier.standardCleanupModel` → the fine-tune. `compactCleanupModel` stays
  Qwen3-1.7B-4bit: the fine-tune is 8-bit/~2.2 GB and defeats the compact tier.
- Settings presets gain the new id at the head; all three Qwen3 presets stay
  selectable.
- `SettingsValues.defaults.cleanupModel` now references the same constant, so the
  panel stops displaying a model the engine would not run.
- `scripts/eval_cleanup_v2.py`: the 28-case ship-gate harness, with `--json` for
  spot-comparing Swift output.

## Download hygiene

Audited per the spike brief. A fresh install fetches exactly one STT model
(parakeet v2, `SttModel.default`) and at most one cleanup model, at arm, only
when cleanup is enabled. `CleanupEngine.swift` has a single `loadContainer` call
site, and `suggestVariants` hard-guards on `container != nil` so suggestion chips
can never trigger a load.

Superseded models still linger in the HF cache after a default change — that is
#100, deliberately not implemented here.

## Known model behaviour (accepted, not worked around in Swift)

- Numbered-when-counted lists come out as bullets.
- `their were` → `there were` homophone fixes happen; the old prompt said leave
  homophones alone. Policy divergence, accepted for now.
- One observed subtle trim dropped a trailing "…or maybe wait".

A future data pass addresses these; guarding them in Swift would mean second-
guessing the model's output, which is what `acceptOutput` deliberately does not do.

ONDEVICE_RESULTS_PLACEHOLDER

SUGGESTVARIANTS_PLACEHOLDER

## Test plan

- Full suite green
- `uv run python scripts/eval_cleanup_v2.py`: 24/28, zero gate failures
- On-device Release build, armed via UI, verified with live `/usr/bin/log stream`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

Before running, create the PR B branch (`git checkout -b feat/simplewords-cleanup-default-b` at the point Task 8 began, cherry-picking tasks 8–10's commits onto it if they landed on the base branch), and replace both placeholders with what Steps 3–6 actually produced — the log lines, the pasted text, and the chip output.

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: §1 profile → Task 3; §2 prompt builder → Task 4; §3 loading → Task 6; §4 prefix cache → Task 5; §5 defaults/presets → Tasks 8–9; §6 HF hygiene → Task 2; §7 untouched → enforced by Global Constraints and Task 4's legacy regression test; testing → Tasks 1, 6, 10, 11; delivery → Tasks 7, 11. The spec's `suggestVariants` requirement is Task 11 Step 6. The spec's `SettingsValues` low-memory display bug is explicitly out of scope in both spec and plan.

**Placeholders.** Two intentional, both flagged inline with explicit instructions to replace before running: `PROBE_RESULT_PLACEHOLDER` (Task 7) and `ONDEVICE_RESULTS_PLACEHOLDER` / `SUGGESTVARIANTS_PLACEHOLDER` (Task 11). They exist because their content cannot be known until the command in an earlier step runs.

**Type consistency.** `CleanupPromptProfile.forModel`, `.prefixKeys`, `.prefixKey(forStyle:)`, `.frozenPromptFilename`, `.sharedPrefixKey` are declared in Task 3 and used with identical spelling in Tasks 5, 6, 8. `buildSimpleWordsMessages(text:system:termsHint:)` is declared in Task 4 and called with that exact label order in Task 6. `frozenPrompt` is declared in Task 6 Step 1 and read in Task 6 Step 6. `FrozenPromptError` is declared in Task 6 Step 1 and thrown in Steps 2 and 4.
