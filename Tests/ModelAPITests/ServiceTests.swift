import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

private struct FixtureEngine: ModelEngine {
    var text = "Synthetic response"
    func models() async -> [ModelInfo] { [.init(id: "fixture", capability: "generation", available: true, detail: "Synthetic")] }
    func generate(_ value: GenerationRequest) async throws -> GenerationResponse { .init(model: value.model, text: text) }
    func decide(_ value: DecisionRequest) async throws -> DecisionResponse { .init(model: value.model, answers: [:]) }
}

final class ServiceTests: XCTestCase, @unchecked Sendable {
    func vault() throws -> (APIKeys, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelAPITests-\(UUID())")
        return (try APIKeys(file: folder.appendingPathComponent("keys.json")), folder)
    }
    func testKeysPersistOnlyDigestsAndRevocationIsImmediate() async throws {
        let (keys, folder) = try vault(); defer { try? FileManager.default.removeItem(at: folder) }
        let token = try await keys.create(name: "Synthetic client")
        let accepted = await keys.accepts(token); XCTAssertTrue(accepted)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("keys.json"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(token))
        let reopened = try APIKeys(file: folder.appendingPathComponent("keys.json"))
        let persisted = await reopened.accepts(token); XCTAssertTrue(persisted)
        let records = await keys.list(); try await keys.revoke(XCTUnwrap(records.first).id)
        let revoked = await keys.accepts(token); XCTAssertFalse(revoked)
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("keys.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testRouterRequiresAKeyRejectsBrowserOriginsAndRevokedKeys() async throws {
        let (keys, folder) = try vault(); defer { try? FileManager.default.removeItem(at: folder) }
        let router = fixtureRouter(keys: keys, engine: FixtureEngine())
        let unauthorized = await router.handle(.init(method: "GET", target: "/v1/models", headers: [:], body: Data()))
        XCTAssertEqual(unauthorized.status, 401)
        let token = try await keys.create(name: "Fixture")
        let valid = HTTPRequest(method: "GET", target: "/v1/models", headers: ["authorization": "Bearer " + token], body: Data())
        let response = await router.handle(valid); XCTAssertEqual(response.status, 200)
        var browser = valid; browser.headers["origin"] = "https://example.test"
        let blocked = await router.handle(browser); XCTAssertEqual(blocked.status, 401)
        let records = await keys.list(); try await keys.revoke(XCTUnwrap(records.first).id)
        let revoked = await router.handle(valid); XCTAssertEqual(revoked.status, 401)
    }
    func testRouterGenerationAndMalformedBody() async throws {
        let (keys, folder) = try vault(); defer { try? FileManager.default.removeItem(at: folder) }
        let token = try await keys.create(name: "Fixture"), router = fixtureRouter(keys: keys, engine: FixtureEngine())
        var request = HTTPRequest(method: "POST", target: "/v1/generate", headers: ["authorization": "Bearer " + token, "content-type": "application/json"], body: try JSONEncoder().encode(GenerationRequest(model: "fixture", prompt: "Synthetic")))
        let valid = await router.handle(request); XCTAssertEqual(valid.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(GenerationResponse.self, from: valid.body).text, "Synthetic response")
        request.body = Data("{".utf8)
        let malformed = await router.handle(request); XCTAssertEqual(malformed.status, 400)
    }
    func testModelSettingsCanUpdateWithoutRestartingTheRouter() async throws {
        let (keys, folder) = try vault(); defer { try? FileManager.default.removeItem(at: folder) }
        let token = try await keys.create(name: "Hot configuration fixture")
        let router = fixtureRouter(keys: keys, engine: FixtureEngine())
        let request = HTTPRequest(method: "POST", target: "/v1/generate", headers: ["authorization": "Bearer " + token, "content-type": "application/json"], body: try JSONEncoder().encode(GenerationRequest(model: "fixture", prompt: "Synthetic")))
        let before = await router.handle(request)
        XCTAssertEqual(try JSONDecoder().decode(GenerationResponse.self, from: before.body).text, "Synthetic response")
        await router.update(engine: FixtureEngine(text: "Updated model configuration"))
        let after = await router.handle(request)
        XCTAssertEqual(after.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(GenerationResponse.self, from: after.body).text, "Updated model configuration")
    }
    func testParserRejectsAmbiguousFraming() throws {
        XCTAssertThrowsError(try HTTPParser.parse(Data("POST /v1/generate HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\na".utf8)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("POST /v1/generate HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("POST /v1/generate HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)))
        XCTAssertThrowsError(try HTTPParser.parse(Data("GET /v1/models HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n".utf8)))
        XCTAssertNil(try HTTPParser.parse(Data("POST /v1/generate HTTP/1.1\r\nContent-Length: 2\r\n\r\na".utf8)))
    }
    func testConfigurationKeepsBackendLocalAndExplicit() throws {
        var config = ServiceConfiguration(); try config.validate()
        config.ollamaURL = "https://example.test"; XCTAssertThrowsError(try config.validate())
        config.ollamaURL = "http://127.0.0.1:18768"; config.generationModels = ["model:cloud"]; XCTAssertThrowsError(try config.validate())
        config.generationModels = ["clef-flash:9b-mxfp8"]; XCTAssertThrowsError(try config.validate())
    }
    func testDecisionBackendRejectsWrongChoicesOrMissingUsage() async throws {
        let question = DecisionQuestion("Synthetic classification", choices: ["yes": "Relevant", "no": "Irrelevant"])
        let request = DecisionRequest(state: .string("Synthetic"), questions: ["answer": question])
        let invalid = DecisionResponse(model: request.model, answers: ["answer": .init(choice: "yes", probabilities: ["yes": 0.1, "no": 0.9], confidence: 0.9)], usage: .init(input: 3, output: 1))
        let engine = try fixtureEngine(configuration: .init()) { wire in
            XCTAssertEqual(wire.url?.path, "/v1/systemone")
            return (try JSONEncoder().encode(invalid), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await engine.decide(request); XCTFail("Invalid probabilities accepted") } catch {}
        var bad = request; bad.questions = [:]
        do { _ = try await engine.decide(bad); XCTFail("Empty questions accepted") } catch {}
    }
    func testLocalGenerationAndSwiftClientWireContract() async throws {
        var configuration = ServiceConfiguration(); configuration.generationModels = ["fixture:small"]
        let engine = try fixtureEngine(configuration: configuration) { wire in
            XCTAssertEqual(wire.url?.host, "127.0.0.1")
            if wire.url?.path == "/api/show" {
                return (Data(#"{"thinking":{"values":[false,true]}}"#.utf8), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let body = try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(wire.httpBody))
            XCTAssertEqual(body.object?["stream"], .bool(false))
            XCTAssertEqual(body.object?["think"], .bool(false))
            return (Data(#"{"model":"fixture:small","response":"Synthetic","done":true,"prompt_eval_count":5,"eval_count":2}"#.utf8), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let response = try await engine.generate(.init(model: "fixture:small", prompt: "Synthetic"))
        XCTAssertEqual(response.usage.input_tokens, 5)
        let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:18767")!, apiKey: "synthetic") { wire in
            XCTAssertEqual(wire.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic")
            XCTAssertEqual(wire.url?.path, "/v1/generate")
            return (try JSONEncoder().encode(response), HTTPURLResponse(url: wire.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let output = try await client.generate(.init(model: "fixture:small", prompt: "Synthetic")); XCTAssertEqual(output.text, "Synthetic")
    }
    func testActualLoopbackListenerAndStop() async throws {
        let ready = expectation(description: "Listener ready")
        let server = try LoopbackServer(port: 0) { _ in .error("Synthetic", status: 401) }
        let task = Task { try await server.run { ready.fulfill() } }
        defer { server.stop(); task.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(server.port)
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/models")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        server.stop(); try await task.value
    }
    func testAuthenticatedHTTPGenerationRoundTripAndRevocation() async throws {
        let (keys, folder) = try vault(); defer { try? FileManager.default.removeItem(at: folder) }
        let token = try await keys.create(name: "HTTP fixture")
        let router = fixtureRouter(keys: keys, engine: FixtureEngine())
        let ready = expectation(description: "Authenticated listener ready")
        let server = try LoopbackServer(port: 0) { await router.handle($0) }
        let task = Task { try await server.run { ready.fulfill() } }
        defer { server.stop(); task.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        let client = try ModelAPIClient(baseURL: URL(string: "http://127.0.0.1:\(XCTUnwrap(server.port))")!, apiKey: token)
        let response = try await client.generate(.init(model: "fixture", prompt: "Synthetic"))
        XCTAssertEqual(response.text, "Synthetic response")
        let records = await keys.list(); try await keys.revoke(XCTUnwrap(records.first).id)
        do { _ = try await client.models(); XCTFail("Revoked HTTP key accepted") } catch {}
        server.stop(); try await task.value
    }
    func testLiveAppleGenerationWhenExplicitlyRequested() async throws {
        guard ProcessInfo.processInfo.environment["MODEL_API_LIVE_APPLE"] == "1" else { throw XCTSkip("Opt-in Apple model check") }
        let apple = AppleModel(), status = await apple.status()
        guard status.available else { throw XCTSkip(status.detail) }
        let response = try await apple.generate(.init(model: "apple", prompt: "Write one short greeting.", maxTokens: 20))
        XCTAssertFalse(response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(response.model, "apple")
    }
}

private struct WaitingEngine: ModelEngine {
    func models() async -> [ModelInfo] { [] }
    func generate(_ value: GenerationRequest) async throws -> GenerationResponse {
        try await Task.sleep(for: .seconds(30)); return .init(model:value.model,text:"Cancelled work must not finish")
    }
    func decide(_ value: DecisionRequest) async throws -> DecisionResponse { .init(model:value.model,answers:[:]) }
}
extension ServiceTests {
    func testJobsAPIIsolationCancellationAndKeyRevocation() async throws {
        let (keys,folder) = try vault(); defer { try? FileManager.default.removeItem(at:folder) }
        let a = try await keys.create(name:"a"), b = try await keys.create(name:"b"), queue = fixtureQueue()
        await keys.observeRevocations { await queue.revoke($0) }
        let router = ModelRouter(keys:keys,engine:WaitingEngine(),jobs:queue)
        func request(_ method:String,_ path:String,_ token:String,_ data:Data = Data()) -> HTTPRequest {
            .init(method:method,target:path,headers:["authorization":"Bearer " + token,"content-type":"application/json"],body:data)
        }
        let body = try JSONEncoder().encode(JobSubmission(operation:"generation",request:.object(["model":.string("fixture"),"prompt":.string("Synthetic") ])))
        let response = await router.handle(request("POST","/v1/jobs",a,body)); XCTAssertEqual(response.status,202)
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let job = try decoder.decode(ModelJob.self,from:response.body)
        let cross = await router.handle(request("GET","/v1/jobs/\(job.id)",b));XCTAssertEqual(cross.status,404)
        let list = await router.handle(request("GET","/v1/jobs",b)); XCTAssertTrue(try decoder.decode([ModelJob].self,from:list.body).isEmpty)
        let cancel = await router.handle(request("POST","/v1/jobs/\(job.id)/cancel",b));XCTAssertEqual(cancel.status,404)
        let pending = await router.handle(request("GET","/v1/jobs/\(job.id)/result",a));XCTAssertEqual(pending.status,409)
        let identity = await keys.identity(for:a);let owner = try XCTUnwrap(identity);try await keys.revoke(owner)
        let cancelled = try await queue.job(job.id);XCTAssertEqual(cancelled.state,.cancelled)
        let rejected = await router.handle(request("GET","/v1/jobs",a));XCTAssertEqual(rejected.status,401)
        await queue.shutdown()
    }
}
extension ServiceTests {
    func testHTTPDisconnectCancelsSyncWorkButAsyncSubmissionSurvives() async throws {
        let (keys,folder) = try vault();defer { try? FileManager.default.removeItem(at:folder) }
        let token=try await keys.create(name:"Fixture"),queue=fixtureQueue(),ready=expectation(description:"Ready")
        let router=ModelRouter(keys:keys,engine:WaitingEngine(),jobs:queue)
        let server=try LoopbackServer(port:0) { await router.handle($0) }
        let serving=Task { try await server.run { ready.fulfill() } }
        await fulfillment(of:[ready],timeout:3)
        defer { server.stop();serving.cancel() }
        let client=try ModelAPIClient(baseURL:URL(string:"http://127.0.0.1:\(try XCTUnwrap(server.port))")!,apiKey:token)
        let asyncJob=try await client.submit(.init(operation:"generation",request:.object(["model":.string("fixture"),"prompt":.string("Synthetic")])))
        try await Task.sleep(for:.milliseconds(50))
        let independent=try await queue.job(asyncJob.id);XCTAssertFalse(independent.state.terminal)
        _ = try await client.cancelJob(asyncJob.id)
        let synchronous=Task { try await client.generate(.init(model:"fixture",prompt:"Synthetic")) }
        var id:UUID?
        for _ in 0..<40 {
            if let job=await queue.list().first(where:{ $0.id != asyncJob.id && $0.state == .running }) { id=job.id;break }
            try await Task.sleep(for:.milliseconds(25))
        }
        XCTAssertNotNil(id);synchronous.cancel();_ = try? await synchronous.value
        if let id {
            for _ in 0..<40 { if try await queue.job(id).state.terminal { break };try await Task.sleep(for:.milliseconds(25)) }
            let cancelled=try await queue.job(id);XCTAssertEqual(cancelled.state,.cancelled)
        }
        await queue.shutdown();server.stop();try await serving.value
    }
}
