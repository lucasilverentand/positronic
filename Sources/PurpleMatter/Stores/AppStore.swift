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
    var installedModels: [InstalledModel] = []
    var modelLibraryMessage = ""
    var downloading: ModelPreset?
    var downloadProgress: ModelDownloadProgress?
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()
    var keys: [APIKeys.Record] = []
    var createdKey = ""
    var message = ""
    var running = false
    var busy = false
    var runtimeRunning = false
    var apiStarting = false
    var loginEnabled = SMAppService.mainApp.status == .enabled
    private var prepared = false
    private var vault: APIKeys?
    private var server: LoopbackServer?
    private var router: ModelRouter?
    private var serverTask: Task<Void, Never>?
    private var listenerID = UUID()
    private let runtime = OllamaRuntime()
    private let configURL = PrivateFiles.directory.appendingPathComponent("settings.json")
    var endpoint: String { "http://127.0.0.1:\(configuration.port)" }
    init() {}
    func prepare() async {
        Self.current = self
        guard !prepared else { return }; prepared = true
        do {
            if FileManager.default.fileExists(atPath: configURL.path) { configuration = try JSONDecoder().decode(ServiceConfiguration.self, from: Data(contentsOf: configURL)) }
            try configuration.validate()
            vault = try APIKeys()
            if configuration.startRuntimeOnLaunch {
                try await runtime.start(assets: URL(fileURLWithPath: configuration.assetsPath), endpoint: URL(string: configuration.ollamaURL)!)
            }
            await refresh()
            if configuration.startAPIOnLaunch { await toggleAPI() }
        } catch { message = error.localizedDescription }
    }
    func refresh() async {
        do {
            let engine = try LocalModelEngine(configuration: configuration); models = await engine.models()
            do { installedModels = try await ModelLibrary(configuration: configuration).installed(); modelLibraryMessage = "" }
            catch { installedModels = []; modelLibraryMessage = "Start a local runtime to discover and download models." }
        }
        catch { message = error.localizedDescription }
        keys = await vault?.list() ?? []; runtimeRunning = await runtime.isRunning()
    }
    func save() throws { try configuration.validate(); try PrivateFiles.save(configuration, to: configURL) }
    func connectToOllama() async {
        guard downloading == nil else { return }
        configuration.ollamaURL = "http://127.0.0.1:11434"
        do { try save(); await router?.update(engine: try LocalModelEngine(configuration: configuration)); await refresh() } catch { message = error.localizedDescription }
    }
    func toggleAPI() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        if server != nil { listenerID = UUID(); server?.stop(); serverTask?.cancel(); server = nil; serverTask = nil; apiStarting = false; running = false; return }
        do {
            guard let vault else { throw ModelAPIError.unavailable("API key storage is unavailable.") }
            try save()
            let router = ModelRouter(keys: vault, engine: try LocalModelEngine(configuration: configuration))
            self.router = router
            let listener = try LoopbackServer(port: configuration.port, allowNetwork: configuration.allowNetwork) { await router.handle($0) }
            server = listener
            apiStarting = true
            let id = UUID(); listenerID = id
            let store = self
            serverTask = Task {
                do { try await listener.run { Task { @MainActor in if store.listenerID == id { store.running = true; store.apiStarting = false } } } }
                catch { if store.listenerID == id { store.message = "Could not start API: " + error.localizedDescription } }
                if store.listenerID == id { store.running = false; store.apiStarting = false; store.server = nil }
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
    func prepareRuntime() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            message = "Preparing the local runtime…"
            let assets = try await RuntimeSetup().prepare()
            configuration.assetsPath = assets.path; configuration.ollamaURL = "http://127.0.0.1:18768"
            configuration.startRuntimeOnLaunch = true; try save()
            try await runtime.start(assets: assets, endpoint: URL(string: configuration.ollamaURL)!)
            await router?.update(engine: try LocalModelEngine(configuration: configuration))
            message = ""; await refresh()
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
    func applyModelSettings() async {
        do { try save(); await router?.update(engine: try LocalModelEngine(configuration: configuration)); await refresh() }
        catch { message = error.localizedDescription }
    }
    func isEnabled(_ model: String, capability: ModelCapability) -> Bool {
        switch capability {
        case .generation: configuration.generationModels.contains(model)
        case .decision: configuration.decisionModels.contains(model)
        case .embedding: configuration.embeddingModels.contains(model)
        }
    }
    func setEnabled(_ model: String, capability: ModelCapability, enabled: Bool) async {
        var next = configuration
        next.generationModels.removeAll { $0 == model }; next.decisionModels.removeAll { $0 == model }; next.embeddingModels.removeAll { $0 == model }
        if enabled {
            switch capability { case .generation: next.generationModels.append(model); case .decision: next.decisionModels.append(model); case .embedding: next.embeddingModels.append(model) }
        }
        do {
            try next.validate(); let engine = try LocalModelEngine(configuration: next)
            try PrivateFiles.save(next, to: configURL); configuration = next
            await router?.update(engine: engine); await refresh()
        }
        catch { message = error.localizedDescription }
    }
    func download(_ preset: ModelPreset) {
        guard downloading == nil else { return }
        do {
            let library = try ModelLibrary(configuration: configuration)
            let id = UUID(); downloadID = id; downloading = preset; downloadProgress = nil; message = ""
            let store = self
            downloadTask = Task {
                do {
                    try await library.download(preset) { update in Task { @MainActor in if store.downloadID == id { store.downloadProgress = update } } }
                } catch is CancellationError {} catch { if store.downloadID == id { store.message = error.localizedDescription } }
                if store.downloadID == id { store.downloading = nil; store.downloadProgress = nil; store.downloadTask = nil; await store.refresh() }
            }
        } catch { message = error.localizedDescription }
    }
    func cancelDownload() {
        downloadID = UUID(); downloadTask?.cancel(); downloadTask = nil; downloading = nil; downloadProgress = nil
    }
    func shutdown() async {
        cancelDownload()
        server?.stop(); serverTask?.cancel()
        await runtime.stop()
    }
}
