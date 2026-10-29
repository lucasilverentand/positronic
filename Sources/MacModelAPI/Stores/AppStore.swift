import Foundation
import Observation
import ServiceManagement
import ModelAPI
import ModelService

@MainActor @Observable
final class AppStore {
    static weak var current: AppStore?
    var configuration = ServiceConfiguration()
    var models: [ModelInfo] = []
    var keys: [APIKeys.Record] = []
    var createdKey = ""
    var message = ""
    var running = false
    var busy = false
    var runtimeRunning = false
    var loginEnabled = SMAppService.mainApp.status == .enabled
    private var prepared = false
    private var vault: APIKeys?
    private var server: LoopbackServer?
    private var serverTask: Task<Void, Never>?
    private var listenerID = UUID()
    private let runtime = OllamaRuntime()
    private let configURL = PrivateFiles.directory.appendingPathComponent("settings.json")
    var endpoint: String { "http://127.0.0.1:\(configuration.port)" }
    init() { Self.current = self }
    func prepare() async {
        guard !prepared else { return }; prepared = true
        do {
            if FileManager.default.fileExists(atPath: configURL.path) { configuration = try JSONDecoder().decode(ServiceConfiguration.self, from: Data(contentsOf: configURL)) }
            vault = try APIKeys(); await refresh()
            if configuration.startAPIOnLaunch { await toggleAPI() }
        } catch { message = error.localizedDescription }
    }
    func refresh() async {
        do { let engine = try LocalModelEngine(configuration: configuration); models = await engine.models() }
        catch { message = error.localizedDescription }
        keys = await vault?.list() ?? []; runtimeRunning = await runtime.isRunning()
    }
    func save() throws { try configuration.validate(); try PrivateFiles.save(configuration, to: configURL) }
    func toggleAPI() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if server != nil { listenerID = UUID(); server?.stop(); serverTask?.cancel(); server = nil; serverTask = nil; running = false; return }
        do {
            guard let vault else { throw ModelAPIError.unavailable("API key storage is unavailable.") }
            try save()
            let router = ModelRouter(keys: vault, engine: try LocalModelEngine(configuration: configuration))
            let listener = try LoopbackServer(port: configuration.port, allowNetwork: configuration.allowNetwork) { await router.handle($0) }
            server = listener
            let id = UUID(); listenerID = id
            let store = self
            serverTask = Task {
                do { try await listener.run { Task { @MainActor in if store.listenerID == id { store.running = true } } } }
                catch { if store.listenerID == id { store.message = "Could not start API: " + error.localizedDescription } }
                if store.listenerID == id { store.running = false; store.server = nil }
            }
            message = ""
        } catch { message = error.localizedDescription }
    }
    func toggleRuntime() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            if await runtime.isRunning() { await runtime.stop() }
            else { try save(); try await runtime.start(assets: URL(fileURLWithPath: configuration.assetsPath), endpoint: URL(string: configuration.ollamaURL)!) }
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func createKey(name: String) async {
        do { guard let vault else { throw ModelAPIError.unavailable("Key storage unavailable.") }; createdKey = try await vault.create(name: name); keys = await vault.list() }
        catch { message = error.localizedDescription }
    }
    func revoke(_ id: UUID) async {
        do { try await vault?.revoke(id); keys = await vault?.list() ?? [] }
        catch { message = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; loginEnabled = SMAppService.mainApp.status == .enabled }
        catch { message = error.localizedDescription }
    }
    func persist() { do { try save() } catch { message = error.localizedDescription } }
    func shutdown() async {
        server?.stop(); serverTask?.cancel()
        await runtime.stop()
    }
}
