import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

final class ModelLibraryTests: XCTestCase, @unchecked Sendable {
    func testDiscoveryClassifiesModelsAndExcludesCloudAliases() async throws {
        let library = try ModelLibrary(configuration: .init()) { request in
            let body: JSONValue
            if request.url?.path == "/api/tags" {
                body = .object(["models": .array([
                    .object(["name": .string("qwen:local"), "size": .number(1024)]),
                    .object(["name": .string("nimble:9b")]),
                    .object(["name": .string("embed:small")]),
                    .object(["name": .string("model:large-cloud")]),
                    .object(["name": .string("model:cloud")]),
                    .object(["name": .string("remote-alias:local"), "remote_host": .string("https://example.test")]),
                    .object(["name": .string("remote-show:local")])
                ])])
            } else {
                let input = try JSONDecoder().decode([String: String].self, from: XCTUnwrap(request.httpBody))
                let name = input["model"]!
                if name == "remote-show:local" { body = .object(["remote_model": .string("cloud-model")]) }
                else {
                    let capability = name.hasPrefix("nimble") ? "decision" : name.hasPrefix("embed") ? "embedding" : "completion"
                    body = .object(["capabilities": .array([.string(capability)]), "remote_host": .null])
                }
            }
            return (try JSONEncoder().encode(body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let models = try await library.installed()
        XCTAssertEqual(Set(models.map(\.id)), Set(["qwen:local", "nimble:9b", "embed:small"]))
        XCTAssertEqual(models.first { $0.id == "nimble:9b" }?.capability, .decision)
        XCTAssertEqual(models.first { $0.id == "embed:small" }?.capability, .embedding)
        XCTAssertEqual(models.first { $0.id == "qwen:local" }?.capability, .generation)
    }
    func testLargeDownloadRequiresCapacityAndWorkingSpace() {
        XCTAssertNotNil(ModelLibrary.storageRestriction(required: 25_000_000_000, available: 15_800_000_000))
        XCTAssertNil(ModelLibrary.storageRestriction(required: 25_000_000_000, available: 25_000_000_000))
        XCTAssertNotNil(ModelLibrary.storageRestriction(required: 25_000_000_000, available: nil))
    }
    func testEveryPresetIsExplicitlyLocal() throws {
        XCTAssertGreaterThanOrEqual(ModelLibrary.presets.count, 12)
        XCTAssertEqual(Set(ModelLibrary.presets.map(\.id)).count, ModelLibrary.presets.count)
        for preset in ModelLibrary.presets { XCTAssertTrue(ServiceConfiguration.isLocalModel(preset.id)) }
        XCTAssertFalse(ServiceConfiguration.isLocalModel("clef:27b-cloud"))
    }
    func testOldSettingsRetainKeysAndConfigurationShape() throws {
        let config = ServiceConfiguration()
        var object = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(config))
        object.removeValue(forKey: "embeddingModels")
        let loaded = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(object))
        XCTAssertEqual(loaded.decisionModels, config.decisionModels)
        XCTAssertTrue(loaded.embeddingModels.isEmpty)
        try loaded.validate()
        XCTAssertEqual(PrivateFiles.directory.lastPathComponent, "MacModelAPI")
    }
    func testEmbeddingBackendPreservesBatchAndRefusesTruncation() async throws {
        var config = ServiceConfiguration(); config.embeddingModels = ["embedding-fixture:local"]
        let engine = try LocalModelEngine(configuration: config) { request in
            XCTAssertEqual(request.url?.path, "/api/embed")
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(request.httpBody))
            XCTAssertEqual(body.object?["truncate"], .bool(false))
            XCTAssertEqual(body.object?["input"], .array([.string("one"), .string("two")]))
            return (Data(#"{"model":"embedding-fixture:local","embeddings":[[0.1,0.2],[0.3,0.4]],"prompt_eval_count":4}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let output = try await engine.embed(.init(model: "embedding-fixture:local", input: ["one", "two"]))
        XCTAssertEqual(output.embeddings.count, 2); XCTAssertEqual(output.usage.input_tokens, 4)
    }
    func testEmbeddingValidationRejectsWrongModelOrRaggedVectors() throws {
        let request = EmbeddingRequest(model: "fixture", input: ["one", "two"])
        XCTAssertThrowsError(try EmbeddingResponse(model: "other", embeddings: [[0.1],[0.2]], usage: .init(input: 2, output: nil)).validate(for: request))
        XCTAssertThrowsError(try EmbeddingResponse(model: "fixture", embeddings: [[0.1],[0.2,0.3]], usage: .init(input: 2, output: nil)).validate(for: request))
        XCTAssertThrowsError(try EmbeddingRequest(model: "fixture", input: []).validate())
    }
    func testMultipleDecisionModelsUseSameValidatedContract() async throws {
        for model in ["nimble:9b", "tev1:0.8b", "clef:27b"] {
            var config = ServiceConfiguration(); config.decisionModels = [model]
            let request = DecisionRequest(state: .string("Synthetic"), model: model, questions: ["route": .init("Fixture", choices: ["yes": "Relevant", "no": "Irrelevant"])])
            let expected = DecisionResponse(model: model, answers: ["route": .init(choice: "yes", probabilities: ["yes": 0.9, "no": 0.1], confidence: 0.9)], usage: .init(input: 8, output: 1))
            let engine = try LocalModelEngine(configuration: config) { wire in
                XCTAssertEqual(wire.url?.path, "/v1/systemone")
                return (try JSONEncoder().encode(expected), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let result = try await engine.decide(request); XCTAssertEqual(result, expected)
        }
    }
    func testCancellingDownloadClosesAnUnresponsivePull() async throws {
        let listening = expectation(description: "Listener ready")
        let requested = expectation(description: "Pull received")
        let cancelled = expectation(description: "Pull cancelled")
        let suspension = DownloadSuspension()
        let server = try LoopbackServer(port: 0) { _ in
            requested.fulfill()
            await suspension.hold()
            return .init(body: Data())
        }
        let serving = Task { try await server.run { listening.fulfill() } }
        defer { server.stop(); serving.cancel() }
        await fulfillment(of: [listening], timeout: 5)
        var config = ServiceConfiguration(); config.ollamaURL = "http://127.0.0.1:\(try XCTUnwrap(server.port))"
        let library = try ModelLibrary(configuration: config)
        let pull = Task {
            defer { cancelled.fulfill() }
            do { try await library.download(try XCTUnwrap(ModelLibrary.presets.first { $0.id == "qwen3.5:4b" })) { _ in }; XCTFail("Cancelled pull cannot succeed") }
            catch { XCTAssertTrue(Task.isCancelled) }
        }
        await fulfillment(of: [requested], timeout: 5)
        pull.cancel()
        await fulfillment(of: [cancelled], timeout: 2)
        await suspension.release()
        await pull.value
    }
    func testExplicitDownloadRequiresACompletionReceipt() async throws {
        for complete in [true, false] {
            let ready = expectation(description: "Download fixture ready")
            let server = try LoopbackServer(port: 0) { wire in
                XCTAssertEqual(wire.path, "/api/pull")
                let input = try? JSONDecoder().decode(JSONValue.self, from: wire.body)
                XCTAssertEqual(input?.object?["model"], .string("qwen3.5:4b"))
                let receipt = complete ? "{\"status\":\"success\"}\n" : ""
                return .init(type: "application/x-ndjson", body: Data(("{\"status\":\"pulling\",\"total\":100,\"completed\":50}\n" + receipt).utf8))
            }
            let task = Task { try await server.run { ready.fulfill() } }
            defer { server.stop(); task.cancel() }
            await fulfillment(of: [ready], timeout: 5)
            var config = ServiceConfiguration(); config.ollamaURL = "http://127.0.0.1:\(try XCTUnwrap(server.port))"
            let library = try ModelLibrary(configuration: config)
            do { try await library.download(try XCTUnwrap(ModelLibrary.presets.first { $0.id == "qwen3.5:4b" })) { _ in }; XCTAssertTrue(complete) }
            catch { XCTAssertFalse(complete) }
            server.stop(); try await task.value
        }
    }
}

private actor DownloadSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
