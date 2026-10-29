import Foundation
import ModelAPI

public enum ModelCapability: String, Codable, Sendable, CaseIterable {
    case generation, decision, embedding
    public var title: String { switch self { case .generation: "Generation"; case .decision: "Decisions"; case .embedding: "Embeddings" } }
}
public struct ModelPreset: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var capability: ModelCapability
    public var detail: String
    public var source: URL
}
public struct InstalledModel: Identifiable, Sendable {
    public var id: String
    public var capability: ModelCapability?
    public var sizeBytes: Int64?
    public var detail: String
}
public struct ModelDownloadProgress: Decodable, Sendable {
    public var status: String?
    public var total: Double?
    public var completed: Double?
    public var error: String?
    public var fraction: Double? {
        guard let total, let completed, total.isFinite, completed.isFinite, total > 0 else { return nil }
        return min(1, max(0, completed / total))
    }
}

/// Read-only discovery and explicit operator downloads. No model is enabled by discovery alone.
public struct ModelLibrary: Sendable {
    public static let presets: [ModelPreset] = [
        .init(id: "qwen3.5:4b", name: "Qwen 3.5 · 4B", capability: .generation, detail: "General writing, coding and reasoning", source: URL(string: "https://ollama.com/library/qwen3.5")!),
        .init(id: "gemma4:e2b", name: "Gemma 4 · E2B", capability: .generation, detail: "A compact general-purpose model", source: URL(string: "https://ollama.com/library/gemma4")!),
        .init(id: "llama3.2:3b", name: "Llama 3.2 · 3B", capability: .generation, detail: "Compact text generation", source: URL(string: "https://ollama.com/library/llama3.2")!),
        .init(id: "mistral:7b", name: "Mistral · 7B", capability: .generation, detail: "General-purpose text generation", source: URL(string: "https://ollama.com/library/mistral")!),
        .init(id: "deepseek-r1:8b", name: "DeepSeek R1 · 8B", capability: .generation, detail: "Reasoning-oriented generation", source: URL(string: "https://ollama.com/library/deepseek-r1")!),
        .init(id: "qwen2.5-coder:7b", name: "Qwen 2.5 Coder · 7B", capability: .generation, detail: "Code generation and explanation", source: URL(string: "https://ollama.com/library/qwen2.5-coder")!),
        .init(id: "clef-flash:9b-mxfp8", name: "Clef Flash · 9B MXFP8", capability: .decision, detail: "The variant used by the existing local Clef setup", source: URL(string: "https://ollama.com/library/clef-flash")!),
        .init(id: "clef-flash:9b", name: "Clef Flash · 9B", capability: .decision, detail: "Typed classification and policy decisions", source: URL(string: "https://ollama.com/library/clef-flash")!),
        .init(id: "clef:27b", name: "Clef · 27B", capability: .decision, detail: "Larger decision model; needs more Mac memory", source: URL(string: "https://ollama.com/library/clef")!),
        .init(id: "nimble:9b", name: "Nimble · 9B", capability: .decision, detail: "Fast typed text classification", source: URL(string: "https://ollama.com/library/nimble")!),
        .init(id: "tev1:4b", name: "Tev1 · 4B", capability: .decision, detail: "Compact typed decisions", source: URL(string: "https://ollama.com/library/tev1")!),
        .init(id: "tev1:0.8b", name: "Tev1 · 0.8B", capability: .decision, detail: "Small decision model for tighter memory budgets", source: URL(string: "https://ollama.com/library/tev1")!),
        .init(id: "embeddinggemma:latest", name: "EmbeddingGemma", capability: .embedding, detail: "Text vectors for search and retrieval", source: URL(string: "https://ollama.com/library/embeddinggemma")!),
        .init(id: "nomic-embed-text:latest", name: "Nomic Embed Text", capability: .embedding, detail: "Text vectors for semantic search", source: URL(string: "https://ollama.com/library/nomic-embed-text")!)
    ]
    private let baseURL: URL
    private let transport: ModelAPIClient.Transport
    private static func hasRemote(_ value: JSONValue?) -> Bool {
        ["remote_host", "remote_model"].contains { !(value?.object?[$0]?.string ?? "").isEmpty }
    }
    public init(configuration: ServiceConfiguration, transport: ModelAPIClient.Transport? = nil) throws {
        try configuration.validate(); baseURL = URL(string: configuration.ollamaURL)!
        self.transport = transport ?? HTTPTransport.send
    }
    public func installed() async throws -> [InstalledModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags")); request.timeoutInterval = 5
        let (data, response) = try await transport(request)
        guard response.statusCode == 200, data.count <= 1_000_000,
              case .array(let tags) = try JSONDecoder().decode(JSONValue.self, from: data).object?["models"], tags.count <= 128 else {
            throw ModelAPIError.unavailable("Could not list the local runtime’s models.")
        }
        var installed: [InstalledModel] = []
        for tag in tags {
            try Task.checkCancellation()
            guard let name = tag.object?["name"]?.string, ServiceConfiguration.isLocalModel(name),
                  !Self.hasRemote(tag) else { continue }
            var details = URLRequest(url: baseURL.appendingPathComponent("api/show")); details.httpMethod = "POST"; details.timeoutInterval = 5
            details.setValue("application/json", forHTTPHeaderField: "Content-Type")
            details.httpBody = try JSONEncoder().encode(["model": name])
            let metadata: JSONValue?
            if let (bytes, reply) = try? await transport(details), reply.statusCode == 200, bytes.count <= 1_000_000 {
                metadata = try? JSONDecoder().decode(JSONValue.self, from: bytes)
            } else { metadata = nil }
            guard !Self.hasRemote(metadata) else { continue }
            var capabilities = Set<String>()
            if case .array(let list) = metadata?.object?["capabilities"] { capabilities = Set(list.compactMap(\.string)) }
            guard !capabilities.contains("cloud") else { continue }
            let capability: ModelCapability?
            if capabilities.contains("embedding") || capabilities.contains("embeddings") { capability = .embedding }
            else if capabilities.contains("decision") { capability = .decision }
            else if capabilities.contains("completion") { capability = .generation }
            else { capability = Self.presets.first(where: { $0.id == name })?.capability }
            let rawDetails = metadata?.object?["details"]?.object ?? tag.object?["details"]?.object
            let description = [rawDetails?["parameter_size"]?.string, rawDetails?["quantization_level"]?.string].compactMap { $0 }.joined(separator: " · ")
            installed.append(.init(id: name, capability: capability, sizeBytes: tag.object?["size"]?.numberValue.flatMap(Int64.init(exactly:)), detail: description))
        }
        return installed.sorted { $0.id < $1.id }
    }
    public func download(_ preset: ModelPreset, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        guard Self.presets.contains(where: { $0.id == preset.id }), ServiceConfiguration.isLocalModel(preset.id) else { throw ModelAPIError.invalid("Choose a local model from the library.") }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull")); request.httpMethod = "POST"; request.timeoutInterval = 3600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["model": JSONValue.string(preset.id), "stream": .bool(true)])
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard (raw as? HTTPURLResponse)?.statusCode == 200 else { throw ModelAPIError.unavailable("Local runtime could not download this model.") }
        var success = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count < 64_000 else { throw ModelAPIError.limit("Invalid model download progress.") }
            let update = try JSONDecoder().decode(ModelDownloadProgress.self, from: Data(line.utf8))
            guard update.error == nil else { throw ModelAPIError.unavailable("The model download failed. Check runtime compatibility and available disk space.") }
            progress(update)
            if update.status == "success" { success = true }
        }
        guard success else { throw ModelAPIError.unavailable("The model download ended before completion.") }
    }
}
