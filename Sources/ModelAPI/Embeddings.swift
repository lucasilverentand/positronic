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

public extension EmbeddingResponse {
    /// Scale before taking norms so large finite coordinates do not overflow.
    func cosineSimilarity(between first: Int, and second: Int) -> Double? {
        guard embeddings.indices.contains(first), embeddings.indices.contains(second) else { return nil }
        let a = embeddings[first], b = embeddings[second]
        guard !a.isEmpty, a.count == b.count, a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite),
              let scaleA = a.map({ abs($0) }).max(), let scaleB = b.map({ abs($0) }).max(), scaleA > 0, scaleB > 0 else { return nil }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for (x,y) in zip(a,b) { let u=x/scaleA,v=y/scaleB;dot += u*v;normA += u*u;normB += v*v }
        return min(1, max(-1, dot / sqrt(normA) / sqrt(normB)))
    }
}
