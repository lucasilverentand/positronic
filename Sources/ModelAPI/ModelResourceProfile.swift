import Foundation

/// Aggregate resource observations only: no prompts, transcripts or audio history.
public struct ModelResourceProfile: Codable, Sendable, Identifiable {
    public var id: String
    public var model: String
    public var operation: String
    public var revision: String
    public var runtime: String
    public var completeMeasurement: Bool
    public var successfulRuns: Int = 0
    public var failedRuns: Int = 0
    public var cancelledRuns: Int = 0
    public var successfulPeakBytes: Int64 = 0
    public var failedPeakBytes: Int64 = 0
    public var longestSuccessfulContextSeconds: Double = 0
    public var totalStepSeconds: Double = 0
    public var steps: Int = 0
    public var stageTotalMilliseconds: [String: Double]?
    public var lastRun: Date
    public var lastFailure: Date?
    public var lastSuccess: Date?
    public init(id: String, model: String, operation: String, revision: String, runtime: String, completeMeasurement: Bool, lastRun: Date) {
        self.id = id; self.model = model; self.operation = operation; self.revision = revision; self.runtime = runtime
        self.completeMeasurement = completeMeasurement; self.lastRun = lastRun
    }
    public var averageStepMilliseconds: Double? { steps > 0 ? totalStepSeconds * 1000 / Double(steps) : nil }
}
