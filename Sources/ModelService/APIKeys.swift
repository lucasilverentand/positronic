import Foundation
import CryptoKit
import Security
import ModelAPI

public actor APIKeys {
    public struct Record: Codable, Sendable, Identifiable {
        public var id: UUID
        public var name: String
        public var createdAt: Date
        var digest: Data
    }
    private var records: [Record]
    private let file: URL
    private var onRevoke: (@Sendable (UUID) async -> Void)?
    public func observeRevocations(_ handler: @escaping @Sendable (UUID) async -> Void) { onRevoke = handler }
    public init(file: URL = PrivateFiles.directory.appendingPathComponent("keys.json")) throws {
        self.file = file
        records = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([Record].self, from: Data(contentsOf: file)) : []
    }
    public func list() -> [Record] { records }
    public func create(name: String) throws -> String {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 80 else { throw ModelAPIError.invalid("Give the key a name up to 80 characters.") }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ModelAPIError.unavailable("Could not create an API key.") }
        let token = "mma_" + bytes.map { String(format: "%02x", $0) }.joined()
        let next = records + [Record(id: UUID(), name: name, createdAt: Date(), digest: Data(SHA256.hash(data: Data(token.utf8))))]
        try PrivateFiles.save(next, to: file); records = next; return token
    }
    public func revoke(_ id: UUID) async throws {
        let next = records.filter { $0.id != id }; try PrivateFiles.save(next, to: file); records = next
        await onRevoke?(id)
    }
    public func accepts(_ token: String) -> Bool { identity(for: token) != nil }
    public func identity(for token: String) -> UUID? {
        guard token.hasPrefix("mma_"), token.utf8.count == 68 else { return nil }
        let digest = Data(SHA256.hash(data: Data(token.utf8)))
        return records.first { record in
            guard record.digest.count == digest.count else { return false }
            return zip(record.digest, digest).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }?.id
    }
}
