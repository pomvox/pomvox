import XCTest
@testable import Pomvox

/// The persistence core behind the Settings UI: read current values (filling
/// config.py defaults for absent keys), validate, and write back touching only
/// the keys the user changed. These pin the M2 acceptance criteria.
final class SettingsStoreTests: XCTestCase {

    private func tempPath() -> String { NSTemporaryDirectory() + "pomvox-cfg-\(UUID().uuidString).toml" }

    func testReadDefaultsFromEmptyDoc() {
        XCTAssertEqual(SettingsIO.read(ConfigDocument(text: "")), SettingsValues.defaults)
    }

    func testReadParsesPresentKeysAndDefaultsTheRest() {
        let doc = ConfigDocument(text: """
            [cleanup]
            style = "light"
            enabled = false
            [vad]
            silence_ms = 800
            """)
        let v = SettingsIO.read(doc)
        XCTAssertEqual(v.cleanupStyle, "light")
        XCTAssertFalse(v.cleanupEnabled)
        XCTAssertEqual(v.vadSilenceMs, 800)
        XCTAssertEqual(v.sttModel, SettingsValues.defaults.sttModel)  // absent → default
    }

    func testWriteTouchesOnlyEditedKeyAndPreservesCommentsByteForByte() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = """
            # hand comment
            [cleanup]
            style = "polish"   # note

            [experimental]
            x = 1

            """
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        var v = SettingsIO.read(ConfigDocument.load(path: path))
        v.cleanupStyle = "light"
        XCTAssertTrue(SettingsIO.writeIfValid(v, path: path))

        let expected = original.replacingOccurrences(of: "style = \"polish\"", with: "style = \"light\"")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), expected)
    }

    func testInvalidModelIDLeavesFileUntouched() throws {
        let path = tempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let original = "[stt]\nmodel = \"mlx-community/parakeet-tdt-0.6b-v3\"\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        var v = SettingsIO.read(ConfigDocument.load(path: path))
        v.sttModel = "   "  // blank → invalid
        XCTAssertFalse(SettingsIO.writeIfValid(v, path: path))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), original)
    }

    func testValidateReportsTheOffendingField() {
        var v = SettingsValues.defaults
        v.cleanupModel = ""
        XCTAssertNotNil(SettingsIO.validate(v)["cleanup.model"])
        XCTAssertNil(SettingsIO.validate(SettingsValues.defaults)["cleanup.model"])
    }

    func testRoundTripAllFields() {
        var v = SettingsValues.defaults
        v.cleanupStyle = "light"
        v.cleanupEnabled = false
        v.hudPosition = "notch"
        v.vadSilenceMs = 1200
        v.vadEnabled = false
        v.audioDevice = "BlackHole 2ch"
        v.retentionDays = 14
        v.ptt = "right_option"
        v.toggle = "right_option+space"
        var doc = ConfigDocument(text: "")
        SettingsIO.applyAll(v, to: &doc)
        XCTAssertEqual(SettingsIO.read(doc), v)
    }

    func testDictationMarkRoundTrips() {
        var v = SettingsValues.defaults
        v.signatureEnabled = true
        v.signatureMark = "✨"
        var doc = ConfigDocument(text: "")
        SettingsIO.applyAll(v, to: &doc)
        let back = SettingsIO.read(doc)
        XCTAssertTrue(back.signatureEnabled)
        XCTAssertEqual(back.signatureMark, "✨")
        // What the settings pane writes is what the engine reads.
        XCTAssertEqual(Signature.read(doc), Signature(enabled: true, mark: "✨"))
    }

    func testDictationMarkDefaultsOff() {
        XCTAssertFalse(SettingsValues.defaults.signatureEnabled)
        XCTAssertFalse(Signature.read(ConfigDocument(text: "")).enabled)
    }

    func testQuickAddHotkeyRoundTrips() {
        var v = SettingsValues.defaults
        XCTAssertEqual(v.quickAdd, "")
        v.quickAdd = "cmd+shift+d"
        var doc = ConfigDocument(text: "")
        SettingsIO.applyAll(v, to: &doc)
        XCTAssertEqual(SettingsIO.read(doc).quickAdd, "cmd+shift+d")
    }

    /// Settings must display the model the engine will actually run when
    /// `[cleanup] model` is absent, or the panel lies about the active model.
    func testTheDisplayedDefaultMatchesTheEngineDefault() {
        XCTAssertEqual(SettingsValues.defaults.cleanupModel, MemoryTier.standardCleanupModel)
    }
}
