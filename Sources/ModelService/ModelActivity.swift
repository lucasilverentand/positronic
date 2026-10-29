import Foundation
import ModelAPI

/// Shared by the app, playground and API across configuration refreshes.
/// Management never interrupts a request that has already started inference.
public actor ModelActivity {
    private var inferenceCount = 0
    private var managing = false
    public let jobs: JobQueue
    public init(jobs: JobQueue = JobQueue()) { self.jobs = jobs }
    public func withInference<Value: Sendable>(model: String = "", budget: Int64? = 0, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !managing else { throw ModelAPIError.unavailable("A model is being loaded, unloaded or removed. Try again when it finishes.") }
        if JobExecution.queueID == jobs.identity {
            inferenceCount += 1; defer { inferenceCount -= 1 }
            return try await operation()
        }
        let box = InferenceResult<Value>()
        let job = try await jobs.submit(model: model, operation: "inference", budget: budget) { _ in
            await box.set(try await operation())
            return JobResult(data: Data())
        }
        _ = try await jobs.wait(job.id)
        return try await box.get()
    }
    public func withManagement<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        guard !managing, inferenceCount == 0 else { throw ModelAPIError.unavailable("A model request is in progress. Wait for it to finish before changing loaded models.") }
        try await jobs.beginManagement()
        managing = true
        do {
            let value = try await operation()
            managing = false; await jobs.endManagement(); return value
        } catch { managing = false; await jobs.endManagement(); throw error }
    }
}

private actor InferenceResult<Value: Sendable> {
    private var value: Value?
    func set(_ value: Value) { self.value = value }
    func get() throws -> Value {
        guard let value else { throw ModelAPIError.unavailable("The job produced no result.") }; return value
    }
}
