import Foundation
import FoundationModels
import ModelAPI

public actor AppleModel {
    public init() {}
    public func status() -> ModelInfo {
        let detail: String
        switch SystemLanguageModel.default.availability {
        case .available: return .init(id: "apple", capability: "generation", available: true, detail: "Apple Intelligence · on this Mac")
        case .unavailable(.deviceNotEligible): detail = "This Mac does not support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): detail = "Enable Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): detail = "Apple’s on-device model is not ready."
        @unknown default: detail = "Apple Intelligence is unavailable."
        }
        return .init(id: "apple", capability: "generation", available: false, detail: detail)
    }
    public func generate(_ request: GenerationRequest) async throws -> GenerationResponse {
        try request.validate()
        guard request.model == "apple" else { throw ModelAPIError.invalid("Choose apple for on-device Apple Intelligence.") }
        let ready = status(); guard ready.available else { throw ModelAPIError.unavailable(ready.detail) }
        let session = LanguageModelSession(instructions: request.instructions ?? "Answer the supplied request.")
        #if compiler(>=6.4)
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: request.maxTokens ?? 600)
        #else
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: request.maxTokens ?? 600)
        #endif
        try Task.checkCancellation()
        if let schema = request.schema {
            let converted = try GenerationSchema(root: AppleGenerationSchema.convert(schema, name: "ModelResponse"), dependencies: [])
            let response = try await session.respond(to: request.prompt, schema: converted, options: options)
            guard response.content.isComplete else { throw ModelAPIError.unavailable("Apple returned an incomplete structure.") }
            return .init(model: "apple", text: response.content.jsonString,
                         content: try JSONDecoder().decode(JSONValue.self, from: Data(response.content.jsonString.utf8)))
        }
        let response = try await session.respond(to: request.prompt, options: options)
        return .init(model: "apple", text: response.content)
    }
}
