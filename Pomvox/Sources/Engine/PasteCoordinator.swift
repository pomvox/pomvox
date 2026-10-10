import Foundation

/// Owns the clipboard for the whole staged-paste lifetime, including restoration.
/// Waiting yields the main actor; cancelled waiters never acquire ownership.
@MainActor
final class PasteCoordinator {
    @MainActor
    final class Lease {
        private let owner: PasteCoordinator
        fileprivate let id: UUID
        private(set) var isReleased = false

        fileprivate init(owner: PasteCoordinator, id: UUID) {
            self.owner = owner
            self.id = id
        }

        func release() {
            guard !isReleased else { return }
            isReleased = true
            owner.release(id)
        }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease?, Never>
    }

    private var active: UUID?
    private var waiters: [Waiter] = []
    var pendingCount: Int { waiters.count }

    func acquire() async -> Lease? {
        guard !Task.isCancelled else { return nil }
        let id = UUID()
        let lease: Lease? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else if active == nil {
                    active = id
                    continuation.resume(returning: Lease(owner: self, id: id))
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        // Cancellation may race release/admission. Give the lease back before
        // returning, even if the cancellation handler has not run yet.
        if Task.isCancelled {
            lease?.release()
            return nil
        }
        return lease
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }

    private func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            active = next.id
            next.continuation.resume(returning: Lease(owner: self, id: next.id))
        }
    }
}
