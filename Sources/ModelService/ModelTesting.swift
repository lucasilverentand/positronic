import Foundation
import ModelAPI

/// Temporary operator access for a local preview. Callers must not persist this copy.
public extension ServiceConfiguration {
    func forModelTest(_ model: String, capability: ModelCapability) throws -> Self {
        var copy = removingModel(model)
        if !["apple", "apple-pcc"].contains(model) {
            switch capability {
            case .generation: copy.generationModels = Array(Set(copy.generationModels + [model]))
            case .decision: copy.decisionModels = Array(Set(copy.decisionModels + [model]))
            case .embedding: copy.embeddingModels = Array(Set(copy.embeddingModels + [model]))
            case .speech, .transcription: copy.audioModels = Array(Set(copy.audioModels + [model]))
            }
        }
        // In particular, this never opts the operator into PCC.
        try copy.validate(); return copy
    }
}
public enum ModelTestInput {
    public static func decision(model: String, text: String, question: String, choices: String) throws -> DecisionRequest {
        let labels = choices.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (2...26).contains(labels.count), Set(labels).count == labels.count else { throw ModelAPIError.invalid("Enter sample text, a question and 2–26 different choices, one per line.") }
        let criteria = Dictionary(uniqueKeysWithValues: labels.enumerated().map { ("option_\($0.offset + 1)", $0.element) })
        let request = DecisionRequest(state: .string(text), model: model, questions: ["result": .init(question, choices: criteria)])
        guard try JSONEncoder().encode(request).count <= 64 * 1024 else { throw ModelAPIError.limit("Decision sample exceeds 64 KiB.") }
        return request
    }
}
