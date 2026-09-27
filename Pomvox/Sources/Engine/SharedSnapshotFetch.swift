import Foundation

/// Hugging Face snapshot downloads that outlive whoever asked for them.
///
/// Cancelling `downloadSnapshot` mid-transfer leaves a `.lock` with no blob,
/// and two downloads of one repo at once wait on the same lock forever (see
/// `HuggingFaceStaleLock`). Three callers want the same snapshot: the in-app
/// download, the in-app load, and the SDK's pack provisioner, whose
/// preparation is cancelled on disarm and on memory pressure. Every one of
/// them joins a single detached fetch per repo. A cancelled caller stops
/// waiting; the transfer does not stop, and the next caller picks it up.
final class SharedSnapshotFetch: @unchecked Sendable {
    static let shared = SharedSnapshotFetch()

    private final class Fetch: @unchecked Sendable {
        let done = AsyncLatch()
        var result: Result<URL, any Error>?
        var listeners: [UUID: @Sendable (Double) -> Void] = [:]
    }

    private let lock = NSLock()
    private var inFlight: [String: Fetch] = [:]

    /// Join the fetch for `key`, starting `body` detached if none is running.
    /// `onProgress` receives the shared transfer's progress while this caller
    /// waits. Throws `CancellationError` when the caller is cancelled.
    func fetch(
        _ key: String, onProgress: (@Sendable (Double) -> Void)?,
        _ body: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> URL
    ) async throws -> URL {
        let listener = UUID()
        lock.lock()
        let fetch: Fetch
        let start: Bool
        if let existing = inFlight[key] {
            fetch = existing
            start = false
        } else {
            fetch = Fetch()
            inFlight[key] = fetch
            start = true
        }
        if let onProgress { fetch.listeners[listener] = onProgress }
        lock.unlock()
        defer {
            lock.lock(); fetch.listeners[listener] = nil; lock.unlock()
        }

        if start {
            Task.detached { [self] in
                let result: Result<URL, any Error>
                do {
                    result = .success(try await body { fraction in self.broadcast(fraction, to: fetch) })
                } catch {
                    result = .failure(error)
                }
                lock.lock()
                fetch.result = result
                if inFlight[key] === fetch { inFlight[key] = nil }
                lock.unlock()
                fetch.done.open()
            }
        }

        _ = try await fetch.done.wait()
        lock.lock(); let result = fetch.result; lock.unlock()
        guard let result else { throw CancellationError() }
        return try result.get()
    }

    private func broadcast(_ fraction: Double, to fetch: Fetch) {
        lock.lock(); let listeners = Array(fetch.listeners.values); lock.unlock()
        listeners.forEach { $0(fraction) }
    }
}
