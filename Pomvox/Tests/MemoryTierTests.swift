import XCTest
@testable import Pomvox

/// Memory-aware first-run defaults: the low-memory tier boundary and the
/// cleanup-default decision, which must never override an existing config.
final class MemoryTierTests: XCTestCase {
    private static let gb: UInt64 = 1024 * 1024 * 1024

    func testEightGBIsLowMemory() {
        XCTAssertTrue(MemoryTier.isLowMemory(8 * Self.gb))
    }

    func testSixteenGBIsNotLowMemory() {
        XCTAssertFalse(MemoryTier.isLowMemory(16 * Self.gb))
    }

    func testBoundaryAllowsSlightlyUnderEightGB() {
        // Some 8 GB machines report marginally under 8 × 1024³.
        XCTAssertTrue(MemoryTier.isLowMemory(8 * Self.gb - 100 * 1024 * 1024))
        XCTAssertTrue(MemoryTier.isLowMemory(MemoryTier.lowMemoryMaxBytes))
        XCTAssertFalse(MemoryTier.isLowMemory(MemoryTier.lowMemoryMaxBytes + 1))
    }

    func testAmpleMemoryAlwaysDefaultsCleanupOn() {
        // 16 GB+ is unaffected by the prompt state.
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(isLowMemory: false, lowMemPrompted: false))
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(isLowMemory: false, lowMemPrompted: true))
    }

    func testLowMemoryDefaultsCleanupOffUntilPrompted() {
        // Off before the one-time prompt is answered...
        XCTAssertFalse(MemoryTier.firstRunCleanupDefault(isLowMemory: true, lowMemPrompted: false))
        // ...and after answering it, follows the normal on default (the answer
        // itself writes an explicit key, so this default is rarely consulted).
        XCTAssertTrue(MemoryTier.firstRunCleanupDefault(isLowMemory: true, lowMemPrompted: true))
    }

    func testLowMemoryDefaultDoesNotDependOnConfigFileExistence() {
        // Regression guard for the second-arm bug: persist() creates config.toml
        // at the end of arm(), but the default is keyed on prompt state, not file
        // existence — so an unanswered low-memory prompt stays off across re-arms.
        XCTAssertFalse(MemoryTier.firstRunCleanupDefault(isLowMemory: true, lowMemPrompted: false))
    }

    // MARK: - memory-aware cleanup model size (item 6)

    func testLowMemoryDefaultsToTheCompactModel() {
        XCTAssertEqual(MemoryTier.firstRunCleanupModel(physicalMemoryBytes: 8 * Self.gb),
                       MemoryTier.compactCleanupModel)
        XCTAssertEqual(MemoryTier.compactCleanupModel, "mlx-community/Qwen3-1.7B-4bit")
    }

    func testAmpleMemoryDefaultsToTheStandardModel() {
        XCTAssertEqual(MemoryTier.firstRunCleanupModel(physicalMemoryBytes: 16 * Self.gb),
                       MemoryTier.standardCleanupModel)
        XCTAssertEqual(MemoryTier.firstRunCleanupModel(physicalMemoryBytes: 64 * Self.gb),
                       MemoryTier.standardCleanupModel, "8B is offered, never auto-selected")
        XCTAssertEqual(MemoryTier.standardCleanupModel,
                       "abhiram3040/simplewords-dictation-cleanup-v2")
    }

    /// The 8-bit fine-tune is the larger of the two models (its footprint has not
    /// been measured; see `MemoryTier.standardCleanupModel`) — it does not belong
    /// on the low-memory tier, whose whole point is the ~1.4 GB compact model.
    func testTheCompactTierIsUnaffectedByTheStandardDefault() {
        XCTAssertEqual(MemoryTier.compactCleanupModel, "mlx-community/Qwen3-1.7B-4bit")
        XCTAssertNotEqual(MemoryTier.compactCleanupModel, MemoryTier.standardCleanupModel)
    }

    /// The frozen-prompt path must actually engage for the shipped default —
    /// otherwise the fine-tune runs on the few-shot prompt it was not trained on.
    func testTheStandardDefaultUsesTheFrozenPromptProfile() {
        XCTAssertEqual(
            CleanupPromptProfile.forModel(MemoryTier.standardCleanupModel), .simpleWords)
        XCTAssertEqual(
            CleanupPromptProfile.forModel(MemoryTier.compactCleanupModel), .legacy)
    }
}
