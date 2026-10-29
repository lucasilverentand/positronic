import Foundation
import ModelAPI

public struct ServiceConfiguration: Codable, Sendable {
    public var port: UInt16 = 18767
    public var allowNetwork = false
    public var ollamaURL = "http://127.0.0.1:18768"
    public var generationModels: [String] = []
    public var decisionModels: [String] = ["clef-flash:9b-mxfp8"]
    public var assetsPath = ""
    public var startAPIOnLaunch = false
    public init() {}
    public func validate() throws {
        guard port > 1024, let url = URL(string: ollamaURL), url.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""), url.user == nil,
              (1...65535).contains(url.port ?? 80),
              url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              Set(generationModels).isDisjoint(with: decisionModels),
              (generationModels + decisionModels).allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) && !$0.hasSuffix(":cloud") && $0 != "apple" }) else {
            throw ModelAPIError.invalid("Use a loopback Ollama URL, a port above 1024, and distinct local model names.")
        }
    }
}

public enum PrivateFiles {
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MacModelAPI", isDirectory: true)
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
