import Foundation

/// Port of `src/pomvox/bench.py` `Timings` — stamps named stages for one
/// utterance, relative to recording stop. `stagesMs()` yields each stage as the
/// delta to the previous stamp plus a "total", exactly the dict Python dumps
/// into `history.timings_json` (keys: stt_finalize, cleanup, insert, total).
struct EngineTimings {
    private let clock: () -> Double
    private var t0: Double?
    private var stamps: [(name: String, t: Double)] = []
    /// Flat extra measurements (not stages): merged into `json()` after the
    /// stages so the Python-shaped keys keep their order. Cleared by `start`.
    private var notes: [(name: String, value: Double)] = []

    init(clock: @escaping () -> Double = { CFAbsoluteTimeGetCurrent() }) {
        self.clock = clock
    }

    /// Mark t0 = recording stop.
    mutating func start() {
        t0 = clock()
        stamps = []
        notes = []
    }

    /// Mark t0 explicitly (the engine already holds `stopAt` from the tap thread).
    mutating func start(at t: Double) {
        t0 = t
        stamps = []
        notes = []
    }

    /// Record a non-stage measurement under its own key (e.g. the cleanup
    /// prefill/decode split). Not part of `stagesMs()` — it is not a delta on
    /// the stamp chain — but it rides along in `json()` so history rows carry
    /// it. A repeated key overwrites the earlier value.
    mutating func note(_ name: String, _ value: Double) {
        if let i = notes.firstIndex(where: { $0.name == name }) {
            notes[i].value = value
        } else {
            notes.append((name, value))
        }
    }

    mutating func stamp(_ name: String) {
        stamps.append((name, clock()))
    }

    /// Stamp at an explicit time (the paste moment is measured on the main
    /// actor; the stamp lands after the hop back).
    mutating func stamp(_ name: String, at t: Double) {
        stamps.append((name, t))
    }

    /// Per-stage durations (each relative to the previous stamp) + total, in ms.
    func stagesMs() -> [(name: String, ms: Double)] {
        guard let t0 else { return [] }
        var out: [(name: String, ms: Double)] = []
        var prev = t0
        for (name, t) in stamps {
            out.append((name, (t - prev) * 1000.0))
            prev = t
        }
        if let last = stamps.last {
            out.append(("total", (last.t - t0) * 1000.0))
        }
        return out
    }

    /// The `timings_json` payload — same shape as Python's
    /// `json.dumps(timings.stages_ms())`. "{}" when nothing was stamped.
    func json() -> String {
        let stages = stagesMs()
        guard !stages.isEmpty else { return "{}" }
        let body = (stages.map { ($0.name, $0.ms) } + notes.map { ($0.name, $0.value) })
            .map { "\"\($0.0)\": \($0.1)" }
            .joined(separator: ", ")
        return "{\(body)}"
    }

    /// `summary()` analog for the engine log line.
    func summary() -> String {
        stagesMs().map { String(format: "%@=%.0fms", $0.name, $0.ms) }.joined(separator: " ")
    }
}
