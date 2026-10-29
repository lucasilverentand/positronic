import Foundation

public enum JobState: String, Codable, Sendable { case queued, waitingForResources, loading, running, succeeded, failed, cancelled
    public var terminal: Bool { [.succeeded, .failed, .cancelled].contains(self) }
}
public struct ResourceStatus: Codable, Sendable {
    public var availableMemoryBytes: Int64
    public var requiredMemoryBytes: Int64
    public var availableDiskBytes: Int64
    public var reason: String?
    public init(availableMemoryBytes: Int64, requiredMemoryBytes: Int64, availableDiskBytes: Int64, reason: String? = nil) {
        self.availableMemoryBytes = availableMemoryBytes; self.requiredMemoryBytes = requiredMemoryBytes; self.availableDiskBytes = availableDiskBytes; self.reason = reason
    }
}
public struct ModelJob: Codable, Sendable, Identifiable {
    public var id: UUID
    public var model: String
    public var operation: String
    public var state: JobState
    public var createdAt: Date
    public var finishedAt: Date?
    public var progress: Double?
    public var position: Int?
    public var message: String?
    public var resources: ResourceStatus?
    public init(id: UUID = UUID(), model: String, operation: String, state: JobState = .queued, createdAt: Date = Date()) {
        self.id = id; self.model = model; self.operation = operation; self.state = state; self.createdAt = createdAt
    }
}
public struct JobSubmission: Codable, Sendable {
    public var operation: String
    public var request: JSONValue
    public init(operation: String, request: JSONValue) { self.operation = operation; self.request = request }
}
public struct SpeechRequest: Codable, Sendable {
    public var model: String
    public var input: String
    public var language: String
    public var voice: String
    public init(model: String = "chatterbox-multilingual-v3", input: String, language: String = "en", voice: String = "default") {
        self.model = model; self.input = input; self.language = language; self.voice = voice
    }
    public func validate() throws {
        guard model == "chatterbox-multilingual-v3", ["en", "nl"].contains(language), voice == "default", !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.count <= 5000 else {
            throw ModelAPIError.invalid("Choose Chatterbox, English or Dutch, the default voice, and 1–5000 text characters.")
        }
    }
}
public struct Transcript: Codable, Sendable {
    public struct Segment: Codable, Sendable { public var start: Double; public var end: Double; public var text: String }
    public var model: String
    public var language: String
    public var text: String
    public var segments: [Segment]
}
