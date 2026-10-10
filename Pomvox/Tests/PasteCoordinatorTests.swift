import AppKit
import XCTest
@testable import Pomvox

final class PasteCoordinatorTests: XCTestCase {
    @MainActor
    private final class Scheduler {
        var steps: [(Double, () -> Void)] = []
        func schedule(_ delay: Double, _ body: @escaping () -> Void) {
            steps.append((delay, body))
        }
        func fire() {
            guard !steps.isEmpty else { return XCTFail("missing scheduled callback") }
            steps.removeFirst().1()
        }
    }

    @MainActor
    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("app.pomvox.ownership-test.\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    @MainActor
    private func queued(_ count: Int, on owner: PasteCoordinator) async {
        for _ in 0..<10_000 {
            if owner.pendingCount == count { return }
            await Task.yield()
        }
        XCTFail("waiter did not reach queue")
    }

    /// The old implementation posts both events immediately and the first
    /// delayed reader gets SECOND. Neither the new snapshot nor the next event
    /// may happen until FIRST's restore lifecycle finishes.
    @MainActor
    func testOneThousandOverlapsPreservePayloadOrderAndClipboardFlavors() async {
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let owner = PasteCoordinator()
        for index in 0..<1_000 {
            pb.clearContents()
            let old = NSPasteboardItem()
            old.setString("original", forType: .string)
            old.setString("<b>original</b>", forType: .html)
            pb.writeObjects([old])
            let clock = Scheduler()
            var events: [String] = []
            let first = await Paster.prepare(using: owner, targetIsCurrent: { true })!
            Paster.perform("FIRST", request: first, to: pb, focusedAcceptsText: true,
                           synthesizePaste: { events.append("first") }, schedule: clock.schedule)
            let second = Task { @MainActor in
                guard let request = await Paster.prepare(using: owner, targetIsCurrent: { true }) else {
                    return XCTFail("unexpected cancellation")
                }
                Paster.perform("SECOND", request: request, to: pb, focusedAcceptsText: true,
                               synthesizePaste: { events.append("second") }, schedule: clock.schedule)
            }
            await queued(1, on: owner)
            XCTAssertEqual(events, ["first"])
            if index % 2 == 0 {
                clock.fire() // unread at checkpoint: retain FIRST until fallback
                XCTAssertEqual(events, ["first"])
                XCTAssertEqual(clock.steps.first?.0, Paster.unreadRestoreDelay - Paster.restoreDelay)
            }
            XCTAssertEqual(pb.string(forType: .string), "FIRST")
            clock.fire()
            await second.value
            XCTAssertEqual(events, ["first", "second"])
            XCTAssertEqual(pb.string(forType: .string), "SECOND")
            clock.fire()
            XCTAssertEqual(pb.string(forType: .string), "original")
            XCTAssertEqual(pb.string(forType: .html), "<b>original</b>")
            XCTAssertEqual(owner.pendingCount, 0)
            XCTAssertTrue(clock.steps.isEmpty)
        }
    }

    @MainActor
    func testCancelledWaiterIsRemovedWithoutWaitingForActiveLease() async {
        let owner = PasteCoordinator()
        let active = await owner.acquire()!
        let waiter = Task { @MainActor in await owner.acquire() }
        await queued(1, on: owner)
        waiter.cancel()
        let cancelled = await waiter.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(owner.pendingCount, 0)
        active.release()
        let next = await owner.acquire()
        XCTAssertNotNil(next)
        next?.release()
    }

    @MainActor
    func testCancellationRacingAdmissionReturnsTheGrantedLease() async {
        let owner = PasteCoordinator()
        for _ in 0..<100 {
            let active = await owner.acquire()!
            let waiter = Task { @MainActor in await owner.acquire() }
            await queued(1, on: owner)
            active.release() // continuation resumed, waiter has not run yet
            waiter.cancel()
            let cancelled = await waiter.value
            XCTAssertNil(cancelled)
            let next = await owner.acquire()
            XCTAssertNotNil(next)
            next?.release()
        }
    }

    @MainActor
    func testFIFOAndRepeatedReleaseCannotReleaseAnotherOwner() async {
        let owner = PasteCoordinator()
        let active = await owner.acquire()!
        let first = Task { @MainActor in await owner.acquire() }
        await queued(1, on: owner)
        let second = Task { @MainActor in await owner.acquire() }
        await queued(2, on: owner)
        active.release()
        let next = await first.value
        active.release()
        XCTAssertEqual(owner.pendingCount, 1)
        next?.release()
        let last = await second.value
        XCTAssertNotNil(last)
        last?.release()
    }

    @MainActor
    func testChangedTargetCopiesWithoutPostingAndReleasesOwnership() async {
        let owner = PasteCoordinator()
        let active = await owner.acquire()!
        var sameTarget = true
        let pending = Task { @MainActor in
            await Paster.prepare(using: owner, targetIsCurrent: { sameTarget })
        }
        await queued(1, on: owner)
        sameTarget = false
        active.release()
        let request = await pending.value!
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let clock = Scheduler()
        var events = 0
        let result = Paster.perform("recover me", request: request, to: pb, focusedAcceptsText: true,
                                    synthesizePaste: { events += 1 }, schedule: clock.schedule)
        XCTAssertEqual(result, .copiedToClipboard)
        XCTAssertEqual(events, 0)
        XCTAssertEqual(pb.string(forType: .string), "recover me")
        XCTAssertEqual(pb.string(forType: Paster.concealedType), "1")
        XCTAssertTrue(clock.steps.isEmpty)
        let next = await owner.acquire()
        XCTAssertNotNil(next)
        next?.release()
    }

    @MainActor
    func testNoFocusAndQueuedCopyKeepActivePayloadUntilDeadline() async {
        let owner = PasteCoordinator()
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        let clock = Scheduler()
        var events = 0
        let first = await Paster.prepare(using: owner, targetIsCurrent: { true })!
        Paster.perform("FIRST", request: first, to: pb, focusedAcceptsText: false,
                       synthesizePaste: { events += 1 }, schedule: clock.schedule)
        let pending = Task { @MainActor in
            let request = await Paster.prepare(using: owner, targetIsCurrent: { true })!
            Paster.perform("COPY", request: request, to: pb, focusedAcceptsText: false,
                           copyOnly: true, synthesizePaste: { events += 1 }, schedule: clock.schedule)
        }
        await queued(1, on: owner)
        XCTAssertEqual(events, 1)
        XCTAssertEqual(pb.string(forType: .string), "FIRST")
        XCTAssertEqual(clock.steps.first?.0, Paster.unreadRestoreDelay)
        clock.fire()
        await pending.value
        XCTAssertEqual(events, 1)
        XCTAssertEqual(pb.string(forType: .string), "COPY")
        XCTAssertTrue(clock.steps.isEmpty)
    }

    @MainActor
    func testUserCopyWinsAndUnusedRequestReleasesWithoutWriting() async {
        let owner = PasteCoordinator()
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("original", forType: .string)
        let clock = Scheduler()
        let first = await Paster.prepare(using: owner, targetIsCurrent: { true })!
        Paster.perform("FIRST", request: first, to: pb, focusedAcceptsText: true,
                       synthesizePaste: {}, schedule: clock.schedule)
        let pending = Task { @MainActor in
            await Paster.prepare(using: owner, targetIsCurrent: { true })
        }
        await queued(1, on: owner)
        XCTAssertEqual(pb.string(forType: .string), "FIRST")
        pb.clearContents()
        pb.setString("user copy", forType: .string)
        clock.fire()
        let unused = await pending.value
        unused?.cancelUnused() // models a stale/empty utterance after admission
        unused?.cancelUnused()
        XCTAssertEqual(pb.string(forType: .string), "user copy")
        let next = await owner.acquire()
        XCTAssertNotNil(next)
        next?.release()
    }

    @MainActor
    func testBestEffortPasteNeverGetsTheManualPastePrompt() async {
        XCTAssertEqual(ReinsertController.Phase.afterPaste(.pasteUnverified), .pasteUnverified)
        XCTAssertEqual(ReinsertController.Phase.afterPaste(.copiedToClipboard),
                       .copied(needsAccessibility: false))
        XCTAssertEqual(ReinsertController.Phase.afterPaste(.pasted), .idle)
    }

    @MainActor
    func testQueuedCopyIsVisibleAndCanBeCancelledBeforeStaging() async {
        let owner = PasteCoordinator()
        let active = await owner.acquire()!
        var copies = 0
        let controller = ReinsertController(
            prepareRequest: { await Paster.prepare(using: owner, targetIsCurrent: { true }) },
            copyText: { _, request in copies += 1; request.cancelUnused() })
        controller.start(text: "cancelled", mode: .copyOnly)
        XCTAssertEqual(controller.phase, .waiting(copyOnly: true))
        await queued(1, on: owner)
        controller.cancel()
        XCTAssertEqual(controller.phase, .idle)
        await queued(0, on: owner)
        active.release()
        let next = await owner.acquire()
        next?.release()
        XCTAssertEqual(copies, 0)
    }

    @MainActor
    func testQueuedCopyReportsCopiedOnlyAfterClipboardWrite() async {
        let owner = PasteCoordinator()
        let active = await owner.acquire()!
        let pb = pasteboard()
        defer { pb.releaseGlobally() }
        pb.setString("FIRST", forType: .string)
        let controller = ReinsertController(
            prepareRequest: { await Paster.prepare(using: owner, targetIsCurrent: { true }) },
            copyText: { text, request in
                Paster.perform(text, request: request, to: pb, focusedAcceptsText: false,
                               copyOnly: true, synthesizePaste: { XCTFail("copy posted a key") },
                               schedule: { _, _ in XCTFail("copy scheduled a restore") })
            })
        controller.start(text: "COPY", mode: .copyOnly)
        await queued(1, on: owner)
        XCTAssertEqual(controller.phase, .waiting(copyOnly: true))
        XCTAssertEqual(pb.string(forType: .string), "FIRST")
        active.release()
        for _ in 0..<10_000 {
            if controller.phase == .copied(needsAccessibility: true) { break }
            await Task.yield()
        }
        XCTAssertEqual(controller.phase, .copied(needsAccessibility: true))
        XCTAssertEqual(pb.string(forType: .string), "COPY")
        controller.cancel()
    }
}
