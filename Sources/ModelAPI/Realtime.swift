import Foundation

/// Positronic realtime protocol v1; PCM is signed 16-bit little-endian, mono.
public struct RealtimeConfiguration: Codable, Sendable {
    public static let modelID = "nemotron-voicechat-11b-4bit"
    public var model: String
    public var instructions: String
    public var language: String
    public var maxDurationSeconds: Int
    public init(model: String = modelID, instructions: String = "Be helpful and concise.", language: String = "en", maxDurationSeconds: Int = 300) {
        self.model = model; self.instructions = instructions; self.language = language; self.maxDurationSeconds = maxDurationSeconds
    }
    public func validate() throws {
        guard model == Self.modelID, language == "en", instructions.utf8.count <= 1024, (10...600).contains(maxDurationSeconds) else {
            throw ModelAPIError.invalid("Choose Nemotron VoiceChat, English, up to 1024 instruction bytes and a 10–600 second session.")
        }
    }
}
/// Events have a type plus typed optional payloads. Ignore unknown future types.
public struct RealtimeEvent: Codable, Sendable {
    public var type: String
    public var session: RealtimeConfiguration?
    public var job: ModelJob?
    public var audio: String?
    public var delta: String?
    public var message: String?
    public var sequence: Int?
    public var epoch: Int?
    public var sampleRate: Int?
    public var frameSamples: Int?
    public init(_ type: String, session: RealtimeConfiguration? = nil, job: ModelJob? = nil, audio: String? = nil, delta: String? = nil, message: String? = nil, sequence: Int? = nil, epoch: Int? = nil, sampleRate: Int? = nil, frameSamples: Int? = nil) {
        self.type = type; self.session = session; self.job = job; self.audio = audio; self.delta = delta; self.message = message
        self.sequence = sequence; self.epoch = epoch; self.sampleRate = sampleRate; self.frameSamples = frameSamples
    }
}

/// A connection owns one ephemeral conversation. Close it to cancel queued or running work.
public actor RealtimeConnection {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    public init(baseURL: URL, apiKey: String) throws {
        // Reuse the normal client's credential/endpoint validation.
        _ = try ModelAPIClient(baseURL: baseURL, apiKey: apiKey)
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/realtime"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        var request = URLRequest(url: components.url!); request.timeoutInterval = 630
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral; config.connectionProxyDictionary = [:]; config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: HTTPTransport(), delegateQueue: nil)
        socket = session.webSocketTask(with: request); socket.maximumMessageSize = 65536; socket.resume()
    }
    public func send(_ event: RealtimeEvent) async throws {
        let data = try JSONEncoder().encode(event)
        guard data.count <= 65536 else { throw ModelAPIError.limit("Realtime message exceeds 64 KiB.") }
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
    public func configure(_ value: RealtimeConfiguration) async throws { try value.validate(); try await send(.init("session.configure", session: value)) }
    public func appendAudio(_ pcm: Data) async throws {
        guard pcm.count == 2560 else { throw ModelAPIError.invalid("Send exactly 1280 PCM16 samples (80 ms at 16 kHz).") }
        try await send(.init("input_audio.append", audio: pcm.base64EncodedString()))
    }
    public func acknowledge(_ sequence: Int, epoch: Int) async throws { try await send(.init("playback.ack", sequence: sequence, epoch: epoch)) }
    public func receive() async throws -> RealtimeEvent {
        let result = try await socket.receive(); let bytes: Data
        switch result { case .data(let data): bytes = data; case .string(let text): bytes = Data(text.utf8); @unknown default: throw ModelAPIError.invalid("Unsupported realtime message.") }
        guard bytes.count <= 65536 else { throw ModelAPIError.limit("Realtime event exceeds 64 KiB.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(RealtimeEvent.self, from: bytes)
    }
    deinit { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
    public func close() { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
}
