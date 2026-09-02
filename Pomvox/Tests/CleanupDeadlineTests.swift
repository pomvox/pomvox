import XCTest

@testable import Pomvox

/// The cleanup deadline policy (`CleanupDeadline`).
///
/// Regression for the "post-idle raw paste" defect re-reported 2026-09-02. The
/// symptom was read as an idle-eviction bug — a prefix-cache re-prefill after
/// the model unloads — but the on-device log shows the caches are reused on
/// every reload (`cleanup: reusing retained prefix caches`, 4/4) and every
/// generation runs `cached=prefix` (14/14). The real discriminator is
/// TRANSCRIPT LENGTH: a fixed `timeout_s` cannot cover work that is linear in
/// the transcript, so past ~1300 chars a dictation blew the deadline whatever
/// the idle gap, and 2 of the 7 recorded timeouts followed gaps under 300 s.
///
/// Pure policy, so these run without the ~2.3 GB model.
final class CleanupDeadlineTests: XCTestCase {

    /// The on-device fit these constants come from: warm cleanup latency is
    /// `564 ms + 9.07 ms/char` (219 dictations, 2026-09-02). If the estimator
    /// drifts from the measurement the whole policy is guesswork.
    func testEstimateMatchesTheMeasuredFit() {
        for chars in [100, 300, 600, 1000, 1500] {
            let measuredS = (564.0 + 9.07 * Double(chars)) / 1000.0
            XCTAssertEqual(
                CleanupDeadline.estimateS(chars: chars), measuredS, accuracy: 0.35,
                "estimate drifted from the measured warm fit at \(chars) chars")
        }
    }

    /// A short utterance must keep EXACTLY the configured budget — the fix may
    /// not quietly lengthen the common case, only the case that could not fit.
    func testShortUtterancesKeepTheConfiguredBudget() {
        for base in [5.0, 12.5] {
            for chars in [0, 40, 120, 250] {
                XCTAssertEqual(
                    CleanupDeadline.effectiveTimeoutS(base: base, chars: chars), base,
                    "\(chars) chars must not move the \(base)s budget")
            }
        }
    }

    /// The defect itself. Every transcript that actually timed out on device
    /// must now be given a deadline that covers the work it needs; before the
    /// fix each of these got a flat 12.5 s against a 11.4–19.3 s requirement.
    func testTranscriptsThatTimedOutOnDeviceNowFit() {
        let base = 12.5   // the user's ~/.pomvox/config.toml
        for chars in [1189, 1512, 1548, 1783, 2053] {
            let effective = CleanupDeadline.effectiveTimeoutS(base: base, chars: chars)
            XCTAssertGreaterThan(
                effective, base,
                "\(chars) chars pasted raw at \(base)s on device and must get more")
            XCTAssertGreaterThan(
                effective, CleanupDeadline.estimateS(chars: chars),
                "\(chars) chars still cannot finish inside its deadline")
            XCTAssertFalse(CleanupDeadline.isHopeless(base: base, chars: chars))
        }
    }

    /// The shipped default is 5 s, where the ceiling binds ~4× sooner — the
    /// same defect, worse. A transcript of the length that fit comfortably on
    /// device (1050 chars cleaned in 9.7 s) must fit here too.
    func testDefaultBudgetAlsoScales() {
        let effective = CleanupDeadline.effectiveTimeoutS(base: 5.0, chars: 1050)
        XCTAssertGreaterThan(effective, CleanupDeadline.estimateS(chars: 1050))
    }

    func testDeadlineIsMonotonicAndCapped() {
        var previous = 0.0
        for chars in stride(from: 0, through: 8000, by: 250) {
            let effective = CleanupDeadline.effectiveTimeoutS(base: 12.5, chars: chars)
            XCTAssertGreaterThanOrEqual(effective, previous, "deadline shrank at \(chars) chars")
            XCTAssertLessThanOrEqual(effective, CleanupDeadline.ceilingS)
            previous = effective
        }
    }

    /// Past the ceiling the answer is raw either way — the point is to hand it
    /// over immediately rather than after `ceilingS` of "polishing".
    func testHopelessOnlyOnceTheCeilingBinds() {
        XCTAssertFalse(CleanupDeadline.isHopeless(base: 12.5, chars: 2053))
        let hopeless = Int((CleanupDeadline.ceilingS + 5) * CleanupDeadline.throughputCharsPerS)
        XCTAssertTrue(CleanupDeadline.isHopeless(base: 12.5, chars: hopeless))
        // …and it must never fire on a transcript the budget already covers.
        XCTAssertFalse(CleanupDeadline.isHopeless(base: 12.5, chars: 0))
    }

    /// The post-idle half of the defect: warm and post-idle cleanups differ
    /// on device ONLY by the ~1.8 s weight reload (identical 9.07 vs 8.94
    /// ms/char slopes). Crediting that wait back is what stops an idle gap from
    /// making an otherwise identical dictation likelier to paste raw.
    func testReloadCreditCoversTheMeasuredReloadButIsBounded() {
        for waited in [1.3, 1.8, 2.2] {   // the logged "cleanup: loaded … in Ns"
            XCTAssertEqual(CleanupDeadline.reloadCreditS(waited: waited), waited, accuracy: 0.001)
        }
        XCTAssertEqual(
            CleanupDeadline.reloadCreditS(waited: 90.0), CleanupDeadline.reloadCreditCapS,
            "a stalled load must not extend the deadline without bound")
        XCTAssertEqual(CleanupDeadline.reloadCreditS(waited: 0), 0)
        XCTAssertEqual(CleanupDeadline.reloadCreditS(waited: -1), 0)
    }

    /// `cleanupWithWatchdog`'s race must clear the deadline plus every credit
    /// `clean()` can award itself — otherwise it cancels a pass that is still
    /// inside its own budget, which is the bug the credit was meant to fix.
    func testWatchdogOutlastsEveryCreditTheDeadlineCanTake() {
        for chars in [0, 500, 1548, 4000] {
            let effective = CleanupDeadline.effectiveTimeoutS(base: 12.5, chars: chars)
            XCTAssertGreaterThan(
                CleanupDeadline.watchdogTimeoutS(effective: effective),
                effective + CleanupDeadline.reloadCreditCapS,
                "the watchdog would cancel a fully-credited pass at \(chars) chars")
        }
    }
}
