import Foundation
import ModelAPI

public actor AudioService {
    public let runtime: AudioRuntime
    public let queue: JobQueue
    private var enabled: [String]
    public init(runtime: AudioRuntime, queue: JobQueue, enabled: [String] = []) { self.runtime = runtime; self.queue = queue; self.enabled = enabled }
    public func update(enabled: [String]) { self.enabled = enabled }
    public func submitSpeech(_ request: SpeechRequest, owner: UUID? = nil) async throws -> ModelJob {
        try request.validate(); try require(request.model)
        let output = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        return try await queue.submit(model: request.model, operation: "speech", owner: owner, budget: AudioCatalog.budget(request.model), disk: 64 * 1024 * 1024, cleanup: { try? FileManager.default.removeItem(at: output) }) { [runtime, queue] id in
            await queue.update(id, state: .loading)
            return try await runtime.speech(request, output: output) { event in await Self.progress(event, id: id, queue: queue) }
        }
    }
    public func submitTranscription(file: URL, model: String = "whisper-large-v3-turbo", language: String, owner: UUID? = nil) async throws -> ModelJob {
        try require(model)
        guard model == "whisper-large-v3-turbo", ["en", "nl"].contains(language) else { throw ModelAPIError.invalid("Choose Whisper and language en or nl.") }
        try AudioIO.validate(file)
        let normalized = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let output = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".json")
        return try await queue.submit(model: model, operation: "transcription", owner: owner, budget: AudioCatalog.budget(model), disk: 64 * 1024 * 1024, cleanup: {
            for url in [file, normalized, output] { try? FileManager.default.removeItem(at: url) }
        }) { [runtime, queue] id in
            await queue.update(id, state: .loading, message: "Preparing audio.")
            try await AudioIO.normalize(file, to: normalized)
            return try await runtime.transcribe(model: model, file: normalized, language: language, output: output) { event in await Self.progress(event, id: id, queue: queue) }
        }
    }
    private func require(_ model: String) throws {
        guard enabled.contains(model), AudioCatalog.installed().contains(where: { $0.id == model }) else { throw ModelAPIError.unavailable("Download and enable this local audio model in Your models first.") }
    }
    private static func progress(_ event: JSONValue, id: UUID, queue: JobQueue) async {
        switch event.object?["event"]?.string {
        case "loading": await queue.update(id, state: .loading, message: "Loading the local audio model.")
        case "loaded", "running": await queue.update(id, state: .running, message: "Processing audio locally.")
        case "progress": await queue.update(id, progress: event.object?["progress"]?.numberValue)
        default: break
        }
    }
}
