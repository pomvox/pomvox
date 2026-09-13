import XCTest

@testable import Pomvox

final class CleanupGenStatsTests: XCTestCase {

    func testAcceptRateIsNilUntilSomethingWasDrafted() {
        var s = CleanupGenStats()
        XCTAssertNil(s.acceptRate)
        s.specDrafted = 8
        s.specAccepted = 6
        XCTAssertEqual(s.acceptRate!, 0.75, accuracy: 1e-9)
    }

    func testTimingNotesCarryTheSplitAndOnlySpecKeysWhenDrafted() {
        var s = CleanupGenStats()
        s.promptTokens = 120
        s.prefillMs = 480
        s.decodeTokens = 100
        s.decodeMs = 3700
        s.cached = true
        var keys = s.timingNotes().map(\.0)
        XCTAssertEqual(
            keys,
            ["cleanup_prefill_ms", "cleanup_prefill_tok", "cleanup_decode_ms",
             "cleanup_decode_tok", "cleanup_cached"])
        XCTAssertEqual(s.decodeTokensPerSecond, 100 / 3.7, accuracy: 1e-6)
        XCTAssertEqual(s.prefillTokensPerSecond, 120 / 0.48, accuracy: 1e-6)

        s.specRounds = 20
        s.specDrafted = 160
        s.specAccepted = 80
        keys = s.timingNotes().map(\.0)
        XCTAssertTrue(keys.contains("spec_accept_rate"))
        XCTAssertTrue(keys.contains("spec_rounds"))
    }

    func testRatesAreZeroNotNaNWhenNothingRan() {
        let s = CleanupGenStats()
        XCTAssertEqual(s.decodeTokensPerSecond, 0)
        XCTAssertEqual(s.prefillTokensPerSecond, 0)
    }
}
