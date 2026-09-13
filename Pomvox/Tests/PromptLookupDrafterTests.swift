import XCTest

@testable import Pomvox

/// The drafter is a table lookup; these pin the lookup rules the decoder
/// relies on. Token ids are arbitrary small ints — the drafter never
/// interprets them.
final class PromptLookupDrafterTests: XCTestCase {

    func testNothingGeneratedYetMeansNoDraft() {
        let d = PromptLookupDrafter()
        XCTAssertEqual(d.draft(input: [1, 2, 3, 4], generated: []), [])
    }

    func testProposesWhatFollowedTheNgramInTheInput() {
        let d = PromptLookupDrafter(ngram: 3, maxDraft: 8)
        // input: "a b c d e f g h"; generated ends with "b c d" → propose "e f g h"
        XCTAssertEqual(d.draft(input: [1, 2, 3, 4, 5, 6, 7, 8], generated: [9, 2, 3, 4]), [5, 6, 7, 8])
    }

    func testDraftIsCappedAtMaxDraft() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 3)
        XCTAssertEqual(d.draft(input: [1, 2, 3, 4, 5, 6, 7], generated: [1, 2]), [3, 4, 5])
    }

    func testFallsBackToShorterKeys() {
        let d = PromptLookupDrafter(ngram: 3, maxDraft: 4)
        // No "x y z" anywhere; "y z" not either; "z" occurs in the input → propose what followed it.
        XCTAssertEqual(d.draft(input: [7, 26, 8, 9], generated: [24, 25, 26]), [8, 9])
    }

    func testMostRecentOccurrenceWins() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 2)
        // "5 6" occurs twice in the input; the later one is followed by 30.
        XCTAssertEqual(d.draft(input: [5, 6, 10, 11, 5, 6, 30, 31], generated: [5, 6]), [30, 31])
    }

    func testGeneratedTextIsPartOfThePool() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 4)
        // The key only occurs earlier in what was generated; the tokens after
        // that earlier occurrence are the proposal.
        XCTAssertEqual(d.draft(input: [100], generated: [1, 2, 3, 4, 1, 2]), [3, 4, 1, 2])
    }

    func testTheTrailingKeyItselfNeverMatches() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 4)
        // "8 9" occurs only as the tail of the pool — nothing follows it.
        XCTAssertEqual(d.draft(input: [1, 2, 3], generated: [8, 9]), [])
    }

    func testShortGenerationUsesWhatItHas() {
        let d = PromptLookupDrafter(ngram: 3, maxDraft: 2)
        // One token generated, n-gram 3 → key is that single token.
        XCTAssertEqual(d.draft(input: [4, 5, 6], generated: [4]), [5, 6])
    }

    func testZeroMaxDraftDisablesDrafting() {
        let d = PromptLookupDrafter(ngram: 3, maxDraft: 0)
        XCTAssertEqual(d.draft(input: [1, 2, 3, 4], generated: [1, 2, 3]), [])
    }

    func testDefaultsAreTheMeasuredSweetSpot() {
        XCTAssertEqual(PromptLookupDrafter.defaultNgram, 3)
        XCTAssertEqual(PromptLookupDrafter.defaultMaxDraft, 4)
    }
}

extension PromptLookupDrafterTests {

    func testProposalNeverCrossesFromInputIntoGenerated() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 8)
        // "3 4" ends the input; only "5" follows it inside the input.
        XCTAssertEqual(d.draft(input: [1, 3, 4, 5], generated: [9, 3, 4]), [5])
        // Nothing follows "4 5" inside the input; the generated copy is the
        // trailing key. No proposal rather than the start of the answer.
        XCTAssertEqual(d.draft(input: [1, 4, 5], generated: [4, 5]), [])
    }

    func testKeyStraddlingTheSeamIsIgnored() {
        let d = PromptLookupDrafter(ngram: 2, maxDraft: 4)
        // "5 | 7" straddles the seam (input ends in 5, generated starts with 7);
        // "5 7" as a key must not match there. The only real match is in the
        // generated text.
        XCTAssertEqual(d.draft(input: [1, 5], generated: [7, 5, 7, 8, 5, 7]), [8, 5, 7])
    }
}
