import Foundation
import ModelAPI
import Darwin

public struct JobResult: Sendable {
    public var data: Data
    public var type: String
    public var file: URL?
    public init(file: URL, type: String) { self.file = file; self.type = type; self.data = Data() }
    public init(data: Data, type: String = "application/json") { self.data = data; self.type = type }
    public static func json<T: Encodable>(_ value: T) throws -> Self { .init(data: try JSONEncoder().encode(value)) }
}
public enum JobExecution {
    @TaskLocal public static var queueID: UUID?
}
public actor JobQueue {
    public typealias Operation = @Sendable (UUID) async throws -> JobResult
    public typealias Probe = @Sendable () throws -> ResourceSnapshot
    public let identity = UUID()
    private struct Entry: Sendable {
        var info: ModelJob; var owner: UUID?; var budget: Int64?; var disk: Int64
        var operation: Operation; var result: JobResult?; var clean: @Sendable () -> Void
        var expiry: Date?; var output: URL?
    }
    private var entries: [UUID: Entry] = [:]
    private var pending: [UUID] = []
    private var revoked: Set<UUID> = []
    private var current: UUID?
    private var pumping: Task<Void, Never>?
    private var running: Task<JobResult, any Error>?
    private var monitor: Task<Void, Never>?
    private var releasing: Task<Void, Never>?
    private var reaper: Task<Void, Never>?
    private var started = false
    private var stopped = false
    private var managing = false
    private var lockFD: Int32 = -1
    private var residency: (@Sendable (String) async throws -> Int64)?
    private var footprint: (@Sendable () async throws -> Int64)?
    private let probe: Probe
    private let directory: URL
    private let interval: Duration
    private let waitLimit: TimeInterval
    private let retention: TimeInterval
    private var prepare: (@Sendable (String) async throws -> Void)?
    private var cancelWorker: (@Sendable () async -> Void)?
    public init(directory: URL = PrivateFiles.directory.appendingPathComponent("Jobs"), interval: Duration = .seconds(2), waitLimit: TimeInterval = 600, retention: TimeInterval = 1800, probe: @escaping Probe = { try ResourceMonitor.snapshot() }) {
        self.directory = directory; self.probe = probe; self.interval = interval; self.waitLimit = waitLimit; self.retention = retention
    }
    public func configure(prepare: @escaping @Sendable (String) async throws -> Void, cancelWorker: @escaping @Sendable () async -> Void, footprint: @escaping @Sendable () async throws -> Int64 = { 0 }, residency: @escaping @Sendable (String) async throws -> Int64 = { _ in 0 }) {
        self.prepare = prepare; self.cancelWorker = cancelWorker; self.footprint = footprint; self.residency = residency
    }
    public func start() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard lockFD < 0 else { return }
        let fd = Darwin.open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw ModelAPIError.unavailable("Cannot lock the private job directory.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(fd); throw ModelAPIError.unavailable("Another Positronic instance owns the job queue.") }
        lockFD = fd
        // Only this process's private ephemeral job directory is cleared; never model storage.
        do {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.lastPathComponent != ".lock" { try FileManager.default.removeItem(at: url) }
        } catch { flock(fd, LOCK_UN); Darwin.close(fd); lockFD = -1; throw error }
        stopped = false; started = true
        reaper = Task { while !Task.isCancelled { do { try await Task.sleep(for: .seconds(30)); self.prune() } catch { return } } }
    }
    public func submit(model: String, operation: String, owner: UUID? = nil, budget: Int64?, disk: Int64 = 0, cleanup: @escaping @Sendable () -> Void = {}, execute: @escaping Operation) throws -> ModelJob {
        if !started { try start() }
        if let owner, revoked.contains(owner) { throw ModelAPIError.unauthorized }
        guard !stopped else { throw ModelAPIError.unavailable("The job queue is shutting down.") }
        guard pending.count < 32 else { throw QueueFull() }
        prune()
        let job = ModelJob(id: UUID(), model: model, operation: operation, state: .queued, createdAt: Date())
        entries[job.id] = .init(info: job, owner: owner, budget: budget, disk: disk, operation: execute, clean: cleanup)
        pending.append(job.id)
        if pumping == nil { pumping = Task { await pump() } }
        return job
    }
    public func list(owner: UUID? = nil) -> [ModelJob] {
        prune()
        return entries.values.filter { owner == nil || $0.owner == owner }.map { item in
            var info = item.info; info.position = pending.firstIndex(of: info.id).map { $0 + 1 }; return info
        }.sorted { $0.createdAt < $1.createdAt }
    }
    public func job(_ id: UUID, owner: UUID? = nil) throws -> ModelJob {
        prune(); guard let entry = entries[id], owner == nil || entry.owner == owner else { throw JobNotFound() }; var info = entry.info; info.position = pending.firstIndex(of: id).map { $0 + 1 }; return info
    }
    public func result(_ id: UUID, owner: UUID? = nil) throws -> JobResult {
        _ = try job(id, owner: owner)
        guard let entry = entries[id], entry.info.state == .succeeded else { throw ModelAPIError.unavailable("The job has no completed result.") }
        if let url = entry.output { return .init(file: url, type: entry.result?.type ?? "application/octet-stream") }
        guard let result = entry.result else { throw JobNotFound() }; return result
    }
    public func update(_ id: UUID, state: JobState? = nil, progress: Double? = nil, message: String? = nil) {
        guard entries[id]?.info.state.terminal == false else { return }
        if let state { entries[id]?.info.state = state }
        if let progress { entries[id]?.info.progress = min(1, max(0, progress)) }
        if let message { entries[id]?.info.message = message }
    }
    public func cancel(_ id: UUID, owner: UUID? = nil) async throws {
        let info = try job(id, owner: owner); guard !info.state.terminal else { return }
        pending.removeAll { $0 == id }
        finish(id, state: .cancelled, message: "Cancelled.")
        if current == id { running?.cancel(); await releaseResources() }
    }
    public func revoke(_ owner: UUID) async {
        revoked.insert(owner)
        for entry in entries.values where entry.owner == owner && !entry.info.state.terminal { try? await cancel(entry.info.id, owner: owner) }
    }
    public func beginManagement() throws {
        if !started { try start() }
        guard current == nil, !managing else { throw ModelAPIError.unavailable("A job is active. Cancel it or wait before managing models.") }; managing = true
    }
    public func endManagement() { managing = false }
    public func hasActiveWork() -> Bool { current != nil }
    public func shutdown() async {
        guard started, lockFD >= 0 else { stopped = true; return }
        stopped = true; reaper?.cancel(); reaper = nil; pumping?.cancel(); running?.cancel(); monitor?.cancel()
        await releaseResources()
        _ = try? await running?.value
        await pumping?.value
        for id in Array(entries.keys) { if entries[id]?.info.state.terminal == false { finish(id, state: .cancelled, message: "App stopped; resubmit from your client.") } }
        pending = []
        for item in entries.values { if let output = item.output { try? FileManager.default.removeItem(at: output) } }
        entries = [:]
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where file.lastPathComponent != ".lock" { try? FileManager.default.removeItem(at: file) }
        }
        if lockFD >= 0 { flock(lockFD, LOCK_UN); Darwin.close(lockFD); lockFD = -1 }
    }
    public func wait(_ id: UUID) async throws -> JobResult {
        do {
            while true {
                try Task.checkCancellation()
                let value = try job(id)
                switch value.state {
                case .succeeded:
                    var value = try result(id)
                    if let file = value.file, value.type == "application/json" { value.data = try Data(contentsOf: file); value.file = nil }
                    return value
                case .failed: throw ModelAPIError.unavailable(value.message ?? "Job failed.")
                case .cancelled: throw CancellationError()
                default: try await Task.sleep(for: .milliseconds(50))
                }
            }
        } catch is CancellationError { try? await cancel(id); throw CancellationError() }
    }
    private func pump() async {
        defer { pumping = nil }
        while !stopped, !Task.isCancelled, let id = pending.first {
            if managing { try? await Task.sleep(for: .milliseconds(100)); continue }
            guard let item = entries[id] else { pending.removeFirst(); continue }
            current = id
            do {
                update(id, state: .loading, message: "Preparing local resources.")
                try await prepare?(item.info.model)
                let deadline = Date().addingTimeInterval(waitLimit)
                var admitted: ResourceSnapshot?
                while Date() < deadline, entries[id]?.info.state.terminal == false {
                    try Task.checkCancellation()
                    do {
                        let snapshot = try probe()
                        let credit = try await residency?(item.info.model) ?? 0
                        let incremental = item.budget.map { max(0, $0 - credit) }
                        let status = ResourceMonitor.restriction(snapshot, budget: incremental, diskBytes: item.disk)
                        entries[id]?.info.resources = status
                        if status.reason == nil { admitted = snapshot; break }
                        update(id, state: .waitingForResources, message: status.reason)
                    } catch { update(id, state: .waitingForResources, message: "Resource telemetry unavailable; waiting safely.") }
                    try await Task.sleep(for: interval)
                }
                guard entries[id]?.info.state.terminal == false else { await releasing?.value; current = nil; continue }
                guard let baseline = admitted else { throw ModelAPIError.unavailable("Resource wait expired after ten minutes. Retry when resources are available.") }
                try Task.checkCancellation()
                pending.removeAll { $0 == id }
                update(id, state: .running, message: "Running locally.")
                let queueID = identity
                let task = Task { try await JobExecution.$queueID.withValue(queueID) { try await item.operation(id) } }
                running = task
                monitor = Task { await watch(id, baseline: baseline, budget: item.budget) }
                let output = try await task.value
                try Task.checkCancellation()
                if entries[id]?.info.state.terminal == false {
                    guard try probe().disk >= ResourceMonitor.diskReserve + (output.file == nil ? Int64(output.data.count) : 0) else { throw ModelAPIError.unavailable("Not enough disk space to retain the result safely.") }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let file = directory.appendingPathComponent(id.uuidString)
                    if let source = output.file { try FileManager.default.moveItem(at: source, to: file) }
                    else { try output.data.write(to: file, options: .atomic) }
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    entries[id]?.output = file; entries[id]?.result = .init(data: Data(), type: output.type)
                    finish(id, state: .succeeded, message: "Completed.")
                }
            } catch is CancellationError { finish(id, state: .cancelled, message: "Cancelled.") }
            catch { finish(id, state: .failed, message: error.localizedDescription) }
            await releasing?.value
            cleanup(id)
            monitor?.cancel(); monitor = nil; running = nil; current = nil
            pending.removeAll { $0 == id }
        }
    }
    private func watch(_ id: UUID, baseline: ResourceSnapshot, budget: Int64?) async {
        var samples: [(Date, Int64)] = [(Date(), baseline.swap)]
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(1))
                let snapshot = try probe(); let now = Date()
                samples.append((now, snapshot.swap)); samples.removeAll { now.timeIntervalSince($0.0) > 30 }
                let critical = snapshot.pressure >= 4 || snapshot.thermal >= 3 || snapshot.swap - (samples.first?.1 ?? baseline.swap) > 256 * 1024 * 1024 || snapshot.available < max(8 * 1024 * 1024 * 1024, snapshot.physical / 5)
                let memory = critical ? 0 : try await footprint?() ?? 0
                if critical || memory > (budget ?? Int64.max) {
                    finish(id, state: .failed, message: "Stopped to protect system resources. Retry after memory pressure clears.")
                    running?.cancel(); await releaseResources(); return
                }
            } catch is CancellationError { return }
            catch { finish(id, state: .failed, message: "Stopped because resource telemetry became unavailable."); running?.cancel(); await releaseResources(); return }
        }
    }
    private func releaseResources() async {
        if let releasing { await releasing.value; return }
        let handler = cancelWorker
        let task = Task<Void, Never> { await handler?() }
        releasing = task
        await task.value
        releasing = nil
    }
    private func finish(_ id: UUID, state: JobState, message: String) {
        guard entries[id]?.info.state.terminal == false else { return }
        entries[id]?.info.state = state; entries[id]?.info.message = message; entries[id]?.info.finishedAt = Date(); entries[id]?.expiry = Date().addingTimeInterval(retention)
        if current != id || running == nil { cleanup(id) }
        entries[id]?.operation = { _ in throw JobNotFound() }
    }
    private func cleanup(_ id: UUID) { entries[id]?.clean(); entries[id]?.clean = {} }
    private func prune() {
        let now = Date()
        for (id, item) in entries where item.expiry.map({ $0 <= now }) == true {
            if let url = item.output { try? FileManager.default.removeItem(at: url) }; entries.removeValue(forKey: id)
        }
    }
}
public struct QueueFull: Error, Sendable {}
public struct JobNotFound: Error, Sendable {}
