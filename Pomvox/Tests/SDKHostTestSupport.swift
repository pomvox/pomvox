import CryptoKit
import Foundation
import PomvoxCleanup
import XCTest

@testable import Pomvox

/// A tiny pack the real `PackLoader`/`PackInstaller` accept: the fixed
/// seven-file layout, a manifest with every required field, real hashes. The
/// "model" is a few bytes; `FakeModel` stands in for the MLX runtime, so every
/// lifecycle test exercises the SDK's real `Cleaner` and `CleanupSession`.
enum FakePack {
    static let files: [String: Data] = [
        "config.json": Data(#"{"model_type":"fake"}"#.utf8),
        "tokenizer.json": Data("{}".utf8),
        "tokenizer_config.json": Data(#"{"eos_token":"</s>"}"#.utf8),
        "chat_template.jinja": Data("{{ messages }}".utf8),
        "model.safetensors": Data((0..<4096).map { UInt8($0 % 251) }),
        "model.safetensors.index.json": Data(#"{"weight_map":{"w":"model.safetensors"}}"#.utf8),
        "system_v2.txt": Data("Clean up the dictation.".utf8),
    ]

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func manifest(version: String = "1.0.0") -> Data {
        let artifacts = files.keys.sorted().map { path -> [String: Any] in
            ["path": path, "bytes": files[path]!.count, "sha256": sha(files[path]!)]
        }
        let object: [String: Any] = [
            "schemaVersion": 1, "id": "fake-pack", "version": version, "publisher": "Tests",
            "license": "Apache-2.0", "licenseURL": "https://example.invalid/license",
            "modelID": "tests/fake-model", "modelRevision": String(repeating: "a", count: 40),
            "runtime": PackLoader.runtimeVersion, "prompt": "simplewords-frozen-v2",
            "quantization": "8bit", "languages": ["en"], "capabilities": ["vocabulary"],
            "rules": [CleanupCore.CleanupLogic.rulesVersion], "artifacts": artifacts,
            "limitations": ["test fixture"], "evidence": "tests",
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// A Hugging Face–shaped snapshot: every artifact a symlink into `blobs/`.
    /// `extraManifest` plants a snapshot-provided `pack.json` that must never
    /// be trusted.
    static func snapshot(in root: URL, extraManifest: Data? = nil) throws -> URL {
        let blobs = root.appendingPathComponent("blobs")
        let snapshot = root.appendingPathComponent("snapshots/rev")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (path, data) in files {
            let blob = blobs.appendingPathComponent(sha(data))
            try data.write(to: blob)
            try FileManager.default.createSymbolicLink(
                at: snapshot.appendingPathComponent(path), withDestinationURL: blob)
        }
        if let extraManifest { try extraManifest.write(to: snapshot.appendingPathComponent("pack.json")) }
        return snapshot
    }
}

/// A gate that ignores cancellation — a worker stuck in a GPU kernel.
final class StuckGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    func open() {
        lock.lock(); isOpen = true; let w = waiters; waiters = []; lock.unlock()
        w.forEach { $0.resume() }
    }
}

/// The MLX runtime's stand-in. Emulates its process-wide device lease (a
/// second open while one is resident throws) and records everything the host
/// sends it.
final class FakeModel: @unchecked Sendable {
    enum GenerateMode { case immediate, cooperative(AsyncLatch), stuck(StuckGate) }

    private let lock = NSLock()
    private var _opens = 0
    private var _openAttempts = 0
    private var _closes = 0
    private var _resident = 0
    private var _maxResident = 0
    private var _requests: [CleanupCore.CleanupRequest] = []
    private var _factoryVocabularies: [[String]] = []
    private var _cancelledGenerations = 0

    var openGate: StuckGate?
    var closeGate: StuckGate?
    var generateMode: GenerateMode = .immediate
    var respond: @Sendable (CleanupCore.CleanupRequest) -> RuntimeOutput = { request in
        var timings = CleanupCore.CleanupTimings()
        timings.tokenizationMS = 1
        timings.prefillMS = 2
        timings.inferenceMS = 3
        timings.prefixCacheUsed = true
        timings.promptTokens = 40
        timings.decodeTokens = 8
        timings.speculativeRounds = 2
        timings.speculativeDrafted = 6
        timings.speculativeAccepted = 3
        return RuntimeOutput(candidate: FakeModel.polish(request.text), timings: timings)
    }

    static func polish(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return trimmed }
        let body = first.uppercased() + trimmed.dropFirst()
        return body.hasSuffix(".") ? body : body + "."
    }

    var opens: Int { lock.withLock { _opens } }
    var openAttempts: Int { lock.withLock { _openAttempts } }
    var closes: Int { lock.withLock { _closes } }
    var resident: Int { lock.withLock { _resident } }
    var maxResident: Int { lock.withLock { _maxResident } }
    var requests: [CleanupCore.CleanupRequest] { lock.withLock { _requests } }
    var factoryVocabularies: [[String]] { lock.withLock { _factoryVocabularies } }
    var cancelledGenerations: Int { lock.withLock { _cancelledGenerations } }

    func factory(_ vocabulary: [String]) -> RuntimeFactory {
        lock.withLock { _factoryVocabularies.append(vocabulary) }
        return RuntimeFactory(name: "fake") { _ in try await self.open() }
    }

    private func open() async throws -> any CleanupRuntime {
        lock.withLock { _openAttempts += 1 }
        if let openGate { await openGate.wait() }
        try lock.withLock {
            guard _resident == 0 else {
                throw CleanupCore.CleanupError.unavailable("fake device already has an open cleaner")
            }
            _resident += 1
            _opens += 1
            _maxResident = max(_maxResident, _resident)
        }
        return FakeRuntime(model: self)
    }

    fileprivate func record(_ request: CleanupCore.CleanupRequest) { lock.withLock { _requests.append(request) } }
    fileprivate func noteCancelled() { lock.withLock { _cancelledGenerations += 1 } }
    fileprivate func closed() { lock.withLock { _resident -= 1; _closes += 1 } }
}

private actor FakeRuntime: CleanupRuntime {
    let model: FakeModel
    init(model: FakeModel) { self.model = model }

    func generate(_ request: CleanupCore.CleanupRequest, deadline: ContinuousClock.Instant) async throws -> RuntimeOutput {
        model.record(request)
        switch model.generateMode {
        case .immediate: break
        case .cooperative(let latch):
            do { _ = try await latch.wait() } catch { model.noteCancelled(); throw error }
        case .stuck(let gate):
            await gate.wait()
        }
        return model.respond(request)
    }

    func close() async {
        if let gate = model.closeGate { await gate.wait() }
        model.closed()
    }
}

/// A host wired to a fake pack in a temporary directory.
struct SDKHostFixture {
    let root: URL
    let model: FakeModel
    let provisioner: SDKPackProvisioner
    let host: SDKCleanupHost
    let acquisitions: Counter
    let releases: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    init(model: FakeModel = FakeModel(), quarantineGrace: Duration = .milliseconds(200),
         snapshotManifest: Data? = nil) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-sdkhost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = try FakePack.snapshot(in: root.appendingPathComponent("hub"), extraManifest: snapshotManifest)
        let manifest = FakePack.manifest()
        let acquisitions = Counter()
        self.acquisitions = acquisitions
        provisioner = try SDKPackProvisioner(
            manifestData: manifest, pinnedSHA256: FakePack.sha(manifest),
            root: root.appendingPathComponent("CleanupPacks")) { _, _ in
                acquisitions.increment()
                return snapshot
            }
        self.model = model
        let releases = Counter()
        self.releases = releases
        host = SDKCleanupHost(provisioner: provisioner, runtime: { model.factory($0) },
                              quarantineGrace: quarantineGrace,
                              afterRelease: {
                                  // Must only ever run with no model resident.
                                  XCTAssertEqual(model.resident, 0)
                                  releases.increment()
                              })
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

extension XCTestCase {
    /// Poll `condition` until true or `timeout` passes.
    func eventually(_ timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                    _ condition: @escaping () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
    }
}
