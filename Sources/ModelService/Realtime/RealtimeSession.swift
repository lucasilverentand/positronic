import Foundation
import ModelAPI

public protocol RealtimeBackend: Sendable {
    func begin(_ configuration: RealtimeConfiguration) async throws
    func step(_ pcm: Data) async throws -> [RealtimeEvent]
    func end() async
}
public struct LocalRealtimeBackend: RealtimeBackend {
    let runtime: AudioRuntime
    public init(runtime: AudioRuntime) { self.runtime = runtime }
    public func begin(_ configuration: RealtimeConfiguration) async throws { try await runtime.beginRealtime(configuration) }
    public func step(_ pcm: Data) async throws -> [RealtimeEvent] { try await runtime.stepRealtime(pcm) }
    public func end() async { await runtime.stop() }
}

/// One admitted session owns the shared inference slot. Incoming audio stays live
/// while inference awaits the worker; neither prompts nor PCM are retained on disk.
public actor RealtimeSession {
    public typealias Emit = @Sendable (RealtimeEvent) async throws -> Void
    private let backend: any RealtimeBackend
    private let emit: Emit
    private let prepareAudio: (@Sendable () async throws -> Void)?
    private var input: [(pcm: Data, received: ContinuousClock.Instant, sequence: Int)] = []
    private var activated: Bool
    private var awaitingFirstSpeech: Bool
    private var ready = false
    private var closed = false
    private var committed = false
    private var lastInput = ContinuousClock.now
    private var inputSequence = 0
    private var lastVoicedInput = 0
    private var processedInput = 0
    private var sequence = 0
    private var acknowledged = 0
    private var epoch = 0
    private var voiceFrames = 0
    private var silenceFrames = 0
    private var speaking = false
    private var muted = false
    private var outputAge: ContinuousClock.Instant?
    public init(backend: any RealtimeBackend, startPaused: Bool = false, waitForSpeech: Bool = false, prepareAudio: (@Sendable () async throws -> Void)? = nil, emit: @escaping Emit) { self.backend = backend; self.emit = emit; self.prepareAudio = prepareAudio; activated = !startPaused; awaitingFirstSpeech = waitForSpeech }
    public func activate() { activated = true }
    public func receive(_ event: RealtimeEvent) async throws {
        guard !closed else { throw CancellationError() }
        switch event.type {
        case "input_audio.append":
            guard ready, !committed else { throw ModelAPIError.invalid("Wait for session.ready before sending microphone frames.") }
            guard let raw = event.audio, raw.utf8.count <= 3420, let pcm = Data(base64Encoded: raw), pcm.count == 2560 else { throw ModelAPIError.invalid("Send exactly 1280 PCM16 samples at 16 kHz.") }
            guard input.count < 25 else { throw ModelAPIError.limit("Input is over two seconds behind; reconnect rather than accumulating stale audio.") }
            inputSequence += 1; input.append((pcm, .now, inputSequence)); lastInput = .now
            // Detect a real onset before awaiting the worker; flush already queued
            // playback immediately. Echo cancellation belongs to the capture client.
            if Self.rms(pcm) >= 0.02 { lastVoicedInput = inputSequence; voiceFrames += 1; silenceFrames = 0 }
            else { voiceFrames = 0; silenceFrames += 1 }
            if voiceFrames >= 2 && !speaking {
                awaitingFirstSpeech = false
                speaking = true; muted = false; epoch += 1; acknowledged = sequence; outputAge = nil
                try await emit(.init("input_audio.speech_started", epoch: epoch))
                try await emit(.init("output_audio.clear", sequence: sequence, epoch: epoch))
            }
            if speaking && silenceFrames >= 4 { speaking = false; try await emit(.init("input_audio.speech_stopped", epoch: epoch)) }
        case "playback.ack":
            guard let value = event.sequence, let eventEpoch = event.epoch, value >= 0, value <= sequence else { throw ModelAPIError.invalid("Invalid playback acknowledgement.") }
            if eventEpoch == epoch, value > acknowledged { acknowledged = value; outputAge = acknowledged == sequence ? nil : .now }
        case "response.cancel":
            muted = true; epoch += 1; acknowledged = sequence; outputAge = nil
            try await emit(.init("output_audio.clear", sequence: sequence, epoch: epoch))
        case "input_audio.commit": committed = true
        case "session.cancel": closed = true
        case "session.ping": try await emit(.init("session.pong"))
        default: throw ModelAPIError.invalid("Unknown realtime event type.")
        }
    }
    public func close() { closed = true; input = [] }
    public func run(_ configuration: RealtimeConfiguration) async throws {
        do {
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            while !activated { try Task.checkCancellation(); guard !closed else { throw CancellationError() }; try await Task.sleep(for: .milliseconds(5)) }
            try await prepareAudio?()
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            try await backend.begin(configuration)
            try Task.checkCancellation(); guard !closed else { throw CancellationError() }
            ready = true; lastInput = .now
            try await emit(.init("session.ready", session: configuration, sampleRate: 16000, frameSamples: 1280))
            let start = ContinuousClock.now; var next = start
            while !closed {
                try Task.checkCancellation()
                guard start.duration(to: .now) < .seconds(configuration.maxDurationSeconds) else { break }
                if committed && input.isEmpty { break }
                guard lastInput.duration(to: .now) < .seconds(10) else { throw ModelAPIError.unavailable("No microphone frames for ten seconds; session closed.") }
                guard input.first.map({ $0.received.duration(to: .now) < .seconds(2) }) ?? true else { throw ModelAPIError.unavailable("Local inference cannot keep up with live input; session stopped instead of falling behind.") }
                if awaitingFirstSpeech {
                    // Keep a short lead-in, but do not advance the model or play
                    // its seeded greeting before the local operator speaks.
                    if input.count > 4 { input.removeFirst(input.count - 4) }
                    next = .now
                    try await Task.sleep(for: .milliseconds(20))
                    continue
                }
                guard sequence - acknowledged < 25, outputAge.map({ $0.duration(to: .now) < .seconds(2) }) ?? true else { throw ModelAPIError.unavailable("Playback is behind; acknowledge played audio or reconnect.") }
                let pcm: Data
                if input.isEmpty { pcm = Data(repeating: 0, count: 2560) }
                else { let frame = input.removeFirst(); pcm = frame.pcm; processedInput = frame.sequence }
                let startedEpoch = epoch
                let events = try await backend.step(pcm)
                try Task.checkCancellation(); guard !closed else { throw CancellationError() }
                for var event in events {
                    if event.type == "output_audio.delta" {
                        guard !muted, !speaking, startedEpoch == epoch, processedInput >= lastVoicedInput else { continue }
                        guard let audio = event.audio, let data = Data(base64Encoded: audio), data.count == 3528 else { throw ModelAPIError.invalid("The worker returned an invalid audio frame.") }
                        sequence += 1; event.sequence = sequence; event.epoch = epoch
                        if outputAge == nil { outputAge = .now }
                    }
                    try await emit(event)
                }
                next += .milliseconds(80)
                // Bounded lag: do not replay a backlog of old clock ticks in a burst.
                if next < .now { next = .now }
                try await ContinuousClock().sleep(until: next)
            }
            // Let the client finish the final bounded playback before closing
            // its transport; an acknowledgement can otherwise race socket close.
            let drainDeadline = ContinuousClock.now + .seconds(2)
            while !closed && acknowledged < sequence {
                try Task.checkCancellation()
                guard ContinuousClock.now < drainDeadline else { throw ModelAPIError.unavailable("Playback did not finish within two seconds.") }
                try await Task.sleep(for: .milliseconds(10))
            }
            ready = false; input = []; await backend.end()
            try Task.checkCancellation()
            if closed { throw CancellationError() }
            try await emit(.init("session.done", message: "Session ended. Reconnect for a fresh bounded context."))
        } catch {
            ready = false; input = []; await backend.end(); throw error
        }
    }
    private static func rms(_ pcm: Data) -> Double {
        let bytes = [UInt8](pcm); var total = 0.0
        for index in stride(from: 0, to: bytes.count, by: 2) {
            let value = Double(Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index+1]) << 8)) / 32768
            total += value * value
        }
        return sqrt(total / Double(bytes.count / 2))
    }
}

public struct RealtimeService: Sendable {
    private let jobs: JobQueue
    private let backend: any RealtimeBackend
    private let validate: @Sendable (String) async throws -> Void
    public init(jobs: JobQueue, backend: any RealtimeBackend, validate: @escaping @Sendable (String) async throws -> Void = { model in
        guard model == RealtimeConfiguration.modelID, AudioCatalog.realtimeReady, AudioCatalog.installed().contains(where: { $0.id == model }) else { throw ModelAPIError.unavailable("Explicitly prepare the updated audio runtime and download Nemotron VoiceChat first.") }
    }) { self.jobs = jobs; self.backend = backend; self.validate = validate }
    public func submit(_ configuration: RealtimeConfiguration, owner: UUID? = nil, session: RealtimeSession) async throws -> ModelJob {
        try configuration.validate(); try await validate(configuration.model)
        return try await jobs.submit(model: configuration.model, operation: "realtime", owner: owner, budget: AudioCatalog.realtimeBudget(seconds: configuration.maxDurationSeconds), staged: true, profile: AudioCatalog.profileContext(configuration.model, seconds: Double(configuration.maxDurationSeconds))) { _ in
            try await session.run(configuration)
            return try .json(["status": "ended"])
        }
    }
    public func makeSession(startPaused: Bool = false, waitForSpeech: Bool = false, prepareAudio: (@Sendable () async throws -> Void)? = nil, emit: @escaping RealtimeSession.Emit) -> RealtimeSession { RealtimeSession(backend: backend, startPaused: startPaused, waitForSpeech: waitForSpeech, prepareAudio: prepareAudio, emit: emit) }
    public func serve(_ socket: RealtimeSocket, owner: UUID, enabled: @escaping @Sendable (String) async -> Bool) async {
        let session = makeSession(startPaused: true) { try await socket.send($0) }
        var jobID: UUID?
        var observer: Task<Void, Never>?
        let timeout = Task { do { try await Task.sleep(for: .seconds(1235)); socket.close() } catch {} }
        do {
            try await socket.send(.init("session.created", message: "Positronic realtime v1. Configure before sending PCM."))
            let configureDeadline = Task { do { try await Task.sleep(for: .seconds(10)); socket.close() } catch {} }
            defer { configureDeadline.cancel() }
            var configuration: RealtimeConfiguration?
            // A message may be split across several network reads. Preserve framing.
            while configuration == nil {
                for event in try await socket.receive() {
                    guard event.type == "session.configure", configuration == nil, let value = event.session else { throw ModelAPIError.invalid("Send session.configure exactly once before audio.") }
                    configuration = value
                }
            }
            configureDeadline.cancel()
            guard let configuration, await enabled(configuration.model) else { throw ModelAPIError.invalid("This conversation model is not enabled for API clients.") }
            let job = try await submit(configuration, owner: owner, session: session); jobID = job.id
            try await socket.send(.init("session.queued", job: job))
            await session.activate()
            observer = Task {
                var previous: JobState?
                var lastReport = ContinuousClock.now
                while !Task.isCancelled {
                    do {
                        let status = try await jobs.job(job.id, owner: owner)
                        if status.state != previous || (!status.state.terminal && lastReport.duration(to: .now) >= .seconds(2)) { try await socket.send(.init("session.status", job: status)); previous = status.state; lastReport = .now }
                        if status.state.terminal {
                            if status.state != .succeeded { try? await socket.send(.init("session.error", job: status, message: status.message)) }
                            socket.close(); return
                        }
                        try await Task.sleep(for: .milliseconds(250))
                    } catch { socket.close(); return }
                }
            }
            while !Task.isCancelled { for event in try await socket.receive() { try await session.receive(event) } }
        } catch is QueueFull {
            try? await socket.send(.init("session.error", message: "The shared queue already contains 32 waiting jobs."))
        } catch is CancellationError {} catch {
            try? await socket.send(.init("session.error", message: (error as? ModelAPIError)?.localizedDescription ?? "Realtime connection failed."))
        }
        timeout.cancel(); observer?.cancel(); await session.close(); socket.close()
        if let jobID { try? await jobs.cancel(jobID, owner: owner) }
    }
}
