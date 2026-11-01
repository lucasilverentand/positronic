import Foundation
import ModelAPI

/// Component estimates for verified Muse loading paths. Not measured peaks.
/// Unknown architectures retain the older conservative fallback in the engine.
public struct OllamaMemoryEstimate: Sendable {
    public let weights: Int64
    public let kvCache: Int64
    public let runtimeWorkspace: Int64
    public let margin: Int64
    public var total: Int64 { weights + kvCache + runtimeWorkspace + margin }
    public static let defaultContext = 8192
    public static let batchTokens = 128
    public static let nvfp4Revision = "6a78d632287ffae676100cc23ab01eeefc535531ff05ce938b6868375e10670f"
    public static let nvfp4Runtime = "0.40.12"

    public static func muse(weights: Int64, metadata: JSONValue, context: Int) -> Self? {
        guard metadata.object?["details"]?.object?["format"]?.string == "gguf",
              metadata.object?["details"]?.object?["quantization_level"]?.string == "Q4_K_M",
              let info = metadata.object?["model_info"]?.object,
              info["general.architecture"]?.string == "muse-glimmer" else { return nil }
        return components(weights: weights, context: context,
            layers: dimension(info, "muse-glimmer.block_count"),
            heads: dimension(info, "muse-glimmer.attention.head_count_kv"),
            key: dimension(info, "muse-glimmer.attention.key_length"),
            value: dimension(info, "muse-glimmer.attention.value_length"),
            embedding: dimension(info, "muse-glimmer.embedding_length"),
            feedforward: dimension(info, "muse-glimmer.feed_forward_length"))
    }

    /// API show omits head_dim. The pinned config supplies 128, which is not
    /// hidden_size/heads. Unknown revisions/loaders must not inherit that fact.
    public static func museNVFP4(weights: Int64, metadata: JSONValue, context: Int, revision: String?, runtime: String?) -> Self? {
        guard revision == nvfp4Revision, runtime == nvfp4Runtime, weights == 17_272_403_205,
              metadata.object?["details"]?.object?["format"]?.string == "safetensors",
              metadata.object?["details"]?.object?["quantization_level"]?.string == "nvfp4",
              let info = metadata.object?["model_info"]?.object,
              info["general.architecture"]?.string == "muse_glimmer",
              dimension(info, "general.parameter_count") == 29_775_638_080,
              dimension(info, "muse_glimmer.attention.head_count") == 32 else { return nil }
        return components(weights: weights, context: context,
            layers: dimension(info, "muse_glimmer.block_count"),
            heads: dimension(info, "muse_glimmer.attention.head_count_kv"), key: 128, value: 128,
            embedding: dimension(info, "muse_glimmer.embedding_length"),
            feedforward: dimension(info, "muse_glimmer.feed_forward_length"))
    }
    private static func dimension(_ info: [String: JSONValue], _ key: String) -> Int64? {
        guard let n = info[key]?.numberValue, n.isFinite else { return nil }
        return Int64(exactly: n)
    }
    private static func components(weights: Int64, context: Int, layers: Int64?, heads: Int64?, key: Int64?, value: Int64?, embedding: Int64?, feedforward: Int64?) -> Self? {
        guard weights > 0, weights <= 128 << 30, (512...8192).contains(context),
              let layers, layers == 52, let heads, heads == 2,
              let key, key == 128, let value, value == 128,
              embedding == 6656, feedforward == 19968 else { return nil }
        // FP16 K and V for every layer/token. Do not assume sliding-window savings
        // or a quantized cache that the selected runtime may not actually provide.
        let kv = Int64(context) * layers * heads * (key + value) * 2
        // Stored bytes count all tensors (including vision) and metadata once.
        // The verified MLX loader retains packed NVFP4, not a full FP16 duplicate.
        // Keep one provisional runtime/graph/load workspace at batch <=128.
        return .init(weights: weights, kvCache: kv, runtimeWorkspace: 2 << 30,
                     margin: max(512 << 20, weights / 20))
    }
}
