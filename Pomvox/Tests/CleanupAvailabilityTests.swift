import Darwin
import XCTest
@testable import Pomvox

/// Cleanup availability: the status the UI shows, a failed download that can
/// be retried, and the rule that an utterance timeout (or an engine restart)
/// does not cancel a download already in flight.
final class CleanupAvailabilityTests: XCTestCase {

    func testMissingModelShowsVisibleStatus() {
        let state = CleanupAvailabilityState.initial.applying(.turnedOn)
        XCTAssertEqual(state.phase, .notDownloaded)
        XCTAssertEqual(
            CleanupAvailability.modelStatusLine(state.phase),
            "Cleanup model not downloaded")
        XCTAssertEqual(
            CleanupAvailability.runtimeSummary(state),
            "Cleanup is on — model not downloaded")
        XCTAssertEqual(
            CleanupAvailability.menuLine(state),
            "Cleanup model not downloaded")
        XCTAssertEqual(
            CleanupAvailability.dictationNotice(state.phase),
            "cleanup unavailable (model not downloaded)")
        XCTAssertEqual(CleanupAvailability.buttonTitle(state.phase), "Download model")
        // Enabling is what starts the transfer — not merely recording that
        // the low-memory sheet was answered.
        XCTAssertEqual(CleanupAvailability.action(for: state), .download)
    }

    func testDownloadingStatusIncludesPercent() {
        let phase = CleanupModelPhase.downloading(fraction: 0.454)
        XCTAssertEqual(
            CleanupAvailability.modelStatusLine(phase),
            "Cleanup model downloading… 45%")
        XCTAssertEqual(
            CleanupAvailability.dictationNotice(phase),
            "cleanup unavailable (downloading)")
    }

    func testFailedDownloadRetryRestartsAndClearsTheError() {
        let failed = CleanupAvailabilityState(
            enabled: true, phase: .notDownloaded,
            downloadInFlight: false, downloadCancelled: false)
            .applying(.downloadStarted)
            .applying(.failed(.download("HTTP 401")))
        XCTAssertEqual(
            CleanupAvailability.modelStatusLine(failed.phase),
            "Download failed: HTTP 401")
        XCTAssertEqual(
            CleanupAvailability.dictationNotice(failed.phase),
            "cleanup unavailable (download failed: HTTP 401)")
        XCTAssertEqual(CleanupAvailability.buttonTitle(failed.phase), "Retry download")
        XCTAssertFalse(failed.downloadInFlight)
        XCTAssertEqual(CleanupAvailability.action(for: failed), .none,
                       "a failed download waits for Retry and does not restart itself")

        let retried = failed.applying(.retry)
        XCTAssertEqual(retried.phase, .downloading(fraction: nil))
        XCTAssertTrue(retried.downloadInFlight)
        XCTAssertFalse(retried.downloadCancelled)
        XCTAssertEqual(
            CleanupAvailability.modelStatusLine(retried.phase),
            "Cleanup model downloading…")
        // A second retry while that attempt is in flight must not start
        // another download — the two would deadlock on the same file lock.
        XCTAssertEqual(retried.applying(.retry), retried)
    }

    func testUtteranceTimeoutDoesNotCancelTheDownload() {
        let downloading = CleanupAvailabilityState(
            enabled: true, phase: .notDownloaded,
            downloadInFlight: false, downloadCancelled: false)
            .applying(.downloadStarted)
            .applying(.progress(0.45))
        let after = downloading.applying(.utteranceTimedOut)
        XCTAssertEqual(after, downloading)
        XCTAssertTrue(after.downloadInFlight)
        XCTAssertFalse(after.downloadCancelled)
        XCTAssertEqual(after.phase, .downloading(fraction: 0.45))
        // And a first load, once the bytes are down, is the same rule.
        let loading = downloading
            .applying(.downloadFinished)
            .applying(.loadStarted)
        let afterLoadTimeout = loading.applying(.utteranceTimedOut)
        XCTAssertEqual(afterLoadTimeout, loading)
        XCTAssertEqual(afterLoadTimeout.phase, .loading)
        XCTAssertFalse(afterLoadTimeout.downloadCancelled)
    }

    func testEngineRestartDoesNotCancelTheDownload() {
        let downloading = CleanupAvailabilityState(
            enabled: true, phase: .notDownloaded,
            downloadInFlight: false, downloadCancelled: false)
            .applying(.downloadStarted)
        let after = downloading.applying(.engineRestarted)
        XCTAssertTrue(after.downloadInFlight)
        XCTAssertFalse(after.downloadCancelled)
        XCTAssertEqual(after.phase, .downloading(fraction: nil))
    }

    func testEngineRestartDropsResidentWeightsWithoutTouchingAFinishedSnapshot() {
        let ready = CleanupAvailabilityState(
            enabled: true, phase: .ready,
            downloadInFlight: false, downloadCancelled: false)
        let after = ready.applying(.engineRestarted)
        XCTAssertEqual(after.phase, .onDisk)
        XCTAssertFalse(after.downloadCancelled)
        XCTAssertEqual(CleanupAvailability.action(for: after), .load)
    }

    func testStaleLockFileIsReclaimedWhenNobodyHoldsIt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-locks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("blobs/abc123.lock")
        try FileManager.default.createDirectory(
            at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: lock.path, contents: Data()))

        XCTAssertEqual(HuggingFaceStaleLock.reclaimUnheldLocks(in: dir), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }

    func testHeldLockIsLeftInPlace() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-locks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("held.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let fd = open(lock.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)

        XCTAssertFalse(HuggingFaceStaleLock.reclaim(lock))
        XCTAssertEqual(HuggingFaceStaleLock.reclaimUnheldLocks(in: dir), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }
}
