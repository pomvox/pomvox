import Foundation

/// Anonymous, content-free usage telemetry, gated on an explicit choice — **native
/// app only** (the Python reference engine stays no-network). On first launch the
/// user picks "Share anonymous stats" or "No thanks"; nothing sends unless they
/// choose to share. The product's promise is unchanged for the things that
/// matter: voice and transcripts never leave this Mac. What *can* leave — only
/// once the user has granted — is a handful of counters: a random per-install
/// UUID and a constrained allowlist of scalars.
///
/// The "no content ever" rule is enforced *structurally*, not by discipline:
/// `TelemetryProps` is a fixed set of typed scalars (there is no free-text field
/// to misuse), and `TelemetryEncoder` runs every prop through `TelemetrySanitizer`
/// at the wire boundary — a model id is reduced to its basename, anything that
/// can't match the contract's regex/enum is dropped. Sending is gated on
/// `maySend` (consent == .granted) AND a configured endpoint,
/// batched, fire-and-forget, and never on the dictation latency path.
///
/// Pure logic (store, sanitizer, encoder, queue, gate, env) is unit-tested in
/// TelemetryTests; the URLSession POST is the thin side-effect shell.

// MARK: - Consent + identity (UserDefaults-backed, native-only)

/// The user's choice and the anonymous install id. UserDefaults is the right
/// home: this is native-app state, not shared `config.toml` (which the Python
/// engine reads and must never learn about telemetry).
/// The user's explicit choice about telemetry. `.undecided` until they answer
/// the first-run choice screen; nothing sends unless it is `.granted`.
enum TelemetryConsent: String {
    case undecided, granted, denied
}

struct TelemetryStore {
    static let consentKey = "telemetry.consent"
    static let installIDKey = "telemetry.installID"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The user's explicit tri-state choice, set by the first-run choice screen
    /// ("Share anonymous stats" / "No thanks") or Settings → Privacy. Default
    /// `.undecided`. Existing installs have no key, so they read as `.undecided`
    /// and are shown the choice screen again — the migration off the earlier
    /// default-on behavior.
    var consent: TelemetryConsent {
        get { TelemetryConsent(rawValue: defaults.string(forKey: Self.consentKey) ?? "") ?? .undecided }
        set { defaults.set(newValue.rawValue, forKey: Self.consentKey) }
    }

    /// The send-gate: only an explicit `.granted` sends. `.undecided` and
    /// `.denied` never send — and nothing is even queued while not granted, so no
    /// buffered event can leak after a later choice.
    var maySend: Bool { consent == .granted }

    /// A random UUID v4, generated once and stable for the life of the install.
    /// Anonymous — it ties events from one machine together, nothing more.
    mutating func installID() -> String {
        if let existing = defaults.string(forKey: Self.installIDKey), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.installIDKey)
        return id
    }
}

// MARK: - Events (typed, allowlisted scalars only — no free-text field exists)

enum TelemetryEventName: String, Codable, Sendable {
    case appLaunch = "app_launch"
    case dictationCompleted = "dictation_completed"
    case cleanupUsed = "cleanup_used"
    case coldStart = "cold_start"
    case error
    case settingChanged = "setting_changed"
    case dictionaryEdited = "dictionary_edited"
}

/// The complete set of properties an event may carry. There is deliberately no
/// `String: Any` here: a transcript, file path, or email has nowhere to go.
struct TelemetryProps: Equatable, Codable, Sendable {
    var durationMs: Int?
    var sttModel: String?
    var cleanup: Bool?
    var cleanupStatus: String?   // ok | timeout | rejected | error | off
    var errorCode: String?       // enum-shaped: ^[a-z0-9_]{1,40}$
    // Cold-start breakdown (schema v2, `cold_start` event) — the four stages
    // that dominate first-dictation latency, plus whether the CoreML compile
    // cache was reused. All numeric/boolean; no content can ride here.
    var sttWeightLoadMs: Int?
    var coremlCompileMs: Int?
    var aneWarmupMs: Int?
    var cleanupLoadMs: Int?
    var coremlCacheHit: Bool?
    // `dictation_completed`'s `dictionaryFired` — how many fixup rules fired on
    // this utterance. A count, not content: no rule text, no source/target
    // words ride here.
    var dictionaryFired: Int?
}

extension TelemetryProps {
    /// Error-only props. `code` is enum-shaped (`^[a-z0-9_]{1,40}$`) — the
    /// sanitizer drops anything else.
    static func error(_ code: String) -> TelemetryProps {
        var p = TelemetryProps(); p.errorCode = code; return p
    }
}

struct TelemetryEvent: Equatable, Codable, Sendable {
    let event: TelemetryEventName
    let ts: Int                  // epoch milliseconds
    var props: TelemetryProps = TelemetryProps()
}

/// The batch envelope's stable, per-install metadata.
struct TelemetryEnv: Equatable, Sendable {
    let schemaVersion: Int
    let installID: String
    let appVersion: String
    let osVersion: String
    let arch: String
}

// MARK: - Sanitizer (validate-or-drop; the last line against content leaking)

enum TelemetrySanitizer {
    /// `mlx-community/parakeet-tdt-0.6b-v3` → `parakeet-tdt-0.6b-v3`. The full id
    /// is path-shaped (a slash); the contract's `stt_model` regex forbids it, so
    /// we send only the basename — and drop it entirely if even that can't match.
    static func sttModel(_ raw: String) -> String? {
        let base = String(raw.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
        return matches(base, "^[A-Za-z0-9._-]{1,64}$") ? base : nil
    }

    /// Clamp into the contract's range rather than drop — a duration is always
    /// meaningful; a nonsensical one just pins to a bound.
    static func durationMs(_ ms: Int) -> Int { max(0, min(ms, 86_400_000)) }

    static func cleanupStatus(_ s: String) -> String? {
        ["ok", "timeout", "rejected", "error", "off"].contains(s) ? s : nil
    }

    static func errorCode(_ s: String) -> String? {
        matches(s, "^[a-z0-9_]{1,40}$") ? s : nil
    }

    /// Clamp like `durationMs` — a count is always meaningful, a nonsensical one
    /// just pins to a bound. 10k is far past any plausible fired-rule count.
    static func dictionaryFired(_ n: Int) -> Int { max(0, min(n, 10_000)) }

    /// Every field validated-or-dropped. Idempotent, so encoding twice is safe.
    static func clean(_ p: TelemetryProps) -> TelemetryProps {
        var out = TelemetryProps()
        if let d = p.durationMs { out.durationMs = durationMs(d) }
        if let m = p.sttModel { out.sttModel = sttModel(m) }
        out.cleanup = p.cleanup
        if let c = p.cleanupStatus { out.cleanupStatus = cleanupStatus(c) }
        if let e = p.errorCode { out.errorCode = errorCode(e) }
        // Cold-start durations reuse the duration clamp (0…24h); the cache-hit
        // flag is a plain boolean and passes through untouched.
        if let v = p.sttWeightLoadMs { out.sttWeightLoadMs = durationMs(v) }
        if let v = p.coremlCompileMs { out.coremlCompileMs = durationMs(v) }
        if let v = p.aneWarmupMs { out.aneWarmupMs = durationMs(v) }
        if let v = p.cleanupLoadMs { out.cleanupLoadMs = durationMs(v) }
        out.coremlCacheHit = p.coremlCacheHit
        if let v = p.dictionaryFired { out.dictionaryFired = dictionaryFired(v) }
        return out
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Encoder (exact contract; sanitizes at the wire boundary)

enum TelemetryEncoder {
    static func batchObject(env: TelemetryEnv, events: [TelemetryEvent]) -> [String: Any] {
        [
            "schema_version": env.schemaVersion,
            "install_id": env.installID,
            "app_version": env.appVersion,
            "os_version": env.osVersion,
            "arch": env.arch,
            "events": events.map(eventObject),
        ]
    }

    private static func eventObject(_ e: TelemetryEvent) -> [String: Any] {
        var o: [String: Any] = ["event": e.event.rawValue, "ts": e.ts]
        // Sanitize here so content can never reach the wire, regardless of caller.
        let p = propsObject(TelemetrySanitizer.clean(e.props))
        if !p.isEmpty { o["props"] = p }   // events without props omit the key
        return o
    }

    private static func propsObject(_ p: TelemetryProps) -> [String: Any] {
        var o: [String: Any] = [:]
        if let v = p.durationMs { o["duration_ms"] = v }
        if let v = p.sttModel { o["stt_model"] = v }
        if let v = p.cleanup { o["cleanup"] = v }
        if let v = p.cleanupStatus { o["cleanup_status"] = v }
        if let v = p.errorCode { o["error_code"] = v }
        if let v = p.sttWeightLoadMs { o["stt_weight_load_ms"] = v }
        if let v = p.coremlCompileMs { o["coreml_compile_ms"] = v }
        if let v = p.aneWarmupMs { o["ane_warmup_ms"] = v }
        if let v = p.cleanupLoadMs { o["cleanup_load_ms"] = v }
        if let v = p.coremlCacheHit { o["coreml_cache_hit"] = v }
        if let v = p.dictionaryFired { o["dictionary_fired"] = v }
        return o
    }

    static func encodeBatch(env: TelemetryEnv, events: [TelemetryEvent]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: batchObject(env: env, events: events), options: [.sortedKeys])
    }
}

// MARK: - Bounded queue + 50-event chunking

struct TelemetryQueue: Sendable {
    private(set) var events: [TelemetryEvent] = []
    let cap: Int
    let maxBatch: Int

    init(cap: Int = 200, maxBatch: Int = 50) {
        self.cap = cap
        self.maxBatch = maxBatch
    }

    /// Rehydrate from a previous run. Still trimmed to `cap`, so a restored
    /// queue can never exceed the bound a live one respects.
    init(restoring events: [TelemetryEvent], cap: Int = 200, maxBatch: Int = 50) {
        self.cap = cap
        self.maxBatch = maxBatch
        self.events = events
        trim()
    }

    var isEmpty: Bool { events.isEmpty }

    mutating func enqueue(_ e: TelemetryEvent) {
        events.append(e)
        trim()
    }

    /// Up to `maxBatch` of the oldest events, removed from the queue.
    mutating func nextBatch() -> [TelemetryEvent] {
        let n = min(maxBatch, events.count)
        guard n > 0 else { return [] }
        let batch = Array(events.prefix(n))
        events.removeFirst(n)
        return batch
    }

    /// Put a batch back at the front after a retryable failure. Still bounded —
    /// a server that's down can never make the queue grow without limit.
    mutating func requeueFront(_ batch: [TelemetryEvent]) {
        events.insert(contentsOf: batch, at: 0)
        trim()
    }

    /// Drop everything pending. Used when consent is withdrawn.
    mutating func removeAll() { events.removeAll() }

    private mutating func trim() {
        if events.count > cap { events.removeFirst(events.count - cap) }
    }
}


// MARK: - Queue persistence (survives quit)

/// UserDefaults-backed persistence for the *pending* queue.
///
/// Without this the queue lives only in the actor, so quitting inside the ~2 s
/// flush debounce -- or while offline with a batch requeued after a retryable
/// failure -- silently loses those events. Nothing new is written that a flush
/// would not already have sent: `TelemetryEvent` is the same content-free set of
/// typed scalars, and it is dropped the moment consent is withdrawn.
///
/// The encoding here is Swift's synthesized `Codable` (camelCase keys), which is
/// deliberately *not* the wire contract -- `TelemetryEncoder` still owns that and
/// still sanitizes at the boundary. This is a private on-disk format, free to
/// change, and unreadable input is discarded rather than trusted.
struct TelemetryQueueStore {
    static let queueKey = "telemetry.pendingQueue"
    static let versionKey = "telemetry.pendingQueue.appVersion"

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Restore the queue recorded by a previous run of *this* app version.
    ///
    /// Events carry no version of their own -- the batch envelope stamps whatever
    /// `TelemetryEnv` is current at flush time. So events queued on 0.2.4 and
    /// flushed after an update to 0.2.5 would be reported as 0.2.5, quietly
    /// mis-attributing an install to a version that never ran. Dropping a handful
    /// of events across an update boundary is the cheaper error: the install
    /// still reports on its next launch, and per-version counts stay honest.
    func load(appVersion: String) -> [TelemetryEvent] {
        guard defaults.string(forKey: Self.versionKey) == appVersion,
              let data = defaults.data(forKey: Self.queueKey),
              let events = try? JSONDecoder().decode([TelemetryEvent].self, from: data)
        else {
            clear()
            return []
        }
        return events
    }

    func save(_ events: [TelemetryEvent], appVersion: String) {
        guard !events.isEmpty, let data = try? JSONEncoder().encode(events) else {
            clear()
            return
        }
        defaults.set(data, forKey: Self.queueKey)
        defaults.set(appVersion, forKey: Self.versionKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.queueKey)
        defaults.removeObject(forKey: Self.versionKey)
    }
}

// MARK: - Gate

enum TelemetryGate {
    /// Sends only when the user opted in AND an endpoint exists — so the whole
    /// system no-ops cleanly even before an endpoint is configured.
    static func shouldSend(enabled: Bool, endpoint: URL?) -> Bool {
        enabled && endpoint != nil
    }
}

// MARK: - Environment metadata

enum TelemetryEnvBuilder {
    /// Schema v2 adds the `cold_start` event and its numeric breakdown props;
    /// the ingest side must accept v2 (and the new fields) before this ships.
    static func current(installID: String) -> TelemetryEnv {
        TelemetryEnv(schemaVersion: 2, installID: installID,
                     appVersion: appVersion(), osVersion: osVersion(), arch: arch())
    }

    static func appVersion() -> String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func arch() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Send result (HTTP status → action)

enum TelemetrySendResult: Equatable, Sendable {
    case success            // 204 — drop the batch (done)
    case permanentFailure   // 400/405/413 — drop the batch (re-sending won't help)
    case retryableFailure   // 5xx / network — requeue (server dedupes, so safe)
}

// MARK: - Client (the thin side-effect shell over the pure pieces)

actor TelemetryClient {
    typealias Sender = @Sendable (URL, Data) async -> TelemetrySendResult

    /// The Pomvox ingest endpoint (GCP Cloud Run → BigQuery, separate repo).
    /// `nil` here would make the whole client no-op cleanly.
    static let productionEndpoint = URL(string: "https://murmur-ingest-w5tvsus5ia-uc.a.run.app")

    private var queue: TelemetryQueue
    private let endpoint: URL?
    private let isEnabled: @Sendable () -> Bool
    private let env: TelemetryEnv
    private let now: @Sendable () -> Int
    private let sender: Sender
    private let persist: @Sendable ([TelemetryEvent]) -> Void
    private var flushTask: Task<Void, Never>?

    /// `persist` is called with the full pending queue after every change, so a
    /// quit cannot lose what the ~2 s debounce hasn't flushed yet. It defaults to
    /// a no-op, which keeps the client pure for tests; `shared` injects the
    /// UserDefaults-backed store.
    init(endpoint: URL?, enabled: @escaping @Sendable () -> Bool, env: TelemetryEnv,
         now: @escaping @Sendable () -> Int, sender: @escaping Sender,
         queue: TelemetryQueue = TelemetryQueue(),
         persist: @escaping @Sendable ([TelemetryEvent]) -> Void = { _ in }) {
        self.endpoint = endpoint
        self.isEnabled = enabled
        self.env = env
        self.now = now
        self.sender = sender
        self.queue = queue
        self.persist = persist
    }

    /// The process-wide client. Reads consent fresh from UserDefaults on every
    /// flush, so turning the toggle off stops sending immediately.
    static let shared: TelemetryClient = {
        var store = TelemetryStore()
        let id = store.installID()
        let queueStore = TelemetryQueueStore()
        let appVersion = TelemetryEnvBuilder.appVersion()
        return TelemetryClient(
            endpoint: productionEndpoint,
            enabled: { TelemetryStore().maySend },
            env: TelemetryEnvBuilder.current(installID: id),
            now: { Int(Date().timeIntervalSince1970 * 1000) },
            sender: TelemetryClient.urlSessionSender,
            queue: TelemetryQueue(restoring: queueStore.load(appVersion: appVersion)),
            persist: { queueStore.save($0, appVersion: appVersion) })
    }()

    // MARK: enqueue

    /// Enqueue and persist, without scheduling a flush (used by tests).
    /// Production uses `emit`, which also schedules a debounced flush so
    /// back-to-back events batch into one POST.
    func record(_ event: TelemetryEvent) {
        queue.enqueue(event)
        persist(queue.events)
    }

    /// Drop everything pending, on disk included. Called when consent is
    /// withdrawn: events queued while granted must not outlive a "No thanks".
    func forget() {
        queue.removeAll()
        persist(queue.events)
    }

    /// Fire-and-forget entry from any context. Never blocks the caller; the
    /// gate makes it a true no-op when consent isn't granted or no endpoint is set.
    nonisolated func emit(_ name: TelemetryEventName, props: TelemetryProps = TelemetryProps()) {
        Task { await self.ingest(name: name, props: props) }
    }

    private func ingest(name: TelemetryEventName, props: TelemetryProps) {
        // Don't even buffer unless consent is granted — so an `.undecided` or
        // `.denied` session never accumulates events that could leak on a later
        // "Share". (flush() re-checks too, as defense in depth.)
        guard isEnabled() else { return }
        record(TelemetryEvent(event: name, ts: now(), props: props))
        scheduleFlush()
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // ~2 s debounce
            await self?.runScheduledFlush()
        }
    }

    private func runScheduledFlush() async {
        flushTask = nil
        await flush()
    }

    // MARK: flush

    func flush() async {
        guard TelemetryGate.shouldSend(enabled: isEnabled(), endpoint: endpoint),
              let endpoint else { return }
        while !queue.isEmpty {
            let batch = queue.nextBatch()
            guard !batch.isEmpty else { break }
            guard let data = try? TelemetryEncoder.encodeBatch(env: env, events: batch),
                  data.count <= 64_000 else {
                persist(queue.events)
                continue   // unencodable or over the 64 KB limit → drop this batch
            }
            switch await sender(endpoint, data) {
            case .success, .permanentFailure:
                persist(queue.events)
                continue   // done, or unrecoverable — either way, drop it
            case .retryableFailure:
                queue.requeueFront(batch)
                persist(queue.events)
                return     // stop now; a later flush retries (dedup makes it safe)
            }
        }
    }

    // MARK: side-effect shell

    static func classify(status: Int) -> TelemetrySendResult {
        switch status {
        case 200..<300: return .success
        case 500..<600: return .retryableFailure
        default: return .permanentFailure   // 400/405/413/etc — must not retry
        }
    }

    static let urlSessionSender: Sender = { url, data in
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("pomvox-macos", forHTTPHeaderField: "X-Pomvox-Client")
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return .retryableFailure }
            return TelemetryClient.classify(status: http.statusCode)
        } catch {
            return .retryableFailure   // network error → retry; server dedupes
        }
    }
}
