import Foundation
import Observation
import AVFoundation
import ModelAPI
import ModelService

@MainActor @Observable
final class RealtimePreviewStore {
    var instructions = "Be helpful and concise."
    var status = "English · built-in LLM and voice · up to five minutes"
    var userText = ""
    var assistantText = ""
    var busy = false
    var jobID: UUID?
    private var session: RealtimeSession?
    private var task: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private let io = RealtimeAudioIO()
    private let jobs: JobQueue
    private let runtime: AudioRuntime
    init(jobs: JobQueue, runtime: AudioRuntime) { self.jobs = jobs; self.runtime = runtime }
    func start() {
        guard !busy else { return }; busy = true; userText = ""; assistantText = ""
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw ModelAPIError.unavailable("Microphone access denied. Enable Positronic in System Settings → Privacy & Security → Microphone.") }
                try Task.checkCancellation()
                let service = RealtimeService(jobs: jobs, backend: LocalRealtimeBackend(runtime: runtime))
                let owner = self
                let conversation = service.makeSession { [weak owner] event in try await owner?.event(event) }
                session = conversation
                let job = try await service.submit(.init(instructions: instructions), session: conversation); jobID = job.id
                while true {
                    try Task.checkCancellation()
                    let value = try await jobs.job(job.id)
                    if value.state.terminal {
                        status = value.message ?? value.state.rawValue; break
                    }
                    if value.state != .running { status = value.message ?? "Waiting for the shared inference slot…" }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError {} catch { status = error.localizedDescription }
            io.stop(); capture?.cancel(); capture = nil
            if let session { await session.close() }
            if let jobID { try? await jobs.cancel(jobID) }
            self.session = nil; busy = false; task = nil
        }
    }
    func stop() {
        io.stop(); capture?.cancel(); capture = nil; task?.cancel()
        let session = session, id = jobID, jobs = jobs
        Task { await session?.close(); if let id { try? await jobs.cancel(id) } }
    }
    private func event(_ event: RealtimeEvent) async throws {
        switch event.type {
        case "session.ready":
            status = "Listening and speaking · Stop ends the session"
            let stream = try io.start()
            capture = Task { [weak self] in
                do { for try await frame in stream { try await self?.session?.receive(.init("input_audio.append", audio: frame.base64EncodedString())) } }
                catch { self?.status = error.localizedDescription; self?.stop() }
            }
        case "input_audio.transcript.delta": userText = String((userText + (event.delta ?? "")).suffix(8000))
        case "response.text.delta": assistantText = String((assistantText + (event.delta ?? "")).suffix(8000))
        case "output_audio.clear": io.clear()
        case "output_audio.delta":
            guard let audio = event.audio, let pcm = Data(base64Encoded: audio), let sequence = event.sequence, let epoch = event.epoch else { throw ModelAPIError.invalid("Invalid live audio.") }
            let session = session
            try io.play(pcm) { Task { try? await session?.receive(.init("playback.ack", sequence: sequence, epoch: epoch)) } }
        case "session.done": status = event.message ?? "Session ended."
        default: break
        }
    }
}

/// Capture is bounded on the audio thread before crossing to Swift concurrency.
private final class RealtimeCaptureBridge: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private var pending = Data()
    init(source: AVAudioFormat, continuation: AsyncThrowingStream<Data, any Error>.Continuation) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: format) else { throw ModelAPIError.unavailable("Cannot convert this microphone to 16 kHz mono.") }
        self.converter = converter; self.continuation = continuation
    }
    func receive(_ input: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        let count = AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return }
        var supplied = false; var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return input
        }
        if error != nil { continuation.finish(throwing: ModelAPIError.unavailable("Microphone conversion failed.")); return }
        guard let channel = output.floatChannelData?[0] else { return }
        for i in 0..<Int(output.frameLength) {
            let sample = channel[i]; guard sample.isFinite else { continuation.finish(throwing: ModelAPIError.invalid("Invalid microphone sample.")); return }
            let value = UInt16(bitPattern: Int16(max(-1, min(1, sample)) * 32767))
            pending.append(UInt8(value & 255)); pending.append(UInt8(value >> 8))
        }
        while pending.count >= 2560 {
            let result = continuation.yield(Data(pending.prefix(2560))); pending.removeFirst(2560)
            if case .dropped = result { continuation.finish(throwing: ModelAPIError.unavailable("Microphone processing fell behind; stopped to keep audio current.")); return }
        }
    }
}

@MainActor private final class RealtimeAudioIO {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    func start() throws -> AsyncThrowingStream<Data, any Error> {
        stop()
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        try engine.inputNode.setVoiceProcessingEnabled(true)
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw ModelAPIError.unavailable("No active microphone.") }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
        let bridge = try RealtimeCaptureBridge(source: source, continuation: continuation)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { buffer, _ in bridge.receive(buffer) }
        engine.attach(player)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: output)
        do { try engine.start(); player.play() }
        catch { engine.inputNode.removeTap(onBus: 0); engine.stop(); continuation.finish(); throw error }
        self.engine = engine; self.player = player; self.continuation = continuation
        return stream
    }
    func play(_ pcm: Data, completion: @escaping @Sendable () -> Void) throws {
        guard pcm.count == 3528, let player, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1764) else { throw ModelAPIError.invalid("Invalid speech playback frame.") }
        buffer.frameLength = 1764
        let bytes = [UInt8](pcm)
        for i in 0..<1764 { buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[2*i]) | UInt16(bytes[2*i+1]) << 8)) / 32768 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in completion() }
    }
    func clear() { player?.stop(); player?.play() }
    func stop() {
        continuation?.finish(); continuation = nil
        player?.stop(); player = nil
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }; engine = nil
    }
}
