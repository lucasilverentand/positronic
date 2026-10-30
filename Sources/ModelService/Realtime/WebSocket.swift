import Foundation
import CryptoKit
@preconcurrency import Network
import ModelAPI

/// Bounded RFC 6455 framing. Clients must mask; control frames cannot fragment.
public struct WebSocketFrames: Sendable {
    public struct Frame: Sendable { public var opcode: UInt8; public var payload: Data }
    private var bytes = Data()
    private var fragments = Data()
    private var fragmentOpcode: UInt8?
    public init() {}
    public static func acceptKey(_ request: HTTPRequest) throws -> String {
        guard request.method == "GET", request.path == "/v1/realtime", request.body.isEmpty,
              request.headers["upgrade"]?.lowercased() == "websocket",
              request.headers["connection"]?.lowercased().split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("upgrade") == true,
              request.headers["sec-websocket-version"] == "13", let key = request.headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else { throw ModelAPIError.invalid("Use a WebSocket v13 upgrade.") }
        return Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
    }
    public mutating func append(_ data: Data) throws -> [Frame] {
        guard bytes.count + data.count <= 131100 else { throw ModelAPIError.limit("WebSocket input buffer exceeded.") }; bytes.append(data)
        var result: [Frame] = []
        while bytes.count >= 2 {
            let b = [UInt8](bytes.prefix(14)); let final = b[0] & 0x80 != 0; let opcode = b[0] & 15; let masked = b[1] & 0x80 != 0
            guard b[0] & 0x70 == 0, masked, [0,1,2,8,9,10].contains(opcode) else { throw ModelAPIError.invalid("Invalid WebSocket frame.") }
            let short = Int(b[1] & 127); var length = short; var offset = 2
            if short == 126 {
                guard bytes.count >= 4 else { break }; length = Int(b[2]) << 8 | Int(b[3]); offset = 4
                guard length >= 126 else { throw ModelAPIError.invalid("Noncanonical WebSocket length.") }
            } else if short == 127 {
                guard bytes.count >= 10 else { break }
                let n = b[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                guard n >= 65536, n <= 65536 else { throw ModelAPIError.limit("WebSocket message exceeds 64 KiB.") }; length = Int(n); offset = 10
            }
            guard length <= 65536, opcode < 8 || (final && length <= 125) else { throw ModelAPIError.invalid("Invalid WebSocket control frame.") }
            guard bytes.count >= offset + 4 + length else { break }
            let raw = [UInt8](bytes.prefix(offset + 4 + length)); let mask = Array(raw[offset..<offset+4]); offset += 4
            let payload = Data(raw[offset...].enumerated().map { $0.element ^ mask[$0.offset % 4] }); bytes.removeFirst(offset + length)
            if opcode >= 8 { result.append(.init(opcode: opcode, payload: payload)); continue }
            if opcode == 0 {
                guard let original = fragmentOpcode, fragments.count + payload.count <= 65536 else { throw ModelAPIError.invalid("Invalid fragmented message.") }
                fragments.append(payload)
                if final { result.append(.init(opcode: original, payload: fragments)); fragments = Data(); fragmentOpcode = nil }
            } else {
                guard fragmentOpcode == nil else { throw ModelAPIError.invalid("Interleaved fragmented messages.") }
                if final { result.append(.init(opcode: opcode, payload: payload)) } else { fragmentOpcode = opcode; fragments = payload }
            }
        }
        return result
    }
    public static func encode(_ payload: Data, opcode: UInt8 = 1) -> Data {
        var result = Data([0x80 | opcode])
        if payload.count < 126 { result.append(UInt8(payload.count)) }
        else if payload.count <= 65535 { result.append(126); result.append(UInt8(payload.count >> 8)); result.append(UInt8(payload.count & 255)) }
        else { result.append(127); for shift in stride(from: 56, through: 0, by: -8) { result.append(UInt8((UInt64(payload.count) >> shift) & 255)) } }
        result.append(payload); return result
    }
}

/// Each send waits for network consumption; no unbounded outbound task queue.
public actor RealtimeSocket {
    private let connection: NWConnection
    private var frames = WebSocketFrames()
    public init(connection: NWConnection) { self.connection = connection }
    private func write(_ data: Data) async throws {
        let timeout = Task { do { try await Task.sleep(for: .seconds(2)); connection.cancel() } catch {} }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { if let error = $0 { c.resume(throwing: error) } else { c.resume() } })
        }
    }
    public func upgrade(accept: String) async throws { try await write(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nCache-Control: no-store\r\n\r\n".utf8)) }
    public func send(_ event: RealtimeEvent) async throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event); guard data.count <= 65536 else { throw ModelAPIError.limit("Realtime event is too large.") }
        try await write(WebSocketFrames.encode(data))
    }
    public func receive() async throws -> [RealtimeEvent] {
        let data: Data = try await withCheckedThrowingContinuation { c in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let error { c.resume(throwing: error) }
                else if let data, !data.isEmpty { c.resume(returning: data) }
                else { c.resume(throwing: CancellationError()) }
            }
        }
        var events: [RealtimeEvent] = []
        for frame in try frames.append(data) {
            switch frame.opcode {
            case 1:
                guard String(data: frame.payload, encoding: .utf8) != nil else { throw ModelAPIError.invalid("WebSocket text must be UTF-8.") }
                events.append(try JSONDecoder().decode(RealtimeEvent.self, from: frame.payload))
            case 8: throw CancellationError()
            case 9: try await write(WebSocketFrames.encode(frame.payload, opcode: 10))
            case 10: break
            default: throw ModelAPIError.invalid("Use JSON text messages for realtime audio.")
            }
        }
        return events
    }
    public nonisolated func close() { connection.cancel() }
}
