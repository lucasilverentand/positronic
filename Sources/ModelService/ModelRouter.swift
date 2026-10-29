import Foundation
import ModelAPI

public actor ModelRouter {
    private let keys: APIKeys
    private var engine: any ModelEngine
    public let jobs: JobQueue
    private let audio: AudioService?
    private var active = 0
    public init(keys: APIKeys, engine: any ModelEngine, jobs: JobQueue = JobQueue(), audio: AudioService? = nil) {
        self.keys = keys; self.engine = engine; self.jobs = jobs; self.audio = audio
    }
    public func update(engine: any ModelEngine) { self.engine = engine }
    public func authorizeUpload(_ request: HTTPRequest) async -> Bool { guard request.headers["origin"] == nil else { return false }; return await keys.accepts(request.bearer) }
    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        guard request.headers["origin"] == nil, let owner = await keys.identity(for: request.bearer) else { return .error("API key required.", status: 401) }
        do {
            if request.method == "GET", request.path == "/v1/models" { return try .json(await engine.models()) }
            if request.method == "GET", request.path == "/v1/jobs" { return try .json(await jobs.list(owner: owner)) }
            let parts = request.path.split(separator: "/")
            if parts.count >= 3, parts[0] == "v1", parts[1] == "jobs", let id = UUID(uuidString: String(parts[2])) {
                if request.method == "GET", parts.count == 3 { return try .json(await jobs.job(id, owner: owner)) }
                if request.method == "POST", parts.count == 4, parts[3] == "cancel" {
                    try await jobs.cancel(id, owner: owner); return try .json(await jobs.job(id, owner: owner))
                }
                if request.method == "GET", parts.count == 4, parts[3] == "result" {
                    guard try await jobs.job(id, owner: owner).state == .succeeded else { return .error("The job has no completed result.", status: 409) }
                    let result = try await jobs.result(id, owner: owner)
                    if let file = result.file { return .init(file: file, type: result.type) }
                    return .init(type: result.type, body: result.data)
                }
                return .error("Endpoint not found.", status: 404)
            }
            guard request.method == "POST" else { return .error("Endpoint not found.", status: 404) }
            if request.path == "/v1/audio/transcriptions" {
                guard let audio, let body = request.upload, let contentType = request.headers["content-type"] else { throw ModelAPIError.invalid("Upload multipart audio with file, model and language fields.") }
                let upload = try MultipartAudio.parse(file: body, contentType: contentType, directory: AudioCatalog.jobsDirectory)
                do { return try .json(await audio.submitTranscription(file: upload.file, model: upload.model, language: upload.language, owner: owner), status: 202) }
                catch { try? FileManager.default.removeItem(at: upload.file); throw error }
            }
            guard request.headers["content-type"]?.lowercased().split(separator: ";").first == "application/json" else { return .error("Use application/json.", status: 415) }
            if request.path == "/v1/audio/speech" {
                guard let audio else { throw ModelAPIError.unavailable("Local audio is not configured.") }
                return try .json(await audio.submitSpeech(JSONDecoder().decode(SpeechRequest.self, from: request.body), owner: owner), status: 202)
            }
            let submission: JobSubmission
            let asynchronous = request.path == "/v1/jobs"
            if asynchronous { submission = try JSONDecoder().decode(JobSubmission.self, from: request.body) }
            else {
                let operation: String
                switch request.path { case "/v1/generate": operation = "generation"; case "/v1/embeddings": operation = "embedding"; case "/v1/decisions", "/v1/systemone": operation = "decision"; default: return .error("Endpoint not found.", status: 404) }
                submission = .init(operation: operation, request: try JSONDecoder().decode(JSONValue.self, from: request.body))
                guard active < 4 else { return .error("Four synchronous requests are already waiting; use the jobs API.", status: 429) }
            }
            guard let model = submission.request.object?["model"]?.string else { throw ModelAPIError.invalid("Supply a model.") }
            try validate(submission)
            try await engine.validateJob(submission)
            let budget = await engine.budget(for: model)
            let job = try await jobs.submit(model: model, operation: submission.operation, owner: owner, budget: budget) { [self] _ in try await execute(submission) }
            if asynchronous { return try .json(job, status: 202) }
            active += 1; defer { active -= 1 }
            let result = try await jobs.wait(job.id)
            return .init(type: result.type, body: result.data)
        } catch is QueueFull { return .error("The job queue already contains 32 waiting jobs.", status: 429) }
        catch is JobNotFound { return .error("Job not found.", status: 404) }
        catch let error as ModelAPIError {
            let status: Int
            switch error { case .invalid: status = 400; case .limit: status = 413; case .unauthorized: status = 401; case .unavailable: status = 503 }
            return .error(error.localizedDescription, status: status)
        } catch is DecodingError { return .error("Invalid JSON request or model response.", status: 400) }
        catch is CancellationError { return .error("Request cancelled.", status: 503) }
        catch { return .error("Model request failed. Check local model availability and resources.", status: 503) }
    }
    private func validate(_ submission: JobSubmission) throws {
        let data = try JSONEncoder().encode(submission.request)
        switch submission.operation {
        case "generation": try JSONDecoder().decode(GenerationRequest.self, from: data).validate()
        case "embedding": try JSONDecoder().decode(EmbeddingRequest.self, from: data).validate()
        case "decision":
            let value = try JSONDecoder().decode(DecisionRequest.self, from: data)
            guard !value.questions.isEmpty, value.questions.count <= 32, data.count <= 65536, value.questions.values.allSatisfy({ $0.type == "choice" && !$0.instructions.isEmpty && (2...26).contains($0.criteria.count) }) else { throw ModelAPIError.invalid("Invalid decision request.") }
        default: throw ModelAPIError.invalid("Choose generation, embedding or decision.")
        }
    }
    private func execute(_ submission: JobSubmission) async throws -> JobResult {
        let data = try JSONEncoder().encode(submission.request)
        switch submission.operation {
        case "generation": return try .json(await engine.generate(JSONDecoder().decode(GenerationRequest.self, from: data)))
        case "embedding": return try .json(await engine.embed(JSONDecoder().decode(EmbeddingRequest.self, from: data)))
        case "decision": return try .json(await engine.decide(JSONDecoder().decode(DecisionRequest.self, from: data)))
        default: throw ModelAPIError.invalid("Unknown operation.")
        }
    }
}
