import ApplicationServices
import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by DictionaryStore after every save; the engine hot-reloads.
    static let pomvoxDictionaryDidChange = Notification.Name("app.pomvox.dictionaryDidChange")
    /// Posted by the engine when a changed words-hint has been re-baked into
    /// the cleanup prefix caches (drives the page's "applying…" indicator).
    static let pomvoxDictionaryHintApplied = Notification.Name("app.pomvox.dictionaryHintApplied")
    /// Posted by SettingsModel after a successful save. Most keys are
    /// snapshotted at arm() by contract; the engine listens so the handful that
    /// must feel instant (the dictation mark) take effect on the next utterance.
    static let pomvoxSettingsDidChange = Notification.Name("app.pomvox.settingsDidChange")
}

/// The native dictation engine, on by default behind the "Native engine (beta)"
/// toggle. M5 adds the live UX the Python HUD has: a never-steals-focus NSPanel
/// HUD with two-tone streaming drafts (incremental re-transcription on a ~1 s
/// cadence — M0 Result 2), a waveform and a VAD silence arc, hands-free mode
/// (Fn+Space), energy-based auto-stop, and Esc-cancel. M6 wires in the cleanup
/// LLM: STT stays on the ANE, LLM cleanup runs on the now-free GPU between
/// transcribe and paste when `[cleanup] enabled`, falling back to the raw
/// transcript on timeout/rejection/error — the raw <300 ms paste path is
/// untouched when cleanup is off. Mutual exclusion with the Python engine is
/// enforced by the pidfile.
///
/// Threading: the hotkey path runs on the event-tap thread (serialized by
/// `machineLock`); the audio callback posts level/VAD via the thread-safe
/// `HudBus` (and a single MainActor hop for the auto-stop action); everything
/// that touches the HUD, the audio/STT stack, or `@Published` state runs on the
/// main actor.
@MainActor
final class NativeEngine: ObservableObject {
    enum Status: Equatable {
        case off
        case preparing
        case ready
        case recording
        case transcribing
        case blocked(String)   // another engine holds the tap
        case failed(String)    // a grant is missing or the model failed to load
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lastTranscript = ""
    @Published private(set) var lastPasteMs: Double?

    // First-run model-download progress (see ModelLoadStatus). `speechLoad` is
    // non-nil while the speech model loads and stands in for the engine status
    // (it gates dictation). Cleanup has its own phase (`cleanupAvailability`):
    // the download is not cleared when it fails, so the menu bar can say why
    // cleanup isn't running.
    @Published private(set) var speechLoad: String?
    /// Choice (enabled) plus whether the model is actually downloaded, loading,
    /// resident, or failed. The Settings toggle writes config; this is what
    /// the running engine is doing with that choice.
    @Published private(set) var cleanupAvailability = CleanupAvailabilityState.initial

    /// Menu-bar note while cleanup is on but the model isn't resident.
    var polishLoad: String? { CleanupAvailability.menuLine(cleanupAvailability) }

    /// Phase of `cleanupAvailability`, for the dictation path.
    var cleanupPhase: CleanupModelPhase { cleanupAvailability.phase }

    // Setup heartbeat: last time the PTT key's own event reached the tap.
    // Distinguishes "tap dead / key handled in keyboard hardware" (stays nil)
    // from "events arrive, problem is downstream".
    @Published private(set) var lastPttSeenAt: Date?

    // The configured PTT key's display name, for the Setup heartbeat row.
    @Published private(set) var pttDisplayName = HotkeyMachine.displayName("fn")

    // Hotkey path — touched on the event-tap thread, serialized by the lock.
    // Rebuilt from [hotkey] at every arm() (snapshot-at-arm like [hud]/[cleanup]).
    // Reassigned only under machineLock, and only from loadEngineConfig() —
    // which runs before the tap installs, so a live tap never sees the swap.
    private nonisolated(unsafe) var machine: HotkeyMachine
    private nonisolated let machineLock = NSLock()
    private nonisolated(unsafe) var stopAt: CFAbsoluteTime = 0  // t0 for paste latency

    private let pidfile = Pidfile()
    private let capture = AudioCapture()
    private let transcriber = Transcriber()
    private let cleanup = CleanupEngine()

    /// UI access for the rule editor's variant suggestions — read-only use of
    /// the actor; `cleanup` is a `let`, so this is safe off the main actor.
    /// Only reached while `cleanupControls.modelVariantSuggestions` is true:
    /// under the SDK backend it would load a second resident model.
    nonisolated var variantSuggester: CleanupEngine { cleanup }

    // [cleanup] backend = "sdk": the SDK host. Created at the first SDK arm and
    // kept for the process, so a re-arm's opener waits for the previous arm's
    // retiring cleaner (the SDK admits one resident model per process).
    private var sdkHost: SDKCleanupHost?
    /// The last enable/disable/vocabulary call sent to `sdkHost`. Each new one
    /// waits for it, so a quick off→on (or disarm→arm) reaches the host in order.
    private var sdkHostOp: Task<Void, Never>?
    /// The backend this armed session runs (snapshot at arm).
    @Published private(set) var cleanupBackendKind = CleanupBackendKind.defaultKind
    /// Which cleanup controls the running backend honours; Settings and the
    /// dictionary editor hide or disable the rest.
    @Published private(set) var cleanupControls = CleanupControls.forBackend(
        .defaultKind, capabilities: ["vocabulary"])
    /// A cleanup setup failure the user has to act on (pack, manifest, runtime
    /// compatibility). Nil when cleanup is configured correctly.
    @Published private(set) var cleanupProblem: String?
    /// "pack version · rules version" once the SDK cleaner has opened.
    @Published private(set) var cleanupPackSummary: String?
    /// The utterance that owns insertion; cancel/sleep/disarm retire it.
    private let utterances = UtteranceSessions()
    private var utteranceTask: Task<Void, Never>?
    /// Whether an evicted cleaner may reopen (memory-pressure cool-down).
    private var memoryPolicy = CleanupMemoryPolicy()
    /// The trusted manifest's capabilities, until an opened pack reports its own.
    private var sdkCapabilities: [String] = []
    private var tap: EventTap?
    private let configPath: String

    // [cleanup] enabled / style / timeout / model hot-apply on save (and when
    // the low-memory sheet writes a choice). They used to be snapshotted only
    // in arm(), so the toggle could read ON while this process still had
    // cleanup off — and the model download never started.
    private var cleanupEnabled = true
    private var cleanupStyle = "polish"
    private var cleanupTimeoutS = 5.0
    // Placeholder only — loadEngineConfig() unconditionally overwrites this
    // before first use with the memory-tiered default or the config value.
    private var cleanupModelID = MemoryTier.standardCleanupModel

    // Cleanup LLM residency (items 4 & 5): STT loads eagerly at arm; the ~2 GB
    // cleanup model does NOT — it loads on first use or after `preloadDelayS`,
    // and is evicted after `idleEvictS` unused (reloads on next use). The hint
    // is snapshotted at arm and applied just before the deferred load so it
    // still rides inside the cached prompt prefix.
    private var cleanupIdleEvictS = CleanupResidency.lowMemoryIdleEvictS
    /// Drops the resident cleanup model when macOS reports memory pressure —
    /// the safety net that lets a 16 GB+ Mac keep the model loaded between
    /// dictations instead of evicting it on a timer.
    private var cleanupPressureSource: DispatchSourceMemoryPressure?
    /// `[cleanup] speculative` — prompt-lookup speculative decoding (default
    /// on; the kill switch is for diagnosing a suspected output difference).
    private var cleanupSpeculative = true
    private var cleanupHint = ""
    private var cleanupLastUsedAt: CFAbsoluteTime?
    private var cleanupLoadedAt: CFAbsoluteTime?
    /// In-memory load (`prepare`). Cancelled on disarm — the bytes stay on
    /// disk and the next arm loads them. This is NOT the download.
    private var cleanupLoadTask: Task<Void, Never>?
    /// Snapshot download. Detached from the engine session and from the
    /// per-utterance cleanup deadline: cancelling it mid-transfer leaves a
    /// Hugging Face `.lock` with no blob, and the next attempt waits on that
    /// lock forever. Disarm, quit-of-the-engine, and a 5 s timeout must not
    /// cancel this task.
    private var cleanupDownloadTask: Task<Void, Never>?
    /// True once arm has reached `.ready`. Weight loads wait for it so an
    /// 8 GB Mac isn't asked to resident the cleanup LLM while STT is still
    /// coming up. Downloads (disk only) do not wait.
    private var acceptingCleanupLoad = false
    /// Onboarding warm is recorded when the load — not just the download —
    /// succeeds. Remembered across the two steps.
    private var markCleanupWarmedOnLoad = false
    private var cleanupResidencyTask: Task<Void, Never>?
    // Perceived-fast HUD (item 8): the first dictation after arm pays the cold
    // model spin-up, so the HUD shows a shimmer placeholder for it. True until
    // the first finalize consumes it.
    private var coldFirstInference = true
    // STT model id, snapshotted at arm() for the (anonymous) dictation_completed
    // telemetry event — the basename only ever reaches the wire.
    private var sttModelID = "mlx-community/parakeet-tdt-0.6b-v2"
    // The resolved FluidAudio model the loader actually uses, from [stt] model.
    // Falls back to the shipped default when config names no wired model.
    private var sttModel = SttModel.default

    // [history] snapshot + store (M7a: the native engine writes the rows).
    // Opens at arm(), closes at disarm(); enabled=false writes nothing.
    private var historyEnabled = true
    private var historyRetentionDays = 7
    private var history: HistoryStore?

    // [dictionary] snapshot (Phase 4), read at arm() like [cleanup]. `words`
    // feed the cleanup prompt prefix (re-arm to apply); `replacements` post-fix
    // the final text just before paste, even when cleanup is off/timed out.
    private var dictionary = PomvoxDictionary(words: [], replacements: [])

    // [signature] snapshot: the opt-in emoji appended to the final text. Read
    // at arm() like the rest, but also hot-reloaded on every Settings save —
    // it's a toggle people flip per-post, so waiting for a re-arm would read
    // as broken. Off unless the user turned it on.
    private var signature = Signature()

    // HUD + bus (the bus is thread-safe; its drain renders on the main actor).
    private let hud: HudController
    private nonisolated let bus: HudBus

    // VAD endpointer — armed only in hands-free mode. Touched on the audio thread
    // (`process`) and the main actor (`arm`/`disarm`); guarded by `vadLock`.
    private nonisolated let vadLock = NSLock()
    private nonisolated(unsafe) var endpointer: Endpointer?
    private var vadEnabled = false

    // Session generation: bumped on every start/stop so a stale VAD endpoint
    // queued across sessions is a no-op (mirrors app.py `_session_gen`). Only the
    // main actor mutates it; the audio thread reads the endpointer's stamped copy.
    private var sessionGen = 0

    // Incremental re-transcription draft loop.
    private var draftTask: Task<Void, Never>?
    private var draftInFlight = false
    private var finishing = false

    // System sleep/wake: macOS disables the CGEventTap across sleep and, after a
    // deep sleep, silently stops delivering events to it even though it still
    // reports enabled — only a *fresh* tap recovers (CGEventTapEnable is not
    // enough). We also drop the push-to-talk key-up, stranding the machine in a
    // recording state. Registered in arm(), removed in disarm().
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var screensWakeObserver: NSObjectProtocol?
    private var wakeRecreateTask: Task<Void, Never>?
    // A wake fired during the .preparing download window, where recreateTap()
    // defers to arm()'s ownership of the tap; arm() retries the recreate once
    // it completes (the arm-installed tap may have died across the deep sleep).
    private var pendingTapRecreate = false

    init(configPath: String = SettingsModel.defaultPath()) {
        self.configPath = configPath
        self.machine = try! HotkeyMachine()  // fixed Fn push-to-talk bindings
        let hud = HudController()
        self.hud = hud
        self.bus = HudBus(render: { payloads in
            // The default schedule already runs on the main thread.
            MainActor.assumeIsolated { hud.render(payloads) }
        })
        NotificationCenter.default.addObserver(
            forName: .pomvoxDictionaryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadDictionary() }
        }
        NotificationCenter.default.addObserver(
            forName: .pomvoxSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSignature()
                // Cleanup enabled/style/timeout/model take effect on save,
                // including the low-memory sheet, which posts the same notice
                // after writing config.toml. A restart used to be required,
                // and the toggle lied until one happened.
                self?.applyCleanupSettingsFromDisk()
            }
        }
    }

    var isArmed: Bool {
        switch status {
        case .off, .blocked, .failed: return false
        default: return true
        }
    }

    /// The Setup checklist's "tap really works" probe: an Input Monitoring
    /// grant doesn't reach an already-running process (relaunch note).
    var tapInstalled: Bool { tap != nil }

    /// One engine per process — the AppDelegate auto-arms it at launch and the
    /// scenes observe it, so both need the same instance.
    static let shared = NativeEngine()

    // MARK: - arm / disarm (Settings/menu toggle, or the silent launch path)

    /// `interactive: false` is the launch auto-arm (M7a): never prompt, never
    /// dialog-storm a fresh login — a missing grant degrades to a menu-bar
    /// badge whose fix path is the Setup pane.
    func arm(interactive: Bool = true) async {
        guard !isArmed else { return }
        if let holder = pidfile.acquire("native") {
            // Name the pid and the executable: a bare "blocked by native engine"
            // is what made the 2026-08-27 stale-pidfile outage undiagnosable
            // from the log alone.
            NSLog("pomvox-engine: blocked by %@ engine (pid %d, %@)",
                  holder.name, holder.pid, holder.execPath ?? "path unknown")
            status = .blocked(
                "Pomvox's \(holder.name) engine (pid \(holder.pid)) is running — quit it "
                + "before enabling the native engine.")
            TelemetryClient.shared.emit(.error, props: errorProps("engine_blocked"))
            return
        }
        if interactive {
            let axTrusted = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            NSLog("pomvox-engine: arm() begin — AX trusted=%@", axTrusted ? "yes" : "no")
        } else {
            guard Permissions.allGranted() else {
                NSLog("pomvox-engine: auto-arm skipped — permissions missing")
                pidfile.release()
                status = .failed("Permissions needed — open Setup to finish enabling Pomvox.")
                TelemetryClient.shared.emit(.error, props: errorProps("permissions_missing"))
                return
            }
            NSLog("pomvox-engine: auto-arm — all grants present")
        }
        status = .preparing

        loadEngineConfig()

        // The audio callback posts mic level (waveform) and, when armed, drives
        // the VAD endpointer. Set before any capture.start().
        capture.onBlock = { [weak self] block in self?.onAudioBlock(block) }

        // Tap FIRST, model second: on a fresh install prepare() downloads
        // ~460 MB — with the tap already live, a press during the download
        // flashes "still downloading" instead of doing nothing (the
        // fresh-install "app is dead" report). startCapture() gates on .ready.
        let tap = makeTap()
        do {
            try tap.start()
            NSLog("pomvox-engine: event tap installed")
        } catch {
            NSLog("pomvox-engine: event tap FAILED (Input Monitoring?): %@", String(describing: error))
            pidfile.release()
            status = .failed(
                "Input Monitoring isn't granted. Enable Pomvox in System Settings ▸ Privacy & "
                + "Security ▸ Input Monitoring, then turn this on again.")
            TelemetryClient.shared.emit(.error, props: errorProps("input_monitoring_denied"))
            return
        }
        self.tap = tap
        // A brand-new tap owes nothing to wakes that predate it (and a stale
        // flag from a failed prior arm must not trigger a spurious recreate).
        pendingTapRecreate = false

        // History store (M7a): the engine process holds the pidfile, so it is
        // the single inserter. A failed open degrades to no-history — the
        // engine must dictate even when bookkeeping can't.
        if historyEnabled {
            history = HistoryStore(
                path: HistoryReader.defaultPath(), retentionDays: historyRetentionDays)
            if history == nil { NSLog("history: store failed to open — history disabled") }
        }

        // Live download percentage so the long first-run fetch (~460 MB) doesn't
        // read as a hang. The FluidAudio handler fires on an arbitrary queue and
        // often; the gate collapses it to distinct lines before the main hop.
        speechLoad = ModelLoad.line(.speech, fraction: nil, downloading: false)
        let speechGate = LineGate()
        // Cold-start instrumentation (items 1 & 3): probe the CoreML compile
        // cache before loading (was a compiled .mlmodelc already on disk?), then
        // measure each load stage so telemetry can show which one dominates.
        let cacheProbe = CompiledModelCache.probe(model: sttModel)
        NSLog("pomvox-engine: %@", cacheProbe.logLine(model: sttModel.rawValue))
        var cold = ColdStartTimings()
        cold.coremlCacheHit = cacheProbe.hit
        do {
            let sttTiming = try await transcriber.prepare(model: sttModel) { [weak self] fraction, downloading in
                let line = ModelLoad.line(.speech, fraction: fraction, downloading: downloading)
                guard speechGate.changed(line) else { return }
                Task { @MainActor in self?.speechLoad = line }
            }
            speechLoad = nil
            if sttTiming.alreadyLoaded {
                // Warm re-arm: STT didn't reload, so its cold-start stages and
                // the cache hit/miss don't apply this launch.
                cold.coremlCacheHit = nil
            } else {
                cold.sttWeightLoadMs = sttTiming.weightLoadMs
                cold.coremlCompileMs = sttTiming.coremlCompileMs
                cold.aneWarmupMs = sttTiming.aneWarmupMs
                // Record the artifact fingerprint so the next launch can tell
                // "unchanged" (compile cache persisted) from "recompiled".
                if let fp = CompiledModelCache.locate(model: sttModel) {
                    CompiledModelCache.record(fp, for: sttModel)
                }
            }
            NSLog("pomvox-engine: model ready")
        } catch {
            speechLoad = nil
            NSLog("pomvox-engine: model load FAILED: %@", String(describing: error))
            // Tear down whichever tap is *current* (self.tap), not the local
            // `tap` this catch closed over: recreateTap() now refuses to run
            // during .preparing, but tearing down through self.tap rather than
            // the stale local is the robust fix regardless — it can never drop
            // the last reference to a live, still-enabled tap.
            self.tap?.stop(); self.tap = nil
            pidfile.release()
            history?.close(); history = nil
            status = .failed("Speech model failed to load. \(error.localizedDescription)")
            TelemetryClient.shared.emit(.error, props: errorProps("model_load_failed"))
            return
        }

        // The STT breakdown is complete now; cleanup loads lazily (below), so
        // its load time is reported as a separate cold_start event when it
        // actually happens rather than blocking arm.
        emitColdStart(cold)

        // Lazy cleanup residency (items 4 & 5): don't load the ~2 GB LLM at
        // arm. Snapshot the prompt hint now (it rides inside the cached prefix),
        // schedule a background preload after a short delay, and start the
        // idle-eviction watchdog. First real use also triggers a load.
        //
        // Onboarding warm (item 2): on a fresh install, warm cleanup eagerly
        // *now* — while the user is still in Setup — so the cold-start cost
        // lands there instead of on their first real dictation. STT already
        // warmed during prepare() above. After this first warm, later launches
        // use the lazy path.
        acceptingCleanupLoad = true
        if cleanupEnabled, cleanupBackendKind == .sdk {
            // SDK backend: prepare now — cleanup is enabled and armed, so the
            // first dictation should not pay the open. No preload timer.
            cleanupLastUsedAt = nil
            cleanupLoadedAt = nil
            await enableSDKCleanup().value
            startCleanupResidencyWatchdog()
        } else if cleanupEnabled {
            cleanupHint = dictionary.hint
            cleanupLastUsedAt = nil
            cleanupLoadedAt = nil
            let onboarding = OnboardingWarm()
            if onboarding.shouldWarmNow {
                NSLog("pomvox-engine: first run — warming cleanup now (onboarding)")
            }
            // Fire-and-forget. The download starts now (disk only); weights
            // load when it finishes. Neither waits on arm→ready, and neither
            // is tied to a dictation's deadline. The onboarding flag is
            // recorded only once the weights are actually resident.
            syncCleanupModel(markWarmedOnSuccess: onboarding.shouldWarmNow)
            startCleanupResidencyWatchdog()
        }

        registerSleepWakeObservers()
        persist(true)
        // The first dictation of this armed session gets the cold-start shimmer.
        coldFirstInference = true
        NSLog("pomvox-engine: ARMED — ready")
        status = .ready
        if pendingTapRecreate {
            pendingTapRecreate = false
            recreateTap()   // a wake fired mid-download; the arm-installed tap may be dead
        }
        TelemetryClient.shared.emit(.appLaunch)
    }

    /// One enum-shaped code, never a message (the contract forbids free text).
    private nonisolated func errorProps(_ code: String) -> TelemetryProps {
        .error(code)
    }

    /// Log the cold-start breakdown and emit the anonymous `cold_start` event
    /// (numeric spans + cache hit only — no content). A no-op on a warm re-arm
    /// where nothing loaded, so we never send an all-empty event.
    private func emitColdStart(_ timings: ColdStartTimings) {
        guard timings.hasMeasurement else { return }
        NSLog("pomvox-engine: %@", timings.summary())
        TelemetryClient.shared.emit(.coldStart, props: timings.telemetryProps())
    }

    // MARK: - cleanup LLM residency (lazy-load + idle eviction)

    /// Load + warm the cleanup LLM if it isn't already resident, deduping
    /// concurrent triggers (a first-use press racing the delayed preload). The
    /// load is off the hot path — until it's ready, `clean()` returns nil and
    /// the raw transcript pastes, exactly as before.
    ///
    /// Returns immediately: the only work done synchronously on the caller's
    /// actor is the cheap guard and spawning `cleanupLoadTask`; every heavy step
    /// (the ~2 GB `cleanup.prepare()` load + warmup) runs inside that detached
    /// Task on the cleanup actor. So `arm()` — including the fresh-install
    /// onboarding warm that calls this eagerly — never waits on it: arm→ready
    /// stays fast whether cleanup warms now or lazily.
    ///
    /// Whether an in-flight cleanup load's completion should be ignored: its
    /// Task was cancelled (disarm/teardown cancels `cleanupLoadTask`) or the
    /// engine is no longer armed. `Task.isCancelled` reads the enclosing load
    /// Task here because this runs synchronously inside that Task's
    /// `MainActor.run` completion. Used so a load finishing after the session
    /// ended can't emit telemetry, persist the onboarding flag, or clobber a
    /// re-arm's fresh load token.
    private func isStaleCleanupLoad() -> Bool {
        Task.isCancelled || !isArmed
    }

    /// Bring the cleanup model in line with `cleanupAvailability`. Downloads
    /// run even when the engine is still starting (disk only). Weight loads
    /// wait until `acceptingCleanupLoad`.
    private func syncCleanupModel(markWarmedOnSuccess: Bool = false) {
        if cleanupBackendKind == .sdk {
            // The SDK host owns download, install and open (one shared
            // preparation). The in-app download/load must not also run: it
            // would load a second resident model. Key-up lands here too —
            // start the preparation early unless memory pressure evicted the
            // cleaner and the policy still says no.
            guard cleanupEnabled, isArmed, let sdkHost else { return }
            let permitted = memoryPolicy.permitsReopen(at: CFAbsoluteTimeGetCurrent())
            Task { await sdkHost.requestPreparation(reopenPermitted: permitted) }
            return
        }
        if markWarmedOnSuccess { markCleanupWarmedOnLoad = true }
        guard cleanupEnabled else { return }
        if cleanupDownloadTask != nil || cleanupLoadTask != nil { return }
        switch CleanupAvailability.action(for: cleanupAvailability) {
        case .none:
            return
        case .download:
            startCleanupDownload(modelID: cleanupModelID)
        case .load:
            beginCleanupLoad(modelID: cleanupModelID)
        }
    }

    /// Settings → Models "Download model" / "Retry download". Works whether or
    /// not the toggle is on: the bytes land either way, and the weights load
    /// only once cleanup is enabled and the engine is armed. A download
    /// already in flight is left alone (a second one deadlocks on the file lock).
    func downloadOrRetryCleanupModel() {
        if cleanupBackendKind == .sdk {
            // Retry = a fresh preparation; the host clears its last failure.
            syncCleanupModel()
            return
        }
        guard cleanupDownloadTask == nil, cleanupLoadTask == nil else { return }
        switch cleanupAvailability.phase {
        case .notDownloaded, .failed:
            startCleanupDownload(modelID: cleanupModelID)
        case .onDisk where cleanupEnabled && acceptingCleanupLoad:
            beginCleanupLoad(modelID: cleanupModelID)
        default:
            break
        }
    }

    /// Re-read `[cleanup]` and apply it now. Called on every settings save and
    /// when the low-memory sheet writes a choice — not on the next arm.
    private func applyCleanupSettingsFromDisk() {
        let doc = ConfigDocument.load(path: configPath)
        let previousModel = cleanupModelID
        let wasEnabled = cleanupEnabled
        let previousBackend = cleanupBackendKind
        loadCleanupSettings(from: doc)
        applyCleanupBackend(from: doc)
        if cleanupBackendKind != previousBackend {
            switchCleanupBackend(from: previousBackend)
            return
        }
        if cleanupBackendKind == .sdk {
            // Timeout is read per dictation; style and model are not the
            // SDK's (frozen prompt, one pack). Only the toggle acts here.
            if wasEnabled, !cleanupEnabled {
                disableSDKCleanup()
            } else if !wasEnabled, cleanupEnabled, isArmed {
                enableSDKCleanup()
                if cleanupResidencyTask == nil { startCleanupResidencyWatchdog() }
            }
            return
        }
        var next = cleanupAvailability
        next.enabled = cleanupEnabled
        if cleanupModelID != previousModel, cleanupDownloadTask == nil {
            // The snapshot we had resident (or were about to load) is for a
            // different id. Drop it and fetch the new one. An in-flight
            // download is for the previous id; its completion sees the
            // mismatch and starts this one, so it is not cancelled.
            Task { [cleanup] in await cleanup.unload() }
            next.phase = .notDownloaded
            next.downloadInFlight = false
        }
        if wasEnabled && !cleanupEnabled {
            // The engine may stay armed. Don't clear acceptingCleanupLoad —
            // that flag tracks arm/disarm, and clearing it here would refuse
            // to load the model when the user turns cleanup back on.
            cleanupLoadTask?.cancel()
            cleanupLoadTask = nil
            Task { [cleanup] in await cleanup.unload() }
            if next.phase == .ready || next.phase == .loading { next.phase = .onDisk }
        }
        cleanupAvailability = next
        if cleanupEnabled, isArmed, cleanupResidencyTask == nil {
            startCleanupResidencyWatchdog()
        }
        syncCleanupModel()
    }

    /// `[cleanup]` enabled / style / timeout / model, including the low-memory
    /// defaults for an absent key. Shared by arm() and by hot-apply.
    private func loadCleanupSettings(from doc: ConfigDocument) {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let lowMem = MemoryTier.isLowMemory(physicalMemory)
        let lowMemPrompted = UserDefaults.standard.bool(forKey: LowMemoryCleanupModel.promptedKey)
        let cleanupKeyPresent = doc.bool("cleanup", "enabled") != nil
        cleanupEnabled = doc.bool("cleanup", "enabled")
            ?? MemoryTier.firstRunCleanupDefault(isLowMemory: lowMem, lowMemPrompted: lowMemPrompted)
        if lowMem, !cleanupKeyPresent, !cleanupEnabled {
            let gb = Double(physicalMemory) / 1_073_741_824
            NSLog("pomvox-engine: low-memory Mac (%.1f GB) — cleanup off by default "
                  + "until the Hub prompt is answered", gb)
        }
        cleanupStyle = doc.string("cleanup", "style") ?? "polish"
        cleanupTimeoutS = doc.double("cleanup", "timeout_s") ?? 5.0
        cleanupModelID = doc.string("cleanup", "model")
            ?? MemoryTier.firstRunCleanupModel(physicalMemoryBytes: physicalMemory)
        var next = cleanupAvailability
        next.enabled = cleanupEnabled
        cleanupAvailability = next
    }

    /// Disk download, in a detached task. Not cancelled by disarm or by an
    /// utterance timeout — see `cleanupDownloadTask`.
    private func startCleanupDownload(modelID: String) {
        guard cleanupDownloadTask == nil, !cleanupAvailability.downloadInFlight else { return }
        let next = cleanupAvailability.applying(.downloadStarted)
        guard next.downloadInFlight else { return }
        cleanupAvailability = next
        let gate = LineGate()
        cleanupDownloadTask = Task.detached { [cleanup, weak self] in
            do {
                try await cleanup.downloadWeights(modelID: modelID) { [weak self] fraction in
                    let line = CleanupAvailability.modelStatusLine(.downloading(fraction: fraction))
                    guard gate.changed(line) else { return }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.cleanupAvailability = self.cleanupAvailability.applying(.progress(fraction))
                    }
                }
            } catch {
                let message = CleanupAvailability.failureMessage(error)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.cleanupDownloadTask = nil
                    self.cleanupAvailability = self.cleanupAvailability
                        .applying(.failed(.download(message)))
                    NSLog("pomvox-engine: cleanup model download FAILED: %@", message)
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.cleanupDownloadTask = nil
                guard self.cleanupModelID == modelID else {
                    // Finished a download the user has since switched away from.
                    var next = self.cleanupAvailability
                    next.downloadInFlight = false
                    next.phase = .notDownloaded
                    self.cleanupAvailability = next
                    self.syncCleanupModel()
                    return
                }
                self.cleanupAvailability = self.cleanupAvailability.applying(.downloadFinished)
                guard self.cleanupEnabled, self.acceptingCleanupLoad else { return }
                self.beginCleanupLoad(modelID: modelID)
            }
        }
    }

    /// Load weights that are already on disk. Cancelled on disarm (the
    /// snapshot remains). Not cancelled by an utterance timeout — this task
    /// is not a child of `cleanupWithWatchdog`.
    private func beginCleanupLoad(modelID: String) {
        // The guard and the `cleanupLoadTask` assignment below run without an
        // intervening await, and NativeEngine is @MainActor, so two triggers
        // are serialized: the first installs the task token, the second sees
        // it non-nil and bails.
        guard cleanupEnabled, acceptingCleanupLoad, cleanupLoadTask == nil,
              cleanupBackendKind == .inapp else { return }
        let hint = cleanupHint
        let style = cleanupStyle
        let speculative = cleanupSpeculative
        let markWarmed = markCleanupWarmedOnLoad
        cleanupAvailability = cleanupAvailability.applying(.loadStarted)
        cleanupLoadTask = Task { [cleanup, weak self] in
            let resident = await cleanup.isLoaded
            let residentID = await cleanup.loadedModel
            if resident, residentID == modelID {
                await MainActor.run {
                    guard let self, !self.isStaleCleanupLoad() else { return }
                    self.cleanupLoadTask = nil
                    self.cleanupLoadedAt = CFAbsoluteTimeGetCurrent()
                    self.cleanupAvailability = self.cleanupAvailability.applying(.loadFinished)
                    if markWarmed {
                        OnboardingWarm().markWarmed()
                        self.markCleanupWarmedOnLoad = false
                    }
                }
                return
            }
            await cleanup.setTermsHint(hint)
            await cleanup.setSpeculativeDecoding(speculative)
            // Build the configured style's prompt prefix first: a dictation
            // racing this load waits behind ONE useful prefill, not both
            // (rc.1's cold-launch first dictation burned its whole deadline
            // behind the other style's build and pasted raw).
            await cleanup.setPreferredStyle(style)
            // No download progress here. The snapshot was fetched by
            // startCleanupDownload; prepare() hits the cache and loads.
            // A progress callback would report "downloading" for a cache hit
            // and hide the real "loading" phase.
            let outcome = await cleanup.prepare(modelID: modelID)
            await MainActor.run {
                guard let self else { return }
                // If this load's Task was cancelled (disarm/teardown) or the
                // session otherwise ended while the load was in flight,
                // drop the completion entirely: it must not emit telemetry,
                // persist the onboarding flag, or clobber a subsequent re-arm's
                // fresh load token. Cancellation is cooperative (prepare() does
                // not poll it), so honoring it here is the single checkpoint.
                // The download task is a different task and is not cancelled
                // along with this one.
                guard !self.isStaleCleanupLoad() else { return }
                self.cleanupLoadTask = nil
                switch outcome {
                case .loaded:
                    // The idle-evict clock starts when the load actually
                    // completes, so a slow first-run load isn't counted as
                    // idle time against the model.
                    self.cleanupLoadedAt = CFAbsoluteTimeGetCurrent()
                    self.cleanupAvailability = self.cleanupAvailability.applying(.loadFinished)
                    if markWarmed {
                        OnboardingWarm().markWarmed()
                        self.markCleanupWarmedOnLoad = false
                    }
                    // Exactly one cold_start per load, structurally: prepare()
                    // returns `.loaded` only to the single deduped Task that
                    // actually brought the model up — concurrent triggers get
                    // `.skipped` or the already-resident early return above, and
                    // the stale-load guard drops a cancelled completion — so no
                    // extra dedup flag is needed.
                    var c = ColdStartTimings(); c.cleanupLoadMs = outcome.prepareMs
                    self.emitColdStart(c)
                case .skipped:
                    // A concurrent load beat us to it; leave its bookkeeping.
                    break
                case .failed(let reason):
                    // Non-fatal (raw transcript still pastes) but visible.
                    self.cleanupAvailability = self.cleanupAvailability
                        .applying(.failed(.load(reason)))
                    NSLog("pomvox-engine: cleanup model load FAILED: %@ — dictation will paste raw",
                          reason)
                    var p = TelemetryProps(); p.errorCode = "cleanup_load_failed"
                    TelemetryClient.shared.emit(.error, props: p)
                }
            }
        }
    }

    /// Evict the cleanup LLM once it's been idle past `cleanupIdleEvictS`; it
    /// reloads on next use. STT stays resident (small, always used). The wake
    /// interval is coarse so this costs nothing at rest.
    private func startCleanupResidencyWatchdog() {
        cleanupResidencyTask?.cancel()
        startCleanupPressureWatch()
        let evictS = cleanupIdleEvictS
        guard evictS > 0 else {
            NSLog("pomvox-engine: cleanup stays resident (idle_evict_s = 0); evicts on memory pressure")
            return
        }
        let interval = CleanupResidency.checkIntervalS(idleEvictS: evictS)
        if cleanupBackendKind == .sdk, let sdkHost {
            cleanupResidencyTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    if Task.isCancelled { break }
                    let resident = await sdkHost.isResident
                    let now = CFAbsoluteTimeGetCurrent()
                    let evict: Bool = await MainActor.run {
                        guard let self else { return false }
                        return CleanupResidency.shouldEvict(
                            loaded: resident, lastUsedAt: self.cleanupLastUsedAt,
                            loadedAt: self.cleanupLoadedAt, now: now, idleEvictS: evictS)
                    }
                    // The host refuses an idle eviction while a request is in
                    // flight, so a dictation racing this check keeps its cleaner.
                    if evict, await sdkHost.evict(.idle) {
                        NSLog("pomvox-engine: cleanup idle > %.0fs — SDK cleaner closed (reopens on next use)",
                              evictS)
                    }
                }
            }
            return
        }
        cleanupResidencyTask = Task { [weak self, cleanup] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                // Snapshot the load generation together with `isLoaded`: if a
                // load lands between here and the unload below, the generation
                // won't match and `unload(ifGeneration:)` no-ops.
                let generation = await cleanup.generation
                let loaded = await cleanup.isLoaded
                let now = CFAbsoluteTimeGetCurrent()
                let evict: Bool = await MainActor.run {
                    guard let self else { return false }
                    // A load already queued/in flight means the model is wanted;
                    // never evict out from under a pending load.
                    guard self.cleanupLoadTask == nil else { return false }
                    return CleanupResidency.shouldEvict(
                        loaded: loaded, lastUsedAt: self.cleanupLastUsedAt,
                        loadedAt: self.cleanupLoadedAt, now: now, idleEvictS: evictS)
                }
                guard evict else { continue }
                // Conditional on the snapshotted generation so a reload that
                // won the race isn't immediately dropped.
                let didEvict = await cleanup.unload(ifGeneration: generation)
                if didEvict {
                    await MainActor.run {
                        self?.cleanupLoadedAt = nil
                        if let self {
                            self.cleanupAvailability = self.cleanupAvailability.applying(.evicted)
                        }
                        NSLog("pomvox-engine: cleanup idle > %.0fs — evicted (reloads on next use)",
                              evictS)
                    }
                }
            }
        }
    }

    /// Evict the cleanup LLM on a memory-pressure warning, whatever the idle
    /// timer says. It reloads on next use exactly like an idle eviction; the
    /// prefix caches are retained, so the reload is the ~2 s weight read.
    private func startCleanupPressureWatch() {
        cleanupPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, cleanup] in
            guard let self else { return }
            let event = source.data
            let pressured = !event.intersection([.warning, .critical]).isEmpty
            let level: CleanupMemoryPolicy.Level =
                event.contains(.critical) ? .critical : (pressured ? .warning : .normal)
            self.memoryPolicy.record(level, at: CFAbsoluteTimeGetCurrent())
            if self.cleanupBackendKind == .sdk {
                // Stop admission and close; stay evicted until an utterance
                // needs cleanup and the policy permits — never reopen in
                // response to this same event.
                guard pressured, let host = self.sdkHost else { return }
                Task {
                    if await host.evict(.memoryPressure) {
                        NSLog("pomvox-engine: memory pressure (%@) — SDK cleaner closing",
                              event.contains(.critical) ? "critical" : "warning")
                    }
                }
                return
            }
            let pending = self.cleanupLoadTask != nil
            Task {
                let generation = await cleanup.generation
                let loaded = await cleanup.isLoaded
                guard CleanupResidency.shouldEvictOnPressure(
                    warningOrCritical: pressured, loaded: loaded, loadPending: pending)
                else { return }
                if await cleanup.unload(ifGeneration: generation) {
                    await MainActor.run {
                        self.cleanupLoadedAt = nil
                        self.cleanupAvailability = self.cleanupAvailability.applying(.evicted)
                        NSLog("pomvox-engine: memory pressure (%@) — cleanup evicted (reloads on next use)",
                              event.contains(.critical) ? "critical" : "warning")
                    }
                }
            }
        }
        source.activate()
        cleanupPressureSource = source
    }

    /// Cancel residency bookkeeping and the in-memory load. The snapshot
    /// download is intentionally not cancelled: this runs on disarm, which is
    /// exactly the "turn the engine off and on to apply cleanup" path, and
    /// cancelling the download there is what left a lock file and no blobs.
    private func stopCleanupResidency() {
        cleanupResidencyTask?.cancel(); cleanupResidencyTask = nil
        cleanupPressureSource?.cancel(); cleanupPressureSource = nil
        cleanupLoadTask?.cancel(); cleanupLoadTask = nil
        cleanupLastUsedAt = nil
        cleanupLoadedAt = nil
        // Clear the snapshotted prompt hint too: arm() re-snapshots it, but a
        // disarm without a following arm (e.g. a config change) must not leave a
        // stale hint that a later load could bake into the cached prefix.
        cleanupHint = ""
    }

    func disarm() {
        acceptingCleanupLoad = false
        unregisterSleepWakeObservers()
        pendingTapRecreate = false
        tap?.stop(); tap = nil
        draftTask?.cancel(); draftTask = nil
        endVadSession()
        capture.stop()
        capture.onBlock = nil
        // Unlike the ~600 MB Parakeet models (kept for fast re-arm), the
        // ~2 GB cleanup LLM is dropped on toggle-off; re-arm reloads in ~1.5s.
        stopCleanupResidency()
        cancelUtterance(reason: "disarm")
        disableSDKCleanup()
        Task { [cleanup] in await cleanup.unload() }
        bus.post(.state("idle", "ready"))   // hide the HUD if showing
        history?.close(); history = nil
        pidfile.release()
        resetMachine()
        persist(false)
        speechLoad = nil
        // Weights are gone; a download still in flight stays in flight.
        cleanupAvailability = cleanupAvailability.applying(.engineRestarted)
        status = .off
    }

    /// Synchronous teardown on app termination (menu Quit / ⌘Q → NSApp.terminate,
    /// which does *not* call disarm()). The Python engine gets this for free via
    /// `atexit.register(pidfile.release, …)`; the native app had no equivalent, so
    /// a Quit left the pidfile on disk, the CGEvent tap installed (still swallowing
    /// Fn), and the HUD pill on screen until the OS reaped the process — leaving
    /// Quit, the HUD, and the engine state out of sync (and, on pid reuse, a stale
    /// pidfile that makes the next launch report "blocked").
    ///
    /// Unlike disarm(), this deliberately does NOT persist(false): quitting must
    /// not silently turn "arm on launch" off. It otherwise mirrors disarm()'s
    /// resource release (tap, mic, HUD, history, pidfile, hotkey machine) so a
    /// Quit leaves nothing behind. Safe to call when idle/disarmed — every step
    /// is a no-op then.
    func prepareForTermination() {
        unregisterSleepWakeObservers()
        pendingTapRecreate = false
        tap?.stop(); tap = nil
        draftTask?.cancel(); draftTask = nil
        stopCleanupResidency()
        cancelUtterance(reason: "quit")
        disableSDKCleanup()
        endVadSession()
        capture.stop()
        capture.onBlock = nil
        hud.teardown()          // drop the pill now, no fade — Quit must not leave it up
        history?.close(); history = nil
        pidfile.release()       // the one thing that outlives the process: the on-disk lock
        resetMachine()          // clear the PTT machine's in-flight state, as disarm() does
        status = .off
    }

    /// Read `[hud]`/`[vad]`/`[cleanup]` from config.toml (defaults match
    /// `config.py`) and build the HUD config + the energy-only endpointer.
    private func loadEngineConfig() {
        let doc = ConfigDocument.load(path: configPath)

        // [hotkey] (#58): rebuild the machine from config. Settings' Hotkeys
        // pane rows are marked restart:true — snapshot-at-arm is the contract.
        let pttName = doc.string("hotkey", "ptt") ?? "fn"
        let (m, fellBack) = HotkeyMachine.resolved(
            ptt: pttName,
            toggle: doc.string("hotkey", "toggle") ?? "fn+space",
            stop: doc.string("hotkey", "stop") ?? "",
            cancel: doc.string("hotkey", "cancel") ?? "esc")
        if fellBack {
            NSLog("pomvox-engine: invalid [hotkey] config — using Fn defaults")
        }
        machineLock.lock(); machine = m; machineLock.unlock()
        pttDisplayName = HotkeyMachine.displayName(fellBack ? "fn" : pttName)
        NSLog("pomvox-engine: hotkeys — ptt=%@", pttDisplayName)

        let hudEnabled = doc.bool("hud", "enabled") ?? true
        hud.applyConfig(
            enabled: hudEnabled,
            position: doc.string("hud", "position") ?? "bottom-center",
            showDraft: doc.bool("hud", "show_draft") ?? true,
            sounds: doc.bool("hud", "sounds") ?? true,
            maxChars: doc.int("hud", "max_chars") ?? 120)
        hud.prepare()

        sttModelID = doc.string("stt", "model") ?? "mlx-community/parakeet-tdt-0.6b-v2"
        sttModel = SttModel.resolve(sttModelID)
        if SttModel.parse(sttModelID) == nil {
            NSLog("pomvox-engine: unrecognized [stt] model %@ — using %@",
                  sttModelID, sttModel.rawValue)
        }
        NSLog("pomvox-engine: stt model — %@ (FluidAudio %@)",
              sttModelID, sttModel.rawValue)
        // Memory-aware first-run default and the compact-model default live in
        // loadCleanupSettings (also the hot-apply path). The low-memory prompt
        // flag, not config-file existence, decides the default: persist(true)
        // writes config.toml at the end of every arm(), and a file-existence
        // heuristic used to flip cleanup back on at the second arm.
        let lowMem = MemoryTier.isLowMemory(ProcessInfo.processInfo.physicalMemory)
        loadCleanupSettings(from: doc)
        // `[cleanup] preload_delay_s` is intentionally not read. The download
        // used to wait out that delay on a task disarm() cancelled, so turning
        // the engine off and on — what the old UI told people to do — aborted
        // the transfer. The download starts as soon as cleanup is on.
        cleanupIdleEvictS = doc.double("cleanup", "idle_evict_s")
            ?? CleanupResidency.defaultIdleEvictS(isLowMemory: lowMem)
        cleanupSpeculative = doc.bool("cleanup", "speculative") ?? true
        cleanupProblem = nil
        cleanupPackSummary = nil
        applyCleanupBackend(from: doc, atArm: true)

        historyEnabled = doc.bool("history", "enabled") ?? true
        historyRetentionDays = doc.int("history", "retention_days") ?? 7

        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        let loaded = DictionaryLoader.load(
            configPath: configPath,
            dictionaryPath: DictionaryPaths.dictionaryPath())
        dictionary = PomvoxDictionary(file: loaded.file, enabled: dictEnabled)

        signature = Signature.read(doc)

        vadEnabled = doc.bool("vad", "enabled") ?? true
        let detector = EndpointDetector(
            silenceMs: doc.int("vad", "silence_ms") ?? 2000,
            minSpeechMs: doc.int("vad", "min_speech_ms") ?? 250,
            frameMs: 30,
            energyGateDbfs: doc.double("vad", "energy_gate_dbfs") ?? -45.0)
        let ep = Endpointer(backend: EnergyGateBackend(), detector: detector,
                            maxSessionS: doc.double("vad", "max_session_s") ?? 600.0)
        vadLock.lock(); endpointer = ep; vadLock.unlock()
    }

    /// Hot-apply a `[signature]` edit (posted by SettingsModel on every save).
    /// Takes effect on the next utterance — the mark is applied post-paste-path
    /// to the finished text, so there's nothing to rebuild.
    func reloadSignature() {
        let next = Signature.read(ConfigDocument.load(path: configPath))
        guard next != signature else { return }
        signature = next
        NSLog("pomvox-engine: dictation mark %@",
              next.enabled ? "on (\(next.mark))" : "off")
    }

    /// Hot-apply a dictionary edit (posted by DictionaryStore on every save).
    /// Rules take effect on the next utterance immediately (they run post-
    /// transcription). A words change re-bakes the cleanup prompt prefix in
    /// the background; dictation during the rebuild uses the new hint
    /// uncached (slower that one time, never stale).
    func reloadDictionary() {
        let doc = ConfigDocument.load(path: configPath)
        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        let loaded = DictionaryLoader.load(
            configPath: configPath,
            dictionaryPath: DictionaryPaths.dictionaryPath())
        dictionary = PomvoxDictionary(file: loaded.file, enabled: dictEnabled)
        NSLog("dictionary: hot-reloaded (%d rules)", loaded.file.rules.count)
        if cleanupBackendKind == .sdk {
            let vocabulary = SDKVocabulary.select(from: dictionary.cleanupWords)
            if let line = vocabulary.omissionSummary { NSLog("%@", line) }
            if let sdkHost {
                Task {
                    await sdkHost.setVocabulary(vocabulary)
                    NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
                }
            } else {
                NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
            }
            return
        }
        let hint = dictionary.hint
        if cleanupEnabled, hint != cleanupHint {
            cleanupHint = hint
            Task { [cleanup] in
                await cleanup.updateTermsHint(hint)
                NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
            }
        } else {
            NotificationCenter.default.post(name: .pomvoxDictionaryHintApplied, object: nil)
        }
    }

    // MARK: - hotkey path (event-tap thread)

    private nonisolated func decide(
        keycode: Int? = nil,
        _ body: (HotkeyMachine) -> HotkeyMachine.Decision
    ) -> HotkeyMachine.Decision {
        machineLock.lock()
        let decision = body(machine)
        let isPtt = keycode == machine.pttKeycode
        if decision.action == .stop { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = key-up
        machineLock.unlock()
        if isPtt { Task { @MainActor [weak self] in self?.lastPttSeenAt = Date() } }
        if decision.action != .none {
            let action = decision.action
            Task { @MainActor [weak self] in self?.handle(action) }
        }
        return decision
    }

    // MARK: - audio callback (audio thread)

    private nonisolated func onAudioBlock(_ block: [Float]) {
        bus.post(.level(level01(blockDbfs(block))))
        vadLock.lock()
        guard let ep = endpointer, ep.armed else { vadLock.unlock(); return }
        let (event, fraction) = ep.process(block)
        let gen = ep.generation
        vadLock.unlock()
        if let fraction { bus.post(.endpointProgress(fraction)) }
        switch event {
        case .endpoint:
            Task { @MainActor [weak self] in self?.onVadEndpoint(gen) }
        case .capWarning:
            bus.post(.state("recording", "recording — time limit soon"))
        case .speechStart, nil:
            break
        }
    }

    /// Main actor. The generation check makes a stale endpoint queued across
    /// sessions a no-op; `externalStop()` makes it a no-op in any state but TOGGLE.
    private func onVadEndpoint(_ generation: Int) {
        guard generation == sessionGen else {
            NSLog("pomvox-engine: vad stale endpoint (gen %d != %d)", generation, sessionGen)
            return
        }
        machineLock.lock()
        let stopped = machine.externalStop()
        if stopped { stopAt = CFAbsoluteTimeGetCurrent() }  // t0 = auto-stop
        machineLock.unlock()
        if stopped {
            NSLog("pomvox-engine: vad natural pause — auto-stop")
            finish()
        }
    }

    // MARK: - actions (main actor)

    private func handle(_ action: HotkeyMachine.Action) {
        switch action {
        case .startPTT:
            startCapture(mode: "push-to-talk")
        case .enterToggle:
            // A Fn+Space that raced the pre-ready guard (no capture ever
            // started) must not fake hands-free: it would set .recording with
            // no capture running and arm a VAD endpointer over dead audio.
            guard status == .recording else { resetMachine(); return }
            // Hands-free: keep recording, arm the energy endpointer.
            bus.post(.state("recording", "recording (hands-free)"))
            if vadEnabled {
                vadLock.lock(); endpointer?.arm(generation: sessionGen); vadLock.unlock()
                NSLog("pomvox-engine: hands-free — VAD armed (gen %d)", sessionGen)
            }
            status = .recording
        case .stop:
            finish()
        case .cancel:
            cancelRecording()
        case .none:
            break
        }
    }

    private func startCapture(mode: String) {
        // Tap is live before the model is (fresh-install download): a press
        // that can't record yet must say why instead of doing nothing.
        guard status == .ready || status == .recording else {
            let line = speechLoad ?? polishLoad
            let msg = line.map { "not ready yet — \($0)" }
                ?? "Pomvox is still starting up — try again in a moment"
            NSLog("pomvox-engine: press before ready (status not .ready) — %@", msg)
            bus.post(.result("error", msg))
            resetMachine()
            return
        }
        sessionGen += 1
        finishing = false
        do {
            try capture.start()
            NSLog("pomvox-engine: capture started (Fn down)")
            bus.post(.state("recording", "recording (\(mode))"))
            startDraftLoop()
            status = .recording
        } catch {
            // One opaque AVAudioEngine error covers every cause — reconstruct it
            // so a Mac with no mic isn't told to grant a permission it can't use.
            let failure = AudioCapture.StartFailure.classify(
                hasInputDevice: AudioCapture.hasInputDevice(),
                permissionGranted: Permissions.microphoneStatus() == true)
            NSLog("pomvox-engine: capture FAILED (%@): %@",
                  failure.errorCode, String(describing: error))
            bus.post(.state("idle", "ready"))
            status = .failed(failure.message)
            TelemetryClient.shared.emit(.error, props: errorProps(failure.errorCode))
            resetMachine()
        }
    }

    private func finish() {
        // A stop that raced the pre-ready guard in startCapture (Fn-up arriving
        // before the main actor ran the guard + resetMachine()) must not fake a
        // transcription cycle: with no capture ever started there is nothing to
        // stop/transcribe, and running the rest of this function would post a
        // bogus "transcribing" state, throw notLoaded, emit bogus stt_failed
        // telemetry, and flip status to .ready mid-download or un-fail a
        // .failed engine. onVadEndpoint's auto-stop only calls finish() when
        // status == .recording, so that path is unaffected by this guard.
        guard status == .recording else { resetMachine(); return }
        finishing = true
        endVadSession()
        draftTask?.cancel(); draftTask = nil
        status = .transcribing
        // The first finalize after arm pays the cold spin-up: mark its HUD
        // states so the renderer shimmers a placeholder (item 8). Consumed here
        // so every later dictation this session uses the plain label.
        let cold = coldFirstInference
        coldFirstInference = false
        let coldMark = cold ? HudConst.coldStartMark : ""
        bus.post(.state("transcribing", coldMark))
        // First real use warms cleanup (if the delayed preload hasn't already)
        // and marks it used so the idle-evict clock resets. The load is off the
        // hot path — this dictation still pastes raw if cleanup isn't ready yet.
        if cleanupEnabled {
            cleanupLastUsedAt = CFAbsoluteTimeGetCurrent()
            // Starts a download or a load if needed. Does not wait, and the
            // utterance below must not cancel either one.
            syncCleanupModel()
        }
        let samples = capture.stop()
        machineLock.lock(); let t0 = stopAt; machineLock.unlock()
        NSLog("pomvox-engine: stop — %d samples (%.1fs), transcribing", samples.count,
              Double(samples.count) / 16000)
        // Snapshot on the main actor; the Task below runs off it.
        let doCleanup = cleanupEnabled
        let style = cleanupStyle
        let timeoutS = cleanupTimeoutS
        let backend = cleanupBackendKind
        let sdk = sdkHost
        let reopenPermitted = memoryPolicy.permitsReopen(at: CFAbsoluteTimeGetCurrent())
        // This utterance now owns insertion; anything still in flight is superseded.
        utteranceTask?.cancel()
        let utterance = utterances.begin()
        let store = history
        let dict = dictionary
        let sig = signature
        let durationS = Double(samples.count) / 16000.0
        // Report the model that actually loaded (canonical id), not the raw
        // config string — an unrecognized value fell back to the default.
        let sttModelTelemetryID = sttModel.canonicalID
        // Eval capture (opt-in, default off): read per dictation so the
        // Privacy toggle applies without a re-arm. Configured cleanup id is the
        // fallback when the model never loaded (e.g. a timeout before warm).
        let captureEval = EvalCaptureSetting().isOn
        let configuredCleanupModelID = cleanupModelID
        utteranceTask = Task { [weak self] in
            guard let self else { return }
            // Stage timings mirror bench.py (t0 = key-up/auto-stop); they land
            // in history.timings_json with Python's keys.
            var timings = EngineTimings()
            timings.start(at: t0)
            var sttError: String?
            var raw = ""
            do {
                raw = try await self.transcriber.transcribe(samples)
            } catch {
                sttError = String(describing: error)
                NSLog("pomvox-engine: finalize transcribe FAILED: %@", sttError!)
            }
            timings.stamp("stt_finalize")
            // Length only: dictated text never goes to the system log.
            NSLog("pomvox-engine: transcript — %d chars", raw.count)
            var text = raw
            var cleanupStatus: CleanupStatus?
            // Cleanup OFF, or a whitespace-only transcript: nothing below runs.
            // The <300 ms raw path stays intact, and blank STT output is not
            // speech to polish — the model invents words from it. The draft
            // loop is already stopped (`finishing`), so the GPU pass never
            // overlaps STT on the ANE.
            var cleanupNotice: String?
            if doCleanup, !isBlankTranscript(raw), backend == .sdk {
                self.bus.post(.state("polishing", coldMark))
                let outcome: SDKCleanupOutcome
                if let sdk {
                    do {
                        outcome = try await runSDKCleanup(sdk, raw: raw, baseTimeoutS: timeoutS,
                                                          reopenPermitted: reopenPermitted)
                    } catch {
                        // Cancelled or superseded: never converted into a raw paste.
                        NSLog("pomvox-engine: utterance cancelled during cleanup — nothing inserted")
                        return
                    }
                } else {
                    outcome = SDKCleanupOutcome(
                        original: raw, text: raw,
                        kind: .configurationFailure("The cleanup SDK could not be set up."),
                        result: nil, preparationWaitMS: nil)
                }
                // result.text for cleaned/unchanged; the original, byte for
                // byte, for every fallback. The SDK already evaluated its
                // output — no second acceptOutput pass here.
                text = outcome.text
                cleanupStatus = outcome.appStatus
                timings.stamp("cleanup")
                for (key, value) in outcome.timingNotes() { timings.note(key, value) }
                switch outcome.kind {
                case .cleaned, .unchanged:
                    break
                case .fallback(let reason):
                    let codes = outcome.warnings.filter { $0.hasPrefix("rejectedBy:") }
                    NSLog("pomvox-engine: cleanup fallback (%@%@) — original transcript",
                          reason.rawValue, codes.isEmpty ? "" : ", " + codes.joined(separator: ","))
                    // The pack was still downloading, installing or opening:
                    // say so, as the in-app path does. The preparation keeps
                    // running — this dictation only stopped waiting for it.
                    if self.cleanupPhase != .ready {
                        cleanupNotice = CleanupAvailability.dictationNotice(
                            self.cleanupPhase, afterWaiting: true)
                        if cleanupNotice != nil { cleanupStatus = .unavailable }
                    }
                case .configurationFailure(let message):
                    NSLog("pomvox-engine: cleanup configuration failure — original transcript")
                    self.cleanupProblem = message
                    cleanupNotice = "cleanup unavailable (setup problem — see Settings)"
                    cleanupStatus = .unavailable
                }
            } else if doCleanup, !isBlankTranscript(raw) {
                let phase = self.cleanupPhase
                if let notice = CleanupAvailability.dictationNotice(phase) {
                    // Model isn't ready and waiting out the 5 s budget would
                    // not make a multi-GB download finish. Don't enter
                    // cleanupWithWatchdog: its cancelAll() is how a deadline
                    // used to be able to reach whatever shared the utterance
                    // task. The download/load tasks are not in that group,
                    // and this branch does not cancel them.
                    self.cleanupAvailability = self.cleanupAvailability.applying(.utteranceTimedOut)
                    cleanupNotice = notice
                    cleanupStatus = .unavailable
                    NSLog("pomvox-engine: %@ — pasting raw", notice)
                } else {
                    self.bus.post(.state("polishing", coldMark))
                    let (cleaned, status) = await cleanupWithWatchdog(
                        self.cleanup, raw: raw, style: style, timeoutS: timeoutS)
                    text = cleaned
                    cleanupStatus = status
                    timings.stamp("cleanup")
                    if status != .ok {
                        NSLog("pomvox-engine: cleanup %@ — pasting raw", status.rawValue)
                        // A real generation timeout (model was resident) stays
                        // `.timeout`. Timing out while the weights were still
                        // coming in is "unavailable", and the download/load
                        // is still running — this did not cancel it.
                        if self.cleanupPhase != .ready {
                            self.cleanupAvailability = self.cleanupAvailability
                                .applying(.utteranceTimedOut)
                            cleanupStatus = .unavailable
                            cleanupNotice = CleanupAvailability.dictationNotice(
                                self.cleanupPhase, afterWaiting: true)
                            if let cleanupNotice {
                                NSLog("pomvox-engine: %@", cleanupNotice)
                            }
                        }
                    }
                }
                // The prefill/decode split for this pass, so history rows say
                // WHERE cleanup time went, not just how much. A timeout while
                // waiting for a reload never reached the model — its stats
                // would be the previous dictation's, so skip them.
                if let cleanupStatus, cleanupStatus != .timeout, cleanupStatus != .unavailable,
                   let stats = await self.cleanup.lastGenStats {
                    for (key, value) in stats.timingNotes() { timings.note(key, value) }
                }
            }
            // What the cleanup model produced (or fell back to), before the
            // dictionary and the dictation mark touch it — the eval pair.
            let cleanedForEval = text
            let cleanupBoundaryText = text
            // The host pipeline, exactly once and in order, on the main actor:
            // spoken layout commands ("new line", "new paragraph", "bullet")
            // become layout — on the cleaned text AND on the raw fallback, since
            // the model renders them as words and a timeout must not also eat
            // them; then the custom-word fixups, so a misheard proper noun is
            // corrected whether cleanup polished the text, fell back to raw, or
            // is off (mirrors app.py); then the dictation mark, last, so it
            // decorates the finished text and never becomes input the LLM or a
            // replacement rule acts on. `deliverUtterance` re-checks this
            // utterance is still current after the transforms and immediately
            // before the paste.
            let notice = cleanupNotice
            let delivered: (text: String, fired: [String], appHint: String?, pastedAt: Double?)? =
                await MainActor.run {
                    var fired: [String] = []
                    var appHint: String?
                    var pastedAt: Double?
                    let delivery = deliverUtterance(
                        cleanupBoundaryText, id: utterance, sessions: self.utterances,
                        spokenFormatting: SpokenFormatting.apply,
                        dictionary: { text in
                            let applied = dict.applyReporting(text)
                            fired = applied.fired
                            return applied.text
                        },
                        signature: { sig.apply(to: $0) },
                        insert: { text in
                            (appHint, pastedAt) = self.insertFinal(
                                text, raw: raw, samples: samples, sttError: sttError, t0: t0,
                                cleanupNotice: notice)
                        })
                    guard case .inserted(let text) = delivery else { return nil }
                    self.utterances.retire()
                    return (text, fired, appHint, pastedAt)
                }
            guard let delivered else {
                NSLog("pomvox-engine: utterance superseded — result discarded, nothing inserted")
                return
            }
            text = delivered.text
            let applied = DictionaryApplied(text: text, fired: delivered.fired)
            let (appHint, pastedAt) = (delivered.appHint, delivered.pastedAt)
            if !applied.fired.isEmpty {
                DictionaryStatsStore.shared.record(applied.fired)
            }
            // Anonymous telemetry, emitted here for the same reason history is —
            // strictly after the paste, off the latency path. Fire-and-forget;
            // a true no-op unless the user opted in. Never any text.
            if !text.isEmpty {
                var props = TelemetryProps()
                props.durationMs = Int(durationS * 1000)
                props.sttModel = sttModelTelemetryID
                props.cleanup = doCleanup
                props.cleanupStatus = cleanupStatus?.rawValue ?? "off"
                props.dictionaryFired = applied.fired.isEmpty ? nil : applied.fired.count
                TelemetryClient.shared.emit(.dictationCompleted, props: props)
                if doCleanup {
                    var used = TelemetryProps()
                    used.cleanup = true
                    used.cleanupStatus = cleanupStatus?.rawValue ?? "off"
                    TelemetryClient.shared.emit(.cleanupUsed, props: used)
                }
            }

            // History row, strictly after the paste and the ready flip — a
            // ~1 ms INSERT on this now-idle task, never on the latency path.
            // Python records even when the insert failed (the words must not
            // be lost from history too) but only stamps "insert" on success.
            if let store, !text.isEmpty {
                if let pastedAt { timings.stamp("insert", at: pastedAt) }
                let now = Date().timeIntervalSince1970
                store.add(
                    ts: now, rawText: raw, finalText: text,
                    cleanupStatus: cleanupStatus?.rawValue ?? "off",
                    appHint: appHint, durationS: durationS,
                    timingsJson: timings.json())
                store.purge(now: now)
                NotificationCenter.default.post(name: .pomvoxHistoryDidChange, object: nil)
            }

            // Eval capture: one local JSON file with the (raw, cleaned) pair and
            // which models ran. Same posture as history — strictly after the
            // paste, best-effort, never on the latency path, never audio, and a
            // true no-op unless the user turned it on in Settings → Privacy.
            if EvalRecord.shouldCapture(enabled: captureEval, raw: raw, pasted: text) {
                let modelVersion: String
                if doCleanup {
                    if backend == .sdk {
                        modelVersion = await sdk?.openedModelID ?? configuredCleanupModelID
                    } else {
                        modelVersion = await self.cleanup.loadedModel ?? configuredCleanupModelID
                    }
                } else {
                    modelVersion = "off"
                }
                EvalCaptureStore.shared.write(EvalRecord(
                    rawAsr: raw, cleaned: cleanedForEval, durationS: durationS,
                    modelVersion: modelVersion,
                    cleanupStatus: cleanupStatus?.rawValue ?? "off",
                    sttModel: sttModelTelemetryID, style: style,
                    appVersion: EvalRecord.appVersion()))
            }
        }
    }

    // MARK: - utterance insertion

    /// Paste the finished text (or report an empty transcript) and return the
    /// frontmost app and paste time for history. Called only from
    /// `deliverUtterance`'s `insert`, after its final currency check.
    private func insertFinal(_ text: String, raw: String, samples: [Float], sttError: String?,
                             t0: CFAbsoluteTime, cleanupNotice: String?) -> (String?, Double?) {
        guard !isBlankTranscript(text) else {
            let peak = peakDbfs(samples)
            let cause = classifyEmptyTranscript(
                raw: raw, peakDbfs: peak, sttError: sttError)
            NSLog("pomvox-engine: empty transcript — %@ (raw %d chars)",
                  String(describing: cause), raw.count)
            if let msg = cause.hudMessage {
                bus.post(.result("error", msg))
            } else {
                bus.post(.result("empty", ""))
            }
            if let code = cause.errorCode {
                TelemetryClient.shared.emit(.error, props: errorProps(code))
            }
            doneMachine()
            status = .ready
            return (nil, nil)
        }
        // app_hint = whatever is frontmost when the paste lands.
        let hint = NSWorkspace.shared.frontmostApplication?.localizedName
        lastTranscript = text  // retained for recovery before the paste
        let outcome = Paster.paste(text)
        let pasteT = CFAbsoluteTimeGetCurrent()
        lastPasteMs = (pasteT - t0) * 1000
        var pastedAt: Double?
        switch outcome {
        case .pasted:
            pastedAt = pasteT
            if let cleanupNotice {
                // The raw words are in the focused field. Say why they
                // weren't cleaned — a silent paste was the bug.
                bus.post(.result("error", cleanupNotice))
            } else {
                bus.post(.result("ok", text))
            }
            NSLog("engine: paste %.0fms (%d chars)", lastPasteMs ?? 0, text.count)
        case .copiedToClipboard:
            // No editable field had focus — the transcript is on the
            // clipboard, not lost. Tell the user via the HUD flash.
            if let cleanupNotice {
                bus.post(.result("error", "\(cleanupNotice) — copied to clipboard"))
            } else {
                bus.post(.result("error", "copied to clipboard"))
            }
            NSLog("engine: no focused field — left %d chars on the clipboard", text.count)
        }
        doneMachine()
        status = .ready
        return (hint, pastedAt)
    }

    /// Retire the utterance that owns insertion (sleep, disarm, quit): its
    /// cleanup waiter is cancelled and whatever it produces is discarded.
    /// Shared preparation is untouched — other utterances may need it.
    private func cancelUtterance(reason: String) {
        guard utterances.current != nil else { return }
        utterances.retire()
        utteranceTask?.cancel()
        utteranceTask = nil
        NSLog("pomvox-engine: in-flight utterance cancelled (%@)", reason)
    }

    // MARK: - cleanup backend selection

    /// `[cleanup] backend`, and the model it depends on, → the backend that
    /// runs. Read at arm and on every settings save (`switchCleanupBackend`
    /// retires the other backend's model when this changes while armed).
    private func applyCleanupBackend(from doc: ConfigDocument, atArm: Bool = false) {
        let kind = CleanupBackendKind.resolve(
            configured: doc.string("cleanup", "backend"), modelID: cleanupModelID)
        guard atArm || kind != cleanupBackendKind else { return }
        if kind == .sdk, cleanupModelID != CleanupBackendKind.sdkModelID {
            NSLog("pomvox-engine: [cleanup] model %@ is ignored by the SDK backend (serves %@)",
                  cleanupModelID, CleanupBackendKind.sdkModelID)
        }
        cleanupBackendKind = kind
        if kind == .sdk {
            if sdkHost == nil { sdkHost = makeSDKHost() }
            // Never silently accept settings the SDK baseline cannot honour.
            if doc.string("cleanup", "style") != nil || doc.bool("cleanup", "speculative") != nil {
                NSLog("pomvox-engine: [cleanup] style/speculative are ignored by the SDK backend "
                      + "(frozen prompt, fixed decoder)")
            }
        }
        cleanupControls = CleanupControls.forBackend(
            kind, capabilities: kind == .sdk ? sdkCapabilities : [])
        NSLog("pomvox-engine: cleanup backend = %@", kind.rawValue)
    }

    /// The backend changed while this process runs. Retire the old backend's
    /// model before the new one prepares, so the two are never resident
    /// together, and restart the residency watchdog (it is per-backend).
    private func switchCleanupBackend(from previous: CleanupBackendKind) {
        cleanupProblem = nil
        cleanupPackSummary = nil
        cleanupResidencyTask?.cancel(); cleanupResidencyTask = nil
        cleanupLoadedAt = nil
        cleanupAvailability = cleanupAvailability.applying(.engineRestarted)
        let active = cleanupEnabled && isArmed
        switch previous {
        case .sdk:
            let retired = disableSDKCleanup()
            guard active else { return }
            let host = sdkHost
            Task { [weak self] in
                await retired.value
                _ = try? await host?.awaitRetirement()
                self?.syncCleanupModel()
            }
        case .inapp:
            cleanupLoadTask?.cancel(); cleanupLoadTask = nil
            let unload = Task { [cleanup] in await cleanup.unload() }
            guard active else { return }
            Task { [weak self] in
                await unload.value
                await self?.enableSDKCleanup().value
            }
        }
        if active { startCleanupResidencyWatchdog() }
    }

    /// Send enable (with the current dictionary vocabulary) to the SDK host,
    /// after whatever was sent before it.
    @discardableResult
    private func enableSDKCleanup() -> Task<Void, Never> {
        guard cleanupBackendKind == .sdk, let sdkHost else { return Task {} }
        let vocabulary = SDKVocabulary.select(from: dictionary.cleanupWords)
        if let line = vocabulary.omissionSummary { NSLog("%@", line) }
        return enqueueSDKHostOp { await sdkHost.enable(vocabulary: vocabulary) }
    }

    /// Close the SDK cleaner (disarm, quit, toggle off, backend switch). The
    /// next open waits for the retiring cleaner inside the host.
    @discardableResult
    private func disableSDKCleanup() -> Task<Void, Never> {
        guard let sdkHost else { return Task {} }
        return enqueueSDKHostOp { await sdkHost.disable() }
    }

    private func enqueueSDKHostOp(_ op: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = sdkHostOp
        let task = Task {
            await previous?.value
            await op()
        }
        sdkHostOp = task
        return task
    }

    // MARK: - SDK cleanup backend

    private func makeSDKHost() -> SDKCleanupHost? {
        do {
            let provisioner = try SDKPackProvisioner.bundled()
            sdkCapabilities = provisioner.trustedManifest.capabilities
            return SDKCleanupHost(provisioner: provisioner,
                                  afterRelease: { MLXBufferPool.releaseCachedBuffers() },
                                  onEvent: { [weak self] event in
                Task { @MainActor in self?.onSDKEvent(event) }
            })
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            NSLog("pomvox-engine: cleanup SDK setup failed: %@", message)
            cleanupProblem = message
            return nil
        }
    }

    /// The SDK host's preparation, expressed in the same availability states
    /// the in-app engine reports, so the menu bar, Settings and the dictation
    /// notice read one source whichever backend runs.
    private func onSDKEvent(_ event: SDKCleanupHost.Event) {
        guard cleanupBackendKind == .sdk else { return }
        switch event {
        case .preparing:
            guard isArmed else { return }
            cleanupAvailability = cleanupAvailability.applying(.loadStarted)
        case .progress(let fraction):
            guard isArmed else { return }
            // Progress comes from the snapshot download; after it, the pack
            // installs and opens (no progress), which is "loading".
            if fraction < 1 {
                cleanupAvailability = cleanupAvailability
                    .applying(.downloadStarted).applying(.progress(fraction))
            } else {
                cleanupAvailability = cleanupAvailability
                    .applying(.downloadFinished).applying(.loadStarted)
            }
        case .prepared(let preparation, let packID, let packVersion, let capabilities):
            cleanupAvailability = cleanupAvailability.applying(.downloadFinished).applying(.loadFinished)
            cleanupProblem = nil
            cleanupPackSummary = "\(packID) \(packVersion) · rules \(SDKCleanupHost.rulesVersion)"
            sdkCapabilities = capabilities
            cleanupControls = CleanupControls.forBackend(.sdk, capabilities: capabilities)
            guard isArmed else { return }
            cleanupLoadedAt = CFAbsoluteTimeGetCurrent()
            OnboardingWarm().markWarmed()
            // Preparation, measured separately from any request.
            var c = ColdStartTimings(); c.cleanupLoadMs = preparation.totalMS
            emitColdStart(c)
        case .failed(let message, let configuration):
            let failure: CleanupFailure = cleanupAvailability.downloadInFlight
                ? .download(message) : .load(message)
            cleanupAvailability = cleanupAvailability.applying(.failed(failure))
            if configuration { cleanupProblem = message }
            guard isArmed else { return }
            NSLog("pomvox-engine: cleanup preparation FAILED — dictation will paste the original transcript")
            var p = TelemetryProps(); p.errorCode = "cleanup_load_failed"
            TelemetryClient.shared.emit(.error, props: p)
        case .evicted:
            // A cancelled preparation may have been mid-download; the
            // transfer itself carries on (SharedSnapshotFetch), so the next
            // preparation joins it rather than starting over.
            var next = cleanupAvailability
            next.downloadInFlight = false
            next.phase = (next.phase == .ready || next.phase == .loading) ? .onDisk : next.phase
            if case .downloading = next.phase { next.phase = .notDownloaded }
            cleanupAvailability = next
            cleanupLoadedAt = nil
        }
    }

    // MARK: - system sleep/wake

    /// Build the CGEventTap wired to the HotkeyMachine. Extracted so both arm()
    /// and the wake path (which rebuilds it) use identical decision closures.
    private func makeTap() -> EventTap {
        EventTap(
            onModifier: { [weak self] keycode, isDown in
                self?.decide(keycode: keycode) { $0.onModifier(keycode, isDown) } ?? HotkeyMachine.Decision()
            },
            onKeyDown: { [weak self] keycode in
                self?.decide { $0.onKeyDown(keycode) } ?? HotkeyMachine.Decision()
            })
    }

    /// On sleep we reset any in-flight recording (the push-to-talk key-up can be
    /// dropped, otherwise stranding the mic open with no HUD). On wake we do that
    /// AND rebuild the event tap from scratch: after a deep sleep macOS stops
    /// delivering events to a session tap even though it still reports enabled,
    /// and only a fresh tap recovers — confirmed on-device (CGEventTapEnable is
    /// not enough). Both `didWake` and `screensDidWake` trigger it because the
    /// former isn't always delivered on a deep-standby wake.
    private func registerSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panicReset(reason: "system will sleep") }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake(reason: "did wake") }
        }
        screensWakeObserver = nc.addObserver(
            forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onWake(reason: "screens did wake") }
        }
    }

    private func unregisterSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        for o in [sleepObserver, wakeObserver, screensWakeObserver] {
            if let o { nc.removeObserver(o) }
        }
        sleepObserver = nil; wakeObserver = nil; screensWakeObserver = nil
        wakeRecreateTask?.cancel(); wakeRecreateTask = nil
    }

    /// Wake handling: clear any stranded recording, then rebuild the tap after a
    /// short settle (the window server/event system may not be ready the instant
    /// the notification fires, and a tap created too early can itself fail to
    /// deliver). Debounced so overlapping wake signals rebuild once.
    private func onWake(reason: String) {
        panicReset(reason: "system \(reason)")
        capture.markStale()   // a post-sleep engine can deliver a dead stream
        hud.markStale()       // a post-sleep panel can refuse to order in
        guard isArmed else { return }
        wakeRecreateTask?.cancel()
        wakeRecreateTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.recreateTap()
        }
    }

    /// Tear down the current tap and install a fresh one — the only reliable
    /// recovery for a session tap that stopped delivering after deep sleep.
    private func recreateTap() {
        guard isArmed else { return }
        // During the first-run download window arm() owns the tap lifecycle
        // end-to-end (it installed the tap, and its catch tears it down on a
        // model-load failure). A wake-triggered recreate here would stop that
        // tap and swap in a fresh one into self.tap — then, if prepare() goes
        // on to throw, arm()'s catch would tear down *this* fresh tap via a
        // stale local reference, dropping the last strong reference to a still-
        // enabled CGEventTap whose callback points at self. Simplest fix: never
        // touch the tap mid-download: let arm() finish owning it. But the wake
        // that got us here means the arm-installed tap may be dead (deep sleep
        // kills session taps) — record the debt so arm() retries the recreate
        // once it completes, instead of finishing with a possibly-dead tap.
        guard status != .preparing else {
            pendingTapRecreate = true
            return
        }
        tap?.stop()
        let fresh = makeTap()
        do {
            try fresh.start()
            tap = fresh
            NSLog("pomvox-engine: wake — event tap recreated")
        } catch {
            tap = nil
            NSLog("pomvox-engine: wake — event tap re-create FAILED: %@", String(describing: error))
            status = .failed(
                "The dictation hotkey stopped after sleep. Toggle the engine off and on to restore it.")
            TelemetryClient.shared.emit(.error, props: errorProps("tap_recreate_failed"))
        }
    }

    /// Force any in-flight recording back to armed-idle without transcribing —
    /// used when the OS pulls the rug out (sleep/wake) and the key-up that would
    /// normally stop push-to-talk may never arrive. A no-op when already idle.
    private func panicReset(reason: String) {
        guard isArmed else { return }
        cancelUtterance(reason: reason)
        machineLock.lock(); let recording = machine.state != .idle; machineLock.unlock()
        NSLog("pomvox-engine: sleep/wake reset (%@) — recording=%@",
              reason, recording ? "yes" : "no")
        guard recording else { return }
        endVadSession()
        draftTask?.cancel(); draftTask = nil
        finishing = true
        capture.stop()
        bus.post(.state("idle", "ready"))   // hide the HUD if it was showing
        resetMachine()
        // Only fold a genuine in-flight recording/transcription back to
        // .ready. A wake that catches a press in flight before startCapture's
        // guard has run (status still .preparing/.failed/.blocked) must not
        // promote that status — the machine/capture/draft/VAD/HUD reset above
        // still applies unconditionally, but the engine's own status is left
        // alone so a mid-download wake can't un-fail a .failed engine or
        // report .ready before the model has actually loaded.
        if status == .recording || status == .transcribing {
            status = .ready
        }
    }

    private func cancelRecording() {
        // Esc racing the pre-ready guard (no capture ever started) must not
        // fake a cancel: capture.stop() on nothing, a bogus "cancelled" HUD
        // flash, and status = .ready mid-download/mid-failure.
        guard status == .recording else { resetMachine(); return }
        NSLog("pomvox-engine: cancelled by user")
        endVadSession()
        draftTask?.cancel(); draftTask = nil
        finishing = true
        capture.stop()
        bus.post(.result("cancelled", ""))
        doneMachine()
        status = .ready
    }

    /// Invalidate any endpoint in flight and stop classifying (mirrors
    /// `app.py:_end_vad_session`).
    private func endVadSession() {
        sessionGen += 1
        vadLock.lock(); endpointer?.disarm(); vadLock.unlock()
    }

    // MARK: - incremental re-transcription draft loop

    private func startDraftLoop() {
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)  // ~1 s cadence
                if Task.isCancelled { break }
                await self?.draftTick()
            }
        }
    }

    /// Re-transcribe the accumulated session audio and push the full text to the
    /// HUD (the controller does the stable/volatile two-tone split). A full ANE
    /// re-transcribe is 0.13–0.27 s (M0), so this refreshes faster than the
    /// Python 2 s chunk cadence at batch quality. `draftInFlight` coalesces; the
    /// `finishing` flag stops new passes from racing the finalize transcribe.
    private func draftTick() async {
        guard !finishing, !draftInFlight else { return }
        let snap = capture.snapshot()
        guard snap.count >= 8000 else { return }  // ~0.5 s before a first draft
        draftInFlight = true
        let text = (try? await transcriber.transcribe(snap)) ?? ""
        draftInFlight = false
        guard !finishing, !Task.isCancelled, !text.isEmpty else { return }
        bus.post(.draft(text))
    }

    private func doneMachine() { machineLock.lock(); machine.done(); machineLock.unlock() }
    private func resetMachine() { machineLock.lock(); machine.reset(); machineLock.unlock() }

    /// Persist the toggle to `config.toml [engine] native`.
    private func persist(_ enabled: Bool) {
        var doc = ConfigDocument.load(path: configPath)
        doc.set("engine", "native", bool: enabled)
        try? doc.write(to: configPath)
    }
}
