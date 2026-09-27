import XCTest
@testable import Pomvox

/// `SharedSnapshotFetch`: one transfer per repo, and a cancelled caller never
/// cancels it (a cancelled Hugging Face download leaves a lock and no blob).
final class SharedSnapshotFetchTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func testConcurrentCallersShareOneTransfer() async throws {
        let fetches = SharedSnapshotFetch()
        let started = Counter()
        let release = AsyncLatch()
        let url = URL(fileURLWithPath: "/tmp/snapshot")
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL = { _ in
            started.increment()
            _ = try await release.wait()
            return url
        }
        async let a = fetches.fetch("org/model", onProgress: nil, body)
        async let b = fetches.fetch("org/model", onProgress: nil, body)
        try await Task.sleep(nanoseconds: 50_000_000)
        release.open()
        let results = try await [a, b]
        XCTAssertEqual(results, [url, url])
        XCTAssertEqual(started.count, 1)
    }

    func testCancelledCallerLeavesTheTransferRunning() async throws {
        let fetches = SharedSnapshotFetch()
        let started = Counter()
        let finished = Counter()
        let release = AsyncLatch()
        let url = URL(fileURLWithPath: "/tmp/snapshot")
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL = { progress in
            started.increment()
            // Not cancellation-aware on purpose: the detached transfer must
            // not see the caller's cancellation at all.
            while !release.opened { try? await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertFalse(Task.isCancelled)
            progress(1)
            finished.increment()
            return url
        }
        let first = Task { try await fetches.fetch("org/model", onProgress: nil, body) }
        try await Task.sleep(nanoseconds: 50_000_000)
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("a cancelled caller stops waiting")
        } catch is CancellationError {}

        // The next caller joins the same transfer instead of starting another.
        let progressSeen = Counter()
        let second = Task {
            try await fetches.fetch("org/model", onProgress: { _ in progressSeen.increment() }, body)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        release.open()
        let result = try await second.value
        XCTAssertEqual(result, url)
        XCTAssertEqual(started.count, 1)
        XCTAssertEqual(finished.count, 1)
        XCTAssertEqual(progressSeen.count, 1)
    }

    func testAFinishedFetchIsNotReused() async throws {
        let fetches = SharedSnapshotFetch()
        let started = Counter()
        let body: @Sendable (@escaping @Sendable (Double) -> Void) async throws -> URL = { _ in
            started.increment()
            return URL(fileURLWithPath: "/tmp/snapshot")
        }
        _ = try await fetches.fetch("org/model", onProgress: nil, body)
        _ = try await fetches.fetch("org/model", onProgress: nil, body)
        XCTAssertEqual(started.count, 2, "a completed (or failed) fetch is retried, not cached")
    }
}
