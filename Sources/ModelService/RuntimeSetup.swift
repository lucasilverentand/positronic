import Foundation
import CryptoKit
import ModelAPI

/// An operator-triggered runtime install. Weights are downloaded separately.
public actor RuntimeSetup {
    public static let version = "0.40.12"
    public static let archiveSHA256 = "1d1b4c2cf40d2a239f9b08a77384830800a8542c744a55f47247f9baf85b55d2"
    public static var managedAssets: URL { PrivateFiles.directory.appendingPathComponent("LocalModels", isDirectory: true) }
    public init() {}
    public func prepare() async throws -> URL {
        let assets = Self.managedAssets
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runtime = assets.appendingPathComponent("runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: runtime.appendingPathComponent("ollama").path) {
            try Self.verify(runtime.appendingPathComponent("ollama"))
            try FileManager.default.createDirectory(at: assets.appendingPathComponent("models"), withIntermediateDirectories: true)
            return assets
        }
        let stage = assets.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        let url = URL(string: "https://github.com/ollama/ollama/releases/download/v\(Self.version)/ollama-darwin.tgz")!
        let (download, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: download) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ModelAPIError.unavailable("Could not download the pinned local runtime.") }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: download); defer { try? input.close() }
        var digest = SHA256()
        while let block = try input.read(upToCount: 8 * 1024 * 1024), !block.isEmpty { try Task.checkCancellation(); digest.update(data: block) }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == Self.archiveSHA256 else {
            throw ModelAPIError.unavailable("Runtime checksum did not match. Nothing was installed.")
        }
        let extracted = stage.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false)
        try Self.run("/usr/bin/tar", ["-xzf", download.path, "-C", extracted.path])
        try Self.verify(extracted.appendingPathComponent("ollama"))
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: extracted, to: runtime)
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("models"), withIntermediateDirectories: true)
        return assets
    }
    public static func verify(_ binary: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw ModelAPIError.unavailable("The local runtime is not installed.") }
        try run("/usr/bin/codesign", ["--verify", "--strict", "--all-architectures", "-R", "=identifier \"ai.ollama.ollama\" and anchor apple generic and certificate leaf[subject.OU] = \"3MU9H2V9Y9\"", binary.path])
    }
    private static func run(_ executable: String, _ arguments: [String]) throws {
        let task = Process(); task.executableURL = URL(fileURLWithPath: executable); task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ModelAPIError.unavailable("Could not unpack or verify the local runtime.") }
    }
}
