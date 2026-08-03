import XCTest

@testable import Pomvox

final class CleanupPromptProfileTests: XCTestCase {

    func testSimpleWordsIDResolvesToTheFrozenProfile() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup-v2"),
            .simpleWords)
    }

    /// The shipped default. Because `frozenPromptIDs` is an exact set, a missing
    /// entry here does not fail loudly — it silently routes the fine-tune down
    /// the legacy few-shot path it was never trained on.
    func testTheV3IDResolvesToTheFrozenProfile() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup-v3"),
            .simpleWords)
    }

    /// v2 is still published and still frozen-prompted, so pinning it in
    /// `config.toml` — or rolling `standardCleanupModel` back one line — keeps
    /// working.
    func testTheSupersededV2StaysOnTheFrozenPath() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup-v2"),
            .simpleWords)
    }

    func testDetectionIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("  Abhiram3040/SimpleWords-Dictation-Cleanup-V2\n"),
            .simpleWords)
        XCTAssertEqual(
            CleanupPromptProfile.forModel("  Abhiram3040/SimpleWords-Dictation-Cleanup-V3\n"),
            .simpleWords)
    }

    func testQwenPresetsAndUnknownIDsStayLegacy() {
        for id in [
            "mlx-community/Qwen3-4B-4bit", "mlx-community/Qwen3-1.7B-4bit",
            "mlx-community/Qwen3-8B-4bit", "someone/some-other-model", "",
        ] {
            XCTAssertEqual(CleanupPromptProfile.forModel(id), .legacy, id)
        }
    }

    /// v1 is an adapter-only repo: no fused weights, no system_v2.txt. A prefix
    /// match on "simplewords-dictation-cleanup" would route it down the frozen
    /// path and fail at load, so detection must be an exact-id match.
    func testTheV1AdapterRepoIsNotTreatedAsFrozen() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel("abhiram3040/simplewords-dictation-cleanup"),
            .legacy)
    }

    func testLegacyKeepsOnePrefixPerStyle() {
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKeys, CleanupLogic.styles)
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKey(forStyle: "light"), "light")
        XCTAssertEqual(CleanupPromptProfile.legacy.prefixKey(forStyle: "polish"), "polish")
    }

    func testFrozenProfileCollapsesEveryStyleOntoOnePrefix() {
        let profile = CleanupPromptProfile.simpleWords
        XCTAssertEqual(profile.prefixKeys.count, 1)
        XCTAssertEqual(profile.prefixKey(forStyle: "light"), profile.prefixKey(forStyle: "polish"))
        XCTAssertEqual(profile.prefixKeys, [profile.prefixKey(forStyle: "polish")])
    }

    /// The few-shot prefix is worth prefilling; the fine-tune's cannot be
    /// prefilled at all (Qwen3.5 hands back a `MambaCache` for its
    /// linear-attention layers, whose offset never advances), so `prepare()`
    /// must skip the build instead of spending ~2.8 s failing it.
    func testOnlyTheLegacyProfileUsesThePrefixCache() {
        XCTAssertTrue(CleanupPromptProfile.legacy.usesPrefixCache)
        XCTAssertFalse(CleanupPromptProfile.simpleWords.usesPrefixCache)
    }

    /// Every style the UI can produce must map to a key the engine will have
    /// prefilled — otherwise clean() waits on a cache that is never built.
    func testEveryConfigurableStyleMapsIntoPrefixKeys() {
        for profile in [CleanupPromptProfile.legacy, .simpleWords] {
            for style in CleanupLogic.styles {
                XCTAssertTrue(
                    profile.prefixKeys.contains(profile.prefixKey(forStyle: style)),
                    "\(profile) style=\(style)")
            }
        }
    }
}
