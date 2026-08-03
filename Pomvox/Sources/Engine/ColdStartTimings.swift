import Foundation

/// One launch's cold-start breakdown — the four stages that make a first
/// dictation feel slow, measured independently so we can see which one
/// dominates before optimizing (ARCHITECTURE.md "latency is a feature").
///
/// Unlike `EngineTimings` (chained per-utterance deltas), these are independent
/// spans: STT weight load and the background cleanup load overlap in wall-clock
/// time, so a chained-delta model would misattribute them. Each field is an
/// optional millisecond duration — `nil` means "not measured this launch" (e.g.
/// cleanup is off, or the model was already resident on a warm re-arm).
///
/// Pure value type: the mapping to a log line and to the (anonymous, numeric)
/// telemetry props is unit-tested; the engine fills the fields from measured
/// `CFAbsoluteTimeGetCurrent()` spans.
struct ColdStartTimings: Equatable, Sendable {
    /// Time fetching the STT weights from Hugging Face (first run only; ~0 on a
    /// warm cache where the bytes are already on disk).
    var sttWeightLoadMs: Double?
    /// Time compiling / loading the CoreML graph into an ANE-ready form. On a
    /// cache miss this is the one-time ~37 s ANE compile; on a hit it should be
    /// the fast `.mlmodelc` load — a large value with `coremlCacheHit == true`
    /// means the compile cache is NOT being reused (the bug item 1 hunts).
    var coremlCompileMs: Double?
    /// The throwaway silent-buffer pass that warms the Neural Engine so the
    /// first real utterance hits the fast path.
    var aneWarmupMs: Double?
    /// Full time preparing the cleanup LLM (currently
    /// abhiram3040/simplewords-dictation-cleanup-v3, a GB-scale load, ~2 GB) —
    /// the model load plus the warmup pass that doubles as the Metal-kernel
    /// compile (nil when cleanup is off, the model was already resident, or
    /// the load failed).
    var cleanupLoadMs: Double?
    /// Whether a compiled CoreML artifact for this STT model already existed on
    /// disk before this launch's load (see `CompiledModelCache`).
    var coremlCacheHit: Bool?

    /// A single log line for the engine log — only the measured stages appear.
    func summary() -> String {
        var parts: [String] = []
        if let v = sttWeightLoadMs { parts.append(String(format: "stt_weight_load=%.0fms", v)) }
        if let v = coremlCompileMs { parts.append(String(format: "coreml_compile=%.0fms", v)) }
        if let v = aneWarmupMs { parts.append(String(format: "ane_warmup=%.0fms", v)) }
        if let v = cleanupLoadMs { parts.append(String(format: "cleanup_load=%.0fms", v)) }
        if let hit = coremlCacheHit { parts.append("coreml_cache=\(hit ? "hit" : "miss")") }
        return parts.isEmpty ? "cold-start: nothing measured" : "cold-start: " + parts.joined(separator: " ")
    }

    /// The anonymous, content-free telemetry payload. Durations round to whole
    /// milliseconds; the sanitizer clamps them at the wire boundary. Only the
    /// measured stages are set, so an event never implies a stage ran when it
    /// didn't.
    func telemetryProps() -> TelemetryProps {
        var p = TelemetryProps()
        if let v = sttWeightLoadMs { p.sttWeightLoadMs = Int(v.rounded()) }
        if let v = coremlCompileMs { p.coremlCompileMs = Int(v.rounded()) }
        if let v = aneWarmupMs { p.aneWarmupMs = Int(v.rounded()) }
        if let v = cleanupLoadMs { p.cleanupLoadMs = Int(v.rounded()) }
        p.coremlCacheHit = coremlCacheHit
        return p
    }

    /// True once any stage has a measurement — used to skip emitting an empty
    /// event on a warm re-arm where nothing loaded.
    var hasMeasurement: Bool {
        sttWeightLoadMs != nil || coremlCompileMs != nil || aneWarmupMs != nil
            || cleanupLoadMs != nil || coremlCacheHit != nil
    }
}
