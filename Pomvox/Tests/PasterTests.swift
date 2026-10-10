import AppKit
import XCTest
@testable import Pomvox

/// The paste/clipboard-recovery policy. The synthesized ⌘V and the AX focus probe
/// can't be unit-tested, so `Paster.deliver` takes them as injected closures +
/// flag; this exercises the clipboard staging, restore-guard, and no-focus
/// fallback against a real (named, off-general) pasteboard.
///
/// The restore is consumption-keyed (issue #82's recurrence): the transcript's
/// string flavor is staged through a data provider, so `deliver` can tell
/// whether any consumer has read it (not an OS acknowledgement). Tests drive the injected
/// scheduler by hand: `schedule` records (delay, body) pairs, and reading the
/// pasteboard from the test IS the consumption signal (same-process promises
/// resolve synchronously).
final class PasterTests: XCTestCase {

    private func freshPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("app.pomvox.test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    /// Captures scheduled restore steps so tests fire them deterministically.
    private final class FakeScheduler {
        var steps: [(delay: Double, body: () -> Void)] = []
        func schedule(_ delay: Double, _ body: @escaping () -> Void) {
            steps.append((delay, body))
        }
        /// Run the next pending step (as if its timer fired).
        func fire() {
            guard !steps.isEmpty else { return XCTFail("no scheduled step to fire") }
            steps.removeFirst().body()
        }
    }

    @MainActor
    func testFocusedFieldStagesTextThenRestoresPriorClipboard() async {
        let pb = freshPasteboard()
        pb.setString("old", forType: .string)
        let scheduler = FakeScheduler()

        var synthesized = false
        let outcome = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                                     synthesizePaste: { synthesized = true },
                                     schedule: scheduler.schedule)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertTrue(synthesized)
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // staged for the ⌘V (and read now)
        scheduler.fire()                                         // the checkpoint fires
        XCTAssertEqual(pb.string(forType: .string), "old")       // prior clipboard back
    }

    @MainActor
    func testNoFocusLeavesTranscriptOnClipboardInsteadOfLosingIt() async {
        let pb = freshPasteboard()
        pb.setString("old", forType: .string)
        let scheduler = FakeScheduler()

        let outcome = Paster.deliver("dictated", to: pb, focusedAcceptsText: false,
                                     synthesizePaste: {},
                                     schedule: scheduler.schedule)

        XCTAssertEqual(outcome, .pasteUnverified)
        XCTAssertEqual(scheduler.steps.count, 1)                 // hold ownership, without restore
        scheduler.fire()
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // recoverable, not lost
    }

    /// Regression guard for the intermittent "pastes previous text" bug: the
    /// restore must not fire so soon that a slow-to-paste app reads the restored
    /// prior clipboard instead of the staged transcript. 0.15 s was too short;
    /// pin the floor to the chosen 0.5 s so it can't be shortened back into the
    /// race — a *longer* delay stays safe (it only widens the recovery window).
    @MainActor
    func testRestoreDelayIsGenerousEnoughToOutlastASlowPaste() async {
        XCTAssertGreaterThanOrEqual(Paster.restoreDelay, 0.5)
        XCTAssertGreaterThan(Paster.unreadRestoreDelay, Paster.restoreDelay)
    }

    @MainActor
    func testRestoreYieldsToARealUserCopyDuringTheDelay() async {
        let pb = freshPasteboard()
        pb.setString("old", forType: .string)
        let scheduler = FakeScheduler()

        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, schedule: scheduler.schedule)
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // consumed by the paste…
        pb.clearContents(); pb.setString("user copied this", forType: .string)  // …then a real copy lands
        scheduler.fire()
        XCTAssertEqual(pb.string(forType: .string), "user copied this")  // user copy wins
    }

    // MARK: - consumption-keyed restore (the fixed timer raced slow apps, #82)

    @MainActor
    func testUnreadTranscriptDefersRestoreToTheLongFallback() async {
        // The target app hasn't processed the ⌘V by the 0.5 s checkpoint (busy
        // Electron, app mid-launch). Restoring now would make its eventual
        // paste insert the PRIOR clipboard — the "pasted what I didn't say"
        // bug. The checkpoint must reschedule to the long fallback instead.
        let pb = freshPasteboard()
        pb.setString("old", forType: .string)
        let scheduler = FakeScheduler()

        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, schedule: scheduler.schedule)
        XCTAssertEqual(scheduler.steps.first?.delay, Paster.restoreDelay)
        scheduler.fire()                                          // checkpoint: nothing read yet
        // Not restored — the slow app can still read the transcript…
        XCTAssertEqual(pb.string(forType: .string), "dictated")
        // …and a fallback step was scheduled to eventually give the clipboard back.
        XCTAssertEqual(scheduler.steps.count, 1)
        scheduler.fire()
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    @MainActor
    func testSlowReadBetweenCheckpointAndFallbackStillGetsTheTranscript() async {
        let pb = freshPasteboard()
        pb.setString("old", forType: .string)
        let scheduler = FakeScheduler()

        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, schedule: scheduler.schedule)
        scheduler.fire()                                          // checkpoint: unread → defer
        XCTAssertEqual(pb.string(forType: .string), "dictated")   // slow app reads at ~2 s
        scheduler.fire()                                          // fallback restores afterwards
        XCTAssertEqual(pb.string(forType: .string), "old")
    }

    // MARK: - full-fidelity restore (a dictation must not eat the clipboard)

    @MainActor
    func testRestorePreservesANonTextClipboard() async {
        // A copied image (screenshot, file, …) must come back after a
        // dictation. Only the plain string used to be saved, so any non-text
        // clipboard was permanently replaced by the transcript.
        let pb = freshPasteboard()
        let png = Data([0x89, 0x50, 0x4E, 0x47])  // magic bytes stand in for a real image
        pb.setData(png, forType: .png)
        let scheduler = FakeScheduler()

        let outcome = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                                     synthesizePaste: {}, schedule: scheduler.schedule)

        XCTAssertEqual(outcome, .pasted)
        XCTAssertEqual(pb.string(forType: .string), "dictated")  // staged for the ⌘V
        scheduler.fire()
        XCTAssertEqual(pb.data(forType: .png), png)              // the image is back
        XCTAssertNil(pb.string(forType: .string))                // and only the image
    }

    @MainActor
    func testRestorePreservesEveryFlavorOfARichItem() async {
        // Rich text (a browser or Word copy) carries several flavors on one
        // item; restoring just the plain string silently degrades it.
        let pb = freshPasteboard()
        let item = NSPasteboardItem()
        item.setString("hello", forType: .string)
        item.setString("<b>hello</b>", forType: .html)
        pb.writeObjects([item])
        let scheduler = FakeScheduler()

        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, schedule: scheduler.schedule)
        XCTAssertEqual(pb.string(forType: .string), "dictated")
        scheduler.fire()
        XCTAssertEqual(pb.string(forType: .string), "hello")
        XCTAssertEqual(pb.string(forType: .html), "<b>hello</b>")
    }

    @MainActor
    func testEmptyPriorClipboardKeepsTranscriptAfterRestore() async {
        // Nothing to restore: keep the transcript recoverable instead of
        // clearing the clipboard (the pre-existing empty-clipboard behavior).
        let pb = freshPasteboard()
        let scheduler = FakeScheduler()

        _ = Paster.deliver("dictated", to: pb, focusedAcceptsText: true,
                           synthesizePaste: {}, schedule: scheduler.schedule)
        XCTAssertEqual(pb.string(forType: .string), "dictated")
        scheduler.fire()
        XCTAssertEqual(pb.string(forType: .string), "dictated")
    }
}
