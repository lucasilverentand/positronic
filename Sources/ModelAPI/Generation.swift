import Foundation

public struct GenerationRequest: Codable, Sendable {
    public var model: String
    public var prompt: String
    public var instructions: String?
    public var schema: JSONValue?
    public var maxTokens: Int?
    public var think: JSONValue?
    public init(model: String, prompt: String, instructions: String? = nil, schema: JSONValue? = nil, maxTokens: Int? = nil, think: JSONValue? = nil) {
        self.model = model; self.prompt = prompt; self.instructions = instructions; self.schema = schema; self.maxTokens = maxTokens
        self.think = think
    }
    public func validate() throws {
        guard !model.isEmpty, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...4096).contains(maxTokens ?? 600), prompt.utf8.count + (instructions?.utf8.count ?? 0) <= 64_000 else {
            throw ModelAPIError.invalid("Supply a model, a prompt up to 64 KB, and maxTokens between 1 and 4096.")
        }
        if let think {
            switch think {
            case .bool, .null: break
            case .string(let level) where !level.isEmpty && level.count <= 40: break
            default: throw ModelAPIError.invalid("think must be a boolean, a supported thinking level, or null.")
            }
        }
    }
}
public struct GenerationResponse: Codable, Sendable {
    public var model: String
    public var text: String
    public var content: JSONValue?
    public var usage: DecisionResponse.Usage
    public init(model: String, text: String, content: JSONValue? = nil, usage: DecisionResponse.Usage = .init(input: nil, output: nil)) {
        self.model = model; self.text = text; self.content = content; self.usage = usage
    }
}

public struct ModelInfo: Codable, Sendable, Identifiable {
    public var id: String
    public var capability: String
    public var available: Bool
    public var detail: String
    public init(id: String, capability: String, available: Bool, detail: String) {
        self.id = id; self.capability = capability; self.available = available; self.detail = detail
    }
}
