import Foundation
import ModelAPI

public struct ServiceConfiguration: Codable, Sendable {
    public var port: UInt16 = 18767
    public var allowNetwork = false
    public var allowApplePCC = false
    public var ollamaURL = "http://127.0.0.1:18768"
    public var generationModels: [String] = []
    public var decisionModels: [String] = ["clef-flash:9b-mxfp8"]
    public var embeddingModels: [String] = []
    public var audioModels: [String] = []
    public var assetsPath = ""
    public var startAPIOnLaunch = false
    public var startRuntimeOnLaunch = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case port, allowNetwork, allowApplePCC, ollamaURL, generationModels, decisionModels, embeddingModels, audioModels, assetsPath, startAPIOnLaunch, startRuntimeOnLaunch }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        port = try values.decode(UInt16.self, forKey: .port)
        allowNetwork = try values.decode(Bool.self, forKey: .allowNetwork)
        allowApplePCC = try values.decodeIfPresent(Bool.self, forKey: .allowApplePCC) ?? false
        ollamaURL = try values.decode(String.self, forKey: .ollamaURL)
        generationModels = try values.decode([String].self, forKey: .generationModels)
        decisionModels = try values.decode([String].self, forKey: .decisionModels)
        embeddingModels = try values.decodeIfPresent([String].self, forKey: .embeddingModels) ?? []
        audioModels = try values.decodeIfPresent([String].self, forKey: .audioModels) ?? []
        assetsPath = try values.decode(String.self, forKey: .assetsPath)
        startAPIOnLaunch = try values.decode(Bool.self, forKey: .startAPIOnLaunch)
        startRuntimeOnLaunch = try values.decodeIfPresent(Bool.self, forKey: .startRuntimeOnLaunch) ?? false
    }
    public static func isLocalModel(_ name: String) -> Bool {
        let tag = name.split(separator: ":").last?.lowercased() ?? ""
        return !name.isEmpty && !name.contains(where: \.isWhitespace) && !(["apple", "apple-pcc"] + AudioCatalog.ids).contains(name) && tag != "cloud" && !tag.hasSuffix("-cloud")
    }
    public func removingModel(_ name: String) -> Self {
        var next = self
        next.generationModels.removeAll { $0 == name }
        next.decisionModels.removeAll { $0 == name }
        next.embeddingModels.removeAll { $0 == name }
        next.audioModels.removeAll { $0 == name }
        return next
    }
    public func validate() throws {
        guard audioModels.allSatisfy(AudioCatalog.ids.contains), port > 1024, let url = URL(string: ollamaURL), url.scheme == "http",
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(url.host ?? ""), url.user == nil,
              (1...65535).contains(url.port ?? 80),
              url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/",
              Set(generationModels).isDisjoint(with: decisionModels),
              Set(embeddingModels).isDisjoint(with: generationModels + decisionModels),
              (generationModels + decisionModels + embeddingModels).allSatisfy(Self.isLocalModel) else {
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
