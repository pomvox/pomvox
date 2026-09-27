import Foundation
import PomvoxCleanup
import XCTest

@testable import Pomvox

/// The SDK backend's host responsibilities, against the real SDK lifecycle
/// (`Cleaner`, `CleanupSession`, `PackInstaller`, `PackLoader`) with a fake
/// runtime. No model, no network, no repository paths.
final class SDKCleanupHostTests: XCTestCase {

    private var fixtures: [SDKHostFixture] = []

    override func tearDown() {
        fixtures.forEach { $0.cleanup() }
        fixtures = []
        super.tearDown()
    }

    private func fixture(model: FakeModel = FakeModel(), grace: Duration = .milliseconds(200),
                         snapshotManifest: Data? = nil) throws -> SDKHostFixture {
        let f = try SDKHostFixture(model: model, quarantineGrace: grace, snapshotManifest: snapshotManifest)
        fixtures.append(f)
        return f
    }

    private func vocab(_ words: [String]) -> SDKVocabulary { SDKVocabulary.select(from: words) }

    private func budget(_ seconds: Double) -> CleanupBudget { CleanupBudget(seconds: seconds) }

    // MARK: - Eager, shared preparation

    func testEnablePreparesEagerlyAndConcurrentDictationsShareOnePreparation() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: vocab(["Pomvox"]))
        // Preparation starts at enable, before any dictation asks for it.
        await eventually { model.openAttempts == 1 }

        async let a = f.host.clean("hello there", budget: budget(5))
        async let b = f.host.clean("second one", budget: budget(5))
        try await Task.sleep(nanoseconds: 50_000_000)
        gate.open()
        let (ra, rb) = try await (a, b)

        XCTAssertEqual(ra.kind, .cleaned)
        XCTAssertEqual(ra.text, "Hello there.")
        XCTAssertEqual(rb.kind, .cleaned)
        XCTAssertNotNil(ra.preparationWaitMS, "the racing dictation waited on the shared preparation")
        XCTAssertEqual(model.opens, 1)
        XCTAssertEqual(f.acquisitions.count, 1)
        let prep = await f.host.lastPreparation
        XCTAssertEqual(prep?.kind, .installed, "first open reuses the installer's validation handle")
    }

    func testDictationWhoseBudgetEndsDuringOpenFallsBackAndPreparationContinues() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)

        let raw = "  keep   me exactly  "
        let early = try await f.host.clean(raw, budget: budget(0.2))
        XCTAssertEqual(early.kind, .fallback(.preparationTimedOut))
        XCTAssertEqual(early.text, raw)
        let stillPreparing = await f.host.isPreparing
        XCTAssertTrue(stillPreparing, "a waiter's deadline must not cancel the shared preparation")

        gate.open()
        await eventually { await f.host.isResident }
        let late = try await f.host.clean("now it works", budget: budget(5))
        XCTAssertEqual(late.kind, .cleaned)
        XCTAssertEqual(model.opens, 1)
    }

    func testCancellingAPreparationWaiterDoesNotCancelSharedPreparation() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)

        let waiter = Task { try await f.host.clean("cancel me", budget: CleanupBudget(seconds: 30)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        let cancelledAt = Date()
        waiter.cancel()
        do {
            _ = try await waiter.value
            XCTFail("a cancelled waiter must throw, not return a raw fallback")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1, "cancellation stops the wait promptly")
        let preparing = await f.host.isPreparing
        XCTAssertTrue(preparing)

        gate.open()
        let other = try await f.host.clean("another utterance", budget: budget(5))
        XCTAssertEqual(other.kind, .cleaned)
        XCTAssertEqual(model.opens, 1)
    }

    // MARK: - Utterance sessions and delivery

    @MainActor
    func testSupersededUtteranceNeverInsertsItsLateResult() async throws {
        let model = FakeModel()
        let latch = AsyncLatch()
        model.generateMode = .cooperative(latch)
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }

        let sessions = UtteranceSessions()
        let first = sessions.begin()
        let pending = Task { try await f.host.clean("first dictation", budget: CleanupBudget(seconds: 5)) }
        await eventually { model.requests.count == 1 }
        let second = sessions.begin()  // supersedes `first`
        latch.open()
        let outcome = try await pending.value

        var inserted: [String] = []
        let stale = deliverUtterance(outcome.text, id: first, sessions: sessions,
                                     spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                                     insert: { inserted.append($0) })
        XCTAssertEqual(stale, .suppressed)
        XCTAssertTrue(inserted.isEmpty)

        let fresh = deliverUtterance("second dictation", id: second, sessions: sessions,
                                     spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                                     insert: { inserted.append($0) })
        XCTAssertEqual(fresh, .inserted("second dictation"))
        XCTAssertEqual(inserted, ["second dictation"])
    }

    func testCancellationBeforeInferenceSendsNothing() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.host.clean("never sent", budget: CleanupBudget(seconds: 5))
        }
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        XCTAssertTrue(f.model.requests.isEmpty)
    }

    func testCancellationDuringInferenceThrowsAndReachesTheWorker() async throws {
        let model = FakeModel()
        let latch = AsyncLatch()
        model.generateMode = .cooperative(latch)
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }

        let task = Task { try await f.host.clean("in flight", budget: CleanupBudget(seconds: 5)) }
        await eventually { model.requests.count == 1 }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        await eventually { model.cancelledGenerations == 1 }
        // The cooperative worker returned, so the cleaner is usable again.
        await eventually { await f.host.availability == .ready }
        model.generateMode = .immediate
        let next = try await f.host.clean("next one", budget: budget(5))
        XCTAssertEqual(next.kind, .cleaned)
    }

    @MainActor
    func testCancellationAfterInferenceSuppressesInsertion() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let sessions = UtteranceSessions()
        let id = sessions.begin()
        let paused = StuckGate()
        let host = f.host
        var inserted: [String] = []
        let task = Task { @MainActor () -> UtteranceDelivery in
            let outcome: SDKCleanupOutcome
            do { outcome = try await host.clean("finished inference", budget: CleanupBudget(seconds: 5)) }
            catch { return .suppressed }
            await paused.wait()  // result in hand; cancellation arrives now
            return deliverUtterance(outcome.text, id: id, sessions: sessions,
                                    spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                                    insert: { inserted.append($0) })
        }
        await eventually { f.model.requests.count == 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        paused.open()
        let delivery = await task.value
        XCTAssertEqual(delivery, .suppressed)
        XCTAssertTrue(inserted.isEmpty, "a cancelled utterance is never converted into an insertion")
    }

    @MainActor
    func testHostTransformsRunOnceInOrderBeforeInsertion() {
        let sessions = UtteranceSessions()
        let id = sessions.begin()
        var calls: [String] = []
        var inserted: [String] = []
        let result = deliverUtterance(
            "cleaned", id: id, sessions: sessions,
            spokenFormatting: { calls.append("spoken"); return $0 + "+spoken" },
            dictionary: { calls.append("dictionary"); return $0 + "+dict" },
            signature: { calls.append("signature"); return $0 + "+sig" },
            insert: { calls.append("insert"); inserted.append($0) })
        XCTAssertEqual(calls, ["spoken", "dictionary", "signature", "insert"])
        XCTAssertEqual(inserted, ["cleaned+spoken+dict+sig"])
        XCTAssertEqual(result, .inserted("cleaned+spoken+dict+sig"))
    }

    @MainActor
    func testTransformThatRetiresTheSessionSynchronouslyPreventsInsertion() {
        let sessions = UtteranceSessions()
        let id = sessions.begin()
        var inserted = false
        let result = deliverUtterance(
            "text", id: id, sessions: sessions,
            spokenFormatting: { $0 },
            dictionary: { text in sessions.retire(); return text },  // no await involved
            signature: { $0 },
            insert: { _ in inserted = true })
        XCTAssertEqual(result, .suppressed)
        XCTAssertFalse(inserted)
    }

    func testCleanedResultIsTheSDKTextWithNoSecondGuardPass() async throws {
        let model = FakeModel()
        // A candidate the SDK accepts; the host must use it verbatim.
        model.respond = { _ in RuntimeOutput(candidate: "Ship it, then test it.") }
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        let outcome = try await f.host.clean("ship it then test it", budget: budget(5))
        XCTAssertEqual(outcome.kind, .cleaned)
        XCTAssertEqual(outcome.text, outcome.result?.text)
        XCTAssertEqual(outcome.original, "ship it then test it")
    }

    // MARK: - Vocabulary

    func testEveryRequestCarriesTheSelectedVocabularyAndDictionaryChangesDoNotReopen() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: vocab(["Pomvox", "Qwen"]))
        _ = try await f.host.clean("first", budget: budget(5))
        await f.host.setVocabulary(vocab(["Pomvox", "Qwen", "Parakeet"]))
        _ = try await f.host.clean("second", budget: budget(5))

        XCTAssertEqual(f.model.factoryVocabularies, [["Pomvox", "Qwen"]], "the factory only pre-warms")
        XCTAssertEqual(f.model.requests.map(\.vocabulary), [["Pomvox", "Qwen"], ["Pomvox", "Qwen", "Parakeet"]])
        XCTAssertEqual(f.model.opens, 1, "a dictionary change replaces the prefix on the next request, no reopen")
    }

    func testReopenPreservesTheCurrentSelectedVocabulary() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: vocab(["One"]))
        await eventually { await f.host.isResident }
        await f.host.setVocabulary(vocab(["One", "Two"]))
        await f.host.evict(.idle)
        await f.host.requestPreparation()
        await eventually { await f.host.isResident }
        XCTAssertEqual(f.model.factoryVocabularies.last, ["One", "Two"])
    }

    func testVocabularySelectionIsBoundedStableAndCountsOmissions() {
        var words = (1...70).map { "term\($0)" }
        words.insert("", at: 3)
        words.insert("line\nbreak", at: 5)
        words.insert(String(repeating: "x", count: 129), at: 7)
        words.insert("term1", at: 9)
        let selection = SDKVocabulary.select(from: words)

        XCTAssertEqual(selection.terms.count, 64)
        XCTAssertEqual(selection.terms.first, "term1")
        XCTAssertEqual(selection.terms.last, "term64")
        XCTAssertEqual(selection.omitted.empty, 1)
        XCTAssertEqual(selection.omitted.lineBreak, 1)
        XCTAssertEqual(selection.omitted.tooLong, 1)
        XCTAssertEqual(selection.omitted.duplicate, 1)
        XCTAssertEqual(selection.omitted.overCount, 6)
        XCTAssertEqual(SDKVocabulary.select(from: words).terms, selection.terms, "deterministic")
        // Accepted by the SDK's own validator.
        XCTAssertNoThrow(try CleanupCore.CleanupRequest("x", vocabulary: selection.terms).validate())
        let summary = selection.omissionSummary ?? ""
        XCTAssertFalse(summary.contains("xxxx") || summary.contains("line\nbreak") || summary.contains("term65"),
                       "counts only, never the words")
    }

    func testVocabularyTotalByteLimitKeepsAStablePrefix() {
        let words = (0..<40).map { String(format: "%02d", $0) + String(repeating: "w", count: 98) }  // 100 bytes each
        let selection = SDKVocabulary.select(from: words)
        XCTAssertEqual(selection.terms.count, 20)
        XCTAssertEqual(selection.terms, Array(words.prefix(20)))
        XCTAssertEqual(selection.omitted.overTotalBytes, 20)
        XCTAssertLessThanOrEqual(selection.terms.reduce(0) { $0 + $1.utf8.count }, 2_048)
    }

    func testInvalidVocabularyNeverReachesTheSDK() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: vocab(["ok", "bad\u{2028}separator", String(repeating: "é", count: 70)]))
        let outcome = try await f.host.clean("hello", budget: budget(5))
        XCTAssertEqual(outcome.kind, .cleaned, "an over-limit term is omitted, not a failed request")
        XCTAssertEqual(f.model.requests.first?.vocabulary, ["ok"])
    }

    func testComposedAndDecomposedDictionaryChangesAreDistinctBytes() async throws {
        let composed = "Caf\u{00E9}"
        let decomposed = "Cafe\u{0301}"
        XCTAssertEqual(composed, decomposed, "Swift String equality is canonical — why identity uses bytes")
        let both = SDKVocabulary.select(from: [composed, decomposed])
        XCTAssertEqual(both.terms.count, 2, "deduplication is by exact UTF-8, not canonical equality")
        XCTAssertNotEqual(SDKVocabulary.select(from: [composed]).identity,
                          SDKVocabulary.select(from: [decomposed]).identity)

        let f = try fixture()
        await f.host.enable(vocabulary: vocab([composed]))
        _ = try await f.host.clean("first", budget: budget(5))
        await f.host.setVocabulary(vocab([decomposed]))
        _ = try await f.host.clean("second", budget: budget(5))
        let sent = f.model.requests.map { $0.vocabulary.map { Array($0.utf8) } }
        XCTAssertEqual(sent, [[Array(composed.utf8)], [Array(decomposed.utf8)]])
        XCTAssertEqual(f.model.opens, 1)
    }

    // MARK: - Fallbacks and diagnostics

    func testRejectedCandidatePreservesTheOriginalAndItsDiagnostics() async throws {
        let model = FakeModel()
        model.respond = { _ in
            var timings = CleanupCore.CleanupTimings()
            timings.inferenceMS = 5
            return RuntimeOutput(candidate: "No.", timings: timings)
        }
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        let raw = "so the quarterly numbers look fine but cafe\u{0301} revenue dipped  "
        let outcome = try await f.host.clean(raw, budget: budget(5))

        XCTAssertEqual(outcome.kind, .fallback(.rejected))
        XCTAssertEqual(Array(outcome.text.utf8), Array(raw.utf8), "byte-exact original")
        XCTAssertEqual(outcome.appStatus.rawValue, "rejected")
        XCTAssertTrue(outcome.warnings.contains { $0.hasPrefix("rejectedBy:") })
        let keys = outcome.timingNotes().map(\.0)
        XCTAssertTrue(keys.contains("sdk_fallback_rejected"))
        XCTAssertTrue(keys.contains { $0.hasPrefix("sdk_rejected_") })
        XCTAssertTrue(keys.contains("cleanup_decode_ms"), "observed timings survive a rejection")
        XCTAssertFalse(keys.contains("cleanup_cached"), "unobserved cache use is unknown, not zero")
    }

    func testMetricsRecordOnlyWhatWasObserved() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let outcome = try await f.host.clean("measure me", budget: budget(5))
        let notes = Dictionary(outcome.timingNotes(), uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(notes["cleanup_cached"], 1)
        XCTAssertEqual(notes["cleanup_prompt_tokens"], 40)
        XCTAssertEqual(notes["cleanup_spec_acceptance"], 0.5)
        XCTAssertNotNil(notes["sdk_total_ms"])
        XCTAssertNil(notes["sdk_preparation_wait_ms"], "this dictation did not wait for preparation")

        let model = FakeModel()
        model.respond = { request in
            var timings = CleanupCore.CleanupTimings()
            timings.speculativeDrafted = 0
            timings.speculativeAccepted = 0
            return RuntimeOutput(candidate: FakeModel.polish(request.text), timings: timings)
        }
        let g = try fixture(model: model)
        await g.host.enable(vocabulary: .empty)
        let plain = try await g.host.clean("no drafts", budget: budget(5))
        let keys = plain.timingNotes().map(\.0)
        XCTAssertFalse(keys.contains("cleanup_spec_acceptance"), "no acceptance ratio without drafted tokens")
        XCTAssertFalse(keys.contains("cleanup_prefill_ms"))
    }

    func testEditorRangesUseTheSDKsUTF16ConversionAgainstTheOriginal() async throws {
        let model = FakeModel()
        model.respond = { _ in RuntimeOutput(candidate: "👋 Hello there.") }
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        let outcome = try await f.host.clean("👋 hello there", budget: budget(5))
        XCTAssertEqual(outcome.kind, .cleaned)
        let ranges = try outcome.editorRanges()
        XCTAssertFalse(ranges.isEmpty)
        let ns = outcome.original as NSString
        var rebuilt = outcome.original
        for (edit, range) in zip(outcome.result!.edits, ranges).reversed() {
            rebuilt = (rebuilt as NSString).replacingCharacters(in: range, with: edit.replacement)
        }
        XCTAssertEqual(rebuilt, outcome.text)
        XCTAssertLessThanOrEqual(ranges.last!.upperBound, ns.length)
    }

    // MARK: - Budgets and input limits

    func testRequestsGetTheRemainingBudgetNeverExtendedAndCappedAtSixtySeconds() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let long = String(repeating: "the quick brown fox jumps over the lazy dog ", count: 70)  // ~3,000 chars
        _ = try await f.host.clean(long, budget: budget(0.5))
        _ = try await f.host.clean("short", budget: budget(120))
        let deadlines = f.model.requests.map { $0.deadline }
        XCTAssertLessThanOrEqual(deadlines[0]!, .milliseconds(500), "a long transcript never extends the budget")
        XCTAssertGreaterThan(deadlines[0]!, .zero)
        XCTAssertEqual(deadlines[1], .seconds(60))
    }

    func testExhaustedBudgetSkipsTheRequest() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let outcome = try await f.host.clean("too late", budget: CleanupBudget(deadline: .now))
        XCTAssertEqual(outcome.kind, .fallback(.budgetExhausted))
        XCTAssertEqual(outcome.text, "too late")
        XCTAssertTrue(f.model.requests.isEmpty, "no zero or negative deadline is ever submitted")
        XCTAssertNil(CleanupBudget(seconds: 0).requestDeadline())
        XCTAssertNil(CleanupBudget(seconds: -3).requestDeadline())
    }

    func testOverLimitTranscriptIsPreservedWholeWithoutCallingTheSDK() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let raw = String(repeating: "é", count: 8_193)  // 8,193 characters, 16,386 bytes
        XCTAssertGreaterThan(raw.utf8.count, 16_384)
        let outcome = try await f.host.clean(raw, budget: budget(30))
        XCTAssertEqual(outcome.kind, .fallback(.unsupportedLength))
        XCTAssertEqual(outcome.text, raw)
        XCTAssertTrue(f.model.requests.isEmpty, "no truncation, no chunking")
    }

    func testHostCeilingFallsBackBeforeAnyWork() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let raw = String(repeating: "word ", count: 3_000)
        XCTAssertTrue(CleanupDeadline.isHopeless(base: 5, chars: raw.count))
        let outcome = try await runSDKCleanup(f.host, raw: raw, baseTimeoutS: 5, reopenPermitted: true)
        XCTAssertEqual(outcome.kind, .fallback(.longDictation), "the long-dictation limit is checked first")
        XCTAssertEqual(outcome.text, raw)
        XCTAssertTrue(f.model.requests.isEmpty)
    }

    func testLongDictationLimitPastesTheOriginalAndSendsNothing() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let atLimit = String(repeating: "a", count: SDKCleanupPolicy.maxCleanedBytes - 1) + " "
        let within = try await runSDKCleanup(f.host, raw: atLimit, baseTimeoutS: 30, reopenPermitted: true)
        XCTAssertNotEqual(within.kind, .fallback(.longDictation))
        XCTAssertEqual(f.model.requests.count, 1)

        let over = "caf\u{00E9} " + String(repeating: "b", count: SDKCleanupPolicy.maxCleanedBytes - 5)
        XCTAssertEqual(over.utf8.count, SDKCleanupPolicy.maxCleanedBytes + 1, "bytes, not characters")
        let outcome = try await runSDKCleanup(f.host, raw: over, baseTimeoutS: 30, reopenPermitted: true)
        XCTAssertEqual(outcome.kind, .fallback(.longDictation))
        XCTAssertEqual(Array(outcome.text.utf8), Array(over.utf8))
        XCTAssertEqual(outcome.appStatus.rawValue, "timeout")
        XCTAssertEqual(f.model.requests.count, 1, "nothing sent for the over-limit dictation")
    }

    // MARK: - Timeout, quarantine, recovery

    func testTimeoutQuarantineAndRecoveryNeverOpenASecondModel() async throws {
        let model = FakeModel()
        let stuck = StuckGate()
        model.generateMode = .stuck(stuck)
        let f = try fixture(model: model, grace: .milliseconds(150))
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }

        let timedOut = try await f.host.clean("stuck worker", budget: budget(0.3))
        XCTAssertEqual(timedOut.kind, .fallback(.timedOut))
        XCTAssertEqual(timedOut.text, "stuck worker")
        let state = await f.host.availability
        XCTAssertEqual(state, .quarantined)

        let waited = try await f.host.clean("while quarantined", budget: budget(3))
        XCTAssertEqual(waited.kind, .fallback(.quarantined))
        XCTAssertEqual(model.requests.count, 1, "no request is admitted behind a quarantined worker")
        XCTAssertEqual(model.openAttempts, 1, "quarantine is never bypassed with a second model")

        stuck.open()
        await eventually { await f.host.availability == .ready }
        model.generateMode = .immediate
        let recovered = try await f.host.clean("recovered", budget: budget(3))
        XCTAssertEqual(recovered.kind, .cleaned)
        XCTAssertEqual(model.maxResident, 1)
    }

    func testQuarantineThatClearsWithinTheGraceGetsOneAttempt() async throws {
        let model = FakeModel()
        let stuck = StuckGate()
        model.generateMode = .stuck(stuck)
        let f = try fixture(model: model, grace: .seconds(2))
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        _ = try await f.host.clean("stuck", budget: budget(0.2))
        Task {
            try await Task.sleep(nanoseconds: 150_000_000)
            model.generateMode = .immediate
            stuck.open()
        }
        let outcome = try await f.host.clean("after recovery", budget: budget(3))
        XCTAssertEqual(outcome.kind, .cleaned)
        XCTAssertEqual(model.openAttempts, 1)
    }

    // MARK: - Eviction, close and reopen

    func testMemoryPressureEvictionClosesStaysEvictedAndReopensWithTheSavedHandle() async throws {
        let model = FakeModel()
        let latch = AsyncLatch()
        model.generateMode = .cooperative(latch)
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }

        let inFlight = Task { try await f.host.clean("in flight during pressure", budget: CleanupBudget(seconds: 5)) }
        await eventually { model.requests.count == 1 }
        let evicted = await f.host.evict(.memoryPressure)
        XCTAssertTrue(evicted)
        let interrupted = try await inFlight.value
        XCTAssertEqual(interrupted.kind, .fallback(.unavailable))
        XCTAssertEqual(interrupted.text, "in flight during pressure")
        let released = try await f.host.awaitRetirement(until: .now.advanced(by: .seconds(5)))
        XCTAssertTrue(released)
        XCTAssertEqual(model.resident, 0)

        // Stays evicted: no reopen in response to the eviction itself.
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.openAttempts, 1)
        let refused = try await f.host.clean("policy says no", budget: budget(1), unprepared: .memoryPolicy)
        XCTAssertEqual(refused.kind, .fallback(.memoryPolicy))

        model.generateMode = .immediate
        await f.host.requestPreparation(reopenPermitted: true)
        let reopened = try await f.host.clean("back again", budget: budget(5))
        XCTAssertEqual(reopened.kind, .cleaned)
        let prep = await f.host.lastPreparation
        XCTAssertEqual(prep?.kind, .reopened)
        XCTAssertEqual(f.acquisitions.count, 1, "no reinstall")
        XCTAssertEqual(model.maxResident, 1)
    }

    func testOverlappingEvictionsCoalesceAndIdleEvictionWaitsForInFlightWork() async throws {
        let model = FakeModel()
        let latch = AsyncLatch()
        model.generateMode = .cooperative(latch)
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }

        let inFlight = Task { try await f.host.clean("busy", budget: CleanupBudget(seconds: 5)) }
        await eventually { model.requests.count == 1 }
        let idle = await f.host.evict(.idle)
        XCTAssertFalse(idle, "idle eviction never interrupts a dictation")
        latch.open()
        _ = try await inFlight.value

        let first = await f.host.evict(.memoryPressure)
        let second = await f.host.evict(.memoryPressure)
        XCTAssertTrue(first)
        XCTAssertFalse(second)
        _ = try await f.host.awaitRetirement(until: .now.advanced(by: .seconds(5)))
        XCTAssertEqual(model.closes, 1)
    }

    func testCancelledRetirementWaitLeavesTheRetiringCleanerTrackedForTheNextOpener() async throws {
        let model = FakeModel()
        let closeGate = StuckGate()
        model.closeGate = closeGate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        await f.host.evict(.memoryPressure)

        let waiter = Task { try await f.host.awaitRetirement() }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let retiring = await f.host.isRetiring
        XCTAssertTrue(retiring, "cancelling the wait does not release the worker")

        await f.host.requestPreparation()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(model.openAttempts, 1, "the opener waits for the retiring cleaner")
        closeGate.open()
        await eventually { await f.host.isResident }
        XCTAssertEqual(model.opens, 2)
        XCTAssertEqual(model.maxResident, 1)
    }

    func testBufferPoolIsReleasedOnlyAfterTheCleanerActuallyReleasesAndNotBeforeAReopen() async throws {
        let model = FakeModel()
        let closeGate = StuckGate()
        model.closeGate = closeGate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        await f.host.evict(.memoryPressure)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(f.releases.count, 0, "not while the worker still holds its resources")
        closeGate.open()
        _ = try await f.host.awaitRetirement(until: .now.advanced(by: .seconds(5)))
        XCTAssertEqual(f.releases.count, 1)

        // A reopen already waiting on the retirement skips the clear: the
        // buffers are about to be reused by the next model.
        model.closeGate = StuckGate()
        let secondGate = model.closeGate!
        await f.host.requestPreparation()
        await eventually { await f.host.isResident }
        await f.host.evict(.idle)
        await f.host.requestPreparation()
        secondGate.open()
        await eventually { await f.host.isResident }
        XCTAssertEqual(f.releases.count, 1)
    }

    func testChangedInstalledFilesForceFullValidationAndRefuseAlteredWeights() async throws {
        let f = try fixture()
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        await f.host.evict(.idle)
        _ = try await f.host.awaitRetirement(until: .now.advanced(by: .seconds(5)))

        // Same bytes, new identity (touched): full revalidation succeeds.
        let weights = f.provisioner.destination.appendingPathComponent("model.safetensors")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-60)],
                                              ofItemAtPath: weights.path)
        await f.host.requestPreparation()
        await eventually { await f.host.isResident }
        let touched = await f.host.lastPreparation
        XCTAssertEqual(touched?.kind, .revalidated)

        // Altered bytes: refused as a configuration failure; no model opened.
        await f.host.evict(.idle)
        _ = try await f.host.awaitRetirement(until: .now.advanced(by: .seconds(5)))
        var bytes = try Data(contentsOf: weights)
        bytes[0] ^= 0xFF
        try bytes.write(to: weights)
        let opensBefore = f.model.opens
        await f.host.requestPreparation()
        let outcome = try await f.host.clean("after tampering", budget: budget(5))
        guard case .configurationFailure = outcome.kind else {
            return XCTFail("expected a configuration failure, got \(outcome.kind)")
        }
        XCTAssertEqual(outcome.text, "after tampering")
        XCTAssertEqual(outcome.appStatus.rawValue, "error")
        XCTAssertEqual(f.model.opens, opensBefore)
    }

    @MainActor
    func testSleepCancelsTheInFlightUtteranceAndWakeReusesTheCleaner() async throws {
        let model = FakeModel()
        let latch = AsyncLatch()
        model.generateMode = .cooperative(latch)
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { await f.host.isResident }
        let sessions = UtteranceSessions()
        let host = f.host
        var inserted: [String] = []

        let id = sessions.begin()
        let utterance = Task { @MainActor () -> UtteranceDelivery in
            guard let outcome = try? await host.clean("dictated before sleep", budget: CleanupBudget(seconds: 5))
            else { return .suppressed }
            return deliverUtterance(outcome.text, id: id, sessions: sessions,
                                    spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                                    insert: { inserted.append($0) })
        }
        await eventually { model.requests.count == 1 }
        // willSleep → panicReset → cancelUtterance.
        sessions.retire()
        utterance.cancel()
        let delivery = await utterance.value
        XCTAssertEqual(delivery, .suppressed)
        XCTAssertTrue(inserted.isEmpty)

        // didWake: the cleaner is still resident; a new utterance works.
        model.generateMode = .immediate
        await eventually { await f.host.availability == .ready }
        let next = sessions.begin()
        let outcome = try await f.host.clean("after wake", budget: budget(5))
        let result = deliverUtterance(outcome.text, id: next, sessions: sessions,
                                      spokenFormatting: { $0 }, dictionary: { $0 }, signature: { $0 },
                                      insert: { inserted.append($0) })
        XCTAssertEqual(result, .inserted("After wake."))
        XCTAssertEqual(model.opens, 1)
    }

    func testDisablingDuringOpenClosesTheLateCleanerInsteadOfPublishingIt() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { model.openAttempts == 1 }
        await f.host.disable()
        gate.open()
        await eventually { model.closes == 1 }
        let resident = await f.host.isResident
        XCTAssertFalse(resident)
        XCTAssertEqual(model.resident, 0)
        let outcome = try await f.host.clean("after disable", budget: budget(1))
        XCTAssertEqual(outcome.kind, .fallback(.notPrepared))
    }

    func testReenablingWhileARetiredOpenIsStillLoadingNeverHoldsTwoModels() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { model.openAttempts == 1 }
        await f.host.disable()
        await f.host.enable(vocabulary: .empty)  // the new preparation waits for the old one
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(model.openAttempts, 1)
        gate.open()
        let outcome = try await f.host.clean("second arm", budget: budget(5))
        XCTAssertEqual(outcome.kind, .cleaned)
        XCTAssertEqual(model.maxResident, 1)
        XCTAssertEqual(model.resident, 1)
    }

    func testRetiringTheBackendWhileADictationWaitsNeverInsertsACleanedResult() async throws {
        let model = FakeModel()
        let gate = StuckGate()
        model.openGate = gate
        let f = try fixture(model: model)
        await f.host.enable(vocabulary: .empty)
        await eventually { model.openAttempts == 1 }
        let waiting = Task { try await f.host.clean("waiting on open", budget: CleanupBudget(seconds: 5)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        await f.host.disable()
        gate.open()
        let outcome = try await waiting.value
        XCTAssertNotEqual(outcome.kind, .cleaned)
        XCTAssertEqual(outcome.text, "waiting on open")
    }

    // MARK: - Installation

    func testProvisioningInstallsRegularFilesFromASymlinkedSnapshotAndIgnoresItsManifest() async throws {
        let planted = Data(#"{"id":"evil"}"#.utf8)
        let f = try fixture(snapshotManifest: planted)
        let provisioned = try await f.provisioner.provision(onProgress: nil)
        guard case .installed(let pack) = provisioned else { return XCTFail("expected a fresh install") }
        XCTAssertEqual(pack.digest, f.provisioner.trustedDigest)
        let destination = f.provisioner.destination
        for name in FakePack.files.keys {
            let values = try destination.appendingPathComponent(name)
                .resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true, name)
            XCTAssertEqual(values.isSymbolicLink, false, name)
        }
        let installedManifest = try Data(contentsOf: destination.appendingPathComponent("pack.json"))
        XCTAssertEqual(installedManifest, f.provisioner.manifestData, "trust never comes from the snapshot")

        let again = try await f.provisioner.provision(onProgress: nil)
        guard case .existing(let url) = again else { return XCTFail("expected reuse") }
        XCTAssertEqual(url, destination)
        XCTAssertEqual(f.acquisitions.count, 1, "an existing installation is reused, not reacquired")
    }

    func testAnExistingInstallationWithADifferentManifestIsRefusedAndLeftUntouched() async throws {
        let f = try fixture()
        let destination = f.provisioner.destination
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let foreign = FakePack.manifest(version: "9.9.9")
        try foreign.write(to: destination.appendingPathComponent("pack.json"))
        do {
            _ = try await f.provisioner.provision(onProgress: nil)
            XCTFail("expected refusal")
        } catch let error as SDKPackError {
            guard case .existingInstallationDiffers = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("pack.json")), foreign)
        XCTAssertEqual(f.acquisitions.count, 0)

        await f.host.enable(vocabulary: .empty)
        let outcome = try await f.host.clean("hello", budget: budget(3))
        guard case .configurationFailure = outcome.kind else {
            return XCTFail("setup errors are surfaced as configuration failures, got \(outcome.kind)")
        }
    }

    func testAManifestThatDoesNotMatchItsPinIsNotTrusted() {
        XCTAssertThrowsError(try SDKPackProvisioner(
            manifestData: FakePack.manifest(), pinnedSHA256: String(repeating: "0", count: 64),
            root: FileManager.default.temporaryDirectory) { _, _ in URL(fileURLWithPath: "/nonexistent") }
        ) { XCTAssertEqual($0 as? SDKPackError, .manifestNotTrusted) }
    }

    func testTheBundledManifestMatchesItsPin() throws {
        let bundle = Bundle(for: NativeEngine.self)
        let provisioner = try SDKPackProvisioner.bundled(in: bundle)
        XCTAssertEqual(provisioner.trustedDigest, SDKPackProvisioner.bundledManifestSHA256)
        XCTAssertEqual(provisioner.trustedManifest.capabilities, ["vocabulary"])
        XCTAssertEqual(provisioner.trustedManifest.modelID, CleanupBackendKind.sdkModelID)
        XCTAssertEqual(provisioner.trustedManifest.rules, [SDKCleanupHost.rulesVersion])
        XCTAssertTrue(provisioner.destination.path.contains("Application Support/Pomvox/CleanupPacks"))
    }

    // MARK: - Controls and policy

    func testSDKBackendHidesControlsItCannotHonour() {
        let sdk = CleanupControls.forBackend(.sdk, capabilities: ["vocabulary"])
        XCTAssertFalse(sdk.style)
        XCTAssertFalse(sdk.speculativeToggle)
        XCTAssertFalse(sdk.modelVariantSuggestions)
        let inapp = CleanupControls.forBackend(.inapp, capabilities: [])
        XCTAssertTrue(inapp.style && inapp.speculativeToggle && inapp.modelVariantSuggestions)
        XCTAssertEqual(CleanupBackendKind.parse("INAPP"), .inapp)
        XCTAssertEqual(CleanupBackendKind.parse("typo"), .sdk)
        // No explicit backend: the SDK only for the model its pack serves.
        XCTAssertEqual(CleanupBackendKind.resolve(configured: nil, modelID: MemoryTier.standardCleanupModel), .sdk)
        XCTAssertEqual(CleanupBackendKind.resolve(configured: nil, modelID: MemoryTier.compactCleanupModel), .inapp)
        XCTAssertEqual(CleanupBackendKind.resolve(configured: "", modelID: "mlx-community/Qwen3-8B-4bit"), .inapp)
        XCTAssertEqual(CleanupBackendKind.resolve(configured: "sdk", modelID: MemoryTier.compactCleanupModel), .sdk)
        XCTAssertEqual(CleanupBackendKind.resolve(configured: "inapp", modelID: MemoryTier.standardCleanupModel), .inapp)
        // Hot-applied like the rest of [cleanup] (NativeEngine.switchCleanupBackend).
        XCTAssertFalse(SettingsSchema.isRestartRequired("cleanup", "backend"))
    }

    func testMemoryPolicyWaitsForNormalPressureOrTheCoolDown() {
        var policy = CleanupMemoryPolicy()
        XCTAssertTrue(policy.permitsReopen(at: 0))
        policy.record(.warning, at: 100)
        XCTAssertFalse(policy.permitsReopen(at: 101), "the same pressure event never reopens")
        XCTAssertTrue(policy.permitsReopen(at: 100 + CleanupMemoryPolicy.coolDownS))
        policy.record(.critical, at: 200)
        XCTAssertFalse(policy.permitsReopen(at: 201))
        policy.record(.normal, at: 202)
        XCTAssertTrue(policy.permitsReopen(at: 203))
    }

    func testFallbackStatusMappingForHistoryAndTelemetry() {
        func status(_ reason: SDKFallbackReason) -> String { SDKCleanupOutcome.fallback("x", reason).appStatus.rawValue }
        XCTAssertEqual(status(.timedOut), "timeout")
        XCTAssertEqual(status(.preparationTimedOut), "timeout")
        XCTAssertEqual(status(.rejected), "rejected")
        XCTAssertEqual(status(.memoryPolicy), "timeout")
        XCTAssertEqual(status(.quarantined), "error")
        XCTAssertEqual(status(.unsupportedLength), "error")
        XCTAssertEqual(SDKCleanupOutcome.fallback("x", .quarantined).timingNotes().first?.0, "sdk_fallback_quarantined")
    }
}
