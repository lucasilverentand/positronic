import Foundation
import ModelAPI
import Darwin

public actor AudioRuntime {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var resident: String?
    private var peak: Int64 = 0
    private var idleTask: Task<Void, Never>?
    public init() {}
    public func loaded() -> [LoadedModel] {
        guard let resident, process?.isRunning == true else { return [] }
        return [.init(id: resident, digest: nil, memoryBytes: peak)]
    }
    public func memory() throws -> Int64 {
        guard let process, process.isRunning else { return 0 }; return max(peak, try ResourceMonitor.residentBytes(of: process.processIdentifier))
    }
    public func prepare() async throws {
        try ResourceMonitor.requireDisk(at: AudioCatalog.directory, additional: 3 * 1024 * 1024 * 1024)
        try await runTool(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [AudioCatalog.resources.appendingPathComponent("setup_runtime.py").path, "--root", AudioCatalog.directory.path])
    }
    public func download(_ model: String) async throws {
        guard AudioCatalog.runtimeReady, AudioCatalog.ids.contains(model) else { throw ModelAPIError.unavailable("Prepare the audio runtime first.") }
        if model == RealtimeConfiguration.modelID, !AudioCatalog.realtimeReady { throw ModelAPIError.unavailable("Prepare the updated audio runtime explicitly in Settings first.") }
        try ResourceMonitor.requireDisk(at: AudioCatalog.directory, additional: (model == RealtimeConfiguration.modelID ? 10 : 4) * 1024 * 1024 * 1024)
        try await runTool(executable: AudioCatalog.directory.appendingPathComponent("venv/bin/python"), arguments: [AudioCatalog.resources.appendingPathComponent("install_model.py").path, "--root", AudioCatalog.directory.path, "--model", model])
    }
    private func runTool(executable: URL, arguments: [String]) async throws {
        let status = ResourceMonitor.restriction(try ResourceMonitor.snapshot(at: AudioCatalog.directory), budget: 256 * 1024 * 1024)
        if let reason = status.reason { throw ModelAPIError.unavailable(reason) }
        let task = Process(); task.executableURL = executable; task.arguments = arguments
        task.environment = ["HOME":FileManager.default.homeDirectoryForCurrentUser.path,"PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "OMP_NUM_THREADS":"2", "TOKENIZERS_PARALLELISM":"false"]
        task.standardOutput = FileHandle.nullDevice; task.standardError = FileHandle.nullDevice
        try task.run()
        try await withTaskCancellationHandler {
            while task.isRunning {
                try await Task.sleep(for: .milliseconds(200))
                do { try ResourceMonitor.requireDisk(at: AudioCatalog.directory, additional: 0) }
                catch { task.terminate(); throw error }
            }
            guard task.terminationStatus == 0 else { throw ModelAPIError.unavailable("Audio setup did not complete. Check storage and the explicit runtime/model download.") }
        } onCancel: { task.terminate() }
    }
    private func start() throws {
        if process?.isRunning == true { return }
        guard AudioCatalog.runtimeReady else { throw ModelAPIError.unavailable("Prepare the local audio runtime first.") }
        let task = Process(), incoming = Pipe(), outgoing = Pipe()
        task.executableURL = AudioCatalog.directory.appendingPathComponent("venv/bin/python")
        task.arguments = ["-u", AudioCatalog.resources.appendingPathComponent("worker.py").path, AudioCatalog.directory.path]
        task.environment = ["HOME":AudioCatalog.directory.path,"PATH":"/usr/bin:/bin", "PYTHONNOUSERSITE":"1","PYTHONDONTWRITEBYTECODE":"1","HF_HOME":AudioCatalog.directory.appendingPathComponent("huggingface").path,"HF_HUB_OFFLINE":"1","TRANSFORMERS_OFFLINE":"1", "OMP_NUM_THREADS":"2", "OPENBLAS_NUM_THREADS":"2", "TOKENIZERS_PARALLELISM":"false"]
        task.standardInput = incoming; task.standardOutput = outgoing; task.standardError = FileHandle.nullDevice
        try task.run(); process = task; input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
    }
    public func stop() async {
        idleTask?.cancel(); idleTask = nil
        let owned = process; process = nil; resident = nil; peak = 0
        try? input?.close(); input = nil
        if owned?.isRunning == true { owned?.terminate() }
        for _ in 0..<50 where owned?.isRunning == true { try? await Task.sleep(for: .milliseconds(100)) }
        if let owned, owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        try? output?.close(); output = nil
    }
    public func load(_ model: String, progress: @escaping @Sendable (JSONValue) async -> Void = { _ in }) async throws {
        _ = try await rpc(["operation":.string("load"),"model":.string(model)], progress: progress)
    }
    public func transcribe(model: String, file: URL, language: String, output: URL, progress: @escaping @Sendable (JSONValue) async -> Void) async throws -> JobResult {
        _ = try await rpc(["operation":.string("transcription"),"model":.string(model),"input":.string(file.path),"output":.string(output.path),"language":.string(language)], progress: progress)
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 1_000_000 else { throw ModelAPIError.limit("Transcript exceeds 1 MB.") }
        let data = try Data(contentsOf: output); _ = try JSONDecoder().decode(Transcript.self, from: data)
        return .init(data: data)
    }
    public func speech(_ request: SpeechRequest, output: URL, progress: @escaping @Sendable (JSONValue) async -> Void) async throws -> JobResult {
        try request.validate()
        _ = try await rpc(["operation":.string("speech"),"model":.string(request.model),"text":.string(request.input),"language":.string(request.language),"output":.string(output.path)], progress: progress)
        guard (try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 64 * 1024 * 1024 else { throw ModelAPIError.limit("Speech output exceeds 64 MiB.") }
        return .init(file: output, type: "audio/wav")
    }
    public func beginRealtime(_ configuration: RealtimeConfiguration) async throws {
        try configuration.validate()
        guard AudioCatalog.realtimeReady else { throw ModelAPIError.unavailable("Prepare the updated audio runtime explicitly in Settings first.") }
        _ = try await rpc(["operation": .string("realtime_start"), "model": .string(configuration.model), "instructions": .string(configuration.instructions), "seconds": .number(Double(configuration.maxDurationSeconds))], progress: { _ in })
    }
    public func stepRealtime(_ pcm: Data) async throws -> [RealtimeEvent] {
        guard pcm.count == 2560 else { throw ModelAPIError.invalid("Invalid realtime PCM frame.") }
        let result = try await rpc(["operation": .string("realtime_step"), "model": .string(RealtimeConfiguration.modelID), "audio": .string(pcm.base64EncodedString())], progress: { _ in })
        guard let value = result.object?["events"] else { throw ModelAPIError.invalid("Missing realtime events.") }
        return try JSONDecoder().decode([RealtimeEvent].self, from: JSONEncoder().encode(value))
    }
    private func rpc(_ body: [String: JSONValue], progress: @escaping @Sendable (JSONValue) async -> Void) async throws -> JSONValue {
        idleTask?.cancel(); idleTask = nil
        guard let model = body["model"]?.string, AudioCatalog.installed().contains(where: { $0.id == model }) else { throw ModelAPIError.unavailable("Download this audio model explicitly before loading it.") }
        if model == RealtimeConfiguration.modelID, !AudioCatalog.realtimeReady { throw ModelAPIError.unavailable("Prepare the updated audio runtime explicitly first.") }
        try start()
        guard let input, let output else { throw ModelAPIError.unavailable("The audio worker is unavailable.") }
        let owned = process
        let data = try JSONEncoder().encode(body) + Data([10]); try input.write(contentsOf: data)
        do {
            return try await withTaskCancellationHandler {
                while true {
                    let line = try await Task.detached(priority: .utility) {
                        var bytes = Data()
                        while true {
                            guard let next = try output.read(upToCount: 1), !next.isEmpty else { throw ModelAPIError.unavailable("The local audio worker stopped unexpectedly.") }
                            if next[0] == 10 { return bytes }
                            guard bytes.count < 64_000 else { throw ModelAPIError.limit("Audio worker reply exceeds its limit.") }
                            bytes.append(next)
                        }
                    }.value
                    try Task.checkCancellation()
                    let value = try JSONDecoder().decode(JSONValue.self, from: line)
                    if let memory = value.object?["memory"]?.numberValue, memory.isFinite, memory >= 0, memory < 1e12 { peak = Int64(memory) }
                    if value.object?["event"]?.string == "loaded" { resident = model }
                    if value.object?["event"] != nil { await progress(value); continue }
                    guard value.object?["ok"]?.bool == true else { throw ModelAPIError.unavailable("Local audio failed. Check the model assets, language and input audio.") }
                    idleTask = Task { do { try await Task.sleep(for: .seconds(300)); await self.stop() } catch {} }
                    return value
                }
            } onCancel: { if owned?.isRunning == true { owned?.terminate() } }
        } catch { await stop(); throw error }
    }
}
