import Foundation

/// Typed judgment is separate from the generative model that carries out work.
public struct DecisionQuestion: Codable, Sendable, Equatable {
    public var type = "choice"
    public var instructions: String
    public var criteria: [String: String]
    public init(_ instructions: String, choices: [String: String]) { self.instructions = instructions; criteria = choices }
}
public struct DecisionAnswer: Codable, Sendable, Equatable {
    public var type: String
    public var choice: String
    public var probabilities: [String: Double]
    public var confidence: Double
    public init(choice: String, probabilities: [String: Double], confidence: Double) {
        type = "choice"; self.choice = choice; self.probabilities = probabilities; self.confidence = confidence
    }
}
public struct DecisionRequest: Codable, Sendable, Equatable {
    public var state: JSONValue
    public var model: String
    public var questions: [String: DecisionQuestion]
    public init(state: JSONValue, model: String = "clef-flash:9b-mxfp8", questions: [String: DecisionQuestion]) {
        self.state = state; self.model = model; self.questions = questions
    }
}
public struct DecisionResponse: Codable, Sendable, Equatable {
    public struct Usage: Codable, Sendable, Equatable {
        public var input_tokens: Int?
        public var output_tokens: Int?
        public init(input: Int?, output: Int?) { input_tokens = input; output_tokens = output }
    }
    public var model: String
    public var answers: [String: DecisionAnswer]
    public var usage: Usage
    public init(model: String = "clef-flash:9b-mxfp8", answers: [String: DecisionAnswer], usage: Usage = .init(input: nil, output: nil)) {
        self.model = model; self.answers = answers; self.usage = usage
    }
    public func validate(for request: DecisionRequest) throws {
        guard !model.isEmpty, Set(answers.keys) == Set(request.questions.keys),
              (0...9_007_199_254_740_991).contains(usage.input_tokens ?? 0),
              (0...9_007_199_254_740_991).contains(usage.output_tokens ?? 0) else { throw ModelAPIError.invalid("Invalid decision response.") }
        for (key, question) in request.questions {
            guard let answer = answers[key], answer.type == "choice", question.criteria[answer.choice] != nil,
                  answer.confidence.isFinite, (0...1).contains(answer.confidence),
                  Set(answer.probabilities.keys) == Set(question.criteria.keys),
                  answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  (answer.probabilities[answer.choice] ?? -1) >= (answer.probabilities.values.max() ?? 0) - 0.000001,
                  abs(answer.probabilities.values.reduce(0, +) - 1) < 0.001 else { throw ModelAPIError.invalid("Decision answer differs from its declared choices.") }
        }
    }
}
public protocol DecisionProvider: Sendable {
    func decide(_ request: DecisionRequest) async throws -> DecisionResponse
}
