import Foundation
import Observation
import ModelAPI
import ModelService

@MainActor @Observable
final class ModelTestStore {
    enum Result {
        case generation(GenerationResponse)
        case decision(DecisionResponse, [String:String])
        case embedding(EmbeddingResponse)
        case transcription(Transcript)
        case speech(UUID)
    }
    let modelID: String
    let capability: ModelCapability?
    let capture = AudioCapture()
    var input: String
    var question = "Which team should handle this request?"
    var choices = "Technical support\nBilling"
    var language = "en"
    var reasoning: ReasoningLevel = .moderate
    var result: Result?
    var job: ModelJob?
    var error = ""
    var busy = false
    @ObservationIgnored private weak var app: AppStore?
    @ObservationIgnored private var work: Task<Void,Never>?
    init(model: ManagedModel, app: AppStore) {
        modelID = model.id; capability = model.capability; self.app = app
        switch model.capability {
        case .speech: input = "Hello! This is a short sample from Positronic."
        case .embedding: input = "A walk through the forest\nA hike among the trees"
        case .decision: input = "A customer needs help fixing a login error."
        default: input = "Write one friendly sentence about a helpful robot."
        }
    }
    func changeLanguage(_ value: String) {
        language = value
        let samples = ["Hello! This is a short sample from Positronic.","Hallo! Dit is een kort voorbeeld van Positronic."]
        if capability == .speech, samples.contains(input) { input = samples[value == "nl" ? 1 : 0] }
    }
    func cancel() { work?.cancel(); capture.cancel() }
    func refresh() async {
        guard !busy, let id = job?.id, let app else { return }
        do { job = try await app.jobs.job(id) }
        catch is JobNotFound { job = nil; result = nil; error = "This sample expired. Run another test." }
        catch {}
    }
    func run(file: URL? = nil, imported: Bool = false) {
        guard !busy, let app, let capability else { return }
        busy = true; error = ""; result = nil; job = nil
        let text = input, language = language, question = question, choices = choices, reasoning = reasoning
        work = Task { [self] in
            var staged: URL? = imported ? nil : file
            var accepted = false
            defer {
                if !accepted, let staged { try? FileManager.default.removeItem(at: staged) }
                busy = false; work = nil
            }
            do {
                guard app.queueReady, !app.managingModels else { throw ModelAPIError.unavailable("Wait for model management to finish.") }
                if !["apple","apple-pcc"].contains(modelID), !app.installedModels.contains(where: { $0.id == modelID }) { throw ModelAPIError.unavailable("This model is no longer installed.") }
                let config = try app.configuration.forModelTest(modelID, capability: capability)
                let audio = AudioService(runtime: app.audioRuntime, queue: app.jobs, enabled: config.audioModels)
                var decisionLabels: [String:String] = [:]
                let submitted: ModelJob
                switch capability {
                case .speech:
                    submitted = try await audio.submitSpeech(.init(model: modelID, input: text, language: language))
                case .transcription:
                    guard let file else { throw ModelAPIError.invalid("Import or record an audio sample.") }
                    if imported { staged = try await Self.importAudio(file) } else { staged = file }
                    submitted = try await audio.submitTranscription(file: staged!, model: modelID, language: language)
                case .generation, .decision, .embedding:
                    let engine = try app.makeEngine(configuration: config)
                    let request: JobSubmission
                    switch capability {
                    case .generation:
                        let value = GenerationRequest(model:modelID,prompt:text,maxTokens:256,reasoningLevel:modelID == "apple-pcc" ? reasoning : nil)
                        try value.validate(); request = .init(operation:"generation",request:try Self.json(value))
                    case .decision:
                        let value = try ModelTestInput.decision(model:modelID,text:text,question:question,choices:choices)
                        decisionLabels = value.questions["result"]!.criteria
                        request = .init(operation:"decision",request:try Self.json(value))
                    case .embedding:
                        let value = EmbeddingRequest(model:modelID,input:text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty })
                        try value.validate(); request = .init(operation:"embedding",request:try Self.json(value))
                    default: throw ModelAPIError.invalid("Unsupported sample type.")
                    }
                    try await engine.validateJob(request)
                    let budget = await engine.budget(for:modelID)
                    submitted = try await app.jobs.submit(model:modelID,operation:"Test · " + capability.title,budget:budget) { _ in
                        let data = try JSONEncoder().encode(request.request)
                        switch capability {
                        case .generation: return try .json(await engine.generate(JSONDecoder().decode(GenerationRequest.self,from:data)))
                        case .decision: return try .json(await engine.decide(JSONDecoder().decode(DecisionRequest.self,from:data)))
                        case .embedding: return try .json(await engine.embed(JSONDecoder().decode(EmbeddingRequest.self,from:data)))
                        default: throw ModelAPIError.invalid("Unsupported sample type.")
                        }
                    }
                }
                job = submitted; accepted = true
                while true {
                    try Task.checkCancellation()
                    job = try await app.jobs.job(submitted.id)
                    if job?.state.terminal == true { break }
                    try await Task.sleep(for:.milliseconds(300))
                }
                let output = try await app.jobs.wait(submitted.id)
                try Task.checkCancellation()
                switch capability {
                case .generation: result = .generation(try JSONDecoder().decode(GenerationResponse.self,from:output.data))
                case .decision: result = .decision(try JSONDecoder().decode(DecisionResponse.self,from:output.data),decisionLabels)
                case .embedding: result = .embedding(try JSONDecoder().decode(EmbeddingResponse.self,from:output.data))
                case .transcription: result = .transcription(try JSONDecoder().decode(Transcript.self,from:output.data))
                case .speech: result = .speech(submitted.id)
                }
            } catch is CancellationError {
                if let id = job?.id { try? await app.jobs.cancel(id); job = try? await app.jobs.job(id) }
            } catch is QueueFull { error = "The job queue is full. Wait for a sample to finish." }
            catch { self.error = error.localizedDescription }
        }
    }
    private static func json<T:Encodable>(_ value:T) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value)) }
    private static func importAudio(_ source: URL) async throws -> URL {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let task = Task.detached(priority:.utility) {
            try AudioIO.validate(source)
            try ResourceMonitor.requireDisk(at:AudioCatalog.jobsDirectory,additional:128 << 20)
            let destination = AudioCatalog.jobsDirectory.appendingPathComponent(UUID().uuidString + ".upload")
            var complete = false
            defer { if !complete { try? FileManager.default.removeItem(at:destination) } }
            FileManager.default.createFile(atPath:destination.path,contents:nil,attributes:[.posixPermissions:0o600])
            let input = try FileHandle(forReadingFrom:source), output = try FileHandle(forWritingTo:destination)
            defer { try? input.close(); try? output.close() }
            var count = 0
            while let bytes = try input.read(upToCount:65536), !bytes.isEmpty {
                try Task.checkCancellation(); count += bytes.count
                guard count <= AudioIO.uploadLimit else { throw ModelAPIError.limit("Audio exceeds 64 MiB.") }
                try output.write(contentsOf:bytes)
            }
            complete = true; return destination
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel:{ task.cancel() }
    }
}
