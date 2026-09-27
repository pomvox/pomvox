import Foundation

// Host-side building blocks for the cleanup SDK integration: the vocabulary the
// SDK is handed, the one budget an utterance gets, and a cancellable wait on
// work this caller does not own. None of these touch the SDK itself, so they
// are testable without a pack or a model.

// MARK: - Vocabulary

/// The bounded, ordered subset of the user's dictionary words handed to the SDK.
///
/// The SDK refuses — rather than trims — a vocabulary over its limits (64
/// terms, 128 UTF-8 bytes each, 2,048 bytes total, no line breaks), and a
/// refused request costs the dictation its cleanup. The host therefore picks a
/// deterministic subset before open and before every request. The complete
/// dictionary is untouched: the host's replacement rules still run on the
/// final text.
///
/// Identity is exact UTF-8. Swift's `String ==` treats canonically equivalent
/// strings ("é" precomposed vs "e" + combining acute) as equal, but the
/// tokenizer and the SDK's prefix key do not, so neither deduplication nor
/// change detection may use it.
struct SDKVocabulary: Sendable {
    static let maxTerms = 64
    static let maxTermBytes = 128
    static let maxTotalBytes = 2_048

    /// The terms sent on every request, in dictionary order.
    let terms: [String]
    /// Counts only — the omitted words themselves are never logged.
    struct Omissions: Equatable, Sendable {
        var empty = 0
        var lineBreak = 0
        var tooLong = 0
        var duplicate = 0
        var overCount = 0
        var overTotalBytes = 0
        var total: Int { empty + lineBreak + tooLong + duplicate + overCount + overTotalBytes }
    }
    let omitted: Omissions

    static let empty = SDKVocabulary(terms: [], omitted: Omissions())

    /// Byte-exact identity, for "did the dictionary change" decisions.
    var identity: [[UInt8]] { terms.map { Array($0.utf8) } }

    /// Select from dictionary words in order. Spaces/tabs at the ends are
    /// trimmed (the prompt hint does the same); a term containing any line
    /// break is omitted, not rewritten, because rewriting would change the
    /// spelling the user pinned. Once the running total would pass the byte
    /// limit, that term and every later one are omitted, so an edit late in the
    /// list can never displace an earlier term.
    static func select(from words: [String]) -> SDKVocabulary {
        var kept: [String] = []
        var seen = Set<[UInt8]>()
        var bytes = 0
        var omitted = Omissions()
        var full = false
        for word in words {
            let term = word.trimmingCharacters(in: .init(charactersIn: " \t"))
            if term.isEmpty { omitted.empty += 1; continue }
            if term.contains(where: \.isNewline) || term.unicodeScalars.contains(where: {
                CharacterSet.newlines.contains($0)
            }) {
                omitted.lineBreak += 1; continue
            }
            let size = term.utf8.count
            if size > maxTermBytes { omitted.tooLong += 1; continue }
            let key = Array(term.utf8)
            if seen.contains(key) { omitted.duplicate += 1; continue }
            if full || bytes + size > maxTotalBytes {
                full = true
                omitted.overTotalBytes += 1
                continue
            }
            if kept.count >= maxTerms { omitted.overCount += 1; continue }
            kept.append(term)
            seen.insert(key)
            bytes += size
        }
        return SDKVocabulary(terms: kept, omitted: omitted)
    }

    /// One content-free log line, or nil when nothing was omitted.
    var omissionSummary: String? {
        let o = omitted
        guard o.total > 0 else { return nil }
        return "cleanup: \(terms.count) dictionary term(s) sent to the SDK, \(o.total) omitted "
            + "(empty \(o.empty), line break \(o.lineBreak), >\(Self.maxTermBytes) bytes \(o.tooLong), "
            + "duplicate \(o.duplicate), over \(Self.maxTerms) terms \(o.overCount), "
            + "over \(Self.maxTotalBytes) bytes \(o.overTotalBytes))"
    }
}

// MARK: - Budget

/// The single deadline for one utterance's whole cleanup operation — waiting
/// for preparation, waiting out a quarantine, and the SDK request itself.
///
/// Fixed once, at cleanup start. Nothing extends it: the SDK's own deadline
/// covers only admitted request work, so each request is given what is left of
/// this budget, capped at the SDK's 60 s maximum.
struct CleanupBudget: Sendable {
    static let sdkMaximum: Duration = .seconds(60)
    let deadline: ContinuousClock.Instant

    init(seconds: Double, from start: ContinuousClock.Instant = .now) {
        let clamped = seconds.isFinite ? max(0, seconds) : 0
        deadline = start.advanced(by: .milliseconds(Int64((clamped * 1000).rounded(.down))))
    }

    init(deadline: ContinuousClock.Instant) { self.deadline = deadline }

    func remaining(at now: ContinuousClock.Instant = .now) -> Duration {
        max(.zero, now.duration(to: deadline))
    }

    var isExhausted: Bool { remaining() <= .zero }

    /// A positive SDK deadline of at most 60 s, or nil when nothing is left.
    /// Never zero or negative: the SDK rejects those, and the right response to
    /// an exhausted budget is the host's fallback, not a doomed request.
    func requestDeadline(at now: ContinuousClock.Instant = .now) -> Duration? {
        let left = remaining(at: now)
        guard left > .milliseconds(1) else { return nil }
        return min(left, Self.sdkMaximum)
    }
}

// MARK: - Latch

/// A one-shot completion signal that any number of callers can wait on,
/// cancellably and with a deadline, without owning the work behind it.
///
/// This is why the backend does not simply `await task.value`: an unstructured
/// task's value ignores the waiter's cancellation, and a task-group race would
/// keep awaiting that value in its cancelled child while the group drains. Here
/// a cancelled or expired waiter is resumed at once and the work carries on for
/// everyone else.
final class AsyncLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Bool, any Error>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        let pendingTimers = timers
        waiters = [:]
        timers = [:]
        lock.unlock()
        pendingTimers.values.forEach { $0.cancel() }
        pending.values.forEach { $0.resume(returning: true) }
    }

    /// True once opened; false if `deadline` passed first. Throws
    /// `CancellationError` promptly when the waiting task is cancelled.
    func wait(until deadline: ContinuousClock.Instant? = nil) async throws -> Bool {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Bool, any Error>) in
                lock.lock()
                if isOpen { lock.unlock(); c.resume(returning: true); return }
                // The cancellation flag is set before the handler runs, so a
                // handler that raced ahead of this registration is caught here.
                if Task.isCancelled { lock.unlock(); c.resume(throwing: CancellationError()); return }
                if let deadline, deadline <= .now { lock.unlock(); c.resume(returning: false); return }
                waiters[id] = c
                if let deadline {
                    timers[id] = Task { [weak self] in
                        try? await ContinuousClock().sleep(until: deadline)
                        guard !Task.isCancelled else { return }
                        self?.resolve(id, with: .success(false))
                    }
                }
                lock.unlock()
            }
        } onCancel: {
            resolve(id, with: .failure(CancellationError()))
        }
    }

    private func resolve(_ id: UUID, with result: Result<Bool, any Error>) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        let timer = timers.removeValue(forKey: id)
        lock.unlock()
        timer?.cancel()
        waiter?.resume(with: result)
    }
}

// MARK: - Memory policy

/// When the host may reopen an evicted cleaner. A memory-pressure eviction
/// must not be undone by the same pressure event: the cleaner stays evicted
/// until an utterance actually needs it, and even then only once the system
/// has reported normal pressure again or the cool-down has passed.
struct CleanupMemoryPolicy: Sendable {
    enum Level: Sendable { case normal, warning, critical }
    static let coolDownS = 60.0

    private(set) var lastLevel: Level = .normal
    private(set) var lastEventAt: Double?

    mutating func record(_ level: Level, at now: Double) {
        lastLevel = level
        lastEventAt = now
    }

    func permitsReopen(at now: Double) -> Bool {
        guard lastLevel != .normal, let at = lastEventAt else { return true }
        return now - at >= Self.coolDownS
    }
}
