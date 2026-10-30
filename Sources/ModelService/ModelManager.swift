import Foundation
import ModelAPI

public struct LoadedModel: Sendable, Identifiable {
    public var id: String
    public var digest: String?
    public var memoryBytes: Int64?
    public func matches(_ model: InstalledModel) -> Bool {
        id == model.id || (digest != nil && digest == model.digest)
    }
}

/// Operator-only controls for the configured local runtime. No weight paths or
/// credentials are accepted; deletion goes through Ollama's exact model tag API.
public struct ModelManager: Sendable {
    private let configuration: ServiceConfiguration
    private let transport: ModelAPIClient.Transport
    public init(configuration: ServiceConfiguration, transport: ModelAPIClient.Transport? = nil) throws {
        try configuration.validate(); self.configuration = configuration; self.transport = transport ?? HTTPTransport.send
    }
    private func call(_ path: String, method: String = "GET", body: JSONValue? = nil, allowMissing: Bool = false) async throws -> JSONValue {
        var request = URLRequest(url: URL(string: configuration.ollamaURL)!.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = method == "GET" ? 5 : 115
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await transport(request)
        try Task.checkCancellation()
        if allowMissing, response.statusCode == 404 { return .null }
        guard (200..<300).contains(response.statusCode) else { throw ModelAPIError.unavailable("Local model operation failed (HTTP \(response.statusCode)).") }
        guard data.count <= 1_000_000 else { throw ModelAPIError.limit("Local runtime response exceeds 1 MB.") }
        return data.isEmpty ? .null : try JSONDecoder().decode(JSONValue.self, from: data)
    }
    public func loaded() async throws -> [LoadedModel] {
        let result = try await call("api/ps")
        guard case .array(let models) = result.object?["models"] else { throw ModelAPIError.invalid("Invalid loaded-model status.") }
        return models.compactMap { value in
            guard let name = value.object?["name"]?.string, ServiceConfiguration.isLocalModel(name) else { return nil }
            return .init(id: name, digest: value.object?["digest"]?.string,
                         memoryBytes: value.object?["size_vram"]?.numberValue.flatMap(Int64.init(exactly:)))
        }
    }
    private func installed(_ name: String) async throws -> InstalledModel? {
        guard ServiceConfiguration.isLocalModel(name) else { throw ModelAPIError.invalid("Choose an installed local model.") }
        return try await ModelLibrary(configuration: configuration, transport: transport).installed().first { $0.id == name }
    }
    public func load(_ name: String) async throws {
        guard let model = try await installed(name), let capability = model.capability else { throw ModelAPIError.invalid("This model is missing or has no supported model type.") }
        var body: [String: JSONValue] = ["model": .string(name), "keep_alive": .number(1800)]
        let path: String
        switch capability {
        case .transcription, .speech, .conversation: throw ModelAPIError.invalid("Use the local audio runtime for this model.")
        case .generation:
            path = "api/generate"; body["stream"] = .bool(false)
        case .embedding:
            path = "api/embed"; body["input"] = .array([.string("Local model readiness check.")]); body["truncate"] = .bool(false)
        case .decision:
            path = "v1/systemone"; body["state"] = .string("Positronic is preparing this local model.")
            body["questions"] = .object(["ready": .object(["type": .string("choice"), "instructions": .string("Is this text about preparing a local model?"),
                "criteria": .object(["yes": .string("Preparing a local model"), "no": .string("Another subject")])])])
        }
        let result = try await call(path, method: "POST", body: .object(body))
        guard result.object?["model"]?.string == name else { throw ModelAPIError.invalid("The runtime loaded a different model.") }
        try await wait(for: model, loaded: true)
    }
    public func unload(_ name: String) async throws {
        guard let model = try await installed(name) else { return }
        // Ollama accepts an empty keep_alive=0 generate request for every model type.
        _ = try await call("api/generate", method: "POST", body: .object(["model": .string(name), "stream": .bool(false), "keep_alive": .number(0)]))
        try await wait(for: model, loaded: false)
    }
    public func remove(_ name: String) async throws {
        guard try await installed(name) != nil else { return }
        try await unload(name)
        _ = try await call("api/delete", method: "DELETE", body: .object(["model": .string(name)]), allowMissing: true)
        guard try await installed(name) == nil else { throw ModelAPIError.unavailable("The model is still installed. Its files were not confirmed removed.") }
    }
    private func wait(for model: InstalledModel, loaded expected: Bool) async throws {
        for _ in 0..<40 {
            if try await loaded().contains(where: { $0.matches(model) }) == expected { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw ModelAPIError.unavailable(expected ? "The model did not become ready in memory." : "The runtime has not released this model from memory yet.")
    }
}
