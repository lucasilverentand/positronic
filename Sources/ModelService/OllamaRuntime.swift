import Foundation
import Darwin
import ModelAPI

/// Optional owned runtime. Model weights and the Ollama binary stay outside the app.
public actor OllamaRuntime {
    private var process: Process?
    private var log: FileHandle?
    public init() {}
    deinit { if process?.isRunning == true { process?.terminate() }; try? log?.close() }
    public func isRunning() -> Bool { process?.isRunning == true }
    public func start(assets: URL, endpoint: URL) async throws {
        guard process?.isRunning != true else { return }
        guard endpoint.host == "127.0.0.1", let port = endpoint.port, (1025...65535).contains(port),
              FileManager.default.isExecutableFile(atPath: assets.appendingPathComponent("runtime/ollama").path),
              FileManager.default.fileExists(atPath: assets.appendingPathComponent("models").path) else {
            throw ModelAPIError.invalid("Choose a folder with runtime/ollama and models/, and use a 127.0.0.1 backend URL with an explicit port.")
        }
        // Reserve-check the configured loopback port without adopting another service.
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ModelAPIError.unavailable("Cannot check the runtime port.") }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        Darwin.close(socket)
        guard bound == 0 else { throw ModelAPIError.unavailable("The runtime port is already occupied. Choose another port or use that service explicitly.") }
        let file = PrivateFiles.directory.appendingPathComponent("runtime.log")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
        let owned = Process(); owned.executableURL = assets.appendingPathComponent("runtime/ollama"); owned.arguments = ["serve"]
        // Do not inherit provider credentials, proxy settings or an unrelated Ollama configuration.
        owned.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OLLAMA_HOST": "127.0.0.1:\(port)", "OLLAMA_MODELS": assets.appendingPathComponent("models").path,
            "OLLAMA_NO_CLOUD": "1", "OLLAMA_NOPRUNE": "1", "OLLAMA_NUM_PARALLEL": "1",
            "OLLAMA_MAX_LOADED_MODELS": "1", "OLLAMA_CONTEXT_LENGTH": "8192", "OLLAMA_KEEP_ALIVE": "5m"]
        owned.standardOutput = handle; owned.standardError = handle
        do {
            try owned.run(); process = owned; log = handle
            for _ in 0..<100 {
                try Task.checkCancellation()
                guard process === owned, owned.isRunning else { throw ModelAPIError.unavailable("The local runtime stopped before it was ready. Check its local log.") }
                var request = URLRequest(url: endpoint.appendingPathComponent("api/version")); request.timeoutInterval = 1
                if let (_, response) = try? await HTTPTransport.send(request), response.statusCode == 200 { return }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw ModelAPIError.unavailable("Local runtime startup timed out.")
        } catch {
            if process === owned { await stop() } else { try? handle.close() }
            throw error
        }
    }
    public func stop() async {
        guard let owned = process else { return }
        if owned.isRunning { owned.terminate() }
        for _ in 0..<30 where owned.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
        if owned.isRunning { kill(owned.processIdentifier, SIGKILL) }
        if process === owned { process = nil; try? log?.close(); log = nil }
    }
}
