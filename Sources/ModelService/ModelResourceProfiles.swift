import Foundation
import CryptoKit
import ModelAPI

public struct ModelResourceContext: Sendable {
    public var revision: String
    public var runtime: String
    public var completeMeasurement: Bool
    public var requestedContextSeconds: Double
    public var minimumBudgetBytes: Int64
    public init(revision: String, runtime: String, completeMeasurement: Bool, requestedContextSeconds: Double = 0, minimumBudgetBytes: Int64 = 0) {
        self.revision = revision; self.runtime = runtime; self.completeMeasurement = completeMeasurement; self.requestedContextSeconds = requestedContextSeconds; self.minimumBudgetBytes = minimumBudgetBytes
    }
    public func key(model: String, operation: String) -> String {
        SHA256.hash(data: Data([model, operation, revision, runtime].joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
public struct ModelRunObservation: Sendable {
    public var peakBytes: Int64
    public var contextSeconds: Double
    public var stepSeconds: Double
    public var steps: Int
    public var stages: [String: Double] = [:]
    public init(peakBytes: Int64 = 0, contextSeconds: Double = 0, stepSeconds: Double = 0, steps: Int = 0) {
        self.peakBytes = peakBytes; self.contextSeconds = contextSeconds; self.stepSeconds = stepSeconds; self.steps = steps
    }
}
public actor ModelRunMetrics {
    private var value = ModelRunObservation()
    public init() {}
    public func memory(_ bytes: Int64) { value.peakBytes = max(value.peakBytes, bytes) }
    public func step(seconds: Double, contextSeconds: Double, stages: [String: Double] = [:]) {
        guard seconds.isFinite, seconds >= 0, contextSeconds.isFinite, contextSeconds >= 0 else { return }
        for (key, milliseconds) in stages where milliseconds.isFinite && milliseconds >= 0 { value.stages[key, default: 0] += milliseconds }
        value.stepSeconds += seconds; value.steps += 1; value.contextSeconds += contextSeconds
    }
    public func observation() -> ModelRunObservation { value }
}

/// One queue owner writes these aggregates atomically. Revision/runtime changes
/// create separate profiles; incomplete or failed runs cannot lower reservations.
public actor ModelResourceProfiles {
    private let file: URL
    private let checkDisk: @Sendable (URL, Int64) throws -> Void
    public private(set) var lastWriteError: String?
    private var loaded = false
    private var values: [String: ModelResourceProfile] = [:]
    public init(file: URL = PrivateFiles.directory.appendingPathComponent("resource-profiles.json"), checkDisk: @escaping @Sendable (URL, Int64) throws -> Void = { try ResourceMonitor.requireDisk(at: $0, additional: $1) }) { self.file = file; self.checkDisk = checkDisk }
    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: file.path) {
            let bytes = try Data(contentsOf: file)
            guard bytes.count <= 1_000_000 else { throw ModelAPIError.limit("Resource profile store is too large.") }
            values = try JSONDecoder().decode([String: ModelResourceProfile].self, from: bytes)
        }
        loaded = true
    }
    public func all() throws -> [ModelResourceProfile] { try load(); return values.values.sorted { $0.lastRun > $1.lastRun } }
    public func record(model: String, operation: String, context: ModelResourceContext, outcome: JobState, observation: ModelRunObservation, now: Date = Date()) throws {
        try load()
        guard outcome.terminal, observation.peakBytes > 0, observation.peakBytes <= 1 << 50 else { return }
        let key = context.key(model: model, operation: operation)
        var profile = values[key] ?? ModelResourceProfile(id: key, model: model, operation: operation, revision: context.revision, runtime: context.runtime, completeMeasurement: context.completeMeasurement, lastRun: now)
        profile.lastRun = now
        profile.totalStepSeconds += observation.stepSeconds; profile.steps += observation.steps
        var totals = profile.stageTotalMilliseconds ?? [:]
        for (key, value) in observation.stages { totals[key, default: 0] += value }
        if !totals.isEmpty { profile.stageTotalMilliseconds = totals }
        if outcome == .succeeded {
            profile.successfulRuns += 1; profile.lastSuccess = now
            profile.successfulPeakBytes = max(profile.successfulPeakBytes, observation.peakBytes)
            profile.longestSuccessfulContextSeconds = max(profile.longestSuccessfulContextSeconds, observation.contextSeconds)
        } else if outcome == .cancelled { profile.cancelledRuns += 1; profile.failedPeakBytes = max(profile.failedPeakBytes, observation.peakBytes) }
        else { profile.failedRuns += 1; profile.lastFailure = now; profile.failedPeakBytes = max(profile.failedPeakBytes, observation.peakBytes) }
        var next = values; next[key] = profile
        if next.count > 128 { for old in next.values.sorted(by: { $0.lastRun > $1.lastRun }).dropFirst(128) { next.removeValue(forKey: old.id) } }
        let bytes = try JSONEncoder().encode(next)
        try checkDisk(file.deletingLastPathComponent(), Int64(bytes.count * 2))
        try PrivateFiles.save(next, to: file); values = next
    }
    public func recordSafely(model: String, operation: String, context: ModelResourceContext, outcome: JobState, observation: ModelRunObservation) {
        do { try record(model: model, operation: operation, context: context, outcome: outcome, observation: observation); lastWriteError = nil }
        catch { lastWriteError = "Resource observations could not be saved." }
    }
    public func failedRunFloor(model: String, operation: String, context: ModelResourceContext) throws -> Int64? {
        try load()
        guard context.completeMeasurement, let value = values[context.key(model: model, operation: operation)], value.completeMeasurement, value.failedPeakBytes > 0 else { return nil }
        return value.failedPeakBytes + value.failedPeakBytes / 4 + (512 << 20)
    }
    public func learnedBudget(model: String, operation: String, context: ModelResourceContext) throws -> Int64? {
        try load()
        guard context.completeMeasurement, let profile = values[context.key(model: model, operation: operation)],
              profile.completeMeasurement, profile.successfulRuns >= 3, profile.successfulPeakBytes > 0,
              profile.longestSuccessfulContextSeconds >= context.requestedContextSeconds,
              profile.lastFailure.map({ $0 < (profile.lastSuccess ?? .distantPast) }) ?? true else { return nil }
        // Keep 25% plus 512 MiB above the largest successful observation. A later
        // failure suspends learning until another complete run succeeds.
        return max(context.minimumBudgetBytes, profile.successfulPeakBytes + profile.successfulPeakBytes / 4 + (512 << 20))
    }
}
