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
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Output.self, from: data)
    }
}

/// Refuse redirects so credentials and prompts stay with the configured endpoint.
public final class HTTPTransport: NSObject, URLSessionTaskDelegate, Sendable {
    public static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, raw) = try await session.bytes(for: request)
            guard let response = raw as? HTTPURLResponse else { throw ModelAPIError.unavailable("Invalid HTTP response.") }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_000_000 else { throw ModelAPIError.limit("Model response exceeds 1 MB.") }
                data.append(byte)
            }
            return (data, response)
        } onCancel: { session.invalidateAndCancel() }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public extension ModelAPIClient {
    func jobs() async throws -> [ModelJob] { try await request("v1/jobs", body: Optional<String>.none) }
    func job(_ id: UUID) async throws -> ModelJob { try await request("v1/jobs/\(id.uuidString)", body: Optional<String>.none) }
    func cancelJob(_ id: UUID) async throws -> ModelJob { try await request("v1/jobs/\(id.uuidString)/cancel", body: [String: String]()) }
    func submit(_ submission: JobSubmission) async throws -> ModelJob { try await request("v1/jobs", body: submission) }
    func speech(_ request: SpeechRequest) async throws -> ModelJob { try request.validate(); return try await self.request("v1/audio/speech", body: request) }
    func transcriptResult(_ id: UUID) async throws -> Transcript { try await request("v1/jobs/\(id.uuidString)/result", body: Optional<String>.none) }
    func transcribe(file: URL, language: String) async throws -> ModelJob {
        guard ["en", "nl"].contains(language), let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0, size <= 64 * 1024 * 1024 else { throw ModelAPIError.invalid("Choose en or nl and an audio file up to 64 MiB.") }
        let boundary = "Positronic-" + UUID().uuidString
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: temp) }
        let writer = try FileHandle(forWritingTo: temp), reader = try FileHandle(forReadingFrom: file)
        defer { try? writer.close(); try? reader.close() }
        func write(_ value: String) throws { try writer.write(contentsOf: Data(value.utf8)) }
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nwhisper-large-v3-turbo\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(language)\r\n")
        try write("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio\"\r\nContent-Type: application/octet-stream\r\n\r\n")
        var count = 0
        while let chunk = try reader.read(upToCount: 65536), !chunk.isEmpty {
            try Task.checkCancellation(); count += chunk.count
            guard count <= 64 * 1024 * 1024 else { throw ModelAPIError.limit("Audio file grew beyond 64 MiB.") }; try writer.write(contentsOf: chunk)
        }
        try write("\r\n--\(boundary)--\r\n"); try writer.close()
        var wire = URLRequest(url: baseURL.appendingPathComponent("v1/audio/transcriptions")); wire.httpMethod = "POST"; wire.timeoutInterval = 130
        wire.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization"); wire.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.upload(for: wire, fromFile: temp)
        guard let response = response as? HTTPURLResponse, response.statusCode == 202 else { throw ModelAPIError.unavailable("Audio upload was not accepted.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(ModelJob.self, from: data)
    }
    func downloadAudioResult(_ id: UUID, to destination: URL) async throws {
        var wire = URLRequest(url: baseURL.appendingPathComponent("v1/jobs/\(id.uuidString)/result")); wire.timeoutInterval = 120
        wire.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]; config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil); defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: wire)
        guard let reply = response as? HTTPURLResponse, reply.statusCode == 200, reply.mimeType == "audio/wav", (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw ModelAPIError.unavailable("Speech result is unavailable or invalid.") }
        try FileManager.default.moveItem(at: file, to: destination)
    }
}
