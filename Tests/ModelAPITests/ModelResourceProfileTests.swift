import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

final class ModelResourceProfileTests: XCTestCase, @unchecked Sendable {
    func testSuccessfulMeasurementsPersistAndStaySeparateFromFailures() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("profiles.json"), store = ModelResourceProfiles(file: file, checkDisk: { _, _ in })
        let context = ModelResourceContext(revision: "rev1", runtime: "mlx1", completeMeasurement: true, requestedContextSeconds: 30)
        for i in 0..<3 { try await store.record(model: "model", operation: "realtime", context: context, outcome: .succeeded, observation: .init(peakBytes: 4 << 30, contextSeconds: 40, stepSeconds: 1, steps: 20), now: Date(timeIntervalSince1970: Double(i))) }
        let learned = try await store.learnedBudget(model: "model", operation: "realtime", context: context)
        XCTAssertEqual(learned, (5 << 30) + (512 << 20))
        try await store.record(model: "model", operation: "realtime", context: context, outcome: .failed, observation: .init(peakBytes: 2 << 30), now: Date(timeIntervalSince1970: 4))
        let disabled = try await store.learnedBudget(model: "model", operation: "realtime", context: context)
        XCTAssertNil(disabled)
        let reopened = ModelResourceProfiles(file: file, checkDisk: { _, _ in })
        let stats = try await reopened.all(); XCTAssertEqual(stats.count, 1); XCTAssertEqual(stats[0].successfulPeakBytes, 4 << 30); XCTAssertEqual(stats[0].failedRuns, 1)
        XCTAssertEqual(stats[0].averageStepMilliseconds ?? 0, 50, accuracy: 0.1)
    }
    func testRevisionRuntimeContextAndIncompleteMeasurementsDoNotMix() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ModelResourceProfiles(file: file, checkDisk: { _, _ in })
        let context = ModelResourceContext(revision: "r1", runtime: "runtime1", completeMeasurement: true)
        for _ in 0..<3 { try await store.record(model: "m", operation: "realtime", context: context, outcome: .succeeded, observation: .init(peakBytes: 1 << 30, contextSeconds: 10)) }
        for other in [ModelResourceContext(revision: "r2", runtime: "runtime1", completeMeasurement: true), ModelResourceContext(revision: "r1", runtime: "runtime2", completeMeasurement: true), ModelResourceContext(revision: "r1", runtime: "runtime1", completeMeasurement: false), ModelResourceContext(revision: "r1", runtime: "runtime1", completeMeasurement: true, requestedContextSeconds: 60)] {
            let learned = try await store.learnedBudget(model: "m", operation: "realtime", context: other); XCTAssertNil(learned)
        }
        try await store.record(model: "m", operation: "load", context: context, outcome: .cancelled, observation: .init())
        let profiles = try await store.all(); XCTAssertEqual(profiles.count, 1) // Unstarted/zero observations are not sizing evidence.
    }
    func testCorruptStoreIsPreservedRatherThanOverwritten() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let bytes = Data("invalid-profile-file".utf8); try bytes.write(to: file)
        let store = ModelResourceProfiles(file: file, checkDisk: { _, _ in })
        do { _ = try await store.all(); XCTFail("Corrupt profile accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
}
extension ModelResourceProfileTests {
    func testQueueRecordsOnlyActuallyExecutedJobsAndFlushesAtShutdown() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ModelResourceProfiles(file: file, checkDisk: { _, _ in }), queue = fixtureQueue()
        await queue.configure(prepare: { _ in }, cancelWorker: {}, footprint: { 4 << 30 }, profiles: store)
        let context = ModelResourceContext(revision: "r1", runtime: "fixture", completeMeasurement: true)
        let job = try await queue.submit(model: "fixture", operation: "realtime", budget: 16 << 30, staged: true, profile: context) { _ in
            await JobExecution.metrics?.step(seconds: 0.02, contextSeconds: 0.08)
            return .init(data: Data())
        }
        _ = try await queue.wait(job.id); await queue.shutdown()
        let observed = try await store.all(); XCTAssertEqual(observed.count, 1); XCTAssertEqual(observed[0].successfulRuns, 1); XCTAssertEqual(observed[0].successfulPeakBytes, 4 << 30)
        XCTAssertEqual(observed[0].averageStepMilliseconds ?? 0, 20, accuracy: 0.01)
    }
    func testFailedRunCanRaiseButNeverLowerTheBudgetFloor() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ModelResourceProfiles(file: file, checkDisk: { _, _ in })
        let context = ModelResourceContext(revision: "r", runtime: "v", completeMeasurement: true)
        try await store.record(model: "m", operation: "realtime", context: context, outcome: .failed, observation: .init(peakBytes: 10 << 30))
        let floor = try await store.failedRunFloor(model: "m", operation: "realtime", context: context)
        XCTAssertGreaterThan(floor ?? 0, 10 << 30)
        let estimate = try await store.learnedBudget(model: "m", operation: "realtime", context: context); XCTAssertNil(estimate)
    }
}
