import AVFoundation
import Darwin
import Foundation
import XCTest

@testable import Pomvox

/// The SDK backend on the real ~2 GB pack, through the same host code the app
/// runs (`SDKCleanupHost`, `runSDKCleanup`, `deliverUtterance`).
///
/// Skipped unless `POMVOX_SDK_REAL=1`. Installs into a temporary root (APFS
/// clones of the cached Hugging Face snapshot, so no second copy of the
/// weights), never into the user's Application Support. Results go to
/// `POMVOX_SDK_REAL_OUT` as JSON lines; transcript text is not written except
/// for the public, committed corpus.
///   TEST_RUNNER_POMVOX_SDK_REAL=1 TEST_RUNNER_POMVOX_SDK_REAL_OUT=/tmp/out.jsonl \
///   TEST_RUNNER_POMVOX_SDK_REAL_WAVS=/tmp/wavs xcodebuild test … \
///   -only-testing:PomvoxTests/SDKHostRealModelTests
///
/// One test at a time: the SDK admits one resident model per process, so each
/// test disables its host and waits for release before returning.
final class SDKHostRealModelTests: XCTestCase {

    private static let env = ProcessInfo.processInfo.environment

    private var root: URL!
    private var host: SDKCleanupHost!

    override func setUp() async throws {
        try XCTSkipUnless(Self.env["POMVOX_SDK_REAL"] == "1", "set TEST_RUNNER_POMVOX_SDK_REAL=1")
        root = FileManager.default.temporaryDirectory.appendingPathComponent("pomvox-real-\(UUID().uuidString)")
        host = try makeHost()
    }

    override func tearDown() async throws {
        if let host {
            await host.disable()
            _ = try? await host.awaitRetirement(until: .now.advanced(by: .seconds(30)))
        }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeHost() throws -> SDKCleanupHost {
        let bundle = Bundle(for: NativeEngine.self)
        let url = try XCTUnwrap(bundle.url(forResource: SDKPackProvisioner.bundledResourceName, withExtension: "json"))
        let provisioner = try SDKPackProvisioner(manifestData: Data(contentsOf: url), root: root) { manifest, progress in
            try await CleanupEngine.fetchFrozenSnapshot(modelID: manifest.modelID, onProgress: progress)
        }
        // The app's configuration: clear MLX's pool once a cleaner has released
        // (POMVOX_SDK_REAL_KEEP_POOL=1 measures the SDK default instead).
        let keep = Self.env["POMVOX_SDK_REAL_KEEP_POOL"] == "1"
        return SDKCleanupHost(provisioner: provisioner,
                              afterRelease: { if !keep { MLXBufferPool.releaseCachedBuffers() } })
    }

    private func record(_ fields: [String: Any]) {
        var line = fields
        line["ts"] = ISO8601DateFormatter().string(from: Date())
        let data = (try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys])) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        print("SDKREAL \(text)")
        guard let path = Self.env["POMVOX_SDK_REAL_OUT"], !path.isEmpty else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        } else {
            try? Data((text + "\n").utf8).write(to: URL(fileURLWithPath: path))
        }
    }

    private func waitResident(_ host: SDKCleanupHost, timeout: TimeInterval = 300) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await host.isResident { return }
            if let failure = await host.failure { throw XCTSkip("preparation failed: \(failure.message)") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("not resident after \(timeout)s")
    }

    /// Physical footprint (what Activity Monitor calls Memory), in MB.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private static func kindName(_ kind: SDKCleanupOutcome.Kind) -> String {
        switch kind {
        case .cleaned: return "cleaned"
        case .unchanged: return "unchanged"
        case .fallback(let r): return "fallback:\(r.rawValue)"
        case .configurationFailure: return "configurationFailure"
        }
    }

    // MARK: - Startup and reopen

    func testColdInstallExistingOpenAndReopenLatency() async throws {
        let before = Self.footprintMB()
        await host.enable(vocabulary: .empty)
        try await waitResident(host)
        let cold = await host.lastPreparation
        record(["test": "startup", "phase": "cold-install+open", "kind": cold?.kind.rawValue ?? "?",
                "totalMS": cold?.totalMS ?? -1, "sdkPreparationMS": cold?.sdkPreparationMS ?? -1,
                "footprintBeforeMB": before, "footprintAfterMB": Self.footprintMB()])

        for i in 1...3 {
            await host.evict(.memoryPressure)
            let released = try await host.awaitRetirement(until: .now.advanced(by: .seconds(30)))
            let afterClose = Self.footprintMB()
            await host.requestPreparation()
            try await waitResident(host)
            let reopen = await host.lastPreparation
            let warm = try await host.clean("um so i think we should ship it today",
                                            budget: CleanupBudget(seconds: 30))
            record(["test": "startup", "phase": "reopen", "iteration": i, "released": released,
                    "kind": reopen?.kind.rawValue ?? "?", "totalMS": reopen?.totalMS ?? -1,
                    "sdkPreparationMS": reopen?.sdkPreparationMS ?? -1,
                    "footprintAfterCloseMB": afterClose, "footprintAfterReopenMB": Self.footprintMB(),
                    "firstRequestKind": Self.kindName(warm.kind),
                    "firstRequestTotalMS": warm.result?.timings.totalMS ?? -1,
                    "firstRequestCached": warm.result?.timings.prefixCacheUsed.map { $0 ? 1 : 0 } ?? -1])
        }

        // A second host instance over the same installation: full validation.
        await host.disable()
        _ = try await host.awaitRetirement(until: .now.advanced(by: .seconds(30)))
        for i in 1...2 {
            let fresh = try makeHost()
            await fresh.enable(vocabulary: .empty)
            try await waitResident(fresh)
            let opened = await fresh.lastPreparation
            record(["test": "startup", "phase": "existing-installation-open", "iteration": i,
                    "kind": opened?.kind.rawValue ?? "?", "totalMS": opened?.totalMS ?? -1,
                    "sdkPreparationMS": opened?.sdkPreparationMS ?? -1])
            await fresh.disable()
            _ = try await fresh.awaitRetirement(until: .now.advanced(by: .seconds(30)))
        }
        host = nil
    }

    // MARK: - Warm latency by vocabulary size

    func testWarmCleanupLatencyWithZeroOneTwoAndSixtyFourTerms() async throws {
        let sentences = [
            "um so the demo went fine but the export button is still broken",
            "can you send me the notes from yesterday's call before lunch",
            "i think we should move the launch to next thursday wait no friday",
            "the new build fixes the crash when you paste a long transcript",
            "remind me to follow up with the design team about the icons",
        ]
        let dictionary = ["Pomvox", "Parakeet", "Qwen", "SimpleWords", "Sparkle"]
            + (1...59).map { "Term\($0)x" }
        await host.enable(vocabulary: .empty)
        try await waitResident(host)
        _ = try await host.clean(sentences[0], budget: CleanupBudget(seconds: 30))  // settle

        for size in [0, 1, 2, 64] {
            let selection = SDKVocabulary.select(from: Array(dictionary.prefix(size)))
            XCTAssertEqual(selection.terms.count, size)
            await host.setVocabulary(selection)
            // First request after a dictionary change rebuilds the single prefix.
            let rebuild = try await host.clean(sentences[0], budget: CleanupBudget(seconds: 30))
            var totals: [Double] = []
            var cached: [Int] = []
            var kinds: [String: Int] = [:]
            for round in 0..<3 {
                for sentence in sentences {
                    let outcome = try await host.clean(sentence, budget: CleanupBudget(seconds: 30))
                    kinds[Self.kindName(outcome.kind), default: 0] += 1
                    if let t = outcome.result?.timings {
                        totals.append(t.totalMS)
                        if let c = t.prefixCacheUsed { cached.append(c ? 1 : 0) }
                    }
                    _ = round
                }
            }
            record(["test": "warm-latency", "terms": size,
                    "vocabularyBytes": selection.terms.reduce(0) { $0 + $1.utf8.count },
                    "rebuildTotalMS": rebuild.result?.timings.totalMS ?? -1,
                    "rebuildCached": rebuild.result?.timings.prefixCacheUsed.map { $0 ? 1 : 0 } ?? -1,
                    "requests": totals.count, "p50TotalMS": Self.median(totals),
                    "maxTotalMS": totals.max() ?? -1, "cacheUsed": cached.reduce(0, +),
                    "cacheObserved": cached.count, "kinds": kinds])
        }
    }

    // MARK: - Behaviour corpus

    func testPublicBehaviorCorpusThroughTheHost() async throws {
        await host.enable(vocabulary: .empty)
        try await waitResident(host)
        var failures: [String] = []
        var tally: [String: Int] = [:]
        for c in CleanupE2ETests.cases {
            let outcome = try await host.clean(c.raw, budget: CleanupBudget(seconds: 30))
            let kind = Self.kindName(outcome.kind)
            tally[kind, default: 0] += 1
            let accepted = outcome.kind == .cleaned || outcome.kind == .unchanged
            var problems: [String] = []
            if let want = c.expectAccepted, want != accepted {
                problems.append("expected accepted=\(want), got \(kind)")
            } else if accepted {
                for w in c.mustKeep where !CleanupE2ETests.containsWordPublic(outcome.text, w) { problems.append("lost \(w)") }
                for w in c.mustDrop where CleanupE2ETests.containsWordPublic(outcome.text, w) { problems.append("kept \(w)") }
            }
            record(["test": "corpus", "case": c.name, "kind": kind, "raw": c.raw, "out": outcome.text,
                    "problems": problems, "knownGap": c.knownGap ?? "",
                    "totalMS": outcome.result?.timings.totalMS ?? -1, "warnings": outcome.warnings])
            if !problems.isEmpty, c.knownGap == nil { failures.append("\(c.name): \(problems)") }
        }
        record(["test": "corpus-summary", "cases": CleanupE2ETests.cases.count, "tally": tally,
                "unexpectedFailures": failures.count])
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    // MARK: - Long, non-repetitive inputs

    static let prose: [String] = [
        "so the first thing i want to cover is the onboarding flow for new users",
        "right now it asks for three permissions before you can even try a dictation",
        "which feels like a lot when you have not seen the product do anything yet",
        "my proposal is that we let people record once with just the microphone",
        "and then ask for accessibility only when they try to paste into another app",
        "the second topic is pricing and honestly i do not have a strong opinion",
        "marketing wants a yearly plan with a discount of maybe twenty percent",
        "finance would rather we keep a single monthly price until the fall",
        "we should probably look at what the three closest competitors charge",
        "third item is the crash reports we got from the beta group last week",
        "most of them trace back to the audio engine restarting after sleep",
        "there is a fix in review that rebuilds the engine when the device changes",
        "i would like two more people to test it on older intel laptops",
        "on the hiring side we have four candidates for the platform role",
        "two of them are strong on systems work and one has shipped a mac app",
        "can we schedule the final interviews for the week after the offsite",
        "the offsite itself is in denver and the hotel block closes on the tenth",
        "please book flights before then because prices jump after that date",
        "for the roadmap i want to move the history search feature up a quarter",
        "customers keep asking for it and the backend work is mostly done",
        "the tradeoff is that the dictionary sync work slips to the next release",
        "last thing the legal team reviewed the privacy policy and signed off",
        "they asked us to add one sentence about how long crash logs are kept",
        "i will send the updated draft around tomorrow morning for a final look",
        "if nobody objects by friday we will publish it with the next update",
        "oh and before i forget the office will be closed on the holiday monday",
        "the cleaning crew is moving to tuesdays starting next month as well",
        "someone asked about parking and the answer is the garage validates now",
        "we also need a volunteer to organize the team lunch in december",
        "okay i think that is everything let me know if i missed anything",
    ]

    func testLongNonRepetitiveInputsWithTheAppBudgetPolicy() async throws {
        await host.enable(vocabulary: .empty)
        try await waitResident(host)
        for target in [600, 1_200, 2_400, 4_800, 9_600, 15_000, 17_000] {
            var text = ""
            var i = 0
            // Cycle distinct sentences, varying the connective so no span repeats verbatim.
            let connectives = ["and", "also", "then", "plus", "anyway", "so", "next", "besides"]
            while text.utf8.count < target {
                let sentence = Self.prose[i % Self.prose.count]
                let joiner = connectives[(i / Self.prose.count + i) % connectives.count]
                text += (text.isEmpty ? "" : " \(joiner) ") + sentence + (i >= Self.prose.count ? " round \(i / Self.prose.count + 1)" : "")
                i += 1
            }
            let start = ContinuousClock.now
            let outcome = try await runSDKCleanup(host, raw: text, baseTimeoutS: 5, reopenPermitted: true)
            let elapsed = start.duration(to: .now).milliseconds
            XCTAssertTrue(outcome.kind == .cleaned || outcome.kind == .unchanged || outcome.text == text,
                          "every fallback preserves the whole original")
            record(["test": "long-input", "targetBytes": target, "bytes": text.utf8.count, "chars": text.count,
                    "kind": Self.kindName(outcome.kind), "hostElapsedMS": elapsed,
                    "hostBudgetS": CleanupDeadline.effectiveTimeoutS(base: 5, chars: text.count),
                    "sdkBudgetMS": outcome.result?.timings.budgetMS ?? -1,
                    "totalMS": outcome.result?.timings.totalMS ?? -1,
                    "decodeTokens": outcome.result?.timings.decodeTokens ?? -1,
                    "promptTokens": outcome.result?.timings.promptTokens ?? -1,
                    "outBytes": outcome.text.utf8.count, "warnings": outcome.warnings])
        }
    }

    // MARK: - Concurrent STT and repeated-session soak

    func testRepeatedSessionsWithConcurrentSpeechRecognition() async throws {
        let wavDir = try XCTUnwrap(Self.env["POMVOX_SDK_REAL_WAVS"], "set TEST_RUNNER_POMVOX_SDK_REAL_WAVS")
        let wavs = try FileManager.default.contentsOfDirectory(atPath: wavDir)
            .filter { $0.hasSuffix(".wav") }.sorted()
            .map { URL(fileURLWithPath: wavDir).appendingPathComponent($0) }
        try XCTSkipIf(wavs.isEmpty, "no .wav files in \(wavDir)")
        let audio = try wavs.map(Self.loadMono16k)

        let transcriber = Transcriber()
        try await transcriber.prepare()
        await host.enable(vocabulary: SDKVocabulary.select(from: ["Pomvox", "Parakeet"]))
        try await waitResident(host)
        let startFootprint = Self.footprintMB()
        let sessions = await UtteranceSessions()
        let host = self.host!
        let iterations = Int(Self.env["POMVOX_SDK_REAL_SOAK"] ?? "") ?? 40

        var previous = try await transcriber.transcribe(audio[0])
        var tally: [String: Int] = [:]
        var sttMS: [Double] = []
        var cleanupMS: [Double] = []
        var staleInserts = 0
        var inserted = 0
        var suppressed = 0
        for i in 1...iterations {
            let samples = audio[i % audio.count]
            let raw = previous
            let cancelThis = i % 9 == 0
            let id = await sessions.begin()
            // Cleanup of the last utterance on the GPU while the next one is
            // recognised on the ANE — the overlap a live draft loop produces.
            let cleanup = Task { () -> (UtteranceDelivery, SDKCleanupOutcome?) in
                let outcome: SDKCleanupOutcome
                do { outcome = try await runSDKCleanup(host, raw: raw, baseTimeoutS: 5, reopenPermitted: true) }
                catch { return (.suppressed, nil) }
                let delivery = await MainActor.run {
                    deliverUtterance(outcome.text, id: id, sessions: sessions,
                                     spokenFormatting: SpokenFormatting.apply,
                                     dictionary: { $0 }, signature: { $0 }, insert: { _ in })
                }
                return (delivery, outcome)
            }
            let sttStart = ContinuousClock.now
            let recognised = try await transcriber.transcribe(samples)
            sttMS.append(sttStart.duration(to: .now).milliseconds)
            if cancelThis {
                await sessions.retire()
                cleanup.cancel()
            }
            let (delivery, outcome) = await cleanup.value
            if let outcome {
                tally[Self.kindName(outcome.kind), default: 0] += 1
                if let t = outcome.result?.timings { cleanupMS.append(t.totalMS) }
            } else {
                tally["cancelled", default: 0] += 1
            }
            switch delivery {
            case .inserted: inserted += 1; if cancelThis { staleInserts += 1 }
            case .suppressed: suppressed += 1
            }
            previous = recognised.isEmpty ? raw : recognised
        }
        let availability = await host.availability
        let generation = await host.generation
        record(["test": "soak", "iterations": iterations, "wavs": wavs.count, "tally": tally,
                "inserted": inserted, "suppressed": suppressed, "staleInserts": staleInserts,
                "p50SttMS": Self.median(sttMS), "p50CleanupMS": Self.median(cleanupMS),
                "maxCleanupMS": cleanupMS.max() ?? -1,
                "footprintStartMB": startFootprint, "footprintEndMB": Self.footprintMB(),
                "availabilityEnd": availability?.rawValue ?? "none", "opens": generation])
        XCTAssertEqual(staleInserts, 0)
        XCTAssertEqual(generation, 1, "no reopen, no second model during the soak")
    }

    private static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: input)
        let capacity = AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

extension CleanupE2ETests {
    static func containsWordPublic(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: "\\b" + NSRegularExpression.escapedPattern(for: needle) + "\\b",
                       options: [.regularExpression, .caseInsensitive]) != nil
    }
}
