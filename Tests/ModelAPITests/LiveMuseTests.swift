import Foundation
import XCTest
import ModelAPI
import ModelService

/// Explicit, bounded test of existing weights. Never downloads or changes settings.
final class LiveMuseTests: XCTestCase, @unchecked Sendable {
    func testInstalledMuseThroughResourceScheduler() async throws {
        guard ProcessInfo.processInfo.environment["POSITRONIC_LIVE_MUSE"] == "1" else { throw XCTSkip("Explicit Muse test required") }
        let model = ProcessInfo.processInfo.environment["POSITRONIC_MUSE_MODEL"] ?? "muse-glimmer:30b"
        guard ["muse-glimmer:30b", "muse-glimmer:30b-nvfp4"].contains(model) else {
            throw ModelAPIError.invalid("Choose the installed Muse GGUF or MLX NVFP4 model for this bounded check.")
        }
        var configuration = ServiceConfiguration()
        configuration.ollamaURL = "http://127.0.0.1:18768"
        configuration.generationModels = [model]
        let manager = try ModelManager(configuration: configuration)
        guard try await manager.loaded().isEmpty else { throw XCTSkip("An existing local model is in use; leave it untouched.") }
        let queue = JobQueue(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MuseCheck-" + UUID().uuidString), waitLimit: 30)
        let activity = ModelActivity(jobs: queue)
        let engine = try LocalModelEngine(configuration: configuration, contextTokens: 1024, activity: activity)
        let budget = await engine.budget(for: model)
        let before = try ResourceMonitor.snapshot()
        let status = ResourceMonitor.restriction(before, budget: budget)
        print("MUSE_PREFLIGHT model=\(model) available=\(before.available) required=\(status.requiredMemoryBytes) disk=\(before.disk) swapActivity=\(before.swapActivityBytes) pressure=\(before.pressure) reason=\(status.reason ?? "admitted")")
        if let reason = status.reason { throw XCTSkip(reason) }
        await queue.configure(prepare: { _ in }, cancelWorker: { try? await manager.unload(model) }, footprint: {
            try await manager.loaded().reduce(0) { $0 + ($1.memoryBytes ?? 0) }
        })
        let start = ContinuousClock.now
        do {
            let answer = try await engine.generate(.init(model: model, prompt: "What is 2 plus 2? Reply with only the answer.", maxTokens: 32, think: .bool(false)))
            XCTAssertFalse(answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let after = try ResourceMonitor.snapshot()
            print("MUSE_RESULT text=\(answer.text) elapsed=\(start.duration(to: .now)) pressure=\(after.pressure) swapActivity=\(after.swapActivityBytes)")
            try await manager.unload(model)
            let loaded = try await manager.loaded()
            XCTAssertFalse(loaded.contains { $0.id == model })
            await queue.shutdown()
        } catch {
            try? await manager.unload(model)
            await queue.shutdown()
            throw error
        }
    }
}
