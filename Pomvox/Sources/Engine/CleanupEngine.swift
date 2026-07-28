import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHuggingFace
import MLXLMTokenizers

/// Owns the mlx-swift-lm cleanup model (Qwen3 on the GPU; STT stays on the
/// ANE). Port of `cleanup.py`'s `CleanupEngine`, the same model-owner split as
/// `Transcriber`: `prepare()` loads + warms off the hot path (toggle-on),
/// `clean()` runs per utterance with a hard deadline. `nil` from `clean` means
/// deadline / model-not-ready — `runCleanup` turns every failure into the raw
/// transcript, so cleanup can only ever improve the text, never lose it.
/// Outcome of `CleanupEngine.prepare()`.
///
/// `.loaded` carries the cold-start split so the caller sees both the model
/// load and the warmup (which doubles as the Metal-kernel compile). `.skipped`
/// is a no-op — the model was already resident or a load was already in
/// flight — so it must not be reported as a fresh cold-start stage. `.failed`
/// means the model load threw: the engine is left unloaded (per-utterance
/// `clean()` returns nil, raw transcript pastes), and the caller MUST surface
/// it loudly rather than proceeding as if cleanup were ready.
enum CleanupPrepareOutcome: Sendable {
    case loaded(loadMs: Double, warmupMs: Double)
    case skipped
    case failed(String)

    /// Full preparation time (load + warmup) for the cold-start breakdown, or
    /// `nil` when nothing loaded this call (skipped or failed).
    var prepareMs: Double? {
        if case let .loaded(loadMs, warmupMs) = self { return loadMs + warmupMs }
        return nil
    }
}

actor CleanupEngine: CleanupCleaning {

    /// One prefix key's static prompt prefix (system + few-shot examples, ~95%
    /// of the prompt's tokens) and its prefilled KV cache. Keyed by
    /// `CleanupPromptProfile.prefixKey(forStyle:)`, which is the style itself
    /// on the legacy path and one shared key on the frozen path. `KVCache`
    /// isn't Sendable; safe here because the entry is built inside the model
    /// actor, only read afterwards, and per-request `copy()`s never escape
    /// `perform`.
    private final class PrefixEntry: @unchecked Sendable {
        let prefix: [Int]
        let cache: [KVCache]
        init(prefix: [Int], cache: [KVCache]) {
            self.prefix = prefix
            self.cache = cache
        }
    }

    private enum PrefixCacheError: Error {
        case unexpectedOffset(got: Int, want: Int)
        case notTrimmable
    }

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

    private var container: ModelContainer?
    private var preparing = false
    private var prefixCaches: [String: PrefixEntry] = [:]
    /// What `prefixCaches` was built for (see `PrefixCacheKey`). The caches
    /// are retained across idle eviction, so `prepare()` re-prefills only when
    /// the model or the dictionary hint actually changed — a same-model reload
    /// costs the ~1 s weight load, not the ~10 s per-key prefill.
    private var prefixKey: PrefixCacheKey?
    /// The id of the currently/last loaded model, for keying `prefixCaches`.
    private var loadedModelID: String?
    /// The configured cleanup style — its prefix builds FIRST so a dictation
    /// racing a cold-launch prepare() waits behind one useful prefill.
    private var preferredStyle = CleanupLogic.styles[0]
    /// The prompt recipe for the loaded model. Assigned in `prepare()` from the
    /// model id; `.legacy` until a model loads, which is also the right answer
    /// for every model but the SimpleWords fine-tune.
    private var profile: CleanupPromptProfile = .legacy

    /// The frozen system text for `.simpleWords`, read from the model snapshot
    /// at load. `nil` on the legacy path. Retained across idle eviction for the
    /// same reason the prefix caches are: it belongs to the model id, not to
    /// the container instance.
    private var frozenSystem: String?

    /// The loaded model's frozen prompt, for tests and diagnostics.
    var frozenPrompt: String? { frozenSystem }

    /// Prefix keys whose build finished this residency (success OR failure).
    /// `clean()` stops waiting for a key once its build was attempted — a
    /// failed build means uncached generation, the sanctioned fallback.
    private var prefixAttempted: Set<String> = []
    /// Dictations currently inside `clean()`. Non-preferred prefix builds
    /// yield the serial GPU queue while this is non-zero — otherwise a
    /// cold-launch dictation's generation queues behind a prefill for a key
    /// it doesn't use (rc.1: first chunk at 15.9 s, deadline 12.5 s).
    private var pendingCleans = 0

    /// Whether a hint-triggered prefix-cache rebuild is in flight. Coalesces
    /// overlapping updateTermsHint calls the way `preparing` coalesces
    /// prepare(): later calls just set the hint; the in-flight loop notices
    /// and rebuilds again, so the latest hint always wins.
    private var rebuildingHint = false

    /// Bumped on every successful load. The idle-eviction watchdog snapshots it
    /// before deciding to evict and passes it to `unload(ifGeneration:)`, so a
    /// load that races in after the decision (but before the unload lands on
    /// this actor) is detected and the eviction is skipped — otherwise the
    /// watchdog could drop a model that was just reloaded.
    private var loadGeneration = 0

    /// The current load generation (see `loadGeneration`), read on the actor.
    var generation: Int { loadGeneration }

    /// Custom-dictionary spelling rule injected into the cleanup prompt. Set at
    /// arm before `prepare()` so it's baked into the cached prefix (changing it
    /// is re-arm-required — the prefix cache is built once). Default "" keeps
    /// the prompt byte-identical to the no-dictionary case.
    private var termsHint = ""

    var isLoaded: Bool { container != nil }

    /// Set the dictionary prompt hint. Must precede `prepare()`/`buildPrefixCaches`
    /// so the hint rides inside the prefilled prefix.
    func setTermsHint(_ hint: String) { termsHint = hint }

    /// Set the configured style (see `preferredStyle`). Like the terms hint,
    /// set it before `prepare()` so the build order helps the first dictation.
    func setPreferredStyle(_ style: String) { preferredStyle = style }

    /// Hot-apply a dictionary words edit: swap the hint and, if the model is
    /// resident, rebuild the per-style prefix caches so the change takes
    /// effect on the next utterance — seconds of background prefill instead
    /// of a full re-arm. When the model isn't loaded this just stores the
    /// hint; the next prepare() bakes it in.
    ///
    /// Reentrancy: the actor suspends inside buildPrefixCaches, so a second
    /// edit or the idle-eviction unload can interleave. The loop re-checks
    /// the hint after every rebuild (latest wins), and a load-generation or
    /// container change mid-rebuild discards the orphaned work — mirroring
    /// prepare()'s `preparing` + `loadGeneration` guards.
    func updateTermsHint(_ hint: String) async {
        guard hint != termsHint else { return }
        termsHint = hint
        guard container != nil, !rebuildingHint else { return }
        rebuildingHint = true
        defer { rebuildingHint = false }
        var builtFor: String? = nil
        while builtFor != termsHint {
            guard container != nil else { return }   // evicted mid-loop; prepare() rebakes
            let target = termsHint
            let generation = loadGeneration
            prefixCaches = [:]
            await buildPrefixCaches()
            if container == nil || loadGeneration != generation {
                // Unload or a fresh load interleaved: that path owns the
                // caches now (prepare re-prefills on a PrefixCacheKey
                // mismatch). Drop our orphaned, possibly half-built work —
                // key included, so retention can't mistake it for complete.
                if container == nil {
                    prefixCaches = [:]
                    prefixKey = nil
                    prefixAttempted = []
                }
                return
            }
            builtFor = target
        }
        NSLog("cleanup: prefix caches rebuilt for new dictionary hint")
    }

    /// Download (first run, ~2.3 GB), load, and warm the model. Idempotent.
    /// Mirrors Python: a load failure leaves the engine unloaded (raw pastes,
    /// status timeout); a warmup failure still leaves it usable.
    /// `onProgress` reports the download fraction [0, 1] while the ~2.3 GB
    /// first-run fetch is in flight, so the background load can surface a note
    /// instead of the first few dictations silently pasting raw.
    /// Returns a `CleanupPrepareOutcome` describing the cold-start breakdown
    /// (item 3): `.loaded` with the load + warmup split when the model came up
    /// this call, `.skipped` when nothing loaded (already resident or a load in
    /// flight), or `.failed` when the load threw — the last leaves the engine
    /// unloaded so the caller can surface the failure loudly instead of
    /// silently pasting raw.
    @discardableResult
    func prepare(
        modelID: String, onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> CleanupPrepareOutcome {
        guard container == nil, !preparing else { return .skipped }
        preparing = true
        defer { preparing = false }

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

        // Warmup: prefill the static prompt prefix per prefix key (doubles as
        // the Metal kernel compile) and run one tiny generation. A warmup failure
        // is non-fatal (the model is loaded and usable), but it's timed and
        // folded into the returned span so the cold-start breakdown reflects
        // the full preparation cost.
        //
        // The prefill is skipped when the retained caches (they survive idle
        // eviction) still match this model + hint — the common post-evict
        // reload — so a dictation racing this prepare() can generate cached
        // the moment the container lands. A partial cache (a key failed
        // last time) still re-prefills.
        let t0 = CFAbsoluteTimeGetCurrent()
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
        do {
            _ = try await clean("um hello", style: preferredStyle, timeoutS: 120.0)
            NSLog("cleanup: warmup %.1fs", CFAbsoluteTimeGetCurrent() - t0)
        } catch {
            NSLog("cleanup: warmup failed: %@", String(describing: error))
        }
        if rebuild {
            // Remaining prefix keys build after warmup and YIELD to any
            // dictation mid-clean, so a real generation never queues behind a
            // prefill for a key it doesn't use. (Empty on the frozen path,
            // which has a single shared key.)
            await buildPrefixCaches(Array(order.dropFirst()), yieldToCleans: true)
        }
        let warmupMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return .loaded(loadMs: loadMs, warmupMs: warmupMs)
    }

    /// Drop the model weights (toggle-off / idle eviction); re-arm or next use
    /// reloads. The prefix caches are deliberately KEPT: they're ~100 MB of
    /// prompt-derived K/V tensors (vs the ~2.3 GB weights), independent of the
    /// container instance, and still valid for the same model + hint — which
    /// is what makes the post-eviction reload fast enough for a racing
    /// dictation's deadline. `prepare()` drops them itself when the
    /// `PrefixCacheKey` no longer matches.
    func unload() {
        guard container != nil else { return }
        container = nil
        Memory.clearCache()
        NSLog("cleanup: unloaded (prefix caches retained)")
    }

    /// Idle-evict variant: unload only if no load has completed since the
    /// caller snapshotted `generation`. Runs on the actor, so a `prepare()` that
    /// won the race to load the model bumps `loadGeneration` first and this
    /// no-ops — closing the check-then-unload window the watchdog would
    /// otherwise have. Returns whether the model was actually dropped.
    @discardableResult
    func unload(ifGeneration expected: Int) -> Bool {
        guard container != nil, loadGeneration == expected else { return false }
        unload()
        return true
    }

    /// Prefill a reusable KV cache of each prefix key's static prompt prefix.
    /// On the legacy path a prefix key IS a style, so this is one cache per
    /// style; on the frozen path every style shares one key and one cache.
    ///
    /// The prefix is found empirically — the longest common token prefix of
    /// two renders with different texts — because the chat template renders
    /// some messages position-dependently (e.g. Qwen3 injects an empty
    /// <think> block into the final assistant turn only). A failure here is
    /// non-fatal: the key just runs uncached (M0's sanctioned fallback).
    private func buildPrefixCaches(
        _ keys: [String]? = nil, yieldToCleans: Bool = false
    ) async {
        // `container.perform`'s closure is @Sendable, so hoist the actor state
        // the renders need into locals before the loop.
        let profile = self.profile
        let frozen = frozenSystem
        let keys = keys ?? profile.prefixKeys
        let hint = termsHint
        for key in keys {
            if yieldToCleans {
                while pendingCleans > 0 {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            guard let container = self.container else { return }
            do {
                let entry: PrefixEntry = try await container.perform { context in
                    let a = try await Self.renderTokens(
                        context, text: "placeholder one", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
                    let b = try await Self.renderTokens(
                        context, text: "a different text entirely", style: key, termsHint: hint,
                        profile: profile, frozenSystem: frozen)
                    let prefix = Array(a.prefix(CleanupLogic.commonPrefixLen(a, b)))
                    // TokenIterator prefills the prompt into the cache and
                    // samples ahead; generate one token like Python's
                    // stream_generate(max_tokens=1), then trim the overshoot
                    // back off so the cache holds exactly the prefix.
                    let cache = context.model.newCache(parameters: nil)
                    var iterator = try TokenIterator(
                        input: LMInput(tokens: MLXArray(prefix.map(Int32.init))),
                        model: context.model, cache: cache,
                        parameters: GenerateParameters(maxTokens: 1, temperature: 0.0))
                    _ = iterator.next()
                    let offset = cache.first?.offset ?? 0
                    let over = offset - prefix.count
                    guard over >= 0, over <= 2 else {
                        throw PrefixCacheError.unexpectedOffset(got: offset, want: prefix.count)
                    }
                    if over > 0 {
                        guard cache.allSatisfy({ $0.isTrimmable }) else {
                            throw PrefixCacheError.notTrimmable
                        }
                        for layer in cache { _ = layer.trim(over) }
                    }
                    // `perform` requires arrays evaluated before they leave.
                    eval(cache.flatMap { $0.innerState() })
                    return PrefixEntry(prefix: prefix, cache: cache)
                }
                prefixCaches[key] = entry
                NSLog("cleanup: cached %d-token prefix for style=%@", entry.prefix.count, key)
            } catch {
                NSLog(
                    "cleanup: prefix cache failed for style=%@ (%@) — running uncached",
                    key, String(describing: error))
            }
            prefixAttempted.insert(key)
        }
        prefixKey = PrefixCacheKey(modelID: loadedModelID ?? "", hint: hint)
    }

    /// Generate cleaned text, or `nil` on deadline / model not ready.
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
        pendingCleans += 1
        defer { pendingCleans -= 1 }
        let entered = CFAbsoluteTimeGetCurrent()
        let deadline = entered + timeoutS
        // A post-eviction dictation races the reload its own key-up fired
        // (ensureCleanupLoaded is fire-and-forget): the container is nil for
        // the ~1 s the weights take to come back, and bailing immediately
        // pasted raw after every idle gap. Wait out an in-flight load within
        // this utterance's own deadline (plus a short grace for a load that
        // hasn't reached the actor yet); the actor suspends here, so the
        // loading prepare() makes progress between polls.
        while CleanupResidency.shouldAwaitLoad(
            loaded: container != nil, loading: preparing,
            now: CFAbsoluteTimeGetCurrent(), deadline: deadline, entered: entered)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard let container else {
            NSLog(
                "cleanup: model not loaded%@, skipping",
                preparing ? " within the deadline" : " (no load in flight)")
            return nil
        }
        // Cold launch: this style's prefix may still be prefilling on the same
        // serial GPU queue. An uncached generation would queue BEHIND that
        // prefill and then re-prefill the whole prompt itself — rc.1's first
        // dictation burned 12.9s that way and pasted raw. Waiting for the
        // cache (while the deadline still leaves room to generate) turns that
        // into prefill-once-then-cached-gen.
        //
        // Snapshot the prompt recipe HERE, in the same suspension-free stretch
        // as the container guard above: `prepare()` publishes `container`,
        // `profile` and `frozenSystem` together without an await between them,
        // so reading all three before the next suspension is what guarantees
        // the recipe matches the weights. (The waits below suspend, so a
        // reload could otherwise split the pair.)
        let profile = self.profile
        let frozen = frozenSystem
        let prefixKeyForStyle = profile.prefixKey(forStyle: style)
        while CleanupResidency.shouldAwaitStylePrefix(
            cached: prefixCaches[prefixKeyForStyle] != nil,
            attempted: prefixAttempted.contains(prefixKeyForStyle),
            loading: preparing,
            now: CFAbsoluteTimeGetCurrent(), deadline: deadline)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // The STT pass that just ran leaves the MLX buffer pool full of
        // Parakeet-shaped buffers, which slowed the first generation by ~0.5s
        // in the Python engine (ARCHITECTURE.md). Dropping the pool is cheaper;
        // the next recording re-allocates off the stop-to-text critical path.
        Memory.clearCache()
        let cached = prefixCaches[prefixKeyForStyle]
        let hint = termsHint

        return try await container.perform { context in
            var tokens = try await Self.renderTokens(
                context, text: text, style: style, termsHint: hint,
                profile: profile, frozenSystem: frozen)
            // Reuse the prefilled static prefix: feed only the suffix tokens
            // with a copy of its KV cache (the deepcopy-per-request from
            // cleanup.py — `copy()` re-materializes, later updates never touch
            // the original). Falls through to the full prompt when unavailable.
            var cache: [KVCache]? = nil
            if let cached, tokens.count > cached.prefix.count,
                Array(tokens.prefix(cached.prefix.count)) == cached.prefix
            {
                tokens = Array(tokens.dropFirst(cached.prefix.count))
                cache = cached.cache.map { $0.copy() }
            }
            let maxTokens = max(64, min(2 * context.tokenizer.encode(text: text).count, 1024))
            let params = GenerateParameters(maxTokens: maxTokens, temperature: 0.0)

            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                cache: cache, parameters: params, context: context)
            let tGen = CFAbsoluteTimeGetCurrent()
            var parts: [String] = []
            for await generation in stream {
                switch generation {
                case .chunk(let piece):
                    parts.append(piece)
                    if CFAbsoluteTimeGetCurrent() > deadline {
                        // Returning ends stream consumption; the generation
                        // task is cancelled via the stream's onTermination.
                        NSLog("cleanup: deadline %.1fs hit, falling back to raw", timeoutS)
                        return nil
                    }
                case .info(let info):
                    // A legit cleanup is at most ~input-sized; hitting the
                    // 2x-input cap means a runaway (echo, analysis, invention)
                    // that was truncated — rc.1 pasted one mid-sentence. Raw
                    // is always the better paste.
                    if info.generationTokenCount >= maxTokens {
                        NSLog(
                            "cleanup: hit the %d-token cap — runaway output, falling back to raw",
                            maxTokens)
                        return nil
                    }
                    NSLog(
                        "cleanup: gen %.2fs prefill=%dtok@%.0ftps decode=%dtok@%.1ftps cached=%@",
                        CFAbsoluteTimeGetCurrent() - tGen,
                        info.promptTokenCount, info.promptTokensPerSecond,
                        info.generationTokenCount, info.tokensPerSecond,
                        cache == nil ? "no" : "prefix")
                default:
                    break
                }
            }
            return parts.joined()
        }
    }

    /// One-shot "what might the STT model write for ⟨term⟩?" generation for
    /// the rule editor's suggestion chips. Empty (not nil — chips are additive,
    /// there's no error state to surface) when the model isn't resident — the
    /// editor's heuristics are the floor and this is opportunistic garnish; it
    /// must never trigger a 2.3 GB load.
    func suggestVariants(for term: String, timeoutS: Double = 8.0) async -> [String] {
        guard let container else { return [] }
        guard !Task.isCancelled else { return [] }
        let deadline = CFAbsoluteTimeGetCurrent() + timeoutS
        let chat: [Chat.Message] = [
            .system("""
            You help a dictation app anticipate speech-to-text errors. \
            Given a word, list up to 5 plausible ways an STT model might \
            mistranscribe it when spoken aloud. One per line, lowercase, \
            no explanations, no numbering.
            """),
            .user(term),
        ]
        let raw: String? = try? await container.perform { context in
            let lmInput = try await context.processor.prepare(
                input: UserInput(chat: chat, additionalContext: ["enable_thinking": false]))
            let tokens = lmInput.text.tokens.asArray(Int.self)
            let params = GenerateParameters(maxTokens: 80, temperature: 0.0)
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(tokens.map(Int32.init))),
                cache: nil, parameters: params, context: context)
            var parts: [String] = []
            for await generation in stream {
                if case .chunk(let piece) = generation {
                    parts.append(piece)
                    if CFAbsoluteTimeGetCurrent() > deadline { return parts.joined() }
                    if Task.isCancelled { return parts.joined() }
                }
            }
            return parts.joined()
        }
        return parseVariantLines(raw ?? "", term: term)
    }

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
    /// isn't silently dropped. `*.json` does still cross '/' — a snapshot of the
    /// v2 repo lands an inert `adapter/adapter_config.json` (a training
    /// manifest) — but nothing in the load path reads json recursively, and
    /// excluding the adapter WEIGHTS is what keeps `loadWeights` happy.
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

    private static func toChat(_ messages: [ChatMessage]) -> [Chat.Message] {
        messages.map { message in
            switch message.role {
            case "system": return .system(message.content)
            case "assistant": return .assistant(message.content)
            default: return .user(message.content)
            }
        }
    }
}
