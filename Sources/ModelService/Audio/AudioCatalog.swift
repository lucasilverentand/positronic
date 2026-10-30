import Foundation
import ModelAPI
import CryptoKit

public enum AudioCatalog {
    public static var directory: URL { PrivateFiles.directory.appendingPathComponent("Audio") }
    public static var jobsDirectory: URL { PrivateFiles.directory.appendingPathComponent("Jobs") }
    public static let ids = ["whisper-large-v3-turbo", "chatterbox-multilingual-v3", RealtimeConfiguration.modelID]
    public static let presets: [ModelPreset] = [
        .init(id: ids[0], name: "Whisper Large V3 Turbo", capability: .transcription, detail: "Local English and Dutch transcription with timestamps", source: URL(string: "https://huggingface.co/mlx-community/whisper-large-v3-turbo")!),
        .init(id: ids[1], name: "Chatterbox Multilingual V3", capability: .speech, detail: "Local English and Dutch speech with a packaged default voice", source: URL(string: "https://huggingface.co/mlx-community/chatterbox-multilingual-v3")!),
        .init(id: ids[2], name: "Nemotron VoiceChat · 11B · 4-bit", capability: .conversation, detail: "Full-duplex English conversation · built-in LLM · about 9.2 GB", source: URL(string: "https://huggingface.co/mlx-community/NemotronLabs-VoiceChat-11B-4bit")!)
    ]
    public static func budget(_ model: String) -> Int64? {
        switch model { case ids[2]: 16 * 1024 * 1024 * 1024; case ids[0]: 6 * 1024 * 1024 * 1024; case ids[1]: 6 * 1024 * 1024 * 1024; default: nil }
    }
    public static var resources: URL {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Audio"), FileManager.default.fileExists(atPath: url.appendingPathComponent("worker.py").path) { return url }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Audio")
    }
    public static var runtimeReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("venv/bin/python").path),
              let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data),
              let lock = try? Data(contentsOf: resources.appendingPathComponent("requirements.lock")) else { return false }
        let digest = SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
        return [digest, "e531fa0ee3ca41aca3e9b211f05f01975529047eda8d6be4bb4c9392ae8dbb06"].contains(manifest.object?["lock"]?.string ?? "") && manifest.object?["python"]?.string == "3.12.12" && manifest.object?["mlx-audio"]?.string == "0.6.3"
    }
    public static var realtimeReady: Bool {
        guard runtimeReady, let data = try? Data(contentsOf: directory.appendingPathComponent("runtime.json")),
              let manifest = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        guard let lock = try? Data(contentsOf: resources.appendingPathComponent("requirements.lock")) else { return false }
        let digest = SHA256.hash(data: lock).map { String(format: "%02x", $0) }.joined()
        return manifest.object?["lock"]?.string == digest && manifest.object?["mlx-vlm"]?.string == "0.7.11"
    }
    public static func receipt(_ model: String, at root: URL = directory) -> URL { root.appendingPathComponent("models/\(model).json") }
    public static func installed() -> [InstalledModel] {
        presets.compactMap { preset in
            guard let data = try? Data(contentsOf: receipt(preset.id)), let raw = try? JSONDecoder().decode(JSONValue.self, from: data),
                  raw.object?["model"]?.string == preset.id, let path = raw.object?["path"]?.string,
                  FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent("config.json").path) else { return nil }
            var total: Int64 = 0
            if case .array(let files) = raw.object?["files"] { total = files.compactMap { $0.object?["size"]?.numberValue }.reduce(0) { $0 + Int64($1) } }
            return InstalledModel(id: preset.id, capability: preset.capability, sizeBytes: total, detail: preset.capability == .conversation ? "Local full-duplex · English · built-in Nemotron LLM" : "MLX Audio · English / Dutch", digest: raw.object?["revision"]?.string)
        }
    }
    public static func remove(_ model: String, at root: URL = directory) throws {
        guard ids.contains(model) else { throw ModelAPIError.invalid("Unknown audio model.") }
        let file = receipt(model, at: root)
        let removed = try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file))
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        let local = root.appendingPathComponent("Installed/\(model)")
        if FileManager.default.fileExists(atPath: local.path) { try FileManager.default.removeItem(at: local) }
        let remaining = ids.compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: receipt($0, at: root))) }
        for path in removed?.object?["dependencies"]?.object?.values.compactMap(\.string) ?? [] {
            guard !remaining.contains(where: { $0.object?["dependencies"]?.object?.values.contains(.string(path)) == true }) else { continue }
            let repo = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            guard repo.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("huggingface/hub").standardizedFileURL, repo.lastPathComponent.hasPrefix("models--") else { continue }
            if FileManager.default.fileExists(atPath: repo.path) { try FileManager.default.removeItem(at: repo) }
        }
    }
}
