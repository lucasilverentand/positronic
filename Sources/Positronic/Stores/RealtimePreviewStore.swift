import Foundation
import Observation
import AVFoundation
import CoreAudio
import OSLog
import ModelAPI
import ModelService

@MainActor @Observable
final class RealtimePreviewStore {
    var instructions = "Be helpful and concise."
    private static let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "RealtimePreview")
    var status = "English · built-in LLM and voice · up to five minutes" {
        didSet { if oldValue != status { Self.log.info("Conversation status: \(self.status, privacy: .public)") } }
    }
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
        status = "Requesting microphone access…"
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw ModelAPIError.unavailable("Microphone access denied. Enable Positronic in System Settings → Privacy & Security → Microphone.") }
                try Task.checkCancellation()
                status = "Preparing conversation…"
                let service = RealtimeService(jobs: jobs, backend: LocalRealtimeBackend(runtime: runtime))
                let owner = self
                let conversation = service.makeSession(waitForSpeech: true) { [weak owner] event in try await owner?.event(event) }
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
            status = "Starting microphone and playback…"
            let stream = try io.start()
            status = io.usesVoiceProcessing ? "Listening and speaking · Stop ends the session" : "Listening and speaking · Use headphones: echo cancellation unavailable"
            capture = Task { [weak self] in
                do {
                    var first = true
                    for try await frame in stream {
                        guard let session = self?.session else { throw CancellationError() }
                        try await session.receive(.init("input_audio.append", audio: frame.base64EncodedString()))
                        if first { first = false; Self.log.info("First microphone frame accepted by the conversation model.") }
                    }
                }
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
final class RealtimeCaptureBridge: @unchecked Sendable {
    let converter: AVAudioConverter
    let format: AVAudioFormat
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let lock = NSLock()
    private let conversionQueue = DispatchQueue(label: "Positronic.MicrophoneConversion", qos: .userInitiated)
    private var queuedBuffers = 0
    private var pending = Data()
    private var sawInput = false
    private var sawPCM = false
    private static let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "RealtimeCapture")
    init(source: AVAudioFormat, continuation: AsyncThrowingStream<Data, any Error>.Continuation) throws {
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: source, to: format) else { throw ModelAPIError.unavailable("Cannot convert this microphone to 16 kHz mono.") }
        self.converter = converter; self.continuation = continuation
    }
    func receive(_ input: AVAudioPCMBuffer) {
        // The device callback only copies its borrowed buffers. Conversion must
        // not block the hardware IO thread or retain Core Audio-owned memory.
        lock.lock()
        guard queuedBuffers < 25 else {
            lock.unlock()
            continuation.finish(throwing: ModelAPIError.unavailable("Microphone conversion fell behind; stopped instead of queuing old audio."))
            return
        }
        queuedBuffers += 1; lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            lock.lock(); queuedBuffers -= 1; lock.unlock(); return
        }
        copy.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            if let from = source[index].mData, let to = target[index].mData {
                memcpy(to, from, min(Int(source[index].mDataByteSize), Int(target[index].mDataByteSize)))
            }
        }
        conversionQueue.async {
            self.convert(copy)
            self.lock.lock(); self.queuedBuffers -= 1; self.lock.unlock()
        }
    }
    func finish() { conversionQueue.async { self.continuation.finish() } }
    private func convert(_ input: AVAudioPCMBuffer) {
        if !sawInput { sawInput = true; Self.log.info("First microphone buffer received: \(input.frameLength) frames at \(input.format.sampleRate) Hz.") }
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
            if !sawPCM { sawPCM = true; Self.log.info("First normalized 80 ms microphone frame produced.") }
            let result = continuation.yield(Data(pending.prefix(2560))); pending.removeFirst(2560)
            if case .dropped = result { continuation.finish(throwing: ModelAPIError.unavailable("Microphone processing fell behind; stopped to keep audio current.")); return }
        }
    }
}

@MainActor private final class RealtimeAudioIO {
    private static let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "RealtimeAudioIO")
    private(set) var usesVoiceProcessing = false
    private var engine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    func start() throws -> AsyncThrowingStream<Data, any Error> {
        stop()
        do { return try startEngine(voiceProcessing: true) }
        catch {
            let failure = error as NSError
            Self.log.warning("Voice-processing audio setup failed: \(failure.domain, privacy: .public) \(failure.code); retrying a fresh standard audio graph.")
            return try startEngine(voiceProcessing: false)
        }
    }
    private func startEngine(voiceProcessing: Bool) throws -> AsyncThrowingStream<Data, any Error> {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        if voiceProcessing { try engine.inputNode.setVoiceProcessingEnabled(true) }
        else { try engine.inputNode.auAudioUnit.setDeviceID(try defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) }
        let source = engine.inputNode.outputFormat(forBus: 0)
        guard source.sampleRate > 0, source.channelCount > 0 else { throw ModelAPIError.unavailable("No active microphone.") }
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
        let bridge = try RealtimeCaptureBridge(source: source, continuation: continuation)
        if voiceProcessing {
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: source) { @Sendable buffer, _ in bridge.receive(buffer) }
        } else {
            let sink = AVAudioSinkNode { @Sendable _, frames, buffers in
                guard let input = AVAudioPCMBuffer(pcmFormat: source, bufferListNoCopy: buffers, deallocator: nil) else { return kAudio_ParamError }
                input.frameLength = frames
                // Consume synchronously while Core Audio owns these buffers.
                bridge.receive(input)
                return noErr
            }
            engine.attach(sink)
            engine.connect(engine.inputNode, to: sink, format: source)
        }
        // Separate standard input/output engines avoid a combined hardware
        // aggregate when a USB microphone and a different speaker device are used.
        let playback = voiceProcessing ? engine : AVAudioEngine()
        if !voiceProcessing { try playback.outputNode.auAudioUnit.setDeviceID(try defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) }
        playback.attach(player)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        playback.connect(player, to: playback.mainMixerNode, format: output)
        do {
            if playback !== engine { try playback.start() }
            try engine.start()
            player.play()
        }
        catch { if voiceProcessing { engine.inputNode.removeTap(onBus: 0) }; engine.stop(); playback.stop(); continuation.finish(); throw error }
        self.engine = engine; self.playbackEngine = playback; self.player = player; self.continuation = continuation
        usesVoiceProcessing = voiceProcessing
        return stream
    }
    private func defaultDevice(_ selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr, device != 0 else { throw ModelAPIError.unavailable("The selected audio device is unavailable.") }
        return device
    }
    func play(_ pcm: Data, completion: @escaping @Sendable () -> Void) throws {
        guard pcm.count == 3528, let player, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1764) else { throw ModelAPIError.invalid("Invalid speech playback frame.") }
        buffer.frameLength = 1764
        let bytes = [UInt8](pcm)
        for i in 0..<1764 { buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[2*i]) | UInt16(bytes[2*i+1]) << 8)) / 32768 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in completion() }
    }
    func clear() { player?.stop(); player?.play() }
    func stop() {
        continuation?.finish(); continuation = nil
        player?.stop(); player = nil
        playbackEngine?.stop(); playbackEngine = nil
        if let engine { if usesVoiceProcessing { engine.inputNode.removeTap(onBus: 0) }; engine.stop() }; engine = nil
    }
}
