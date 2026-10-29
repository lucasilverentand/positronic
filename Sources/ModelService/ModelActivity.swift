import Foundation
import ModelAPI

/// Shared by the app, playground and API across configuration refreshes.
/// Management never interrupts a request that has already started inference.
public actor ModelActivity {
    private var inferenceCount = 0
    private var managing = false
    public init() {}
    public func withInference<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        guard !managing else { throw ModelAPIError.unavailable("A model is being loaded, unloaded or removed. Try again when it finishes.") }
        inferenceCount += 1; defer { inferenceCount -= 1 }
        return try await operation()
    }
    public func withManagement<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value {
        guard !managing, inferenceCount == 0 else { throw ModelAPIError.unavailable("A model request is in progress. Wait for it to finish before changing loaded models.") }
        managing = true; defer { managing = false }
        return try await operation()
    }
}
