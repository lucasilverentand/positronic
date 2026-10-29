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
    var loadedModels: [LoadedModel] = []
    var loadedStatusKnown = false
    var modelOperation: String?
    private let modelActivity = ModelActivity()
    var managingModels: Bool { modelOperation != nil }
    var canManageModels: Bool { !busy && !managingModels && downloading == nil }
    func makeEngine(configuration value: ServiceConfiguration? = nil) throws -> LocalModelEngine {
        try LocalModelEngine(configuration: value ?? configuration, activity: modelActivity)
    }
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
            let engine = try makeEngine(); models = await engine.models()
            do { installedModels = try await ModelLibrary(configuration: configuration).installed(); modelLibraryMessage = "" }
            catch { installedModels = []; modelLibraryMessage = "Start a local runtime to discover and download models." }
        }
        catch { message = error.localizedDescription }
        await refreshLoaded()
        keys = await vault?.list() ?? []; runtimeRunning = await runtime.isRunning()
    }
    func save() throws { try configuration.validate(); try PrivateFiles.save(configuration, to: configURL) }
    func connectToOllama() async {
        guard canManageModels else { return }
        configuration.ollamaURL = "http://127.0.0.1:11434"
        do { try save(); await router?.update(engine: try makeEngine()); await refresh() } catch { message = error.localizedDescription }
    }
    func toggleAPI() async {
        guard canManageModels else { return }; busy = true; defer { busy = false }
        if server != nil { listenerID = UUID(); server?.stop(); serverTask?.cancel(); server = nil; serverTask = nil; apiStarting = false; running = false; return }
        do {
            guard let vault else { throw ModelAPIError.unavailable("API key storage is unavailable.") }
            try save()
            let router = ModelRouter(keys: vault, engine: try makeEngine())
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
        guard canManageModels else { return }; busy = true; defer { busy = false }
        do {
            if await runtime.isRunning() { await runtime.stop() }
            else { try save(); try await runtime.start(assets: URL(fileURLWithPath: configuration.assetsPath), endpoint: URL(string: configuration.ollamaURL)!) }
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func prepareRuntime() async {
        guard canManageModels else { return }; busy = true; defer { busy = false }
        do {
            message = "Preparing the local runtime…"
            let assets = try await RuntimeSetup().prepare()
            configuration.assetsPath = assets.path; configuration.ollamaURL = "http://127.0.0.1:18768"
            configuration.startRuntimeOnLaunch = true; try save()
            try await runtime.start(assets: assets, endpoint: URL(string: configuration.ollamaURL)!)
            await router?.update(engine: try makeEngine())
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
        guard !managingModels else { return }
        do { try save(); await router?.update(engine: try makeEngine()); await refresh() }
        catch { message = error.localizedDescription }
    }
    func setApplePCC(_ enabled: Bool) async {
        guard !managingModels else { return }
        var next = configuration; next.allowApplePCC = enabled
        do {
            let engine = try makeEngine(configuration: next)
            try PrivateFiles.save(next, to: configURL); configuration = next
            await router?.update(engine: engine); await refresh()
        } catch { message = error.localizedDescription }
    }
    func isEnabled(_ model: String, capability: ModelCapability) -> Bool {
        switch capability {
        case .generation: configuration.generationModels.contains(model)
        case .decision: configuration.decisionModels.contains(model)
        case .embedding: configuration.embeddingModels.contains(model)
        }
    }
    func setEnabled(_ model: String, capability: ModelCapability, enabled: Bool) async {
        guard !managingModels else { return }
        var next = configuration.removingModel(model)
        if enabled {
            switch capability { case .generation: next.generationModels.append(model); case .decision: next.decisionModels.append(model); case .embedding: next.embeddingModels.append(model) }
        }
        do {
            try next.validate(); let engine = try makeEngine(configuration: next)
            try PrivateFiles.save(next, to: configURL); configuration = next
            await router?.update(engine: engine); await refresh()
        }
        catch { message = error.localizedDescription }
    }
    func refreshLoaded() async {
        do {
            loadedModels = try await ModelManager(configuration: configuration).loaded()
            loadedStatusKnown = true
        } catch { loadedStatusKnown = false; loadedModels = [] }
    }
    func loadedModel(_ model: InstalledModel) -> LoadedModel? {
        loadedModels.first { $0.matches(model) }
    }
    enum ModelAction { case load, unload, remove }
    func manage(_ action: ModelAction, model: InstalledModel) async {
        guard canManageModels else { return }
        modelOperation = model.id; message = ""
        defer { modelOperation = nil }
        do {
            let manager = try ModelManager(configuration: configuration)
            // The shared gate survives engine replacements and also covers Playground requests.
            try await modelActivity.withManagement { @MainActor in
                switch action {
                case .load: try await manager.load(model.id)
                case .unload: try await manager.unload(model.id)
                case .remove:
                    // Persist revoked access before deleting files. A failed deletion stays disabled.
                    let next = self.configuration.removingModel(model.id)
                    let engine = try self.makeEngine(configuration: next)
                    try PrivateFiles.save(next, to: self.configURL)
                    self.configuration = next
                    await self.router?.update(engine: engine)
                    try await manager.remove(model.id)
                }
            }
            switch action {
            case .load: message = "\(model.id) is loaded and ready."
            case .unload: message = "\(model.id) is unloaded. Its downloaded files are still on this Mac."
            case .remove: message = "\(model.id) was removed from this Mac and disabled for API clients."
            }
        } catch { message = error.localizedDescription }
        await refresh()
    }
    func download(_ preset: ModelPreset) {
        guard canManageModels else { return }
        do {
            let library = try ModelLibrary(configuration: configuration)
            let id = UUID(); downloadID = id; downloading = preset; downloadProgress = nil; message = ""
            let store = self
            downloadTask = Task {
                do {
                    try await library.download(preset) { update in Task { @MainActor in if store.downloadID == id { store.downloadProgress = update } } }
                } catch is CancellationError {} catch { if store.downloadID == id, !Task.isCancelled { store.message = error.localizedDescription } }
                if store.downloadID == id { store.downloadID = UUID(); store.downloading = nil; store.downloadProgress = nil; store.downloadTask = nil; await store.refresh() }
            }
        } catch { message = error.localizedDescription }
    }
    func cancelDownload() {
        // Retain the download guard until the cancelled URLSession has finished.
        // Otherwise a pull could recreate a model while removal is in progress.
        downloadTask?.cancel()
    }
    func shutdown() async {
        cancelDownload()
        await downloadTask?.value
        server?.stop(); serverTask?.cancel()
        await runtime.stop()
    }
}
