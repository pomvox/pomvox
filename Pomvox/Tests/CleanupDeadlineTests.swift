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

    // MARK: - cleanupWithWatchdog
    //
    // The wiring, not just the arithmetic. This is what decides whether a
    // dictation gets cleaned or pastes raw, and until it was lifted out of
    // `NativeEngine` as a free function it had no coverage at all.

    /// Records the budget it was handed, and can stall to trip the watchdog.
    /// An actor rather than a class so the task group can capture it safely.
    actor FakeCleaner: CleanupCleaning {
        private(set) var budgets: [Double] = []
        private let result: String?
        private let stallS: Double

        init(result: String?, stallS: Double = 0) {
            self.result = result
            self.stallS = stallS
        }

        func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? {
            budgets.append(timeoutS)
            if stallS > 0 { try await Task.sleep(nanoseconds: UInt64(stallS * 1_000_000_000)) }
            return result
        }
    }

    /// A short utterance must be handed exactly the configured budget.
    func testWatchdogPassesTheConfiguredBudgetThroughForShortText() async {
        let raw = "um so the meeting is on tuesday wait no friday"
        let engine = FakeCleaner(result: "The meeting is on Friday.")
        let (out, status) = await cleanupWithWatchdog(
            engine, raw: raw, style: "polish", timeoutS: 12.5)
        XCTAssertEqual(status, .ok)
        XCTAssertEqual(out, "The meeting is on Friday.")
        let budgets = await engine.budgets
        XCTAssertEqual(budgets, [12.5], "a short utterance must not have its budget moved")
    }

    /// The fix, at the wiring level: a transcript of the length that pasted raw
    /// on device must be handed a budget that actually covers the work.
    func testWatchdogWidensTheBudgetForALongTranscript() async {
        let raw = String(repeating: "a", count: 1548)
        let engine = FakeCleaner(result: String(repeating: "a", count: 1500))
        let (_, status) = await cleanupWithWatchdog(
            engine, raw: raw, style: "polish", timeoutS: 12.5)
        XCTAssertEqual(status, .ok)
        let budgets = await engine.budgets
        XCTAssertEqual(budgets.count, 1)
        XCTAssertGreaterThan(budgets[0], 12.5, "the long transcript kept the unusable budget")
        XCTAssertGreaterThan(
            budgets[0], CleanupDeadline.estimateS(chars: raw.count),
            "the widened budget still cannot cover the work")
    }

    /// Past the ceiling the engine must not be invoked at all — the point is to
    /// hand back raw immediately rather than occupy the GPU for a minute first.
    func testWatchdogSkipsTheEngineEntirelyWhenHopeless() async {
        let raw = String(
            repeating: "a",
            count: Int((CleanupDeadline.ceilingS + 20) * CleanupDeadline.throughputCharsPerS))
        let engine = FakeCleaner(result: "cleaned")
        let t0 = CFAbsoluteTimeGetCurrent()
        let (out, status) = await cleanupWithWatchdog(
            engine, raw: raw, style: "polish", timeoutS: 12.5)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertEqual(status, .timeout)
        XCTAssertEqual(out, raw, "the raw transcript must come back untouched")
        let budgets = await engine.budgets
        XCTAssertTrue(budgets.isEmpty, "a hopeless pass must never reach the engine")
        XCTAssertLessThan(elapsed, 1.0, "the whole point is that it returns at once")
    }

    /// The hung-kernel case the watchdog exists for: an engine that never
    /// returns must still yield the raw text, bounded by `watchdogTimeoutS`.
    func testWatchdogRecoversRawTextFromAHungEngine() async {
        let raw = "um hello"
        let engine = FakeCleaner(result: "Hello.", stallS: 120)
        let base = 1.0
        let limit = CleanupDeadline.watchdogTimeoutS(
            effective: CleanupDeadline.effectiveTimeoutS(base: base, chars: raw.count))
        let t0 = CFAbsoluteTimeGetCurrent()
        let (out, status) = await cleanupWithWatchdog(
            engine, raw: raw, style: "polish", timeoutS: base)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        XCTAssertEqual(status, .timeout)
        XCTAssertEqual(out, raw, "a hung engine must never lose the transcript")
        XCTAssertGreaterThanOrEqual(
            elapsed, limit - 0.5, "the watchdog fired early, cancelling a live pass")
        XCTAssertLessThan(elapsed, limit + 5.0, "the watchdog did not fire")
    }
}
