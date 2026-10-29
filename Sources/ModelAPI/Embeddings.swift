import Foundation

public struct EmbeddingRequest: Codable, Sendable {
    public var model: String
    public var input: [String]
    public init(model: String, input: [String]) { self.model = model; self.input = input }
    public func validate() throws {
        guard !model.isEmpty, (1...32).contains(input.count), input.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              input.reduce(0, { $0 + $1.utf8.count }) <= 64_000 else { throw ModelAPIError.invalid("Supply 1–32 nonempty inputs totaling at most 64 KB.") }
    }
}
public struct EmbeddingResponse: Codable, Sendable {
    public var model: String
    public var embeddings: [[Double]]
    public var usage: DecisionResponse.Usage
    public init(model: String, embeddings: [[Double]], usage: DecisionResponse.Usage) { self.model = model; self.embeddings = embeddings; self.usage = usage }
    public func validate(for request: EmbeddingRequest) throws {
        guard model == request.model, embeddings.count == request.input.count,
              let dimensions = embeddings.first?.count, (1...16384).contains(dimensions),
              embeddings.allSatisfy({ $0.count == dimensions && $0.allSatisfy(\.isFinite) }),
              let tokens = usage.input_tokens, tokens >= 0 else { throw ModelAPIError.invalid("Embedding vectors, model identity or measured usage are invalid.") }
    }
}
