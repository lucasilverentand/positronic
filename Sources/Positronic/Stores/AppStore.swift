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
    let jobs: JobQueue
    private let modelActivity: ModelActivity
    let audioRuntime: AudioRuntime
    let audioService: AudioService
    @ObservationIgnored private var modelTests: [String: ModelTestStore] = [:]
    func testSession(for model: ManagedModel) -> ModelTestStore {
        if let existing = modelTests[model.id], existing.capability == model.capability { return existing }
        modelTests[model.id]?.cancel()
        let session = ModelTestStore(model: model, app: self); modelTests[model.id] = session; return session
    }
    @ObservationIgnored private let engineTransport: ModelAPIClient.Transport?
    var queueReady = false
    var jobRecords: [ModelJob] = []
    var managingModels: Bool { modelOperation != nil }
    var canManageModels: Bool { queueReady && !busy && !managingModels && downloading == nil }
    func makeEngine(configuration value: ServiceConfiguration? = nil) throws -> LocalModelEngine {
        try LocalModelEngine(configuration: value ?? configuration, transport: engineTransport, activity: modelActivity)
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
    init(jobs queue: JobQueue = JobQueue(), audio: AudioRuntime = AudioRuntime(), transport: ModelAPIClient.Transport? = nil) {
        engineTransport = transport
        jobs = queue; modelActivity = ModelActivity(jobs: queue); audioRuntime = audio
        audioService = AudioService(runtime: audio, queue: queue)
    }
    func refreshJobs() async { jobRecords = await jobs.list() }
    func prepareAudioRuntime() async {
        guard canManageModels else { return }; busy = true; defer { busy = false }
        do {
            message = "Preparing the private audio runtime…"
            try await modelActivity.withManagement { [audioRuntime] in try await audioRuntime.prepare() }
            message = "Local audio runtime is ready. Download an audio model in Discover."; await refresh()
        } catch { message = error.localizedDescription }
    }
    private func ownedModelManager() async throws -> ModelManager? {
        guard let endpoint = await runtime.ownedEndpoint() else { return nil }
        var owned = ServiceConfiguration(); owned.ollamaURL = endpoint.absoluteString
        return try ModelManager(configuration: owned)
    }
    private func prepareForJob(_ model: String) async throws {
        let audio = await audioRuntime.loaded()
        if !audio.isEmpty && !audio.contains(where: { $0.id == model }) { await audioRuntime.stop() }
        // The app never unloads another application's runtime.
        if let manager = try await ownedModelManager() {
            for loaded in try await manager.loaded() where loaded.id != model { try await manager.unload(loaded.id) }
        }
    }
    private func cancelInferenceResources() async {
        await audioRuntime.stop()
        if await runtime.isRunning() {
            do {
                guard let manager = try await ownedModelManager() else { return }
                for model in try await manager.loaded() { try await manager.unload(model.id) }
            } catch { await runtime.stop() }
        }
    }
    private func residentMemory(for model: String? = nil) async throws -> Int64 {
        let audio = await audioRuntime.loaded()
        var total = audio.filter { model == nil || $0.id == model }.compactMap(\.memoryBytes).reduce(0, +)
        if let manager = try await ownedModelManager() {
            total += try await manager.loaded().filter { model == nil || $0.id == model }.compactMap(\.memoryBytes).reduce(0, +)
        }
        if model == nil || audio.contains(where: { $0.id == model }) { total = max(total, try await audioRuntime.memory()) }
        if model == nil { total += try ResourceMonitor.residentBytes(of: ProcessInfo.processInfo.processIdentifier) }
        return total
    }
    func prepare() async {
        Self.current = self
        guard !prepared else { return }; prepared = true
        do {
            if FileManager.default.fileExists(atPath: configURL.path) { configuration = try JSONDecoder().decode(ServiceConfiguration.self, from: Data(contentsOf: configURL)) }
            try configuration.validate()
            try await jobs.start(); queueReady = true
            await jobs.configure(prepare: { [weak self] model in try await self?.prepareForJob(model) }, cancelWorker: { [weak self] in await self?.cancelInferenceResources() }, footprint: { [weak self] in try await self?.residentMemory() ?? 0 }, residency: { [weak self] model in try await self?.residentMemory(for: model) ?? 0 })
            vault = try APIKeys()
            await vault?.observeRevocations { [jobs] id in await jobs.revoke(id) }
            await audioService.update(enabled: configuration.audioModels)
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
            do { installedModels = try await ModelLibrary(configuration: configuration).installed() + AudioCatalog.installed(); modelLibraryMessage = "" }
            catch { installedModels = AudioCatalog.installed(); modelLibraryMessage = "Start a local runtime to discover and download models." }
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
            let router = ModelRouter(keys: vault, engine: try makeEngine(), jobs: jobs, audio: audioService)
            self.router = router
            let listener = try LoopbackServer(port: configuration.port, allowNetwork: configuration.allowNetwork, authorizeUpload: { await router.authorizeUpload($0) }) { await router.handle($0) }
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
            try await modelActivity.withManagement { @MainActor in
                if await self.runtime.isRunning() { await self.runtime.stop() }
                else { try self.save(); try await self.runtime.start(assets: URL(fileURLWithPath: self.configuration.assetsPath), endpoint: URL(string: self.configuration.ollamaURL)!) }
            }
            await refresh()
        } catch { message = error.localizedDescription }
    }
    func prepareRuntime() async {
        guard canManageModels else { return }; busy = true; defer { busy = false }
        do {
            message = "Preparing the local runtime…"
            let assets = try await modelActivity.withManagement { try await RuntimeSetup().prepare() }
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
            await router?.update(engine: engine); await audioService.update(enabled: configuration.audioModels); await refresh()
        } catch { message = error.localizedDescription }
    }
    func isEnabled(_ model: String, capability: ModelCapability) -> Bool {
        switch capability {
        case .generation: configuration.generationModels.contains(model)
        case .decision: configuration.decisionModels.contains(model)
        case .embedding: configuration.embeddingModels.contains(model)
        case .transcription, .speech: configuration.audioModels.contains(model)
        }
    }
    func setEnabled(_ model: String, capability: ModelCapability, enabled: Bool) async {
        guard !managingModels else { return }
        var next = configuration.removingModel(model)
        if enabled {
            switch capability { case .generation: next.generationModels.append(model); case .decision: next.decisionModels.append(model); case .embedding: next.embeddingModels.append(model); case .transcription, .speech: next.audioModels.append(model) }
        }
        do {
            try next.validate(); let engine = try makeEngine(configuration: next)
            try PrivateFiles.save(next, to: configURL); configuration = next
            await router?.update(engine: engine); await audioService.update(enabled: configuration.audioModels); await refresh()
        }
        catch { message = error.localizedDescription }
    }
    func refreshLoaded() async {
        do {
            loadedModels = try await ModelManager(configuration: configuration).loaded()
            loadedStatusKnown = true
        } catch { loadedStatusKnown = false; loadedModels = [] }
        loadedModels += await audioRuntime.loaded()
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
            if action == .load {
                let budget: Int64?
                if let value = AudioCatalog.budget(model.id) { budget = value }
                else { budget = await (try makeEngine()).budget(for: model.id) }
                let job = try await jobs.submit(model: model.id, operation: "load", budget: budget) { [audioRuntime, jobs] id in
                    await jobs.update(id, state: .loading)
                    if AudioCatalog.ids.contains(model.id) { try await audioRuntime.load(model.id) }
                    else { try await manager.load(model.id) }
                    return JobResult(data: Data())
                }
                _ = try await jobs.wait(job.id)
                message = "\(model.id) is loaded and ready."; await refresh(); return
            }
            // The shared gate survives engine replacements and also covers model tests.
            try await modelActivity.withManagement { @MainActor in
                switch action {
                case .load: try await manager.load(model.id)
                case .unload:
                    if AudioCatalog.ids.contains(model.id) { await self.audioRuntime.stop() }
                    else { try await manager.unload(model.id) }
                case .remove:
                    // Persist revoked access before deleting files. A failed deletion stays disabled.
                    let next = self.configuration.removingModel(model.id)
                    let engine = try self.makeEngine(configuration: next)
                    try PrivateFiles.save(next, to: self.configURL)
                    self.configuration = next
                    await self.router?.update(engine: engine)
                    await self.audioService.update(enabled: next.audioModels)
                    if AudioCatalog.ids.contains(model.id) { await self.audioRuntime.stop(); try AudioCatalog.remove(model.id) }
                    else { try await manager.remove(model.id) }
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
                    if AudioCatalog.ids.contains(preset.id) {
                        try await store.modelActivity.withManagement { [audioRuntime] in try await audioRuntime.download(preset.id) }
                    } else {
                        try await store.modelActivity.withManagement { try await library.download(preset) { update in Task { @MainActor in if store.downloadID == id { store.downloadProgress = update } } } }
                    }
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
        for session in modelTests.values { session.cancel() }
        cancelDownload()
        await downloadTask?.value
        server?.stop(); serverTask?.cancel()
        await jobs.shutdown(); await audioRuntime.stop()
        await runtime.stop()
    }
}
