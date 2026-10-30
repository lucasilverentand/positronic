import AVFoundation
import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

/// Explicit physical-Mac acceptance. Default test runs never install or infer models.
final class LiveRealtimeTests: XCTestCase, @unchecked Sendable {
    func testExplicitRuntimePreparationOrModelDownload() async throws {
        guard let phase = ProcessInfo.processInfo.environment["POSITRONIC_PREPARE_REALTIME"], ["runtime", "model"].contains(phase) else { throw XCTSkip("Explicit operator runtime/model installation only") }
        let queue = JobQueue(), runtime = AudioRuntime(), activity = ModelActivity(jobs: queue)
        try await queue.start()
        do {
            try await activity.withManagement {
                if phase == "runtime" { try await runtime.prepare() }
                else { try await runtime.download(RealtimeConfiguration.modelID) }
            }
            XCTAssertTrue(AudioCatalog.realtimeReady)
            if phase == "model" { XCTAssertTrue(AudioCatalog.installed().contains { $0.id == RealtimeConfiguration.modelID }) }
        } catch { await queue.shutdown(); throw error }
        await queue.shutdown()
    }
}

private actor LiveConversationReceipt {
    struct Sample: Codable { var seconds: Double; var available: Int64; var pressure: Int32; var swap: Int64; var swapActivity: Int64; var worker: Int64; var disk: Int64 }
    var audio = Data()
    var assistant = ""
    var user = ""
    var cleared = 0
    var interrupted = false
    var job: UUID?
    var samples: [Sample] = []
    var events: [String] = []
    let start = Date()
    func record(_ event: RealtimeEvent) {
        events.append(event.type)
        if let id = event.job?.id { job = id }
        if event.type == "response.text.delta" { assistant += event.delta ?? "" }
        if event.type == "input_audio.transcript.delta" { user += event.delta ?? "" }
        if event.type == "output_audio.delta", let raw = event.audio, let pcm = Data(base64Encoded: raw) { audio.append(pcm) }
        if event.type == "output_audio.clear" { cleared += 1 }
    }
    func sample(_ snapshot: ResourceSnapshot, worker: Int64) { samples.append(.init(seconds: Date().timeIntervalSince(start), available: snapshot.available, pressure: snapshot.pressure, swap: snapshot.swap, swapActivity: snapshot.swapActivityBytes, worker: worker, disk: snapshot.disk)) }
    func markInterrupted() { interrupted = true }
    func hasResponse() -> Bool { assistant.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 }
    func save(to folder: URL, transcript: Transcript?) throws {
        struct Receipt: Encodable { var assistant: String; var user: String; var interrupted: Bool; var clearEvents: Int; var audioBytes: Int; var samples: [Sample]; var events: [String]; var outputTranscript: Transcript? }
        let value = Receipt(assistant: assistant, user: user, interrupted: interrupted, clearEvents: cleared, audioBytes: audio.count, samples: samples, events: events, outputTranscript: transcript)
        try JSONEncoder().encode(value).write(to: folder.appendingPathComponent("receipt.json"))
    }
}

extension LiveRealtimeTests {
    func testNativeDuplexConversationOverStreamingAPI() async throws {
        guard ProcessInfo.processInfo.environment["POSITRONIC_LIVE_REALTIME"] == "1" else { throw XCTSkip("Explicit bounded physical-Mac conversation test only") }
        guard AudioCatalog.realtimeReady, AudioCatalog.installed().contains(where: { $0.id == RealtimeConfiguration.modelID }) else { throw XCTSkip("Explicitly install the pinned runtime and model first") }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["POSITRONIC_LIVE_REALTIME_OUTPUT"] ?? "/private/tmp/positronic-live-conversation")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = AudioRuntime(), queue = JobQueue(waitLimit: 20), receipt = LiveConversationReceipt()
        try await queue.start()
        await queue.configure(prepare: { model in
            if !(await runtime.loaded()).contains(where: { $0.id == model }) { await runtime.stop() }
        }, cancelWorker: { await runtime.stop() }, footprint: {
            try await runtime.memory() + ResourceMonitor.residentBytes(of: ProcessInfo.processInfo.processIdentifier)
        })
        let monitor = Task {
            while !Task.isCancelled {
                do { await receipt.sample(try ResourceMonitor.snapshot(), worker: try await runtime.memory()); try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(180)); await queue.shutdown() } catch {}
        }
        defer { deadline.cancel() }
        var server: LoopbackServer?
        var serving: Task<Void, any Error>?
        var client: RealtimeConnection?
        var transcript: Transcript?
        do {
            // Establish a full swap-activity window before any inference allocation.
            for _ in 0..<30 { _ = try ResourceMonitor.snapshot(); try await Task.sleep(for: .seconds(1)) }
            let status = ResourceMonitor.restriction(try ResourceMonitor.snapshot(), budget: AudioCatalog.budget(RealtimeConfiguration.modelID), diskBytes: 4 << 20)
            if let reason = status.reason { throw XCTSkip("Physical-Mac admission blocked: " + reason) }
            let audio = AudioService(runtime: runtime, queue: queue, enabled: AudioCatalog.ids)
            let prompts = ["Hi. Tell me about the ocean in a few sentences.", "Stop. What color is a ripe banana? Just say the color."]
            var spoken: [Data] = []
            for (index, prompt) in prompts.enumerated() {
                let job = try await audio.submitSpeech(.init(input: prompt))
                let result = try await queue.wait(job.id)
                let file = try XCTUnwrap(result.file)
                let copy = output.appendingPathComponent("input-\(index+1).wav")
                if FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.removeItem(at: copy) }
                try FileManager.default.copyItem(at: file, to: copy)
                let normalized = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
                try await AudioIO.normalize(file, to: normalized)
                defer { try? FileManager.default.removeItem(at: normalized) }
                spoken.append(try Self.pcm16(normalized))
            }
            await runtime.stop()
            var configuration = ServiceConfiguration(); configuration.audioModels = [RealtimeConfiguration.modelID]
            let activity = ModelActivity(jobs: queue)
            let engine = try LocalModelEngine(configuration: configuration, activity: activity)
            let secretFolder = output.appendingPathComponent("temporary-key")
            defer { try? FileManager.default.removeItem(at: secretFolder) }
            let keys = try APIKeys(file: secretFolder.appendingPathComponent("keys.json"))
            let key = try await keys.create(name: "Bounded local conversation acceptance")
            await keys.observeRevocations { await queue.revoke($0) }
            let service = RealtimeService(jobs: queue, backend: LocalRealtimeBackend(runtime: runtime))
            let router = ModelRouter(keys: keys, engine: engine, jobs: queue, realtime: service)
            let ready = expectation(description: "Live API listener")
            let listener = try LoopbackServer(port: 0, authorizeUpload: { await router.authorizeUpload($0) }, realtime: { await router.serveRealtime($0, socket: $1) }) { await router.handle($0) }
            server = listener; serving = Task { try await listener.run { ready.fulfill() } }
            await fulfillment(of: [ready], timeout: 5)
            let connection = try RealtimeConnection(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(listener.port))")!, apiKey: key); client = connection
            let greeting = try await Self.next(connection, receipt: receipt)
            XCTAssertEqual(greeting.type, "session.created")
            try await connection.configure(.init(instructions: "Be a helpful conversational assistant. Speak briefly in English. Do not use tools.", maxDurationSeconds: 40))
            while try await Self.next(connection, receipt: receipt).type != "session.ready" {}
            let first = spoken[0], second = spoken[1]
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    let clock = ContinuousClock(); let begin = clock.now
                    var cursor = 0; var phase = 0; var secondStarted = false
                    for frame in 0..<425 {
                        try Task.checkCancellation()
                        let elapsed = Double(frame) * 0.08
                        if phase == 0 && elapsed >= 0.64 { phase = 1; cursor = 0 }
                        let responseReady = await receipt.hasResponse()
                        if phase == 2 && !secondStarted && (responseReady || elapsed >= 15) {
                            try await connection.send(.init("response.cancel")); await receipt.markInterrupted()
                            phase = 3; cursor = 0; secondStarted = true
                        }
                        let source = phase == 1 ? first : second
                        var pcm = Data(repeating: 0, count: 2560)
                        if phase == 1 || phase == 3 {
                            let remaining = min(2560, source.count-cursor)
                            if remaining > 0 { pcm.replaceSubrange(0..<remaining, with: source[cursor..<cursor+remaining]); cursor += remaining }
                            if cursor >= source.count { phase = phase == 1 ? 2 : 4 }
                        }
                        try await connection.appendAudio(pcm)
                        try await clock.sleep(until: begin + .milliseconds((frame+1)*80))
                    }
                    try await connection.send(.init("input_audio.commit"))
                }
                group.addTask {
                    while true {
                        let event = try await Self.next(connection, receipt: receipt)
                        if event.type == "output_audio.delta", let sequence = event.sequence, let epoch = event.epoch {
                            // Pace acknowledgement like a real 80 ms playback completion.
                            try await Task.sleep(for: .milliseconds(80)); try await connection.acknowledge(sequence, epoch: epoch)
                        }
                        if event.type == "session.done" { break }
                    }
                }
                while try await group.next() != nil {}
            }
            await connection.close(); client = nil
            if let id = await receipt.job { _ = try await queue.wait(id) }
            listener.stop(); _ = try? await serving?.value; serving = nil
            let pcm = await receipt.audio
            XCTAssertGreaterThan(pcm.count, 22050)
            let wave = output.appendingPathComponent("conversation.wav")
            try Self.writeWAV(pcm, to: wave)
            let input = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try FileManager.default.copyItem(at: wave, to: input)
            let transcription = try await audio.submitTranscription(file: input, language: "en")
            transcript = try JSONDecoder().decode(Transcript.self, from: await queue.wait(transcription.id).data)
            let user = await receipt.user, assistant = await receipt.assistant, interrupted = await receipt.interrupted, clears = await receipt.cleared
            XCTAssertTrue(user.lowercased().contains("banana"), "User transcript: \(user)")
            XCTAssertFalse(assistant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(interrupted); XCTAssertGreaterThan(clears, 1)
            XCTAssertFalse(transcript?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let samples = await receipt.samples
            XCTAssertTrue(samples.allSatisfy { $0.pressure == 1 && $0.swapActivity < ResourceMonitor.swapActivityLimit && $0.disk >= ResourceMonitor.diskReserve })
        } catch {
            await client?.close(); server?.stop(); _ = try? await serving?.value
            monitor.cancel(); await runtime.stop(); await queue.shutdown(); try await receipt.save(to: output, transcript: transcript); throw error
        }
        monitor.cancel(); await runtime.stop(); await queue.shutdown(); try await receipt.save(to: output, transcript: transcript)
    }
    private static func next(_ client: RealtimeConnection, receipt: LiveConversationReceipt) async throws -> RealtimeEvent {
        let event = try await client.receive(); await receipt.record(event)
        if event.type == "session.error" { throw ModelAPIError.unavailable(event.message ?? "Live session failed.") }
        return event
    }
    private static func pcm16(_ file: URL) throws -> Data {
        let audio = try AVAudioFile(forReading: file)
        guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1, audio.length <= 16000*15,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)) else { throw ModelAPIError.invalid("Invalid spoken test fixture.") }
        try audio.read(into: buffer); var bytes = Data()
        for index in 0..<Int(buffer.frameLength) {
            let value = UInt16(bitPattern: Int16(max(-1, min(1, buffer.floatChannelData![0][index])) * 32767))
            bytes.append(UInt8(value & 255)); bytes.append(UInt8(value >> 8))
        }
        return bytes
    }
    private static func writeWAV(_ pcm: Data, to file: URL) throws {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(UInt32(36+pcm.count)); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(22050); u32(44100); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(UInt32(pcm.count)); data.append(pcm)
        try ResourceMonitor.requireDisk(at: file.deletingLastPathComponent(), additional: Int64(data.count))
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
