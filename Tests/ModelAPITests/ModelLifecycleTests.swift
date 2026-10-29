import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

private actor LifecycleFixture {
    var installed = true
    var resident = false
    var operations: [String] = []
    let capability: String
    let failDelete: Bool
    init(_ capability: String, failDelete: Bool = false) { self.capability = capability; self.failDelete = failDelete }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let body = try request.httpBody.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        var result: JSONValue = .object([:])
        var status = 200
        switch path {
        case "/api/tags": result = .object(["models": .array(installed ? [.object(["name": .string("fixture:local"), "digest": .string("digest")])] : [])])
        case "/api/show": result = .object(["capabilities": .array([.string(capability)])])
        case "/api/ps":
            // Runtime can report another alias for the same loaded weights.
            result = .object(["models": .array(resident ? [.object(["name": .string("another:alias"), "digest": .string("digest"), "size_vram": .number(1000)])] : [])])
        case "/api/generate", "/api/embed", "/v1/systemone":
            if body?.object?["keep_alive"] == .number(0) { resident = false; operations.append("unload") }
            else { resident = true; operations.append(path) }
            result = .object(["model": .string("fixture:local"), "done": .bool(true)])
        case "/api/delete":
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(body?.object?["model"], .string("fixture:local"))
            operations.append("delete")
            if failDelete { status = 500 } else { installed = false }
        default: XCTFail("Unexpected path \(path)")
        }
        return (try JSONEncoder().encode(result), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private actor Suspension {
    var continuation: CheckedContinuation<Void, Never>?
    var entered = false
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func waitUntilEntered() async throws {
        while !entered { try await Task.sleep(for: .milliseconds(1)) }
    }
}
final class ModelLifecycleTests: XCTestCase, @unchecked Sendable {
    func testLoadUnloadReloadAndRemovalForAllCapabilities() async throws {
        for (capability, path) in [("completion", "/api/generate"), ("embedding", "/api/embed"), ("decision", "/v1/systemone")] {
            let fixture = LifecycleFixture(capability)
            let manager = try ModelManager(configuration: .init(), transport: { try await fixture.send($0) })
            try await manager.load("fixture:local")
            let loaded = try await manager.loaded()
            XCTAssertEqual(loaded.first?.memoryBytes, 1000)
            try await manager.unload("fixture:local")
            let empty = try await manager.loaded(); XCTAssertTrue(empty.isEmpty)
            try await manager.load("fixture:local")
            try await manager.remove("fixture:local")
            // Removing an already absent model is safe and does not send another mutation.
            try await manager.remove("fixture:local")
            let operations = await fixture.operations
            XCTAssertEqual(operations, [path, "unload", path, "unload", "delete"])
        }
    }
    func testFailedRemovalDoesNotReportSuccess() async throws {
        let fixture = LifecycleFixture("completion", failDelete: true)
        let manager = try ModelManager(configuration: .init(), transport: { try await fixture.send($0) })
        do { try await manager.remove("fixture:local"); XCTFail("Deletion must fail") } catch {}
        let installed = await fixture.installed; XCTAssertTrue(installed)
        let resident = await fixture.resident; XCTAssertFalse(resident)
    }
    func testRemovalRevokesOnlyTheSelectedModel() throws {
        var config = ServiceConfiguration()
        config.generationModels = ["qwen:local", "other:local"]
        config.embeddingModels = ["embed:local"]
        config.startAPIOnLaunch = true
        let next = config.removingModel("qwen:local")
        try next.validate()
        XCTAssertEqual(next.generationModels, ["other:local"])
        XCTAssertEqual(next.decisionModels, config.decisionModels)
        XCTAssertEqual(next.embeddingModels, config.embeddingModels)
        XCTAssertTrue(next.startAPIOnLaunch)
        XCTAssertEqual(next.ollamaURL, config.ollamaURL)
    }
    func testManagementCannotInterruptAnAcceptedRequest() async throws {
        let activity = ModelActivity(jobs: fixtureQueue()), suspension = Suspension()
        let request = Task { try await activity.withInference { await suspension.hold() } }
        try await suspension.waitUntilEntered()
        do { try await activity.withManagement {}; XCTFail("Active inference must block management") } catch {}
        await suspension.release(); try await request.value
        try await activity.withManagement {}
    }
    func testManagementBlocksNewRequestsAndAlwaysReleasesGate() async throws {
        let activity = ModelActivity(jobs: fixtureQueue()), suspension = Suspension()
        let management = Task { try await activity.withManagement { await suspension.hold() } }
        try await suspension.waitUntilEntered()
        do { try await activity.withInference {}; XCTFail("Management must block inference") } catch {}
        do { try await activity.withManagement {}; XCTFail("Management must block another mutation") } catch {}
        await suspension.release(); try await management.value
        do { try await activity.withManagement { throw CancellationError() }; XCTFail("Expected cancellation") } catch {}
        try await activity.withInference {}
    }
    func testEngineUsesTheSharedManagementGate() async throws {
        let activity = ModelActivity(jobs: fixtureQueue()), suspension = Suspension()
        let management = Task { try await activity.withManagement { await suspension.hold() } }
        try await suspension.waitUntilEntered()
        var config = ServiceConfiguration(); config.embeddingModels = ["embed:local"]
        let engine = try fixtureEngine(configuration: config, transport: { _ in
            XCTFail("Busy engine must not reach runtime"); throw CancellationError()
        }, activity: activity)
        do { _ = try await engine.embed(.init(model: "embed:local", input: ["fixture"])); XCTFail("Expected busy error") } catch {}
        await suspension.release(); try await management.value
    }
    func testAppleAndCloudModelsCannotBeManaged() async throws {
        let manager = try ModelManager(configuration: .init(), transport: { _ in
            XCTFail("Invalid model must not reach the runtime"); throw CancellationError()
        })
        for name in ["apple", "remote:cloud", "large:9b-cloud"] {
            do { try await manager.remove(name); XCTFail("Expected local-model validation") } catch {}
        }
    }
}
