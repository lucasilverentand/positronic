import Foundation
import FoundationModels
import XCTest
@testable import ModelAPI
@testable import ModelService

private actor AppleFixture: AppleModelBackend {
    var localRequests = 0
    var cloudRequests: [GenerationRequest] = []
    let cloudAvailable: Bool
    let failCloud: Bool
    init(cloudAvailable: Bool = true, failCloud: Bool = false) { self.cloudAvailable = cloudAvailable; self.failCloud = failCloud }
    func status() -> ModelInfo { .init(id: "apple", capability: "generation", available: true, detail: "On device") }
    func cloudStatus(enabled: Bool) -> ModelInfo {
        .init(id: "apple-pcc", capability: "generation", available: enabled && cloudAvailable, detail: enabled ? "Fixture cloud availability" : "Disabled",
              execution: .applePrivateCloudCompute, reasoningLevels: ReasoningLevel.allCases)
    }
    func generate(_ request: GenerationRequest) throws -> GenerationResponse {
        localRequests += 1; return .init(model: "apple", text: "Local fixture")
    }
    func generateCloud(_ request: GenerationRequest) throws -> GenerationResponse {
        cloudRequests.append(request)
        if failCloud { throw ModelAPIError.unavailable("Synthetic cloud failure") }
        return .init(model: "apple-pcc", text: request.schema == nil ? "Cloud fixture" : #"{"ready":true}"#,
                     content: request.schema == nil ? nil : .object(["ready": .bool(true)]))
    }
}
final class PrivateCloudComputeTests: XCTestCase, @unchecked Sendable {
    private func engine(_ fixture: AppleFixture, enabled: Bool) throws -> LocalModelEngine {
        var config = ServiceConfiguration(); config.allowApplePCC = enabled
        return try fixtureEngine(configuration: config, transport: { _ in
            XCTFail("Apple generation must not use Ollama or HTTP fallback"); throw CancellationError()
        }, apple: fixture)
    }
    func testOldSettingsKeepCloudDisabled() throws {
        var config = ServiceConfiguration(); config.allowApplePCC = true
        var legacy = try JSONDecoder().decode([String: JSONValue].self, from: JSONEncoder().encode(config))
        legacy.removeValue(forKey: "allowApplePCC")
        let decoded = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(legacy))
        XCTAssertFalse(decoded.allowApplePCC)
        XCTAssertEqual(decoded.decisionModels, config.decisionModels)
        let roundTrip = try JSONDecoder().decode(ServiceConfiguration.self, from: JSONEncoder().encode(config))
        XCTAssertTrue(roundTrip.allowApplePCC)
    }
    func testReasoningWireValuesAndLocalIsolation() throws {
        for level in ReasoningLevel.allCases {
            let request = GenerationRequest(model: "apple-pcc", prompt: "Synthetic", reasoningLevel: level)
            try request.validate()
            let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(request))
            XCTAssertEqual(json.object?["reasoningLevel"], .string(level.rawValue))
            XCTAssertEqual(try JSONDecoder().decode(GenerationRequest.self, from: JSONEncoder().encode(request)).reasoningLevel, level)
            for local in ["apple", "qwen:local"] {
                XCTAssertThrowsError(try GenerationRequest(model: local, prompt: "Synthetic", reasoningLevel: level).validate())
            }
        }
        XCTAssertThrowsError(try GenerationRequest(model: "apple-pcc", prompt: "Synthetic", think: .bool(true)).validate())
        let old = try JSONDecoder().decode(GenerationRequest.self, from: Data(#"{"model":"apple","prompt":"Synthetic"}"#.utf8))
        XCTAssertNil(old.reasoningLevel); try old.validate()
        let oldInfo = try JSONDecoder().decode(ModelInfo.self, from: Data(#"{"id":"apple","capability":"generation","available":true,"detail":"Local"}"#.utf8))
        XCTAssertNil(oldInfo.execution); XCTAssertNil(oldInfo.reasoningLevels)
    }
    func testPCCCannotBeEnabledThroughALocalAllowlist() throws {
        XCTAssertFalse(ServiceConfiguration.isLocalModel("apple-pcc"))
        for capability in [ModelCapability.generation, .decision, .embedding] {
            var config = ServiceConfiguration()
            switch capability {
            case .generation: config.generationModels = ["apple-pcc"]
            case .decision: config.decisionModels = ["apple-pcc"]
            case .embedding: config.embeddingModels = ["apple-pcc"]
            case .transcription, .speech, .conversation: XCTFail("Unexpected audio capability")
            }
            XCTAssertThrowsError(try config.validate())
        }
    }
    func testDisabledPCCCannotInvokeCloudButLocalAppleStillWorks() async throws {
        let apple = AppleFixture(), backend = try engine(apple, enabled: false)
        do { _ = try await backend.generate(.init(model: "apple-pcc", prompt: "Synthetic")); XCTFail("Cloud disabled") } catch {}
        let output = try await backend.generate(.init(model: "apple", prompt: "Synthetic"))
        XCTAssertEqual(output.model, "apple")
        let cloud = await apple.cloudRequests; XCTAssertTrue(cloud.isEmpty)
    }
    func testEnabledPCCPreservesReasoningAndNeverChangesLocalRouting() async throws {
        let apple = AppleFixture(), backend = try engine(apple, enabled: true)
        for level in ReasoningLevel.allCases {
            let answer = try await backend.generate(.init(model: "apple-pcc", prompt: "Synthetic", reasoningLevel: level))
            XCTAssertEqual(answer.model, "apple-pcc")
        }
        _ = try await backend.generate(.init(model: "apple", prompt: "Synthetic"))
        let cloud = await apple.cloudRequests; XCTAssertEqual(cloud.map(\.reasoningLevel), ReasoningLevel.allCases.map(Optional.some))
        let local = await apple.localRequests; XCTAssertEqual(local, 1)
    }
    func testUnavailableOrFailedCloudDoesNotFallBack() async throws {
        for fixture in [AppleFixture(cloudAvailable: false), AppleFixture(failCloud: true)] {
            let backend = try engine(fixture, enabled: true)
            do { _ = try await backend.generate(.init(model: "apple-pcc", prompt: "Synthetic")); XCTFail("Cloud failure must propagate") } catch {}
            let local = await fixture.localRequests; XCTAssertEqual(local, 0)
        }
    }
    func testAuthenticatedClientCarriesCloudChoiceReasoningAndStructuredOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let keys = try APIKeys(file: folder.appendingPathComponent("keys.json"))
        let key = try await keys.create(name: "Synthetic PCC fixture")
        let apple = AppleFixture()
        let router = fixtureRouter(keys: keys, engine: try engine(apple, enabled: true))
        let ready = expectation(description: "Cloud fixture listener")
        let listener = try LoopbackServer(port: 0) { await router.handle($0) }
        let serving = Task { try await listener.run { ready.fulfill() } }
        defer { listener.stop(); serving.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:\(try XCTUnwrap(listener.port))")!, apiKey: key)
        let schema: JSONValue = .object(["type": .string("object"), "properties": .object(["ready": .object(["type": .string("boolean")])]), "required": .array([.string("ready")])])
        let output = try await client.generate(.init(model: "apple-pcc", prompt: "Synthetic", schema: schema, reasoningLevel: .deep))
        XCTAssertEqual(output.model, "apple-pcc"); XCTAssertEqual(output.content?.object?["ready"], JSONValue.bool(true))
        let requests = await apple.cloudRequests
        XCTAssertEqual(requests.first?.reasoningLevel, .deep); XCTAssertEqual(requests.first?.schema, schema)
    }
    func testCloudDiscoveryAndClientTimeoutAreExplicit() async throws {
        let apple = AppleFixture()
        var config = ServiceConfiguration(); config.allowApplePCC = true
        let engine = try fixtureEngine(configuration: config, transport: { request in
            (Data(#"{"models":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, apple: apple)
        let models = await engine.models()
        let cloud = try XCTUnwrap(models.first { $0.id == "apple-pcc" })
        XCTAssertEqual(cloud.execution, .applePrivateCloudCompute)
        XCTAssertEqual(cloud.reasoningLevels, ReasoningLevel.allCases)
        XCTAssertEqual(models.first { $0.id == "apple" }?.execution, .local)
        for (model, timeout) in [("apple-pcc", 300.0), ("apple", 120.0)] {
            let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:18767")!, apiKey: "synthetic") { wire in
                XCTAssertEqual(wire.timeoutInterval, timeout)
                return (try JSONEncoder().encode(GenerationResponse(model: model, text: "Synthetic")), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            _ = try await client.generate(.init(model: model, prompt: "Synthetic"))
        }
    }
    func testQuotaExplanationSurvivesTheHTTPClient() async throws {
        let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:18767")!, apiKey: "synthetic") { wire in
            (Data(#"{"error":"Apple Private Cloud Compute’s daily request limit is reached."}"#.utf8), HTTPURLResponse(url: wire.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await client.generate(.init(model: "apple-pcc", prompt: "Synthetic")); XCTFail("Expected quota error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("daily request limit")) }
    }
    func testActualUnsignedHarnessReportsMissingEntitlementWithoutSendingAPrompt() async throws {
        guard !AppEntitlements.allowsPrivateCloudCompute() else { throw XCTSkip("Harness has a PCC entitlement") }
        let apple = AppleModel()
        let status = await apple.cloudStatus(enabled: true)
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.execution, .applePrivateCloudCompute)
        do { _ = try await apple.generateCloud(.init(model: "apple-pcc", prompt: "Synthetic")); XCTFail("Missing entitlement must prevent submission") }
        catch { XCTAssertTrue(error.localizedDescription.contains("entitlement")) }
    }
    func testAppleQuotaAndNetworkFailuresAreActionable() throws {
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            let reset = Date(timeIntervalSince1970: 1800000000)
            let quota = AppleModel.cloudFailure(.quotaLimitReached(.init(resetDate: reset, debugDescription: "Synthetic")))
            XCTAssertTrue(quota.localizedDescription.contains(reset.ISO8601Format()))
            XCTAssertTrue(AppleModel.cloudFailure(.networkFailure(.init(debugDescription: "Synthetic"))).localizedDescription.contains("internet"))
            XCTAssertTrue(AppleModel.cloudFailure(.serviceUnavailable(.init(debugDescription: "Synthetic"))).localizedDescription.contains("Retry later"))
        }
        #endif
    }
}
