import XCTest
@testable import Pomvox

/// The opt-in eval capture folder: the record format is a file contract for
/// downstream tooling, so its keys are pinned here; the store's create /
/// write / purge behaviour runs against a temp dir. The engine-side gate
/// (`shouldCapture`) is pure and tested where the decision is made.
final class EvalCaptureTests: XCTestCase {
    private var dir: String!

    override func setUp() {
        super.setUp()
        dir = NSTemporaryDirectory() + "pomvox-eval-\(UUID().uuidString)"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: dir)
        super.tearDown()
    }

    private func record(raw: String = "um so we've got to build this thing",
                        cleaned: String = "We've got to build this thing.",
                        status: String = "ok",
                        durationS: Double = 2.5) -> EvalRecord {
        EvalRecord(id: UUID(uuidString: "8B1F3A2C-0000-4000-8000-00000000ABCD")!,
                   at: Date(timeIntervalSince1970: 1_788_000_000.25),
                   rawAsr: raw, cleaned: cleaned, durationS: durationS,
                   modelVersion: "abhiram3040/simplewords-dictation-cleanup-v3",
                   cleanupStatus: status,
                   sttModel: "mlx-community/parakeet-tdt-0.6b-v3",
                   style: "polish", appVersion: "0.2.6 (17)")
    }

    // MARK: - record format

    func testRecordEncodesExactlyTheDocumentedKeys() throws {
        let data = try EvalCaptureStore.encoder.encode(record())
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), [
            "id", "ts", "raw_asr", "cleaned", "duration_ms", "model_version",
            "cleanup_status", "stt_model", "style", "app_version",
        ])
        XCTAssertEqual(obj["id"] as? String, "8b1f3a2c-0000-4000-8000-00000000abcd")
        XCTAssertEqual(obj["ts"] as? String, "2026-08-29T10:40:00.250Z")
        XCTAssertEqual(obj["raw_asr"] as? String, "um so we've got to build this thing")
        XCTAssertEqual(obj["cleaned"] as? String, "We've got to build this thing.")
        XCTAssertEqual(obj["duration_ms"] as? Int, 2500)
        XCTAssertEqual(obj["model_version"] as? String, "abhiram3040/simplewords-dictation-cleanup-v3")
        XCTAssertEqual(obj["cleanup_status"] as? String, "ok")
        // Slashes in model ids stay readable — no "\/" escaping.
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("abhiram3040/simplewords"))
    }

    func testTimestampIsUTCWithMilliseconds() {
        XCTAssertEqual(EvalRecord.iso8601(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(EvalRecord.iso8601(Date(timeIntervalSince1970: 1.5)), "1970-01-01T00:00:01.500Z")
    }

    func testDurationRoundsToWholeMilliseconds() {
        XCTAssertEqual(EvalRecord.milliseconds(2.5), 2500)
        XCTAssertEqual(EvalRecord.milliseconds(0.0004), 0)
        XCTAssertEqual(EvalRecord.milliseconds(1.23456), 1235)
    }

    func testFileNameSortsByTimeAndCarriesTheID() {
        XCTAssertEqual(record().fileName,
                       "20260829-104000-8b1f3a2c-0000-4000-8000-00000000abcd.json")
    }

    func testShouldCaptureGate() {
        XCTAssertTrue(EvalRecord.shouldCapture(enabled: true, raw: "hi", pasted: "Hi."))
        XCTAssertFalse(EvalRecord.shouldCapture(enabled: false, raw: "hi", pasted: "Hi."))
        XCTAssertFalse(EvalRecord.shouldCapture(enabled: true, raw: "", pasted: "Hi."))
        XCTAssertFalse(EvalRecord.shouldCapture(enabled: true, raw: "hi", pasted: ""))
    }

    func testSettingDefaultsOff() throws {
        let suite = "pomvox-eval-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = EvalCaptureSetting(defaults: defaults)
        XCTAssertFalse(setting.isOn)
        setting.isOn = true
        XCTAssertTrue(EvalCaptureSetting(defaults: defaults).isOn)
    }

    // MARK: - store

    func testWriteCreatesTheFolderAndOneFilePerRecord() throws {
        let store = EvalCaptureStore(dir: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
        XCTAssertTrue(store.write(record()))
        XCTAssertTrue(store.write(EvalRecord(rawAsr: "two", cleaned: "Two.", durationS: 1,
                                             modelVersion: "off", cleanupStatus: "off",
                                             sttModel: "s", style: "light", appVersion: "v")))
        let files = store.recordFiles().map(\.lastPathComponent)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(Set(files).count, 2, "two records must never share a file name")
        XCTAssertEqual(store.count(), 2)
        XCTAssertGreaterThan(store.bytes(), 0)

        // Owner-only, like history.db.
        let attrs = try FileManager.default.attributesOfItem(atPath: dir)
        XCTAssertEqual(((attrs[.posixPermissions] as? Int) ?? 0) & 0o777, 0o700)
    }

    func testWrittenFileRoundTrips() throws {
        let store = EvalCaptureStore(dir: dir)
        let r = record(status: "timeout")
        XCTAssertTrue(store.write(r))
        let url = try XCTUnwrap(store.recordFiles().first)
        let back = try JSONDecoder().decode(EvalRecord.self, from: Data(contentsOf: url))
        XCTAssertEqual(back, r)
    }

    func testPurgeRemovesOnlyRecordFiles() throws {
        let store = EvalCaptureStore(dir: dir)
        store.write(record())
        store.write(EvalRecord(rawAsr: "second", cleaned: "Second.", durationS: 1,
                               modelVersion: "m", cleanupStatus: "ok",
                               sttModel: "s", style: "polish", appVersion: "v"))
        // A user's own note and a nested folder survive a purge.
        try "keep me".write(toFile: dir + "/notes.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: dir + "/nested.json", withIntermediateDirectories: false)
        try "{}".write(toFile: dir + "/nested.json/inner.json", atomically: true, encoding: .utf8)

        XCTAssertEqual(store.count(), 2)
        XCTAssertEqual(store.purge(), 2)
        XCTAssertEqual(store.count(), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/notes.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/nested.json/inner.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir), "the folder itself stays")
    }

    func testPurgeOnMissingFolderIsHarmless() {
        let store = EvalCaptureStore(dir: dir)
        XCTAssertEqual(store.purge(), 0)
        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(store.bytes(), 0)
    }

    func testUnwritableLocationFailsQuietly() throws {
        // The "folder" is a regular file: creation must fail without throwing,
        // and the write must report false rather than crash the finalize task.
        try "not a directory".write(toFile: dir, atomically: true, encoding: .utf8)
        let store = EvalCaptureStore(dir: dir)
        XCTAssertFalse(store.ensureDirectory())
        XCTAssertFalse(store.write(record()))
        XCTAssertEqual(store.count(), 0)
    }

    func testWritePostsChangeNotification() {
        let store = EvalCaptureStore(dir: dir)
        let exp = expectation(forNotification: .pomvoxEvalCaptureDidChange, object: nil)
        store.write(record())
        wait(for: [exp], timeout: 1)
    }
}
