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
    var microphoneReady = false
    var echoCancellationEnabled = true
    var voiceFocusEnabled = true
    private var activeOptions = LocalVoiceOptions()
    var echoCancellationActive = false
    var voiceFocusActive = false
    private static var checkedStartup = false
    var processingStatus: String {
        guard microphoneReady else { return "Audio processing starts with the microphone." }
        if echoCancellationActive && voiceFocusActive { return "Local echo cancellation · neural voice cleanup" }
        if echoCancellationActive { return "Local echo cancellation active" }
        return voiceFocusActive ? "Local neural voice cleanup active" : "Microphone processing off"
    }
    private func refreshAudioProcessing() {
        echoCancellationActive = activeOptions.echoCancellation && microphoneReady
        voiceFocusActive = activeOptions.voiceFocus && microphoneReady
    }
    private var session: RealtimeSession?
    private var task: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var preparedMicrophone: AsyncThrowingStream<Data, any Error>?
    private let io = RealtimeAudioIO()
    private let jobs: JobQueue
    private let runtime: AudioRuntime
    init(jobs: JobQueue, runtime: AudioRuntime) { self.jobs = jobs; self.runtime = runtime }
    func start() {
        guard !busy else { return }; busy = true; userText = ""; assistantText = ""
        microphoneReady = false; echoCancellationActive = false; voiceFocusActive = false
        status = "Requesting microphone access…"
        task = Task {
            do {
                let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                guard allowed else { throw ModelAPIError.unavailable("Microphone access denied. Enable Positronic in System Settings → Privacy & Security → Microphone.") }
                try Task.checkCancellation()
                status = "Preparing conversation…"
                let service = RealtimeService(jobs: jobs, backend: LocalRealtimeBackend(runtime: runtime))
                let owner = self
                let conversation = service.makeSession(waitForSpeech: true, prepareAudio: { [weak owner] in
                    guard let owner else { throw CancellationError() }
                    try await owner.prepareMicrophone()
                }) { [weak owner] event in try await owner?.event(event) }
                session = conversation
                let job = try await service.submit(.init(instructions: instructions), session: conversation); jobID = job.id
                while true {
                    try Task.checkCancellation()
                    let value = try await jobs.job(job.id)
                    refreshAudioProcessing()
                    if value.state.terminal {
                        status = value.message ?? value.state.rawValue; break
                    }
                    if value.state != .running { status = value.message ?? "Waiting for the shared inference slot…" }
                    try await Task.sleep(for: .milliseconds(250))
                }
            } catch is CancellationError { status = "Conversation stopped." } catch { status = error.localizedDescription }
            preparedMicrophone = nil; await io.stop(); microphoneReady = false; refreshAudioProcessing(); capture?.cancel(); capture = nil
            if let session { await session.close() }
            if let jobID { try? await jobs.cancel(jobID) }
            self.session = nil; busy = false; task = nil
        }
    }
    func stop(reason: String = "Stop button") {
        Self.log.info("Conversation stop requested: \(reason, privacy: .public)")
        capture?.cancel(); capture = nil; task?.cancel()
        let session = session, id = jobID, jobs = jobs, io = io
        Task { await io.stop(); await session?.close(); if let id { try? await jobs.cancel(id) } }
    }
    func checkRepeatedStartupIfRequested() async {
        let continuous = CommandLine.arguments.contains("--check-continuous-preview")
        guard (continuous || CommandLine.arguments.contains("--check-realtime-preview")), !Self.checkedStartup else { return }
        Self.checkedStartup = true
        for cycle in 1...(continuous ? 1 : 3) {
            start()
            let deadline = ContinuousClock.now + .seconds(40)
            while busy && !microphoneReady && ContinuousClock.now < deadline && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard busy && microphoneReady && !Task.isCancelled else {
                stop(reason: "Startup diagnostic failed or interrupted"); Self.log.error("Repeated preview start check failed at cycle \(cycle).")
                return
            }
            let holdUntil = ContinuousClock.now + .seconds(continuous ? 30 : 1)
            while busy && microphoneReady && ContinuousClock.now < holdUntil && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
            guard busy && microphoneReady && !Task.isCancelled else { stop(reason: "Startup diagnostic interrupted during live hold"); Self.log.error("Conversation did not remain live during the startup check."); return }
            stop(reason: "Startup diagnostic completed")
            while busy { try? await Task.sleep(for: .milliseconds(50)) }
            Self.log.info("Repeated preview startup cycle \(cycle) completed with live microphone frames.")
            try? await Task.sleep(for: .milliseconds(300))
        }
        status = continuous ? "Sustained conversation check passed. Ready for a new conversation." : "Three conversation startup checks passed. Ready for a new conversation."
        Self.log.info("Conversation startup check passed; continuous mode \(continuous).")
    }
    private func prepareMicrophone() async throws {
        status = "Starting microphone and local voice processing…"
        activeOptions = .init(echoCancellation: echoCancellationEnabled, voiceFocus: voiceFocusEnabled)
        preparedMicrophone = try await io.start(paused: true, options: activeOptions)
        try Task.checkCancellation()
        status = "Loading the conversation model…"
    }
    private func event(_ event: RealtimeEvent) async throws {
        switch event.type {
        case "session.ready":
            guard let stream = preparedMicrophone else { throw ModelAPIError.unavailable("The microphone was not prepared.") }
            preparedMicrophone = nil
            try Task.checkCancellation()
            await io.setCaptureEnabled(true)
            status = "Waiting for microphone audio…"
            capture = Task { [weak self] in
                do {
                    var first = true
                    for try await frame in stream {
                        guard let session = self?.session else { throw CancellationError() }
                        try await session.receive(.init("input_audio.append", audio: frame.base64EncodedString()))
                        if first {
                            first = false
                            self?.microphoneReady = true; self?.refreshAudioProcessing()
                            self?.status = "Listening · speak when you are ready"
                            Self.log.info("First microphone frame accepted by the conversation model.")
                        }
                    }
                }
                catch is CancellationError {}
                catch { self?.status = error.localizedDescription; self?.stop(reason: "Microphone processing failed") }
            }
        case "input_audio.transcript.delta": userText = String((userText + (event.delta ?? "")).suffix(8000))
        case "response.text.delta": assistantText = String((assistantText + (event.delta ?? "")).suffix(8000))
        case "output_audio.clear": try await io.clear()
        case "output_audio.delta":
            guard let audio = event.audio, let pcm = Data(base64Encoded: audio), let sequence = event.sequence, let epoch = event.epoch else { throw ModelAPIError.invalid("Invalid live audio.") }
            let session = session
            try await io.play(pcm) { Task { try? await session?.receive(.init("playback.ack", sequence: sequence, epoch: epoch)) } }
        case "session.done": status = event.message ?? "Session ended."
        default: break
        }
    }
}

private actor RealtimeAudioIO {
    private(set) var options = LocalVoiceOptions()
    private var engine: AVAudioEngine?
    private var microphone: RealtimeMicrophone?
    private var player: AVAudioPlayerNode?
    private var continuation: AsyncThrowingStream<Data, any Error>.Continuation?
    private var captureBridge: RealtimeCaptureBridge?
    private var activity: NSObjectProtocol?
    func start(paused: Bool = false, options: LocalVoiceOptions = .init()) throws -> AsyncThrowingStream<Data, any Error> {
        stop()
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: "Live local microphone processing")
        var committed = false
        defer { if !committed { stop() } }
        self.options = options
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var outputDevice = AudioDeviceID(0), deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &deviceSize, &outputDevice) == noErr, outputDevice != 0 else { throw ModelAPIError.unavailable("The selected speaker is unavailable.") }
        try engine.outputNode.auAudioUnit.setDeviceID(outputDevice)
        let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(25))
        let bridge = try RealtimeCaptureBridge(source: source, continuation: continuation, enabled: !paused, options: options)
        let microphone = RealtimeMicrophone(bridge: bridge)
        let clock = AVAudioSourceNode(format: source) { @Sendable silence, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            silence.pointee = true
            return noErr
        }
        engine.attach(clock); engine.connect(clock, to: engine.mainMixerNode, format: source)
        engine.attach(player)
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: output)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 480, format: nil) { @Sendable buffer, time in
            if time.isHostTimeValid { bridge.receiveRender(buffer, at: AVAudioTime.seconds(forHostTime: time.hostTime)) }
        }
        do {
            try microphone.start()
            try engine.start()
            try startPlayer(player)
        }
        catch { microphone.stop(); engine.stop(); engine.mainMixerNode.removeTap(onBus: 0); continuation.finish(); throw error }
        self.engine = engine; self.player = player; self.continuation = continuation
        captureBridge = bridge
        self.microphone = microphone
        committed = true
        return stream
    }
    func play(_ pcm: Data, completion: @escaping @Sendable () -> Void) throws {
        guard pcm.count == 3528, let player, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 22050, channels: 1, interleaved: false), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1764) else { throw ModelAPIError.invalid("Invalid speech playback frame.") }
        buffer.frameLength = 1764
        let bytes = [UInt8](pcm)
        for i in 0..<1764 { buffer.floatChannelData![0][i] = Float(Int16(bitPattern: UInt16(bytes[2*i]) | UInt16(bytes[2*i+1]) << 8)) / 32768 }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in completion() }
    }
    func setCaptureEnabled(_ enabled: Bool) { captureBridge?.setEnabled(enabled) }
    private func startPlayer(_ player: AVAudioPlayerNode) throws {
        for _ in 0..<200 where player.lastRenderTime == nil { Thread.sleep(forTimeInterval: 0.01) }
        guard player.lastRenderTime != nil else { throw ModelAPIError.unavailable("The selected speaker did not begin rendering. Check the audio device and retry.") }
        if #available(macOS 27.0, *) { try player.playAudio() }
        else { player.play() }
    }
    func clear() throws { if let player { player.stop(); try startPlayer(player) } }
    func stop() {
        captureBridge?.setEnabled(false); captureBridge = nil
        continuation?.finish(); continuation = nil
        microphone?.stop(); microphone = nil
        player?.stop(); player = nil
        engine?.stop(); engine?.mainMixerNode.removeTap(onBus: 0); engine = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
}


/// Explicit developer check: bounded microphone buffers and silent playback;
/// no models, recordings or transcripts are created.
@MainActor enum RealtimeAudioCheck {
    private static var ran = false
    static func runIfRequested() async {
        let continuous = CommandLine.arguments.contains("--check-continuous-audio")
        guard (continuous || CommandLine.arguments.contains("--check-realtime-audio")), !ran else { return }
        ran = true
        let log = Logger(subsystem: "nl.lucasilverentand.mac-model-api", category: "RealtimeAudioCheck")
        for cycle in 1...(continuous ? 1 : 3) {
            let io = RealtimeAudioIO()
            do {
                let stream = try await io.start(paused: continuous)
                if continuous { try await Task.sleep(for: .seconds(2)); await io.setCaptureEnabled(true) }
                let frames = try await withThrowingTaskGroup(of: Int.self) { group in
                    group.addTask {
                        var count = 0
                        for try await _ in stream { count += 1; if count == (continuous ? 250 : 5) { return count } }
                        throw ModelAPIError.unavailable("Capture ended before five frames.")
                    }
                    group.addTask { try await Task.sleep(for: .seconds(continuous ? 30 : 5)); throw ModelAPIError.unavailable("Microphone check timed out.") }
                    let count = try await group.next()!
                    group.cancelAll(); return count
                }
                let (played, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                try await io.play(Data(repeating: 0, count: 3528)) { completion.yield(()); completion.finish() }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { for await _ in played { return }; throw ModelAPIError.unavailable("Playback check ended early.") }
                    group.addTask { try await Task.sleep(for: .seconds(3)); throw ModelAPIError.unavailable("Playback check timed out.") }
                    _ = try await group.next(); group.cancelAll()
                }
                try await io.clear()
                let options = await io.options
                log.info("Audio lifecycle cycle \(cycle): \(frames) capture frames and silent playback acknowledged; independent echo cancellation \(options.echoCancellation), neural cleanup \(options.voiceFocus).")
                await io.stop()
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                await io.stop(); log.error("Audio lifecycle check failed: \(error.localizedDescription, privacy: .public)"); return
            }
        }
        if continuous { log.info("Continuous audio check completed: 20 seconds of cleaned capture on one persistent input queue.") }
        else { log.info("Three audio lifecycle cycles completed.") }
    }
}
