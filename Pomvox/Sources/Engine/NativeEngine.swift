import ApplicationServices
import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted by DictionaryStore after every save; the engine hot-reloads.
    static let pomvoxDictionaryDidChange = Notification.Name("app.pomvox.dictionaryDidChange")
    /// Posted by the engine when a changed words-hint has been re-baked into
    /// the cleanup prefix caches (drives the page's "applying…" indicator).
    static let pomvoxDictionaryHintApplied = Notification.Name("app.pomvox.dictionaryHintApplied")
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
    // (it gates dictation); `polishLoad` tracks the background cleanup-model
    // fetch after the engine is already usable. Both clear to nil when loaded.
    @Published private(set) var speechLoad: String?
    @Published private(set) var polishLoad: String?

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
    nonisolated var variantSuggester: CleanupEngine { cleanup }
    private var tap: EventTap?
    private let configPath: String

    // [cleanup] snapshot, read at arm() like [hud]/[vad] (re-arm to apply).
    // Defaults mirror SettingsStore/config.py.
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
    private var cleanupPreloadDelayS = CleanupResidency.defaultPreloadDelayS
    private var cleanupIdleEvictS = CleanupResidency.defaultIdleEvictS
    private var cleanupHint = ""
    private var cleanupLastUsedAt: CFAbsoluteTime?
    private var cleanupLoadedAt: CFAbsoluteTime?
    private var cleanupLoadTask: Task<Void, Never>?
    private var cleanupPreloadTask: Task<Void, Never>?
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
        if cleanupEnabled {
            cleanupHint = dictionary.hint
            cleanupLastUsedAt = nil
            cleanupLoadedAt = nil
            let onboarding = OnboardingWarm()
            if onboarding.shouldWarmNow {
                NSLog("pomvox-engine: first run — warming cleanup now (onboarding)")
                // Fire-and-forget: ensureCleanupLoaded only spawns the background
                // load Task and returns, so this eager warm does not block
                // arm→ready — the cost is paid off the hot path during Setup.
                // markWarmedOnSuccess persists the one-time flag only once that
                // background load completes, so an interrupted/failed warm is
                // retried next launch instead of dropping to a cold first
                // dictation.
                ensureCleanupLoaded(markWarmedOnSuccess: true)
            } else {
                scheduleCleanupPreload()
            }
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

    /// `markWarmedOnSuccess` records the one-time onboarding warm once the model
    /// is actually resident. It's passed per-call and captured as an immutable
    /// local inside the load Task rather than kept in a shared flag, so there's
    /// no cross-task mutable state to reason about: the fresh-install arm is the
    /// sole trigger before the engine reports ready, so its Task owns the load
    /// and persists the flag on completion; a failed/abandoned load never marks.
    private func ensureCleanupLoaded(markWarmedOnSuccess: Bool = false) {
        // The guard and the `cleanupLoadTask` assignment below run without an
        // intervening await, and NativeEngine is @MainActor, so two triggers
        // (the delayed preload racing a first-use press) are serialized on the
        // main actor: the first installs the task token, the second sees it
        // non-nil and bails. That makes the dedup atomic without extra locking.
        guard cleanupEnabled, isArmed, cleanupLoadTask == nil else { return }
        let modelID = cleanupModelID
        let hint = cleanupHint
        let style = cleanupStyle
        let markWarmed = markWarmedOnSuccess
        let polishGate = LineGate()
        cleanupLoadTask = Task { [cleanup, weak self] in
            if await cleanup.isLoaded {
                await MainActor.run {
                    guard let self, !self.isStaleCleanupLoad() else { return }
                    self.cleanupLoadTask = nil
                    // Already resident (e.g. preload finished before this
                    // first-use trigger): reset the idle clock so a fresh use
                    // isn't measured from the old load time.
                    self.cleanupLoadedAt = CFAbsoluteTimeGetCurrent()
                    // The model is warm — an onboarding warm counts as done.
                    if markWarmed { OnboardingWarm().markWarmed() }
                }
                return
            }
            await cleanup.setTermsHint(hint)
            // Build the configured style's prompt prefix first: a dictation
            // racing this load waits behind ONE useful prefill, not both
            // (rc.1's cold-launch first dictation burned its whole deadline
            // behind the other style's build and pasted raw).
            await cleanup.setPreferredStyle(style)
            await MainActor.run {
                self?.polishLoad = ModelLoad.line(.polish, fraction: nil, downloading: false)
            }
            let outcome = await cleanup.prepare(modelID: modelID) { [weak self] fraction in
                let line = ModelLoad.line(.polish, fraction: fraction, downloading: true)
                guard polishGate.changed(line) else { return }
                Task { @MainActor in self?.polishLoad = line }
            }
            await MainActor.run {
                guard let self else { return }
                // If this load's Task was cancelled (disarm/teardown) or the
                // session otherwise ended while the ~2 GB load was in flight,
                // drop the completion entirely: it must not emit telemetry,
                // persist the onboarding flag, or clobber a subsequent re-arm's
                // fresh load token. Cancellation is cooperative (prepare() does
                // not poll it), so honoring it here is the single checkpoint.
                guard !self.isStaleCleanupLoad() else { return }
                self.polishLoad = nil
                self.cleanupLoadTask = nil
                switch outcome {
                case .loaded:
                    // The idle-evict clock starts when the load actually
                    // completes, so a slow (~2 GB first-run) load isn't
                    // counted as idle time against the model.
                    self.cleanupLoadedAt = CFAbsoluteTimeGetCurrent()
                    // The eager onboarding warm (if any) succeeded — record it
                    // now, gated on the completed load rather than up front.
                    if markWarmed { OnboardingWarm().markWarmed() }
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
                case .failed:
                    // Non-fatal (raw transcript still pastes) but not silent.
                    NSLog("pomvox-engine: cleanup model load FAILED — dictation will paste raw")
                    var p = TelemetryProps(); p.errorCode = "cleanup_load_failed"
                    TelemetryClient.shared.emit(.error, props: p)
                }
            }
        }
    }

    /// After a short post-launch delay, preload cleanup so a user reading the UI
    /// has a warm model before their first dictation — without blocking startup.
    private func scheduleCleanupPreload() {
        cleanupPreloadTask?.cancel()
        let delay = cleanupPreloadDelayS
        cleanupPreloadTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.ensureCleanupLoaded() }
        }
    }

    /// Evict the cleanup LLM once it's been idle past `cleanupIdleEvictS`; it
    /// reloads on next use. STT stays resident (small, always used). The wake
    /// interval is coarse so this costs nothing at rest.
    private func startCleanupResidencyWatchdog() {
        cleanupResidencyTask?.cancel()
        let evictS = cleanupIdleEvictS
        guard evictS > 0 else { return }
        let interval = CleanupResidency.checkIntervalS(idleEvictS: evictS)
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
                        NSLog("pomvox-engine: cleanup idle > %.0fs — evicted (reloads on next use)",
                              evictS)
                    }
                }
            }
        }
    }

    /// Cancel every cleanup-residency task (disarm / re-arm).
    private func stopCleanupResidency() {
        cleanupPreloadTask?.cancel(); cleanupPreloadTask = nil
        cleanupResidencyTask?.cancel(); cleanupResidencyTask = nil
        cleanupLoadTask?.cancel(); cleanupLoadTask = nil
        cleanupLastUsedAt = nil
        cleanupLoadedAt = nil
        // Clear the snapshotted prompt hint too: arm() re-snapshots it, but a
        // disarm without a following arm (e.g. a config change) must not leave a
        // stale hint that a later load could bake into the cached prefix.
        cleanupHint = ""
    }

    func disarm() {
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
        Task { [cleanup] in await cleanup.unload() }
        bus.post(.state("idle", "ready"))   // hide the HUD if showing
        history?.close(); history = nil
        pidfile.release()
        resetMachine()
        persist(false)
        speechLoad = nil; polishLoad = nil
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
        // Memory-aware first-run default: on a fresh install (no config yet) on a
        // low-memory Mac, cleanup defaults off so raw dictation (~600 MB) works
        // out of the box instead of the ~2.6 GB armed+cleanup cost swapping. An
        // existing config or an explicit key is always honored — this can only
        // supply a default for an absent key on a brand-new install.
        //
        // The choice is no longer persisted silently (item 7): the engine runs
        // with the in-memory default, and the Hub shows a one-time prompt
        // (LowMemoryCleanupModel) that writes the user's explicit choice — so a
        // low-memory user understands the tradeoff instead of a missing feature.
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let lowMem = MemoryTier.isLowMemory(physicalMemory)
        // The fresh-state default is keyed on whether the one-time low-memory
        // prompt has been answered — NOT on config-file existence. persist(true)
        // writes config.toml at the end of every arm(), so a file-existence
        // heuristic flipped the low-memory default back on at the second arm
        // (and the model to 4B), loading the ~2 GB LLM on exactly the low-RAM
        // Macs this guards. Engine and Hub are one process, so the engine reads
        // the same flag the Hub's LowMemoryCleanupModel writes.
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
        // Item 6: memory-aware model-size default (1.7B on ≤8 GB, the
        // SimpleWords fine-tune on 16 GB+) when no explicit [cleanup] model
        // key. Keyed on the memory tier, not on config-file existence, so the
        // compact model survives a re-arm.
        cleanupModelID = doc.string("cleanup", "model")
            ?? MemoryTier.firstRunCleanupModel(physicalMemoryBytes: physicalMemory)
        // Residency tuning (items 4 & 5): how long after arm to preload cleanup
        // in the background, and how long idle before evicting it. 0 disables.
        cleanupPreloadDelayS = doc.double("cleanup", "preload_delay_s")
            ?? CleanupResidency.defaultPreloadDelayS
        cleanupIdleEvictS = doc.double("cleanup", "idle_evict_s")
            ?? CleanupResidency.defaultIdleEvictS

        historyEnabled = doc.bool("history", "enabled") ?? true
        historyRetentionDays = doc.int("history", "retention_days") ?? 7

        let dictEnabled = doc.bool("dictionary", "enabled") ?? true
        let loaded = DictionaryLoader.load(
            configPath: configPath,
            dictionaryPath: DictionaryPaths.dictionaryPath())
        dictionary = PomvoxDictionary(file: loaded.file, enabled: dictEnabled)

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
            ensureCleanupLoaded()
        }
        let samples = capture.stop()
        machineLock.lock(); let t0 = stopAt; machineLock.unlock()
        NSLog("pomvox-engine: stop — %d samples (%.1fs), transcribing", samples.count,
              Double(samples.count) / 16000)
        // Snapshot on the main actor; the Task below runs off it.
        let doCleanup = cleanupEnabled
        let style = cleanupStyle
        let timeoutS = cleanupTimeoutS
        let store = history
        let dict = dictionary
        let durationS = Double(samples.count) / 16000.0
        // Report the model that actually loaded (canonical id), not the raw
        // config string — an unrecognized value fell back to the default.
        let sttModelTelemetryID = sttModel.canonicalID
        Task { [weak self] in
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
            NSLog("pomvox-engine: transcript = %@", raw.isEmpty ? "<empty>" : raw)
            var text = raw
            var cleanupStatus: CleanupStatus?
            // Cleanup OFF: nothing below runs — the <300 ms raw path is intact.
            // The draft loop is already stopped (`finishing`), so the GPU pass
            // never overlaps STT on the ANE.
            if doCleanup, !raw.isEmpty {
                self.bus.post(.state("polishing", coldMark))
                let (cleaned, status) = await self.cleanupWithWatchdog(
                    raw: raw, style: style, timeoutS: timeoutS)
                text = cleaned
                cleanupStatus = status
                timings.stamp("cleanup")
                if status != .ok {
                    NSLog("pomvox-engine: cleanup %@ — pasting raw", status.rawValue)
                }
            }
            // Custom-word fixups run last so a misheard proper noun is corrected
            // whether cleanup polished the text, fell back to raw, or is off
            // (mirrors app.py). `final_text` stored in history reflects them.
            let applied = dict.applyReporting(text)
            text = applied.text
            let (appHint, pastedAt): (String?, Double?) = await MainActor.run {
                guard !text.isEmpty else {
                    let peak = peakDbfs(samples)
                    let cause = classifyEmptyTranscript(
                        rawWasEmpty: raw.isEmpty, peakDbfs: peak, sttError: sttError)
                    NSLog("pomvox-engine: empty transcript — %@ (raw %d chars)",
                          String(describing: cause), raw.count)
                    if let msg = cause.hudMessage {
                        self.bus.post(.result("error", msg))
                    } else {
                        self.bus.post(.result("empty", ""))
                    }
                    if let code = cause.errorCode {
                        TelemetryClient.shared.emit(.error, props: self.errorProps(code))
                    }
                    self.doneMachine()
                    self.status = .ready
                    return (nil, nil)
                }
                // app_hint = whatever is frontmost when the paste lands.
                let hint = NSWorkspace.shared.frontmostApplication?.localizedName
                self.lastTranscript = text  // retained for recovery before the paste
                let outcome = Paster.paste(text)
                let pasteT = CFAbsoluteTimeGetCurrent()
                self.lastPasteMs = (pasteT - t0) * 1000
                var pastedAt: Double?
                switch outcome {
                case .pasted:
                    pastedAt = pasteT
                    self.bus.post(.result("ok", text))
                    NSLog("engine: paste %.0fms (%d chars)", self.lastPasteMs ?? 0, text.count)
                case .copiedToClipboard:
                    // No editable field had focus — the transcript is on the
                    // clipboard, not lost. Tell the user via the HUD flash.
                    self.bus.post(.result("error", "copied to clipboard"))
                    NSLog("engine: no focused field — left %d chars on the clipboard", text.count)
                }
                self.doneMachine()
                self.status = .ready
                return (hint, pastedAt)
            }
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
        }
    }

    /// Race the cleanup against `timeout_s` plus a grace period. The per-chunk
    /// deadline inside `clean()` is authoritative, but a Metal kernel that
    /// hangs without ever yielding a chunk would never reach it — the paste
    /// must not be held hostage. First result wins; a late one is discarded
    /// (the zombie generation can only delay the *next* cleanup, never STT,
    /// which runs on the ANE).
    private nonisolated func cleanupWithWatchdog(
        raw: String, style: String, timeoutS: Double
    ) async -> (String, CleanupStatus) {
        await withTaskGroup(of: Optional<(String, CleanupStatus)>.self) { group in
            group.addTask { [cleanup] in
                await runCleanup(cleanup, text: raw, style: style, timeoutS: timeoutS)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64((timeoutS + 2.0) * 1_000_000_000))
                return nil
            }
            let first = await group.next()!
            group.cancelAll()
            return first ?? (raw, .timeout)
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
