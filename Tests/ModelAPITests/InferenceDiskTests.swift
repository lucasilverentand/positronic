import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

final class InferenceDiskTests: XCTestCase, @unchecked Sendable {
    func testInstalledInferenceUsesWorkingReserveAndProjectedWrites() {
        var snapshot = ResourceSnapshot(physical: 36 << 30, available: 30 << 30, disk: 3 << 30)
        XCTAssertNil(ResourceMonitor.restriction(snapshot, budget: 1 << 30, diskBytes: 1 << 30).reason)
        snapshot.disk -= 1
        XCTAssertTrue(ResourceMonitor.restriction(snapshot, budget: 1 << 30, diskBytes: 1 << 30).reason?.contains("2 GiB") == true)
        XCTAssertEqual(ResourceMonitor.diskReserve, 25 << 30)
        snapshot.disk = 17 << 30
        snapshot.pressure = 2
        XCTAssertNotNil(ResourceMonitor.restriction(snapshot, budget: 1 << 30).reason)
        snapshot.pressure = 1; snapshot.swapActivityBytes = ResourceMonitor.swapActivityLimit
        XCTAssertEqual(ResourceMonitor.restriction(snapshot, budget: 1 << 30).reason, "Waiting for SSD swap activity to settle.")
    }
    func testQueueRetainsResultsBelowDownloadReserve() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = JobQueue(directory: directory, interval: .milliseconds(5), probe: {
            .init(physical: 36 << 30, available: 30 << 30, disk: 3 << 30)
        })
        let job = try await queue.submit(model: "fixture", operation: "generation", budget: 1 << 30) { _ in .init(data: Data("ok".utf8)) }
        let result = try await queue.wait(job.id)
        XCTAssertEqual(String(decoding: result.data, as: UTF8.self), "ok")
        await queue.shutdown()
    }
}
