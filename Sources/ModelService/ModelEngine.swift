import Foundation
import ModelAPI

public protocol ModelEngine: Sendable {
    func models() async -> [ModelInfo]
    func generate(_ value: GenerationRequest) async throws -> GenerationResponse
    func decide(_ value: DecisionRequest) async throws -> DecisionResponse
}

public struct LocalModelEngine: ModelEngine {
    private let configuration: ServiceConfiguration
    private let apple = AppleModel()
    private let transport: ModelAPIClient.Transport
    public init(configuration: ServiceConfiguration, transport: ModelAPIClient.Transport? = nil) throws {
        try configuration.validate(); self.configuration = configuration; self.transport = transport ?? HTTPTransport.send
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
    public func models() async -> [ModelInfo] {
        let tags = try? await call("api/tags", decode: JSONValue.self)
        var installed = Set<String>()
        if case .array(let entries) = tags?.object?["models"] { installed = Set(entries.compactMap { $0.object?["name"]?.string }) }
        var result = [await apple.status()]
        for (names, capability) in [(configuration.generationModels, "generation"), (configuration.decisionModels, "decision")] {
            result += names.map { .init(id: $0, capability: capability, available: installed.contains($0), detail: installed.contains($0) ? "Installed in the local runtime" : "Not found in the local runtime") }
        }
        return result
    }
    public func generate(_ value: GenerationRequest) async throws -> GenerationResponse {
        try value.validate()
        if value.model == "apple" { return try await apple.generate(value) }
        guard configuration.generationModels.contains(value.model) else { throw ModelAPIError.invalid("This generation model is not enabled.") }
        var body: [String: JSONValue] = ["model": .string(value.model), "prompt": .string(value.prompt), "stream": .bool(false),
                                       "options": .object(["num_predict": .number(Double(value.maxTokens ?? 600))])]
        if let instructions = value.instructions { body["system"] = .string(instructions) }
        if let schema = value.schema { body["format"] = schema }
        let result = try await call("api/generate", value: .object(body), decode: JSONValue.self)
        guard result.object?["model"]?.string == value.model, result.object?["done"]?.bool == true,
              let text = result.object?["response"]?.string else { throw ModelAPIError.invalid("Local generation response is incomplete or has a different model.") }
        let content = value.schema == nil ? nil : try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        return .init(model: value.model, text: text, content: content,
                     usage: .init(input: result.object?["prompt_eval_count"]?.numberValue.flatMap(Int.init(exactly:)),
                                  output: result.object?["eval_count"]?.numberValue.flatMap(Int.init(exactly:))))
    }
    public func decide(_ value: DecisionRequest) async throws -> DecisionResponse {
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
