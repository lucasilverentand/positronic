import Foundation
import ModelAPI

public protocol ModelEngine: Sendable {
    func validateJob(_ submission: JobSubmission) async throws
    func budget(for model: String) async -> Int64?
    func models() async -> [ModelInfo]
    func generate(_ value: GenerationRequest) async throws -> GenerationResponse
    func decide(_ value: DecisionRequest) async throws -> DecisionResponse
    func embed(_ value: EmbeddingRequest) async throws -> EmbeddingResponse
}
public extension ModelEngine {
    func validateJob(_ submission: JobSubmission) async throws {}
    func budget(for model: String) async -> Int64? { 0 }
    func embed(_ value: EmbeddingRequest) async throws -> EmbeddingResponse { throw ModelAPIError.unavailable("Embeddings are unavailable in this engine.") }
}

public struct LocalModelEngine: ModelEngine {
    private let configuration: ServiceConfiguration
    private let apple: any AppleModelBackend
    private let transport: ModelAPIClient.Transport
    private let activity: ModelActivity
    private let contextTokens: Int
    private let budgetProvider: (@Sendable (String) async -> Int64?)?
    public init(configuration: ServiceConfiguration, contextTokens: Int = OllamaMemoryEstimate.defaultContext, budgetProvider: (@Sendable (String) async -> Int64?)? = nil, transport: ModelAPIClient.Transport? = nil, activity: ModelActivity = .init(), apple: any AppleModelBackend = AppleModel()) throws {
        guard (512...8192).contains(contextTokens) else { throw ModelAPIError.invalid("Local context must be between 512 and 8192 tokens.") }
        self.contextTokens = contextTokens
        try configuration.validate(); self.configuration = configuration; self.transport = transport ?? HTTPTransport.send; self.activity = activity; self.apple = apple; self.budgetProvider = budgetProvider
    }
    private func call<T: Decodable>(_ path: String, value: JSONValue? = nil, decode: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: configuration.ollamaURL)!.appendingPathComponent(path))
        request.timeoutInterval = 115
        if let value {
            request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(value)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw ModelAPIError.unavailable("Local runtime returned HTTP \(response.statusCode).") }
        guard data.count <= 1_000_000 else { throw ModelAPIError.limit("Local model response exceeds 1 MB.") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    public func validateJob(_ submission: JobSubmission) async throws {
        guard let model = submission.request.object?["model"]?.string else { throw ModelAPIError.invalid("Supply a model.") }
        let allowed: Bool
        switch submission.operation {
        case "generation":
            if model == "apple-pcc", !configuration.allowApplePCC { throw ModelAPIError.unavailable("Private Cloud Compute is disabled.") }
            allowed = ["apple", "apple-pcc"].contains(model) || configuration.generationModels.contains(model)
        case "embedding": allowed = configuration.embeddingModels.contains(model)
        case "decision": allowed = configuration.decisionModels.contains(model)
        default: allowed = false
        }
        guard allowed else { throw ModelAPIError.invalid("The selected model is not enabled for this operation.") }
    }
    public func budget(for model: String) async -> Int64? {
        if let budgetProvider { return await budgetProvider(model) }
        if JobExecution.queueID == activity.jobs.identity { return 0 }
        if model == "apple" { return 4 * 1024 * 1024 * 1024 }
        if model == "apple-pcc" { return 1 * 1024 * 1024 * 1024 }
        guard let raw = try? await call("api/tags", decode: JSONValue.self), case .array(let models) = raw.object?["models"],
              let tag = models.first(where: { $0.object?["name"]?.string == model }), let size = tag.object?["size"]?.numberValue,
              size.isFinite, size > 0, size < 1e12 else { return nil }
        if let metadata = try? await call("api/show", value: .object(["model": .string(model)]), decode: JSONValue.self) {
            if let estimate = OllamaMemoryEstimate.muse(weights: Int64(size), metadata: metadata, context: contextTokens) {
                return estimate.total
            }
            if tag.object?["digest"]?.string == OllamaMemoryEstimate.nvfp4Revision,
               let version = try? await call("api/version", decode: JSONValue.self),
               let estimate = OllamaMemoryEstimate.museNVFP4(weights: Int64(size), metadata: metadata, context: contextTokens,
                    revision: tag.object?["digest"]?.string, runtime: version.object?["version"]?.string) {
                return estimate.total
            }
        }
        return Int64(size * 1.35) + 2 * 1024 * 1024 * 1024
    }
    public func models() async -> [ModelInfo] {
        let tags = try? await call("api/tags", decode: JSONValue.self)
        var installed = Set<String>()
        if case .array(let entries) = tags?.object?["models"] { installed = Set(entries.compactMap { $0.object?["name"]?.string }) }
        var result = [await apple.status(), await apple.cloudStatus(enabled: configuration.allowApplePCC)]
        for (names, capability) in [(configuration.generationModels, "generation"), (configuration.decisionModels, "decision"), (configuration.embeddingModels, "embedding")] {
            result += names.map { .init(id: $0, capability: capability, available: installed.contains($0), detail: installed.contains($0) ? "Installed in the local runtime" : "Not found in the local runtime") }
        }
        for id in configuration.audioModels {
            let preset = AudioCatalog.presets.first { $0.id == id }
            let available = (id == RealtimeConfiguration.modelID ? AudioCatalog.realtimeReady : AudioCatalog.runtimeReady) && AudioCatalog.installed().contains { $0.id == id }
            result.append(.init(id: id, capability: preset?.capability.rawValue ?? "audio", available: available, detail: available ? (id == RealtimeConfiguration.modelID ? "Local full-duplex · English · built-in LLM" : "Local MLX Audio · English / Dutch") : "Download this local audio model first."))
        }
        return result
    }
    public func embed(_ value: EmbeddingRequest) async throws -> EmbeddingResponse {
        try value.validate()
        try await validateJob(.init(operation: "embedding", request: .object(["model": .string(value.model)])))
        return try await activity.withInference(model: value.model, budget: await budget(for: value.model)) { try await performEmbedding(value) }
    }
    private func performEmbedding(_ value: EmbeddingRequest) async throws -> EmbeddingResponse {
        try value.validate()
        guard configuration.embeddingModels.contains(value.model) else { throw ModelAPIError.invalid("This embedding model is not enabled.") }
        let body: JSONValue = .object(["model": .string(value.model), "input": .array(value.input.map(JSONValue.string)), "truncate": .bool(false)])
        let raw = try await call("api/embed", value: body, decode: JSONValue.self)
        guard let vectors = raw.object?["embeddings"] else { throw ModelAPIError.invalid("Embedding response is missing vectors.") }
        let embeddings = try JSONDecoder().decode([[Double]].self, from: JSONEncoder().encode(vectors))
        let result = EmbeddingResponse(model: raw.object?["model"]?.string ?? "", embeddings: embeddings,
                                      usage: .init(input: raw.object?["prompt_eval_count"]?.numberValue.flatMap(Int.init(exactly:)), output: nil))
        try result.validate(for: value); return result
    }
    public func generate(_ value: GenerationRequest) async throws -> GenerationResponse {
        try value.validate()
        try await validateJob(.init(operation: "generation", request: .object(["model": .string(value.model)])))
        return try await activity.withInference(model: value.model, budget: await budget(for: value.model)) { try await performGeneration(value) }
    }
    private func performGeneration(_ value: GenerationRequest) async throws -> GenerationResponse {
        try value.validate()
        if value.model == "apple" { return try await apple.generate(value) }
        if value.model == "apple-pcc" {
            guard configuration.allowApplePCC else { throw ModelAPIError.unavailable("Apple Private Cloud Compute is disabled. Enable it in Positronic’s Models page.") }
            let status = await apple.cloudStatus(enabled: true)
            guard status.available else { throw ModelAPIError.unavailable(status.detail) }
            return try await apple.generateCloud(value)
        }
        guard configuration.generationModels.contains(value.model) else { throw ModelAPIError.invalid("This generation model is not enabled.") }
        var body: [String: JSONValue] = ["model": .string(value.model), "prompt": .string(value.prompt), "stream": .bool(false),
                                       "options": .object(["num_predict": .number(Double(value.maxTokens ?? 600)), "num_ctx": .number(Double(contextTokens)), "num_batch": .number(Double(OllamaMemoryEstimate.batchTokens))])]
        if let instructions = value.instructions { body["system"] = .string(instructions) }
        if let schema = value.schema { body["format"] = schema }
        if let think = value.think { body["think"] = think }
        else if let metadata = try? await call("api/show", value: .object(["model": .string(value.model)]), decode: JSONValue.self),
                case .array(let modes) = metadata.object?["thinking"]?.object?["values"], modes.contains(.bool(false)) {
            // Prefer a bounded final answer when this model explicitly supports it.
            body["think"] = .bool(false)
        }
        let result = try await call("api/generate", value: .object(body), decode: JSONValue.self)
        guard result.object?["model"]?.string == value.model, result.object?["done"]?.bool == true,
              let text = result.object?["response"]?.string else { throw ModelAPIError.invalid("Local generation response is incomplete or has a different model.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelAPIError.limit("The model produced no final answer within maxTokens. Increase the budget or choose a supported think mode.")
        }
        let content: JSONValue?
        do { content = value.schema == nil ? nil : try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }
        catch { throw ModelAPIError.unavailable("The model returned incomplete structured output. Increase maxTokens or choose a supported think mode.") }
        return .init(model: value.model, text: text, content: content,
                     usage: .init(input: result.object?["prompt_eval_count"]?.numberValue.flatMap(Int.init(exactly:)),
                                  output: result.object?["eval_count"]?.numberValue.flatMap(Int.init(exactly:))))
    }
    public func decide(_ value: DecisionRequest) async throws -> DecisionResponse {
        try await validateJob(.init(operation: "decision", request: .object(["model": .string(value.model)])))
        return try await activity.withInference(model: value.model, budget: await budget(for: value.model)) { try await performDecision(value) }
    }
    private func performDecision(_ value: DecisionRequest) async throws -> DecisionResponse {
        guard configuration.decisionModels.contains(value.model), !value.questions.isEmpty, value.questions.count <= 32,
              value.questions.values.allSatisfy({ $0.type == "choice" && !$0.instructions.isEmpty && (2...26).contains($0.criteria.count) }) else {
            throw ModelAPIError.invalid("Enable this decision model and supply 1–32 choice questions, each with 2–26 options.")
        }
        let encoded = try JSONEncoder().encode(value)
        guard encoded.count <= 64 * 1024 else { throw ModelAPIError.limit("Decision context exceeds 64 KiB.") }
        let body = try JSONDecoder().decode(JSONValue.self, from: encoded)
        let result = try await call("v1/systemone", value: body, decode: DecisionResponse.self)
        guard result.model == value.model, result.usage.input_tokens != nil, result.usage.output_tokens != nil else {
            throw ModelAPIError.invalid("Decision model identity or measured usage is missing.")
        }
        try result.validate(for: value); return result
    }
}
