import Foundation

/// The bearer token belongs to the caller and is never persisted by this client.
public struct ModelAPIClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let baseURL: URL
    private let apiKey: String
    private let transport: Transport
    public init(baseURL: URL, apiKey: String, transport: Transport? = nil) throws {
        guard ["http", "https"].contains(baseURL.scheme), baseURL.host != nil, baseURL.user == nil,
              baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
              baseURL.path.isEmpty || baseURL.path == "/", !apiKey.isEmpty,
              !apiKey.contains(where: { $0.isNewline || $0 == "\r" }) else { throw ModelAPIError.invalid("Invalid API connection.") }
        self.baseURL = baseURL; self.apiKey = apiKey; self.transport = transport ?? HTTPTransport.send
    }
    public func models() async throws -> [ModelInfo] { try await request("v1/models", body: Optional<String>.none) }
    public func generate(_ value: GenerationRequest) async throws -> GenerationResponse {
        try value.validate()
        return try await request("v1/generate", body: value, timeout: value.model == "apple-pcc" ? 300 : 120)
    }
    public func embed(_ value: EmbeddingRequest) async throws -> EmbeddingResponse {
        try value.validate()
        let result: EmbeddingResponse = try await request("v1/embeddings", body: value)
        try result.validate(for: value); return result
    }
    public func decide(_ value: DecisionRequest) async throws -> DecisionResponse {
        let result: DecisionResponse = try await request("v1/decisions", body: value)
        guard result.model == value.model else { throw ModelAPIError.invalid("Model identity mismatch.") }
        try result.validate(for: value); return result
    }
    private func request<Input: Encodable, Output: Decodable>(_ path: String, body: Input?, timeout: TimeInterval = 120) async throws -> Output {
        var wire = URLRequest(url: baseURL.appendingPathComponent(path)); wire.timeoutInterval = timeout
        wire.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        if let body {
            wire.httpMethod = "POST"; wire.httpBody = try JSONEncoder().encode(body)
            wire.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(wire)
        guard (200..<300).contains(response.statusCode) else {
            let error = data.count <= 1_000_000 ? try? JSONDecoder().decode([String: String].self, from: data)["error"] : nil
            let detail = error.flatMap { $0.utf8.count <= 4096 ? $0 : nil }
            throw ModelAPIError.unavailable("Model API returned HTTP \(response.statusCode)." + (detail.map { " " + $0 } ?? ""))
        }
        return try JSONDecoder().decode(Output.self, from: data)
    }
}

/// Refuse redirects so credentials and prompts stay with the configured endpoint.
public final class HTTPTransport: NSObject, URLSessionTaskDelegate, Sendable {
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, raw) = try await session.bytes(for: request)
        guard let response = raw as? HTTPURLResponse else { throw ModelAPIError.unavailable("Invalid HTTP response.") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_000_000 else { throw ModelAPIError.limit("Model response exceeds 1 MB.") }
            data.append(byte)
        }
        return (data, response)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
