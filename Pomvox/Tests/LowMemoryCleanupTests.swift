import XCTest
@testable import Pomvox

/// The explicit low-memory cleanup prompt (item 7): the pure show/don't-show
/// decision that replaces PR #65's silent skip.
final class LowMemoryCleanupTests: XCTestCase {

    func testPromptsOnLowMemoryWhenUndecidedAndNotYetAsked() {
        XCTAssertTrue(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: false, alreadyPrompted: false))
    }

    func testNeverPromptsOnAmpleMemory() {
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: false, cleanupKeyPresent: false, alreadyPrompted: false))
    }

    func testNeverPromptsWhenTheUserAlreadyChose() {
        // An explicit [cleanup] enabled key means the user has decided.
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: true, alreadyPrompted: false))
    }

    func testNeverPromptsTwice() {
        XCTAssertFalse(LowMemoryCleanupDecision.shouldPrompt(
            isLowMemory: true, cleanupKeyPresent: false, alreadyPrompted: true))
    }

    // MARK: - writing the choice (item 7)

    private static let gb: UInt64 = 1024 * 1024 * 1024

    private func freshDefaults() -> UserDefaults {
        let name = "lowmemcleanup.tests." + UUID().uuidString
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func tempConfigPath() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomvox-lowmem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.toml").path
    }

    /// Fresh low-memory install: enabling seeds the compact model (item 6).
    @MainActor
    func testEnableCleanupSeedsCompactModelWhenNoneChosen() throws {
        let path = try tempConfigPath()
        let model = LowMemoryCleanupModel(
            defaults: freshDefaults(), configPath: path, physicalMemory: 8 * Self.gb)
        model.enableCleanup()
        let doc = ConfigDocument.load(path: path)
        XCTAssertEqual(doc.bool("cleanup", "enabled"), true)
        XCTAssertEqual(doc.string("cleanup", "model"), MemoryTier.compactCleanupModel)
    }

    /// An explicit model choice must survive enabling via the prompt — the
    /// compact model is only *seeded* when no `cleanup.model` key exists, never
    /// forced over a user's selection (regression guard for the round-8 finding).
    @MainActor
    func testEnableCleanupPreservesAnExplicitModelChoice() throws {
        let path = try tempConfigPath()
        var seed = ConfigDocument(text: "")
        seed.set("cleanup", "model", string: MemoryTier.standardCleanupModel)
        try seed.write(to: path)
        let model = LowMemoryCleanupModel(
            defaults: freshDefaults(), configPath: path, physicalMemory: 8 * Self.gb)
        model.enableCleanup()
        let doc = ConfigDocument.load(path: path)
        XCTAssertEqual(doc.bool("cleanup", "enabled"), true)
        XCTAssertEqual(doc.string("cleanup", "model"), MemoryTier.standardCleanupModel,
                       "an explicit model choice must not be overwritten")
    }

    /// Enabling must tell the running engine. The sheet used to only set
    /// `lowMemPrompted` and a config key that nothing read until the next arm,
    /// so the compact model never started downloading.
    @MainActor
    func testEnableCleanupNotifiesTheEngineToStartTheDownload() throws {
        let path = try tempConfigPath()
        let model = LowMemoryCleanupModel(
            defaults: freshDefaults(), configPath: path, physicalMemory: 8 * Self.gb)
        let exp = expectation(forNotification: .pomvoxSettingsDidChange, object: nil)
        model.enableCleanup()
        wait(for: [exp], timeout: 1)
    }

    /// "Keep it off" records the choice and seeds compact only when unset.
    @MainActor
    func testKeepOffRecordsChoiceAndSeedsCompactOnlyWhenUnset() throws {
        let path = try tempConfigPath()
        let model = LowMemoryCleanupModel(
            defaults: freshDefaults(), configPath: path, physicalMemory: 8 * Self.gb)
        model.keepOff()
        let doc = ConfigDocument.load(path: path)
        XCTAssertEqual(doc.bool("cleanup", "enabled"), false)
        XCTAssertEqual(doc.string("cleanup", "model"), MemoryTier.compactCleanupModel)
    }
}
