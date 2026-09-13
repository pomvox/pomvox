import XCTest

@testable import Pomvox

/// The pass-length policy is one number read off the measured cost curve;
/// this pins it so a "tuning" edit that quietly drafts 6–8 tokens (the worst
/// point on the curve, ~2.5× the cost of 5) fails a test.
final class SpeculativeDecoderPolicyTests: XCTestCase {

    func testPassCarriesAtMostFiveTokens() {
        let p = SpeculativeDecoder.DraftPolicy()
        XCTAssertEqual(p.passLength, 5)
        XCTAssertEqual(p.draftRoom(pending: 1), 4)
        XCTAssertEqual(p.draftRoom(pending: 5), 0, "a full backlog is absorbed draft-free")
        XCTAssertEqual(p.draftRoom(pending: 9), 0, "never negative")
    }

    func testTheDrafterAndThePolicyAgree() {
        XCTAssertEqual(
            PromptLookupDrafter.defaultMaxDraft + 1, SpeculativeDecoder.DraftPolicy().passLength,
            "one pending token plus the default draft must exactly fill the cheap pass")
    }
}
