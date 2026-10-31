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
    private var nvfp4Metadata: JSONValue { .object([
        "details": .object(["format": .string("safetensors"), "quantization_level": .string("nvfp4")]),
        "model_info": .object(["general.architecture": .string("muse_glimmer"),
            "general.parameter_count": .number(29_775_638_080),
            "muse_glimmer.block_count": .number(52), "muse_glimmer.attention.head_count_kv": .number(2),
            "muse_glimmer.attention.head_count": .number(32),
            "muse_glimmer.embedding_length": .number(6656), "muse_glimmer.feed_forward_length": .number(19968)])]) }
    func testVerifiedNVFP4IsSmallerWithoutDiscountingItsWeights() throws {
        let estimate = try XCTUnwrap(OllamaMemoryEstimate.museNVFP4(weights: 17_272_403_205,
            metadata: nvfp4Metadata, context: 1024, revision: OllamaMemoryEstimate.nvfp4Revision, runtime: "0.40.12"))
        let gguf = try XCTUnwrap(OllamaMemoryEstimate.muse(weights: 18_157_010_252, metadata: metadata, context: 1024))
        XCTAssertEqual(estimate.weights, 17_272_403_205)
        XCTAssertEqual(estimate.kvCache, 54_525_952)
        XCTAssertEqual(estimate.total, 20_338_032_965)
        XCTAssertLessThan(estimate.total, gguf.total)
        XCTAssertNil(OllamaMemoryEstimate.museNVFP4(weights: estimate.weights, metadata: nvfp4Metadata,
            context: 1024, revision: "unverified", runtime: "0.40.12"))
        XCTAssertNil(OllamaMemoryEstimate.museNVFP4(weights: estimate.weights, metadata: nvfp4Metadata,
            context: 1024, revision: OllamaMemoryEstimate.nvfp4Revision, runtime: "unknown"))
        XCTAssertNil(OllamaMemoryEstimate.museNVFP4(weights: estimate.weights - 1, metadata: nvfp4Metadata,
            context: 1024, revision: OllamaMemoryEstimate.nvfp4Revision, runtime: "0.40.12"))
        var bad = nvfp4Metadata.object!, info = bad["model_info"]!.object!
        info["muse_glimmer.attention.head_count_kv"] = .number(4); bad["model_info"] = .object(info)
        XCTAssertNil(OllamaMemoryEstimate.museNVFP4(weights: estimate.weights, metadata: .object(bad),
            context: 1024, revision: OllamaMemoryEstimate.nvfp4Revision, runtime: "0.40.12"))
    }
    func testEngineUsesVerifiedNVFP4ComponentsAndFallsBackForUnknownLoader() async throws {
        let fixture = nvfp4Metadata
        for version in ["0.40.12", "unverified"] {
            let engine = try LocalModelEngine(configuration: .init(), contextTokens: 1024, transport: { request in
                let value: JSONValue
                switch request.url!.path {
                case "/api/tags": value = .object(["models": .array([.object([
                    "name": .string("muse-glimmer:30b-nvfp4"), "size": .number(17_272_403_205),
                    "digest": .string(OllamaMemoryEstimate.nvfp4Revision)])])])
                case "/api/show": value = fixture
                case "/api/version": value = .object(["version": .string(version)])
                default: throw ModelAPIError.invalid("Unexpected request")
                }
                return (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            let budget = await engine.budget(for: "muse-glimmer:30b-nvfp4")
            let expected: Int64 = version == "0.40.12" ? 20_338_032_965 : Int64(Double(17_272_403_205) * 1.35) + (2 << 30)
            XCTAssertEqual(budget, expected)
        }
    }
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
