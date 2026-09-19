import XCTest

@testable import Pomvox

/// Pure tests for the SDK backend's host-side decisions: which backend a config
/// selects, how the app's dictionary becomes the SDK's bounded vocabulary, and
/// where the pack comes from. Nothing here loads a model — the real-model
/// behaviour lives in `SDKBackendE2ETests` and `SDKProbeTests`.
final class SDKCleanupBackendTests: XCTestCase {

    // MARK: - Backend selection

    func testBackendDefaultsToSDKAndParsesBothValues() {
        XCTAssertEqual(CleanupBackendKind.parse(nil), .sdk)
        XCTAssertEqual(CleanupBackendKind.parse(""), .sdk)
        XCTAssertEqual(CleanupBackendKind.parse("sdk"), .sdk)
        XCTAssertEqual(CleanupBackendKind.parse("inapp"), .inapp)
        XCTAssertEqual(CleanupBackendKind.parse("INAPP"), .inapp)
        // A typo must not cost the user their cleanup: fall back, don't refuse.
        XCTAssertEqual(CleanupBackendKind.parse("sdkk"), .sdk)
        XCTAssertEqual(CleanupBackendKind.parse("python"), .sdk)
    }

    func testBackendKeyIsRestartRequired() {
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "backend"))
        XCTAssertTrue(SettingsSchema.isRestartRequired("cleanup", "pack_dir"))
    }

    // MARK: - Pack location

    func testPackDirectoryPrefersEnvironmentThenConfigThenDefault() {
        let home = NSHomeDirectory()
        XCTAssertEqual(SDKCleanupBackend.defaultPackDirectory().path,
                       home + "/.pomvox/packs/simplewords-v3")
        XCTAssertEqual(SDKCleanupBackend.defaultPackDirectory(configured: "~/elsewhere/pack").path,
                       home + "/elsewhere/pack")
        XCTAssertEqual(SDKCleanupBackend.defaultPackDirectory(configured: "/abs/pack").path, "/abs/pack")
        // An empty configured value is "unset", not "install at /".
        XCTAssertEqual(SDKCleanupBackend.defaultPackDirectory(configured: "").path,
                       home + "/.pomvox/packs/simplewords-v3")
    }

    // MARK: - Vocabulary

    func testVocabularyRoundTripsTheDictionaryHint() {
        let hint = dictionaryPromptHint(["Pomvox", "Parakeet", "MLX"])
        XCTAssertEqual(SDKCleanupBackend.vocabulary(fromHint: hint), ["Pomvox", "Parakeet", "MLX"])
    }

    func testVocabularyOfEmptyDictionaryIsEmpty() {
        XCTAssertEqual(SDKCleanupBackend.vocabulary(fromHint: dictionaryPromptHint([])), [])
        XCTAssertEqual(SDKCleanupBackend.vocabulary(fromHint: ""), [])
        // Not a hint at all (a future prompt change, a hand-edited config):
        // better an empty vocabulary than garbage terms sent to the model.
        XCTAssertEqual(SDKCleanupBackend.vocabulary(fromHint: "- Some other rule.\n"), [])
    }

    func testVocabularyKeepsUnicodeTermsIntact() {
        let hint = dictionaryPromptHint(["Zoë", "café", "北京"])
        XCTAssertEqual(SDKCleanupBackend.vocabulary(fromHint: hint), ["Zoë", "café", "北京"])
    }

    /// The SDK's `CleanupRequest.validate()` throws — costing the dictation its
    /// cleanup entirely — on more than 64 terms, a term over 128 bytes, or more
    /// than 2,048 bytes in total. The app's dictionary has no such limits, so
    /// the backend must trim rather than let a large dictionary disable cleanup.
    func testVocabularyIsBoundedToTheSDKLimits() {
        let many = (1...100).map { "Term\($0)" }
        let kept = SDKCleanupBackend.bounded(many)
        XCTAssertEqual(kept.count, 64)
        XCTAssertEqual(kept.first, "Term1", "trimming keeps the user's own order")
        XCTAssertEqual(kept.last, "Term64")

        let long = String(repeating: "a", count: 129)
        let withLong = SDKCleanupBackend.bounded(["ok", long, "fine"])
        XCTAssertEqual(withLong, ["ok", "fine"], "an over-long term is dropped, its neighbours are not")

        let heavy = (1...40).map { _ in String(repeating: "b", count: 100) }
        let boundedBytes = SDKCleanupBackend.bounded(heavy)
        XCTAssertLessThanOrEqual(boundedBytes.reduce(0) { $0 + $1.utf8.count }, 2_048)

        // A newline would make the SDK refuse the whole request; flattening the
        // term keeps the other terms usable.
        XCTAssertEqual(SDKCleanupBackend.bounded(["two\nlines"]), ["two lines"])
        XCTAssertEqual(SDKCleanupBackend.bounded(["  ", ""]), [])
    }

    func testBoundedVocabularySatisfiesTheSDKRequestLimits() {
        // The limits this mirrors, asserted directly so a change in the SDK's
        // contract fails here rather than at runtime on a user's dictation.
        let kept = SDKCleanupBackend.bounded((1...200).map { "Term\($0)" })
        XCTAssertLessThanOrEqual(kept.count, 64)
        XCTAssertTrue(kept.allSatisfy { $0.utf8.count <= 128 })
        XCTAssertTrue(kept.allSatisfy { !$0.contains(where: \.isNewline) })
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.utf8.count }, 2_048)
    }

    // MARK: - Deadline

    func testDeadlineCeilingMatchesTheSDKLimit() {
        // The SDK rejects any deadline over 60 s outright; the app's widened
        // budget for a very long dictation can exceed it.
        XCTAssertEqual(SDKCleanupBackend.maxDeadlineS, 60.0)
        XCTAssertEqual(CleanupDeadline.ceilingS, SDKCleanupBackend.maxDeadlineS,
                       "the app's own ceiling and the SDK's limit must agree")
    }

    // MARK: - Failure mapping

    func testRejectedBackendFailureBecomesRejectedStatus() async {
        let (text, status) = await runCleanup(
            ThrowingCleaner(error: CleanupBackendFailure.rejected),
            text: "um hello there", style: "polish", timeoutS: 5)
        XCTAssertEqual(text, "um hello there", "a rejection pastes the raw transcript")
        XCTAssertEqual(status, .rejected)
    }

    func testOtherBackendFailuresBecomeErrorStatus() async {
        for failure: CleanupBackendFailure in [.busy, .unavailable, .tokenLimit, .other("nope")] {
            let (text, status) = await runCleanup(
                ThrowingCleaner(error: failure), text: "um hello there", style: "polish", timeoutS: 5)
            XCTAssertEqual(text, "um hello there")
            XCTAssertEqual(status, .error, "\(failure) should read as an engine error")
        }
    }

    func testNilCandidateStillMeansTimeout() async {
        let (text, status) = await runCleanup(
            NilCleaner(), text: "um hello there", style: "polish", timeoutS: 5)
        XCTAssertEqual(text, "um hello there")
        XCTAssertEqual(status, .timeout)
    }
}

private struct ThrowingCleaner: CleanupCleaning {
    let error: any Error
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? { throw error }
}

private struct NilCleaner: CleanupCleaning {
    func clean(_ text: String, style: String, timeoutS: Double) async throws -> String? { nil }
}
