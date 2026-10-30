import Foundation
import XCTest
import ModelAPI
import ModelService

final class LiveLifecycleTests: XCTestCase, @unchecked Sendable {
    func testExistingLocalModelsThroughTemporaryAliases() async throws {
        guard ProcessInfo.processInfo.environment["POSITRONIC_LIVE_LIFECYCLE"] == "1" else {
            throw XCTSkip("Explicit local model lifecycle test required")
        }
        let configuration = ServiceConfiguration()
        let library = try ModelLibrary(configuration: configuration)
        let before = try await library.installed()
        let manager = try ModelManager(configuration: configuration)
        func mutate(_ path: String, method: String, body: [String: String]) async throws {
            var request = URLRequest(url: URL(string: configuration.ollamaURL)!.appendingPathComponent(path))
            request.httpMethod = method; request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        for capability in [ModelCapability.generation, .decision, .embedding] {
            let source = try XCTUnwrap(before.first { $0.capability == capability })
            let alias = "positronic-lifecycle:\(UUID().uuidString.lowercased())"
            try await mutate("api/copy", method: "POST", body: ["source": source.id, "destination": alias])
            do {
                try await manager.load(alias)
                let loaded = try await manager.loaded()
                XCTAssertTrue(loaded.contains { $0.id == alias || $0.digest == source.digest })
                try await manager.unload(alias)
                let unloaded = try await manager.loaded()
                XCTAssertFalse(unloaded.contains { $0.id == alias || $0.digest == source.digest })
                // A normal request must also reload an unloaded model on demand.
                var enabled = configuration.removingModel(alias)
                switch capability {
                case .transcription, .speech, .conversation: fatalError("Not an Ollama model")
                case .generation: enabled.generationModels.append(alias)
                case .decision: enabled.decisionModels.append(alias)
                case .embedding: enabled.embeddingModels.append(alias)
                }
                let engine = try LocalModelEngine(configuration: enabled)
                switch capability {
                case .generation:
                    let answer = try await engine.generate(.init(model: alias, prompt: "Reply with the word ready.", maxTokens: 32, think: .bool(false)))
                    XCTAssertFalse(answer.text.isEmpty)
                case .transcription, .speech, .conversation: fatalError("Not an Ollama model")
                case .embedding:
                    let answer = try await engine.embed(.init(model: alias, input: ["Synthetic lifecycle check."]))
                    XCTAssertEqual(answer.embeddings.count, 1)
                case .decision:
                    let answer = try await engine.decide(.init(state: .string("A local model is ready."), model: alias,
                        questions: ["ready": .init("Is this about a local model?", choices: ["yes": "Local model", "no": "Another subject"])]))
                    XCTAssertNotNil(answer.answers["ready"])
                }
                try await manager.unload(alias)
                try await manager.load(alias)
                try await manager.remove(alias)
                let after = try await library.installed()
                XCTAssertFalse(after.contains { $0.id == alias })
                XCTAssertEqual(after.first { $0.id == source.id }?.digest, source.digest)
                print("Verified \(capability.rawValue): load → unload → inference reload → unload → reload → remove temporary alias")
            } catch {
                try? await manager.unload(alias)
                try await mutate("api/delete", method: "DELETE", body: ["model": alias])
                throw error
            }
        }
        let after = try await library.installed()
        XCTAssertEqual(Set(before.map(\.id)), Set(after.map(\.id)))
    }
}
