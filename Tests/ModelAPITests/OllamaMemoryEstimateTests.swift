import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

final class OllamaMemoryEstimateTests: XCTestCase, @unchecked Sendable {
    private var metadata: JSONValue { .object([
        "details": .object(["format": .string("gguf"), "quantization_level": .string("Q4_K_M")]),
        "model_info": .object(["general.architecture": .string("muse-glimmer"),
            "muse-glimmer.block_count": .number(52), "muse-glimmer.attention.head_count_kv": .number(2),
            "muse-glimmer.attention.key_length": .number(128), "muse-glimmer.attention.value_length": .number(128),
            "muse-glimmer.embedding_length": .number(6656), "muse-glimmer.feed_forward_length": .number(19968)])]) }
    func testMuseCountsWeightsFP16CacheAndOneWorkspace() throws {
        let short = try XCTUnwrap(OllamaMemoryEstimate.muse(weights: 18_157_010_252, metadata: metadata, context: 1024))
        let full = try XCTUnwrap(OllamaMemoryEstimate.muse(weights: short.weights, metadata: metadata, context: 8192))
        XCTAssertEqual(short.kvCache, 54_525_952)
        XCTAssertEqual(full.kvCache, short.kvCache * 8)
        XCTAssertEqual(short.runtimeWorkspace, 2 << 30)
        XCTAssertEqual(short.total, short.weights + short.kvCache + short.runtimeWorkspace + short.margin)
        XCTAssertLessThan(short.total, Int64(Double(short.weights) * 1.35) + (2 << 30))
        XCTAssertNil(OllamaMemoryEstimate.muse(weights: short.weights, metadata: .null, context: 1024))
        XCTAssertNil(OllamaMemoryEstimate.muse(weights: short.weights, metadata: metadata, context: 131072))
        XCTAssertNil(OllamaMemoryEstimate.muse(weights: -1, metadata: metadata, context: 1024))
    }
    func testEngineEnforcesTheContextAndBatchItBudgets() async throws {
        var config = ServiceConfiguration(); config.generationModels = ["muse-glimmer:30b"]
        let fixture = metadata
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = JobQueue(directory: directory, interval: .milliseconds(5), probe: {
            .init(physical: 36 << 30, available: 32 << 30, disk: 50 << 30)
        })
        let engine = try LocalModelEngine(configuration: config, contextTokens: 1024, transport: { request in
            let body: JSONValue
            switch request.url!.path {
            case "/api/tags": body = .object(["models": .array([.object(["name": .string("muse-glimmer:30b"), "size": .number(18_157_010_252)])])])
            case "/api/show": body = fixture
            case "/api/generate":
                let sent = try JSONDecoder().decode(JSONValue.self, from: request.httpBody!)
                XCTAssertEqual(sent.object?["options"]?.object?["num_ctx"], .number(1024))
                XCTAssertEqual(sent.object?["options"]?.object?["num_batch"], .number(128))
                body = .object(["model": .string("muse-glimmer:30b"), "done": .bool(true), "response": .string("4")])
            default: throw ModelAPIError.invalid("Unexpected request")
            }
            return (try JSONEncoder().encode(body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, activity: ModelActivity(jobs: queue))
        let budget = await engine.budget(for: "muse-glimmer:30b")
        XCTAssertEqual(budget, OllamaMemoryEstimate.muse(weights: 18_157_010_252, metadata: metadata, context: 1024)?.total)
        let result = try await engine.generate(.init(model: "muse-glimmer:30b", prompt: "2+2?", maxTokens: 32, think: .bool(false)))
        XCTAssertEqual(result.text, "4")
        await queue.shutdown()
    }
}
