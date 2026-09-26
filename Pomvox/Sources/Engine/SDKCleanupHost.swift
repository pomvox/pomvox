import Foundation
import PomvoxCleanupMLX

/// Why an utterance's text is the original transcript rather than a cleaned
/// one. Content-free: these names are what history and logs record.
enum SDKFallbackReason: String, Sendable, CaseIterable {
    // Reported by the SDK in `CleanupResult.status`.
    case timedOut, rejected, unavailable, busy, tokenLimit, transport, invalidResponse
    // Decided by the host, before or around the request.
    /// Transcript over the SDK's 16,384-byte request limit. Never truncated or chunked.
    case unsupportedLength
    /// The host's own length ceiling (`CleanupDeadline.isHopeless`).
    case hostCeiling
    /// Over `SDKCleanupPolicy.maxCleanedBytes`: the baseline's guards have
    /// accepted outputs that dropped most of a long dictation.
    case longDictation
    /// No cleaner and no preparation (evicted and not reopened, or disabled).
    case notPrepared
    /// The utterance budget ran out while waiting for the shared preparation.
    case preparationTimedOut
    /// Preparation failed for a runtime reason (download, device lease, warmup).
    case preparationFailed
    /// Nothing left of the utterance budget by the time a request could be sent.
    case budgetExhausted
    /// The cleaner's worker is still running an expired request.
    case quarantined
    /// Evicted under memory pressure and the host's policy does not yet permit reopening.
    case memoryPolicy

    init(_ reason: CleanupCore.FallbackReason) {
        switch reason {
        case .timedOut: self = .timedOut
        case .rejected: self = .rejected
        case .unavailable: self = .unavailable
        case .busy: self = .busy
        case .tokenLimit: self = .tokenLimit
        case .transport: self = .transport
        case .invalidResponse: self = .invalidResponse
        }
    }
}

/// What one utterance got from the SDK backend, at the cleanup boundary —
/// before any host transform.
struct SDKCleanupOutcome: Sendable {
    enum Kind: Equatable, Sendable {
        case cleaned, unchanged
        case fallback(SDKFallbackReason)
        /// Setup or request configuration is wrong (pack, manifest, runtime
        /// compatibility, invalid request). Not a runtime hiccup, so it is
        /// surfaced to the user rather than quietly pasting raw forever.
        case configurationFailure(String)
    }

    /// The transcript exactly as it reached the cleanup boundary; SDK edit
    /// ranges are UTF-8 offsets into this string.
    let original: String
    /// `result.text` for cleaned/unchanged; `original`, byte for byte, otherwise.
    let text: String
    let kind: Kind
    let result: CleanupCore.CleanupResult?
    /// Host-observed time this utterance spent waiting for preparation. Nil
    /// when it did not wait.
    let preparationWaitMS: Double?

    static func fallback(_ original: String, _ reason: SDKFallbackReason,
                         result: CleanupCore.CleanupResult? = nil, waitedMS: Double? = nil) -> SDKCleanupOutcome {
        SDKCleanupOutcome(original: original, text: original, kind: .fallback(reason),
                          result: result, preparationWaitMS: waitedMS)
    }

    /// The app's four-value status for history and telemetry.
    var appStatus: CleanupStatus {
        switch kind {
        case .cleaned, .unchanged: return .ok
        case .configurationFailure: return .error
        case .fallback(let reason):
            switch reason {
            case .timedOut, .preparationTimedOut, .budgetExhausted, .notPrepared, .hostCeiling, .longDictation,
                 .memoryPolicy:  // a deliberate skip while memory is tight, not a failure
                return .timeout
            case .rejected: return .rejected
            default: return .error
            }
        }
    }

    /// Warning codes the SDK attached (`rejectedBy:<reason>`, cache misses).
    /// Codes only — the SDK never exposes candidate text.
    var warnings: [String] { result?.warnings ?? [] }

    /// Editor ranges for the SDK's edits, converted by the SDK against the
    /// original transcript. Empty unless the text was cleaned.
    func editorRanges() throws -> [NSRange] {
        guard kind == .cleaned, let result else { return [] }
        return try result.edits.map { try $0.utf16Range(in: original) }
    }

    /// Observed metrics for `history.timings_json`. A nil SDK field is left
    /// out — unknown is not zero, and not "cached".
    func timingNotes() -> [(String, Double)] {
        var notes: [(String, Double)] = []
        switch kind {
        case .fallback(let reason): notes.append(("sdk_fallback_\(reason.rawValue)", 1))
        case .configurationFailure: notes.append(("sdk_configuration_failure", 1))
        case .cleaned, .unchanged: break
        }
        for warning in warnings where warning.hasPrefix("rejectedBy:") {
            notes.append(("sdk_rejected_\(warning.dropFirst("rejectedBy:".count))", 1))
        }
        if let preparationWaitMS { notes.append(("sdk_preparation_wait_ms", preparationWaitMS)) }
        guard let t = result?.timings else { return notes }
        notes.append(("sdk_total_ms", t.totalMS))
        notes.append(("sdk_queue_ms", t.queueMS))
        notes.append(("sdk_budget_ms", t.budgetMS))
        if kind == .cleaned || kind == .unchanged {
            notes.append(("sdk_validation_ms", t.validationMS))
            notes.append(("sdk_diff_ms", t.diffMS))
        }
        if let v = t.tokenizationMS { notes.append(("sdk_tokenization_ms", v)) }
        if let v = t.prefillMS { notes.append(("cleanup_prefill_ms", v)) }
        if let v = t.inferenceMS { notes.append(("cleanup_decode_ms", v)) }
        if let v = t.prefixCacheUsed { notes.append(("cleanup_cached", v ? 1 : 0)) }
        if let v = t.promptTokens { notes.append(("cleanup_prompt_tokens", Double(v))) }
        if let v = t.decodeTokens { notes.append(("cleanup_decode_tokens", Double(v))) }
        if let v = t.speculativeRounds { notes.append(("cleanup_spec_rounds", Double(v))) }
        if let v = t.speculativeDrafted { notes.append(("cleanup_spec_drafted", Double(v))) }
        if let v = t.speculativeAccepted { notes.append(("cleanup_spec_accepted", Double(v))) }
        if let drafted = t.speculativeDrafted, drafted > 0, let accepted = t.speculativeAccepted {
            notes.append(("cleanup_spec_acceptance", Double(accepted) / Double(drafted)))
        }
        return notes
    }
}

/// The SDK cleanup backend: one serialized state machine owning at most one
/// preparation and one cleaner.
///
/// - Preparation is a single shared, unstructured task. It starts when cleanup
///   is enabled (at arm) or, after an eviction, when an utterance needs it and
///   the host's memory policy allows. Callers never own it: they wait on its
///   latch, cancellably and within their own budget, so one utterance's
///   cancellation cannot cancel the preparation another utterance needs.
/// - Disabling or evicting bumps `epoch`; a preparation that finishes into a
///   stale epoch closes its late cleaner instead of publishing it.
/// - Closing is `closeAndWait()` in an unstructured task tracked as
///   `retiring`. The next opener waits for it: the SDK's device lease admits
///   one resident model per process, and cancelling a wait never releases a
///   stuck worker or authorizes a second model.
/// - Reopening after an eviction passes `.validated(savedPack)` (a
///   process-local handle), falling back to fresh validation if the files'
///   identities changed. It still reloads weights and warms the prefix.
actor SDKCleanupHost {
    struct Preparation: Sendable, Equatable {
        enum Kind: String, Sendable {
            /// Installed now; first open reused the installer's validation.
            case installed
            /// Opened an existing installation with full validation.
            case opened
            /// Reopened after eviction with the process-local handle.
            case reopened
            /// The handle no longer matched; fully revalidated.
            case revalidated
        }
        let kind: Kind
        /// Host-observed, including install, retirement waits and open.
        let totalMS: Double
        /// The SDK's own aggregate (validation + load + prefix + warmup).
        let sdkPreparationMS: Double
    }

    enum Event: Sendable {
        case preparing
        case progress(Double)
        case prepared(Preparation, packID: String, packVersion: String, capabilities: [String])
        case failed(String, configuration: Bool)
        case evicted(EvictionReason)
    }

    enum EvictionReason: String, Sendable { case idle, memoryPressure, disabled }

    private let provisioner: any SDKPackProvisioning
    private let runtime: @Sendable ([String]) -> RuntimeFactory
    private let quarantineGrace: Duration
    private let onEvent: @Sendable (Event) -> Void
    /// Runs after a retiring cleaner has released its resources (the host's
    /// buffer-pool policy); never while any cleaner is resident or opening.
    private let afterRelease: @Sendable () -> Void

    private var enabled = false
    private var epoch = 0
    private var vocabulary = SDKVocabulary.empty
    private var cleaner: Cleaner?
    private var preparing: (id: UUID, task: Task<Void, Never>, done: AsyncLatch)?
    /// Cancelled preparations that may still be running (a model load does
    /// not stop mid-read). A new preparation waits for them.
    private var superseded: [AsyncLatch] = []
    private var retiring: (id: UUID, done: AsyncLatch)?
    private var savedPack: ValidatedPack?
    /// Utterances inside `clean` right now; an idle eviction waits them out.
    private var activeRequests = 0
    private(set) var failure: (message: String, configuration: Bool)?
    private(set) var generation = 0
    private(set) var lastPreparation: Preparation?

    /// `runtime` builds the factory for the selected vocabulary; tests inject
    /// a fake runtime and exercise the real `Cleaner` lifecycle around it.
    init(provisioner: any SDKPackProvisioning,
         runtime: @escaping @Sendable ([String]) -> RuntimeFactory = { RuntimeFactory.mlx(vocabulary: $0) },
         quarantineGrace: Duration = .milliseconds(1_500),
         afterRelease: @escaping @Sendable () -> Void = {},
         onEvent: @escaping @Sendable (Event) -> Void = { _ in }) {
        self.afterRelease = afterRelease
        self.provisioner = provisioner
        self.runtime = runtime
        self.quarantineGrace = quarantineGrace
        self.onEvent = onEvent
    }

    /// The SDK's guard rules identity, for capability/rules reporting.
    static var rulesVersion: String { CleanupCore.CleanupLogic.rulesVersion }

    // MARK: - State

    var isEnabled: Bool { enabled }
    var isResident: Bool { cleaner != nil }
    var isPreparing: Bool { preparing != nil }
    var isRetiring: Bool { retiring != nil }
    var selectedVocabulary: SDKVocabulary { vocabulary }
    /// The pack's declared capabilities — the opened pack's when resident,
    /// else the trusted manifest's.
    var capabilities: [String] { cleaner?.pack.manifest.capabilities ?? provisioner.trustedManifest.capabilities }
    var openedModelID: String? { cleaner?.pack.manifest.modelID }
    var availability: CleanerAvailability? { get async { await cleaner?.availability } }

    // MARK: - Lifecycle

    /// Cleanup enabled at arm: prepare now, not after a timer.
    func enable(vocabulary: SDKVocabulary) {
        enabled = true
        self.vocabulary = vocabulary
        failure = nil
        startPreparationIfNeeded()
    }

    /// Disarm / cleanup turned off / backend retired. Any preparation is
    /// cancelled and its late cleaner will be closed, never published.
    func disable() {
        guard enabled || cleaner != nil || preparing != nil else { return }
        enabled = false
        failure = nil
        cancelPreparation()
        if let cleaner { self.cleaner = nil; retire(cleaner) }
        onEvent(.evicted(.disabled))
    }

    /// Dictionary edited. Takes effect on the next request; the runtime
    /// rebuilds its single prefix once, on that request.
    func setVocabulary(_ vocabulary: SDKVocabulary) { self.vocabulary = vocabulary }

    /// An utterance needs cleanup. Starts the shared preparation if nothing is
    /// resident or in flight and `reopenPermitted` (the host memory policy).
    /// Returns whether a cleaner is resident or being prepared.
    @discardableResult
    func requestPreparation(reopenPermitted: Bool = true) -> Bool {
        guard enabled else { return false }
        if cleaner != nil || preparing != nil { return true }
        guard reopenPermitted else { return false }
        failure = nil
        startPreparationIfNeeded()
        return preparing != nil || cleaner != nil
    }

    /// Idle or memory-pressure eviction. Coalesces: an eviction with nothing
    /// resident or preparing is a no-op, and the cleaner stays evicted until
    /// `requestPreparation` — never reopened by the eviction itself.
    @discardableResult
    func evict(_ reason: EvictionReason) -> Bool {
        // Idle means idle: a dictation that raced the idle check keeps its
        // cleaner. Memory pressure evicts regardless; that request falls back.
        if reason == .idle, activeRequests > 0 { return false }
        var evicted = false
        if preparing != nil { cancelPreparation(); evicted = true }
        if let cleaner {
            self.cleaner = nil
            savedPack = cleaner.pack
            retire(cleaner)
            evicted = true
        }
        if evicted { onEvent(.evicted(reason)) }
        return evicted
    }

    /// Wait (cancellably, until `deadline`) for every retiring cleaner to
    /// release its resources. Cancelling this wait leaves the retirement
    /// tracked; the next opener still waits for it.
    func awaitRetirement(until deadline: ContinuousClock.Instant? = nil) async throws -> Bool {
        guard let retiring else { return true }
        return try await retiring.done.wait(until: deadline)
    }

    // MARK: - Cleaning

    /// Clean one utterance within `budget`. Throws only `CancellationError`;
    /// every other outcome — including configuration failures — is a value,
    /// and every fallback carries the original transcript unchanged.
    ///
    /// `unprepared` labels the fallback when nothing is resident or preparing
    /// (the host passes `.memoryPolicy` when its policy refused a reopen).
    func clean(_ raw: String, budget: CleanupBudget,
               unprepared: SDKFallbackReason = .notPrepared) async throws -> SDKCleanupOutcome {
        try Task.checkCancellation()
        guard raw.utf8.count <= 16_384 else { return .fallback(raw, .unsupportedLength) }
        activeRequests += 1
        defer { activeRequests -= 1 }
        // The dictionary as of this utterance, sent on the request itself: the
        // factory's vocabulary only pre-warms a cache, it is not a default.
        let terms = vocabulary.terms

        var waitedMS: Double?
        let cleaner: Cleaner
        while true {
            if let resident = self.cleaner { cleaner = resident; break }
            if let failure {
                return failure.configuration
                    ? SDKCleanupOutcome(original: raw, text: raw, kind: .configurationFailure(failure.message),
                                        result: nil, preparationWaitMS: waitedMS)
                    : .fallback(raw, .preparationFailed, waitedMS: waitedMS)
            }
            guard let preparing else { return .fallback(raw, unprepared, waitedMS: waitedMS) }
            let start = ContinuousClock.now
            let done = try await preparing.done.wait(until: budget.deadline)
            waitedMS = (waitedMS ?? 0) + start.duration(to: .now).milliseconds
            try Task.checkCancellation()
            if !done { return .fallback(raw, .preparationTimedOut, waitedMS: waitedMS) }
        }

        var availability = await cleaner.availability
        if availability == .quarantined {
            // A snapshot, not a reservation: wait briefly within this
            // utterance's budget, then make one attempt. Never a second model.
            let until = min(budget.deadline, ContinuousClock.now.advanced(by: quarantineGrace))
            while availability == .quarantined, ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(25))
                availability = await cleaner.availability
            }
        }
        try Task.checkCancellation()
        switch availability {
        case .quarantined: return .fallback(raw, .quarantined, waitedMS: waitedMS)
        case .closed: return .fallback(raw, .unavailable, waitedMS: waitedMS)
        case .ready, .working: break
        }
        guard let deadline = budget.requestDeadline() else {
            return .fallback(raw, .budgetExhausted, waitedMS: waitedMS)
        }

        let result: CleanupCore.CleanupResult
        do {
            result = try await cleaner.clean(CleanupCore.CleanupRequest(raw, vocabulary: terms, deadline: deadline))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CleanupCore.CleanupError {
            if case .unavailable = error { return .fallback(raw, .unavailable, waitedMS: waitedMS) }
            return SDKCleanupOutcome(original: raw, text: raw, kind: .configurationFailure(error.localizedDescription),
                                     result: nil, preparationWaitMS: waitedMS)
        } catch {
            return .fallback(raw, .unavailable, waitedMS: waitedMS)
        }
        try Task.checkCancellation()
        switch result.status {
        case .cleaned:
            return SDKCleanupOutcome(original: raw, text: result.text, kind: .cleaned, result: result,
                                     preparationWaitMS: waitedMS)
        case .unchanged:
            return SDKCleanupOutcome(original: raw, text: result.text, kind: .unchanged, result: result,
                                     preparationWaitMS: waitedMS)
        case .fallback(let reason):
            return .fallback(raw, SDKFallbackReason(reason), result: result, waitedMS: waitedMS)
        }
    }

    // MARK: - Preparation

    private func startPreparationIfNeeded() {
        guard enabled, cleaner == nil, preparing == nil else { return }
        let id = UUID()
        let done = AsyncLatch()
        let myEpoch = epoch
        let terms = vocabulary.terms
        let saved = savedPack
        superseded.removeAll { $0.opened }
        let priors = superseded
        let provisioner = self.provisioner
        let factory = runtime(terms)
        let onEvent = self.onEvent
        onEvent(.preparing)
        let task = Task.detached(priority: .userInitiated) {
            let started = ContinuousClock.now
            let result: Result<(Cleaner, Preparation.Kind), any Error>
            do {
                for prior in priors { _ = try await prior.wait() }
                if let retirement = await self.retirementLatch() { _ = try await retirement.wait() }
                try Task.checkCancellation()
                result = .success(try await Self.open(saved: saved, factory: factory, provisioner: provisioner,
                                                      onProgress: { onEvent(.progress($0)) }))
            } catch {
                result = .failure(error)
            }
            let totalMS = started.duration(to: .now).milliseconds
            await self.preparationFinished(id: id, epoch: myEpoch, result: result, totalMS: totalMS)
            done.open()
        }
        preparing = (id, task, done)
    }

    private static func open(saved: ValidatedPack?, factory: RuntimeFactory,
                             provisioner: any SDKPackProvisioning,
                             onProgress: @escaping @Sendable (Double) -> Void) async throws -> (Cleaner, Preparation.Kind) {
        let cleaner: Cleaner
        let kind: Preparation.Kind
        if let saved {
            do {
                cleaner = try await Cleaner.open(pack: .validated(saved), runtime: factory, policy: .local)
                kind = .reopened
            } catch CleanupCore.CleanupError.invalidPack(_) {
                // Files changed since validation: a fresh, full validation of
                // the trusted installation, never the stale handle.
                let provisioned = try await provisioner.provision(onProgress: onProgress)
                cleaner = try await Cleaner.open(pack: provisioned.source, runtime: factory, policy: .local)
                kind = .revalidated
            }
        } else {
            let provisioned = try await provisioner.provision(onProgress: onProgress)
            cleaner = try await Cleaner.open(pack: provisioned.source, runtime: factory, policy: .local)
            if case .installed = provisioned { kind = .installed } else { kind = .opened }
        }
        do {
            try SDKPackProvisioner.verify(cleaner.pack, trustedDigest: provisioner.trustedDigest)
        } catch {
            try? await cleaner.closeAndWait()
            throw error
        }
        return (cleaner, kind)
    }

    private func retirementLatch() -> AsyncLatch? { retiring?.done }

    private func preparationFinished(id: UUID, epoch myEpoch: Int,
                                     result: Result<(Cleaner, Preparation.Kind), any Error>,
                                     totalMS: Double) {
        if preparing?.id == id { preparing = nil }
        switch result {
        case .success(let (opened, kind)):
            guard myEpoch == epoch, enabled, cleaner == nil else {
                // Disabled, evicted or superseded while opening: close the late
                // cleaner and track it, never publish it into the new state.
                NSLog("cleanup: SDK cleaner finished opening after it was retired — closing it")
                retire(opened)
                return
            }
            cleaner = opened
            savedPack = opened.pack
            generation += 1
            failure = nil
            let preparation = Preparation(kind: kind, totalMS: totalMS, sdkPreparationMS: opened.preparationMS)
            lastPreparation = preparation
            let manifest = opened.pack.manifest
            NSLog("cleanup: SDK cleaner ready (%@ %@, %@, rules %@, prep %.0f ms, sdk %.0f ms)",
                  manifest.id, manifest.version, kind.rawValue, CleanupCore.CleanupLogic.rulesVersion,
                  totalMS, opened.preparationMS)
            onEvent(.prepared(preparation, packID: manifest.id, packVersion: manifest.version,
                              capabilities: manifest.capabilities))
        case .failure(let error):
            guard myEpoch == epoch, !(error is CancellationError) else { return }
            let configuration = Self.isConfiguration(error)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            failure = (message, configuration)
            if configuration { savedPack = nil }
            NSLog("cleanup: SDK preparation failed (%@): %@",
                  configuration ? "configuration" : "runtime", message)
            onEvent(.failed(message, configuration: configuration))
        }
    }

    /// Setup errors the user has to fix, as opposed to transient runtime ones.
    static func isConfiguration(_ error: any Error) -> Bool {
        if error is SDKPackError || error is DecodingError { return true }
        if let error = error as? CleanupCore.CleanupError {
            if case .unavailable = error { return false }
            return true
        }
        return false
    }

    private func cancelPreparation() {
        guard let preparing else { return }
        epoch += 1
        preparing.task.cancel()
        superseded.append(preparing.done)
        self.preparing = nil
    }

    private func retire(_ cleaner: Cleaner) {
        let id = UUID()
        let done = AsyncLatch()
        let previous = retiring?.done
        retiring = (id, done)
        // Unstructured and never cancelled: it waits for the actual release,
        // however long a stuck worker holds it.
        Task.detached {
            if let previous { _ = try? await previous.wait() }
            try? await cleaner.closeAndWait()
            await self.retirementFinished(id)
            done.open()
        }
    }

    private func retirementFinished(_ id: UUID) {
        if retiring?.id == id { retiring = nil }
        // Only with nothing resident, opening or still retiring: the clear is
        // process-global and must never pull buffers from under a live model.
        if retiring == nil, cleaner == nil, preparing == nil { afterRelease() }
    }
}
