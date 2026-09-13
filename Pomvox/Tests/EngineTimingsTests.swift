import XCTest
@testable import Pomvox

/// Port spec: src/pomvox/bench.py Timings — per-stage durations, each relative
/// to the previous stamp, plus "total", all ms from t0 = recording stop. The
/// native engine writes these into history.timings_json with Python's exact
/// keys (stt_finalize, cleanup, insert, total) for dashboard parity.
final class EngineTimingsTests: XCTestCase {

    func testStagesAreChainedDeltasPlusTotal() {
        var clock = 1.0
        var t = EngineTimings(clock: { clock })
        t.start()
        clock = 1.21; t.stamp("stt_finalize")
        clock = 1.71; t.stamp("cleanup")
        clock = 1.76; t.stamp("insert")
        let stages = t.stagesMs()
        XCTAssertEqual(stages.map(\.name), ["stt_finalize", "cleanup", "insert", "total"])
        XCTAssertEqual(stages[0].ms, 210, accuracy: 0.001)
        XCTAssertEqual(stages[1].ms, 500, accuracy: 0.001)
        XCTAssertEqual(stages[2].ms, 50, accuracy: 0.001)
        XCTAssertEqual(stages[3].ms, 760, accuracy: 0.001)
    }

    func testNoStampsMeansNoStages() {
        var t = EngineTimings(clock: { 1.0 })
        XCTAssertTrue(t.stagesMs().isEmpty)  // never started
        t.start()
        XCTAssertTrue(t.stagesMs().isEmpty)  // started but nothing stamped
    }

    func testJsonCarriesPythonKeys() throws {
        var clock = 2.0
        var t = EngineTimings(clock: { clock })
        t.start()
        clock = 2.3; t.stamp("stt_finalize")
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(t.json().utf8)) as? [String: Double])
        XCTAssertEqual(parsed["stt_finalize"]!, 300, accuracy: 0.001)
        XCTAssertEqual(parsed["total"]!, 300, accuracy: 0.001)
    }
}

// MARK: - notes (flat extras riding along in timings_json)

extension EngineTimingsTests {

    func testNotesRideAlongAfterStagesInJson() throws {
        var clock = 2.0
        var t = EngineTimings(clock: { clock })
        t.start()
        clock = 2.3; t.stamp("stt_finalize")
        clock = 3.3; t.stamp("cleanup")
        t.note("cleanup_prefill_ms", 250)
        t.note("cleanup_decode_ms", 700)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(t.json().utf8)) as? [String: Double])
        XCTAssertEqual(parsed["cleanup"]!, 1000, accuracy: 0.001)
        XCTAssertEqual(parsed["cleanup_prefill_ms"], 250)
        XCTAssertEqual(parsed["cleanup_decode_ms"], 700)
        XCTAssertEqual(parsed["total"]!, 1300, accuracy: 0.001)
        // Notes are not stages: the chain of deltas is untouched.
        XCTAssertEqual(t.stagesMs().map(\.name), ["stt_finalize", "cleanup", "total"])
    }

    func testNoteOverwritesAndStartClears() throws {
        var t = EngineTimings(clock: { 1.0 })
        t.start()
        t.stamp("stt_finalize")
        t.note("k", 1)
        t.note("k", 2)
        var parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(t.json().utf8)) as? [String: Double])
        XCTAssertEqual(parsed["k"], 2)
        t.start()
        t.stamp("stt_finalize")
        parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(t.json().utf8)) as? [String: Double])
        XCTAssertNil(parsed["k"], "start() begins a fresh utterance — old notes must not leak")
    }

    func testNotesWithoutStagesStayEmpty() {
        var t = EngineTimings(clock: { 1.0 })
        t.start()
        t.note("k", 1)
        XCTAssertEqual(t.json(), "{}", "a note alone is not a measured utterance")
    }
}
