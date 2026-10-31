import Foundation
import ModelAPI

/// Component estimate for Muse's dense GGUF text path. Not a measured peak.
/// Unknown architectures retain the older conservative fallback in the engine.
public struct OllamaMemoryEstimate: Sendable {
    public let weights: Int64
    public let kvCache: Int64
    public let runtimeWorkspace: Int64
    public let margin: Int64
    public var total: Int64 { weights + kvCache + runtimeWorkspace + margin }
    public static let defaultContext = 8192
    public static let batchTokens = 128
    public static func muse(weights: Int64, metadata: JSONValue, context: Int) -> Self? {
        guard weights > 0, weights <= 128 << 30, (512...8192).contains(context),
              metadata.object?["details"]?.object?["format"]?.string == "gguf",
              metadata.object?["details"]?.object?["quantization_level"]?.string == "Q4_K_M",
              let info = metadata.object?["model_info"]?.object,
              info["general.architecture"]?.string == "muse-glimmer" else { return nil }
        func integer(_ name: String, range: ClosedRange<Int64>) -> Int64? {
            guard let n = info["muse-glimmer." + name]?.numberValue, n.isFinite,
                  let value = Int64(exactly: n), range.contains(value) else { return nil }
            return value
        }
        guard let layers = integer("block_count", range: 1...256),
              let heads = integer("attention.head_count_kv", range: 1...256),
              let key = integer("attention.key_length", range: 1...1024),
              let value = integer("attention.value_length", range: 1...1024), layers == 52, heads == 2, key == 128, value == 128, integer("embedding_length", range: 1...65536) == 6656, integer("feed_forward_length", range: 1...262144) == 19968 else { return nil }
        // FP16 K and V for every layer/token. Do not assume sliding-window savings
        // or a quantized cache that the selected runtime may not actually provide.
        let kv = Int64(context) * layers * heads * (key + value) * 2
        // One explicit runtime/graph/activation workspace at batch <=128, instead
        // of both a 35% weight multiplier and a separate 2 GiB allowance.
        return .init(weights: weights, kvCache: kv, runtimeWorkspace: 2 << 30,
                     margin: max(512 << 20, weights / 20))
    }
}
