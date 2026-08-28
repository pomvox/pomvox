import XCTest
@testable import Pomvox

/// Mirror of `tests/test_pidfile.py` — the cross-engine mutual-exclusion contract.
final class PidfileTests: XCTestCase {
    let DEAD: Int32 = 999_999  // a pid that won't exist
    var me: Int32 { ProcessInfo.processInfo.processIdentifier }
    var myPath: String { Pidfile.currentExecPath() }

    private func tempPidfile() -> Pidfile {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-pidfile-\(UUID().uuidString)")
        return Pidfile(url: dir.appendingPathComponent("engine.pid"))
    }

    private func write(_ pf: Pidfile, _ contents: String) {
        try? FileManager.default.createDirectory(
            at: pf.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? contents.write(to: pf.url, atomically: true, encoding: .utf8)
    }

    // MARK: - acquire / release

    func testAcquireOnEmptyWritesAndReturnsNil() {
        let pf = tempPidfile()
        XCTAssertNil(pf.acquire("native", pid: me))
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: me, name: "native", execPath: myPath))
    }

    func testAcquireBlockedByLiveOtherHolder() {
        let pf = tempPidfile()
        XCTAssertNil(pf.acquire("python", pid: me))             // our live pid holds it
        let blocker = pf.acquire("native", pid: DEAD)           // a different pid is refused
        XCTAssertEqual(blocker, Pidfile.Owner(pid: me, name: "python", execPath: myPath))
        XCTAssertEqual(pf.read(),                               // untouched
                       Pidfile.Owner(pid: me, name: "python", execPath: myPath))
    }

    func testAcquireOverwritesStaleDeadPid() {
        let pf = tempPidfile()
        _ = pf.acquire("python", pid: DEAD)                     // crashed without releasing
        XCTAssertNil(pf.currentHolder())                        // dead → no live holder
        XCTAssertNil(pf.acquire("native", pid: me))             // claimed cleanly
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: me, name: "native", execPath: myPath))
    }

    func testReleaseOnlyRemovesWhenWeOwnIt() {
        let pf = tempPidfile()
        _ = pf.acquire("python", pid: me)
        pf.release(pid: me)
        XCTAssertNil(pf.read())

        _ = pf.acquire("native", pid: DEAD)
        pf.release(pid: me)                                     // not ours → left alone
        XCTAssertEqual(pf.read()?.pid, DEAD)
    }

    // MARK: - parsing

    func testReadMissingAndMalformed() {
        let pf = tempPidfile()
        XCTAssertNil(pf.read())
        write(pf, "not-a-pid\nnative\n")
        XCTAssertNil(pf.read())
        XCTAssertNil(pf.currentHolder())
    }

    func testReadLegacyTwoLineFileHasNoExecPath() {
        let pf = tempPidfile()
        write(pf, "4242\nnative\n")
        XCTAssertEqual(pf.read(), Pidfile.Owner(pid: 4242, name: "native", execPath: nil))
    }

    func testReadThreeLineFileCarriesExecPath() {
        let pf = tempPidfile()
        write(pf, "4242\nnative\n/Applications/Pomvox.app/Contents/MacOS/Pomvox\n")
        XCTAssertEqual(pf.read(), Pidfile.Owner(
            pid: 4242, name: "native",
            execPath: "/Applications/Pomvox.app/Contents/MacOS/Pomvox"))
    }

    // MARK: - the decision (pure)

    func testDeadPidIsNeverLive() {
        let owner = Pidfile.Owner(pid: 42, name: "native", execPath: "/x/Pomvox")
        XCTAssertFalse(pidfileOwnerIsLive(owner, identity: .dead))
    }

    func testMatchingExecPathIsLive() {
        let owner = Pidfile.Owner(pid: 42, name: "native", execPath: "/x/Pomvox")
        XCTAssertTrue(pidfileOwnerIsLive(owner, identity: .running(path: "/x/Pomvox")))
    }

    /// The 2026-08-27 field failure: a reboot handed the recorded pid to an
    /// unrelated daemon and the stale lock read as live forever.
    func testRecycledPidRunningAnotherProcessIsNotLive() {
        let owner = Pidfile.Owner(
            pid: 985, name: "native",
            execPath: "/Applications/Pomvox.app/Contents/MacOS/Pomvox")
        XCTAssertFalse(pidfileOwnerIsLive(owner, identity: .running(path: "/usr/sbin/usernoted")))
    }

    func testUnverifiablePidIsTreatedAsLive() {
        // Another user's process: we cannot disprove it, so we must not steal it.
        let owner = Pidfile.Owner(pid: 42, name: "native", execPath: "/x/Pomvox")
        XCTAssertTrue(pidfileOwnerIsLive(owner, identity: .unverifiable))
    }

    // MARK: - legacy files (no exec-path line to match)

    func testLegacyFileTrustsAPlausibleEnginePath() {
        let owner = Pidfile.Owner(pid: 42, name: "native", execPath: nil)
        XCTAssertTrue(pidfileOwnerIsLive(
            owner, identity: .running(path: "/Applications/Pomvox.app/Contents/MacOS/Pomvox")))
    }

    func testLegacyFileRejectsARecycledPid() {
        let owner = Pidfile.Owner(pid: 985, name: "native", execPath: nil)
        XCTAssertFalse(pidfileOwnerIsLive(owner, identity: .running(path: "/usr/sbin/usernoted")))
    }

    func testLegacyPythonShapes() {
        XCTAssertTrue(legacyPathCouldBeEngine("/opt/homebrew/bin/python3.12", name: "python"))
        XCTAssertTrue(legacyPathCouldBeEngine("/Users/x/.venv/bin/pomvox", name: "python"))
        XCTAssertTrue(legacyPathCouldBeEngine("/opt/homebrew/bin/uv", name: "python"))
        XCTAssertFalse(legacyPathCouldBeEngine("/usr/sbin/usernoted", name: "python"))
        XCTAssertFalse(legacyPathCouldBeEngine("/usr/sbin/usernoted", name: "native"))
        XCTAssertFalse(legacyPathCouldBeEngine("/x/Pomvox", name: "mystery-engine"))
    }

    // MARK: - end to end, against a genuinely live pid

    /// A file naming *our own live pid* but a different executable is a recycled
    /// pid by definition — acquire must break it rather than block forever.
    func testAcquireBreaksALockWhoseLivePidRunsSomethingElse() {
        let pf = tempPidfile()
        write(pf, "\(me)\nnative\n/usr/sbin/usernoted\n")
        XCTAssertNil(pf.currentHolder(), "a recycled pid must not read as a live holder")
        XCTAssertNil(pf.acquire("native", pid: DEAD), "the stale lock must be claimable")
        XCTAssertEqual(pf.read()?.pid, DEAD)
    }

    /// The same pid running the same executable is a real holder — still blocks.
    func testAcquireStillBlocksOnAGenuineLiveHolder() {
        let pf = tempPidfile()
        write(pf, "\(me)\npython\n\(myPath)\n")
        XCTAssertEqual(pf.currentHolder()?.name, "python")
        XCTAssertEqual(pf.acquire("native", pid: DEAD)?.name, "python")
    }

    func testIdentityOfOurOwnPidIsRunningAndAgreesWithWhatWeRecord() {
        // The exact path depends on the test host, so assert the invariant that
        // matters: what we record for ourselves is what we'd read back.
        XCTAssertEqual(Pidfile.identity(of: me), .running(path: myPath))
        XCTAssertFalse(myPath.isEmpty)
        XCTAssertEqual(Pidfile.identity(of: DEAD), .dead)
    }
}
