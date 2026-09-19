import Foundation
import PomvoxCleanupMLX

/// `CleanupBackend` implemented on the external `pomvox-cleanup-engine` package.
///
/// The SDK owns model loading, the frozen prompt, the prefix cache, speculative
/// decoding, admission and the output guards; this file owns everything the SDK
/// deliberately left to the host — acquiring and installing the verified pack,
/// shaping the dictionary into the SDK's bounded `vocabulary`, sizing the
/// deadline the way the app measures it, and translating SDK outcomes back into
/// the app's four-value `CleanupStatus`.
///
/// Name collisions are real here: the app already has `CleanupStatus`,
/// `CleanupLogic`, `ChatMessage` and `SpeculativeDecoder`, and `PomvoxCleanupMLX`
/// re-exports its own. Everything from the package is written qualified
/// (`CleanupCore.X` / `PomvoxCleanup.X`) so a reader never has to guess which
/// one a bare name means, and so adding a type on either side cannot silently
/// change what this file compiles against.
actor SDKCleanupBackend: CleanupBackend {

    /// Where the verified pack lives. `[cleanup] pack_dir`, else
    /// `~/.pomvox/packs/simplewords-v3`; `POMVOX_CLEANUP_PACK` overrides both so
    /// a test can point at a prepared fixture without touching config.
    static func defaultPackDirectory(configured: String? = nil) -> URL {
        if let env = ProcessInfo.processInfo.environment["POMVOX_CLEANUP_PACK"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        if let configured, !configured.isEmpty {
            return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".pomvox/packs/simplewords-v3")
    }

    /// The only model this backend can serve: the pack manifest pins one
    /// snapshot, and the SDK's MLX runtime refuses any other artifact hashes.
    static let supportedModelID = "abhiram3040/simplewords-dictation-cleanup-v3"

    private let packDirectory: URL
    private let installer: CleanupPackInstalling
    private var cleaner: PomvoxCleanup.Cleaner?
    private var loadGeneration = 0
    private var preparing = false
    private var loadedModelID: String?
    private var termsHint = ""
    /// Accepted for protocol parity. The frozen SimpleWords prompt has no style
    /// control and the SDK rejects style settings outright, so this is recorded
    /// for diagnostics and never sent.
    private var preferredStyle = CleanupLogic.styles[0]
    /// Likewise: the SDK always runs its speculative path on the pinned
    /// baseline and exposes no switch. Recorded so a mismatch is visible.
    private var speculativeRequested = true
    private var lastTimings: CleanupCore.CleanupTimings?
    private var lastWarnings: [String] = []

    init(packDirectory: URL, installer: CleanupPackInstalling = CleanupPackInstaller()) {
        self.packDirectory = packDirectory
        self.installer = installer
    }

    // MARK: - Residency

    var isLoaded: Bool { cleaner != nil }
    var generation: Int { loadGeneration }
    var loadedModel: String? { loadedModelID }

    @discardableResult
    func prepare(
        modelID: String, onProgress: (@Sendable (Double) -> Void)? = nil
    ) async -> CleanupPrepareOutcome {
        guard cleaner == nil, !preparing else { return .skipped }
        guard modelID == Self.supportedModelID else {
            // Not a silent downgrade: the pack pins one snapshot, so any other
            // configured model has to be surfaced rather than quietly served by
            // the wrong weights.
            return .failed("cleanup SDK backend supports only \(Self.supportedModelID), not \(modelID)")
        }
        preparing = true
        defer { preparing = false }
        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            try await installer.ensureInstalled(packDirectory: packDirectory,
                                                modelID: modelID, onProgress: onProgress)
        } catch {
            return .failed("cleanup pack install failed: \(error)")
        }
        let installMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        do {
            let opened = try await PomvoxCleanup.Cleaner.open(
                pack: .directory(packDirectory), runtime: .mlx, policy: .local)
            cleaner = opened
            loadedModelID = opened.pack.manifest.modelID
            loadGeneration += 1
            NSLog("cleanup: SDK cleaner open (pack %@ %@, prep %.0f ms, install %.0f ms)",
                  opened.pack.manifest.id, opened.pack.manifest.version,
                  opened.preparationMS, installMs)
            // The SDK reports one preparation number covering hash validation,
            // weight load, prefix prefill and warmup. It does not split load
            // from warmup the way CleanupEngine does, so the cold-start row
            // carries the whole thing as load and 0 warmup rather than
            // inventing a split.
            return .loaded(loadMs: installMs + opened.preparationMS, warmupMs: 0)
        } catch {
            return .failed("cleanup SDK open failed: \(error)")
        }
    }

    func unload() {
        guard let cleaner else { return }
        self.cleaner = nil
        // close() stops admission immediately but releases the model only once
        // any in-flight worker returns, so this is fire-and-forget: the actor
        // must not block a memory-pressure eviction on a GPU pass.
        Task { await cleaner.close() }
        NSLog("cleanup: SDK cleaner closed (no prefix retained — reopen re-validates the pack)")
    }

    @discardableResult
    func unload(ifGeneration expected: Int) -> Bool {
        guard cleaner != nil, loadGeneration == expected else { return false }
        unload()
        return true
    }

    // MARK: - Prompt inputs

    func setTermsHint(_ hint: String) { termsHint = hint }
    func setPreferredStyle(_ style: String) { preferredStyle = style }
    func setSpeculativeDecoding(_ enabled: Bool) { speculativeRequested = enabled }

    /// Dictionary edits need no rebuild here: the SDK re-renders the vocabulary
    /// per request, so the next utterance already carries the new terms. (The
    /// cost of that design is that a vocabulary request may miss the SDK's
    /// prefix cache — `timingNotes()` reports `cleanup_cached` so a regression
    /// is visible in history rather than only in a benchmark.)
    func updateTermsHint(_ hint: String) async { termsHint = hint }

    // MARK: - Cleaning

    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
        guard timeoutS.isFinite, timeoutS > 0 else {
            throw CleanupBackendFailure.other("non-positive cleanup timeout")
        }
        let entered = CFAbsoluteTimeGetCurrent()
        var deadline = entered + timeoutS
        // Same race the in-app engine handles: a post-eviction dictation runs
        // while the reload its own key-up fired is still in flight. The SDK has
        // no notion of "opening" — `clean` on a nil cleaner would simply paste
        // raw — so the wait and the capped reload credit live here instead.
        // The actor suspends in the sleep, letting `prepare()` make progress.
        while CleanupResidency.shouldAwaitLoad(
            loaded: cleaner != nil, loading: preparing,
            now: CFAbsoluteTimeGetCurrent(), deadline: deadline, entered: entered)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let credit = CleanupDeadline.reloadCreditS(waited: CFAbsoluteTimeGetCurrent() - entered)
        if credit > 0.05 {
            deadline += credit
            NSLog("cleanup: waited %.1fs for SDK reload — credited to the deadline", credit)
        }
        guard let cleaner else {
            NSLog("cleanup: SDK cleaner not open%@, skipping",
                  preparing ? " within the deadline" : " (no load in flight)")
            return nil
        }
        let remaining = deadline - CFAbsoluteTimeGetCurrent()
        guard remaining > 0 else { return nil }
        let request = CleanupCore.CleanupRequest(
            text,
            vocabulary: Self.vocabulary(fromHint: termsHint),
            deadline: .seconds(min(Self.maxDeadlineS, remaining)))
        let result: CleanupCore.CleanupResult
        do {
            result = try await cleaner.clean(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CleanupBackendFailure.other(String(describing: error))
        }
        lastTimings = result.timings
        lastWarnings = result.warnings
        switch result.status {
        case .cleaned, .unchanged:
            return result.text
        case .fallback(let reason):
            switch reason {
            // Deadline and "no model" are what `nil` means to `runCleanup`.
            case .timedOut: return nil
            case .rejected: throw CleanupBackendFailure.rejected
            case .busy: throw CleanupBackendFailure.busy
            case .unavailable: throw CleanupBackendFailure.unavailable
            case .tokenLimit: throw CleanupBackendFailure.tokenLimit
            case .transport, .invalidResponse:
                throw CleanupBackendFailure.other(reason.rawValue)
            }
        }
    }

    /// The SDK refuses a deadline above 60 s outright (`invalidRequest`), and
    /// the app's widened budget can exceed it on a very long dictation, so the
    /// request is clamped rather than thrown away.
    static let maxDeadlineS = 60.0

    // MARK: - Vocabulary

    /// Recover the dictionary's terms from the app's prompt hint and shape them
    /// into the SDK's bounded `vocabulary`.
    ///
    /// The app carries the dictionary as one rendered prompt line
    /// (`dictionaryPromptHint`); the SDK takes the terms themselves and renders
    /// its own line. Parsing the app's line back into terms keeps a single
    /// source of truth (`PomvoxDictionary.hint`) instead of threading a second
    /// dictionary accessor through `NativeEngine`.
    ///
    /// The SDK's limits are hard: >64 terms, >128 bytes for one term or >2048
    /// bytes in total make `CleanupRequest.validate()` throw and cost the
    /// dictation its cleanup. Trimming to fit — in the user's own order, so the
    /// terms they care most about survive — degrades one term instead.
    static func vocabulary(fromHint hint: String) -> [String] {
        guard let range = hint.range(of: "fix the spelling): ") else { return [] }
        var tail = String(hint[range.upperBound...])
        if let stop = tail.range(of: ".\n", options: .backwards) { tail = String(tail[..<stop.lowerBound]) }
        else if tail.hasSuffix(".") { tail.removeLast() }
        let terms = tail.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return bounded(terms)
    }

    /// Enforce the SDK's documented request limits, in order, dropping the
    /// overflow. Newlines are stripped rather than dropping the term: the
    /// SDK refuses any term containing one.
    static func bounded(_ terms: [String]) -> [String] {
        var kept: [String] = []
        var bytes = 0
        var dropped = 0
        for term in terms {
            let flat = term.components(separatedBy: .newlines).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !flat.isEmpty else { continue }
            guard flat.utf8.count <= 128, kept.count < 64, bytes + flat.utf8.count <= 2_048 else {
                dropped += 1
                continue
            }
            kept.append(flat)
            bytes += flat.utf8.count
        }
        if dropped > 0 {
            NSLog("cleanup: %d dictionary term(s) dropped — SDK vocabulary limit (64 terms / 2048 bytes)",
                  dropped)
        }
        return kept
    }

    // MARK: - Diagnostics

    func timingNotes() -> [(String, Double)] {
        guard let t = lastTimings else { return [] }
        var notes: [(String, Double)] = []
        if let prefill = t.prefillMS { notes.append(("cleanup_prefill_ms", prefill)) }
        if let decode = t.inferenceMS { notes.append(("cleanup_decode_ms", decode)) }
        // The SDK reports prefix reuse by its absence: a generation that could
        // not use the prepared prefix warns. Same key the in-app engine writes,
        // so a history row reads the same either way.
        notes.append(("cleanup_cached", lastWarnings.contains("prefix-cache-not-used") ? 0 : 1))
        if let tokenization = t.tokenizationMS { notes.append(("sdk_tokenization_ms", tokenization)) }
        notes.append(("sdk_queue_ms", t.queueMS))
        notes.append(("sdk_validation_ms", t.validationMS))
        notes.append(("sdk_total_ms", t.totalMS))
        return notes
    }

    /// Test/diagnostic access to the last result's warnings.
    var warnings: [String] { lastWarnings }
    /// Test/diagnostic access to the last result's stage timings.
    var timings: CleanupCore.CleanupTimings? { lastTimings }
}
