import Foundation
import XCTest
@testable import ModelAPI
@testable import ModelService

private final class MutableResources: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ResourceSnapshot(physical: 36 << 30, available: 30 << 30, disk: 100 << 30)
    private var failed = false
    func get() throws -> ResourceSnapshot { lock.lock(); defer { lock.unlock() }; if failed { throw CocoaError(.fileReadUnknown) }; return value }
    func change(_ update: (inout ResourceSnapshot) -> Void) { lock.lock(); defer { lock.unlock() }; update(&value) }
    func fail() { lock.lock(); defer { lock.unlock() }; failed = true }
}
private actor OrderLog { var order: [Int] = []; func add(_ n: Int) { order.append(n) } }
final class JobQueueTests: XCTestCase, @unchecked Sendable {
    private func queue(_ resources: MutableResources, wait: TimeInterval = 1, retention: TimeInterval = 1800, directory: URL? = nil) -> JobQueue {
        JobQueue(directory: directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("PositronicTests/" + UUID().uuidString), interval: .milliseconds(5), waitLimit: wait, retention: retention, probe: { try resources.get() })
    }
    func testFIFOAndSingleExecution() async throws {
        let resources = MutableResources(), queue = queue(resources), log = OrderLog()
        var ids: [UUID] = []
        for n in 0..<8 {
            let job = try await queue.submit(model: "fixture", operation: "fixture", budget: 1 << 30) { _ in
                await log.add(n); try await Task.sleep(for: .milliseconds(10)); await log.add(n); return .init(data: Data())
            }; ids.append(job.id)
        }
        _ = try await queue.wait(ids.last!)
        let order = await log.order; XCTAssertEqual(order, (0..<8).flatMap { [$0,$0] })
        await queue.shutdown()
    }
    func testQueueFullAndWaitingCancellation() async throws {
        let resources = MutableResources(); resources.change { $0.pressure = 2 }
        let queue = queue(resources)
        var jobs: [ModelJob] = []
        for _ in 0..<32 { jobs.append(try await queue.submit(model: "fixture", operation: "fixture", budget: 1) { _ in XCTFail("Must not start"); return .init(data: Data()) }) }
        do { _ = try await queue.submit(model: "overflow", operation: "fixture", budget: 0) { _ in .init(data: Data()) }; XCTFail("Queue must be bounded") } catch is QueueFull {} catch { XCTFail("Wrong error") }
        try await queue.cancel(jobs[0].id)
        let state = try await queue.job(jobs[0].id).state; XCTAssertEqual(state, .cancelled)
        await queue.shutdown()
    }
    func testLowRAMDiskHeatCPUAndUnknownBudgetNeverStart() async throws {
        let cases: [(ResourceSnapshot) -> ResourceSnapshot] = [
            { var s=$0; s.available=1 << 30; return s }, { var s=$0; s.disk=1 << 30; return s },
            { var s=$0; s.thermal=2; return s }, { var s=$0; s.cpu=0.99; return s }, { var s=$0; s.pressure=2; return s }
        ]
        for update in cases {
            let resources = MutableResources(); resources.change { $0 = update($0) }; let queue = queue(resources, wait: 0.03)
            let job = try await queue.submit(model: "fixture", operation: "fixture", budget: 1 << 30) { _ in XCTFail("Unsafe admission"); return .init(data: Data()) }
            do { _ = try await queue.wait(job.id); XCTFail("Expected resource timeout") } catch {}
            let result = try await queue.job(job.id); XCTAssertEqual(result.state, .failed); XCTAssertNotNil(result.resources?.reason)
            await queue.shutdown()
        }
        let resources = MutableResources(), queue = queue(resources, wait: 0.03)
        let job = try await queue.submit(model: "unknown", operation: "fixture", budget: nil) { _ in XCTFail("Unknown budget"); return .init(data: Data()) }
        do { _ = try await queue.wait(job.id); XCTFail("Unknown model ran") } catch {}
        await queue.shutdown()
    }
    func testTelemetryFailureFailsClosedAndWaitingCanRecover() async throws {
        let resources = MutableResources(); resources.change { $0.available = 1 << 30 }
        let queue = queue(resources)
        let job = try await queue.submit(model: "fixture", operation: "fixture", budget: 1 << 30) { _ in .init(data: Data("ready".utf8)) }
        try await Task.sleep(for: .milliseconds(20))
        let waiting = try await queue.job(job.id); XCTAssertEqual(waiting.state, .waitingForResources)
        resources.change { $0.available = 30 << 30 }
        let result = try await queue.wait(job.id); XCTAssertEqual(String(data: result.data, encoding: .utf8), "ready")
        await queue.shutdown()
        let broken = MutableResources(); broken.fail(); let unavailable = self.queue(broken, wait: 0.03)
        let rejected = try await unavailable.submit(model: "fixture", operation: "fixture", budget: 0) { _ in XCTFail("Telemetry failed"); return .init(data: Data()) }
        do { _ = try await unavailable.wait(rejected.id); XCTFail("Must fail closed") } catch {}
        await unavailable.shutdown()
    }
    func testOwnerIsolationRevocationAndExpiry() async throws {
        let resources = MutableResources(); resources.change { $0.pressure = 2 }; let queue = queue(resources, retention: 0.15)
        let a = UUID(), b = UUID()
        let first = try await queue.submit(model: "fixture", operation: "fixture", owner: a, budget: 0) { _ in .init(data: Data()) }
        let second = try await queue.submit(model: "fixture", operation: "fixture", owner: b, budget: 0) { _ in .init(data: Data()) }
        do { _ = try await queue.job(first.id, owner: b); XCTFail("Cross-key access") } catch is JobNotFound {}
        await queue.revoke(a)
        let cancelled = try await queue.job(first.id, owner: a); XCTAssertEqual(cancelled.state, .cancelled)
        let pending = try await queue.job(second.id, owner: b); XCTAssertFalse(pending.state.terminal)
        resources.change { $0.pressure = 1 }; _ = try await queue.wait(second.id)
        try await Task.sleep(for: .milliseconds(200))
        do { _ = try await queue.result(second.id, owner: b); XCTFail("Result must expire") } catch is JobNotFound {}
        await queue.shutdown()
    }
    func testActiveCancellationDoesNotStartNextJobUntilWorkStops() async throws {
        let resources = MutableResources(), queue = queue(resources), entered = expectation(description: "Work started")
        let first = try await queue.submit(model: "fixture", operation: "fixture", budget: 0) { _ in
            entered.fulfill(); try await Task.sleep(for: .seconds(30)); XCTFail("Cancelled operation resumed"); return .init(data: Data())
        }
        await fulfillment(of: [entered], timeout: 2)
        let second = try await queue.submit(model: "fixture", operation: "fixture", budget: 0) { _ in .init(data: Data()) }
        try await queue.cancel(first.id)
        _ = try await queue.wait(second.id)
        await queue.shutdown()
    }
    func testCriticalPressureStopsRunningWork() async throws {
        let resources = MutableResources(), queue = queue(resources), entered = expectation(description: "Work started")
        let job = try await queue.submit(model: "fixture", operation: "fixture", budget: 0) { _ in
            entered.fulfill(); try await Task.sleep(for: .seconds(30)); return .init(data: Data())
        }
        await fulfillment(of: [entered], timeout: 2); resources.change { $0.pressure = 4 }
        do { _ = try await queue.wait(job.id); XCTFail("Critical pressure must stop inference") } catch {}
        let state = try await queue.job(job.id).state; XCTAssertEqual(state, .failed)
        await queue.shutdown()
    }
    func testStartupCleanupPreservesAnotherInstancesLease() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let resources = MutableResources(), first = queue(resources, directory: folder), second = queue(resources, directory: folder)
        try await first.start(); let file = folder.appendingPathComponent("orphan"); try Data([1]).write(to: file)
        do { try await second.start(); XCTFail("Another process owns jobs") } catch {}
        await second.shutdown()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        await first.shutdown(); try Data([1]).write(to: file)
        try await second.start(); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)); await second.shutdown()
    }
    func testProductionTelemetryIsReadableWithoutInference() throws {
        let snapshot = try ResourceMonitor.snapshot(); XCTAssertGreaterThan(snapshot.physical,0); XCTAssertGreaterThan(snapshot.disk,0)
    }
}

extension JobQueueTests {
    func testConcurrentAdmissionRemainsSerialized() async throws {
        let resources = MutableResources(), queue = queue(resources), log = OrderLog()
        let ids = try await withThrowingTaskGroup(of:UUID.self) { group in
            for n in 0..<20 { group.addTask {
                let job = try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in
                    await log.add(n); try await Task.sleep(for:.milliseconds(5));await log.add(n); return .init(data:Data())
                };return job.id
            } }
            var ids:[UUID]=[];for try await id in group { ids.append(id) };return ids
        }
        for id in ids { _ = try await queue.wait(id) }
        let order = await log.order
        XCTAssertEqual(order.count,40)
        for n in stride(from:0,to:40,by:2) { XCTAssertEqual(order[n],order[n+1]) }
        await queue.shutdown()
    }
    func testSwapGrowthOverrunAndLostTelemetryStopWork() async throws {
        for condition in 0..<3 {
            let resources=MutableResources(),queue=queue(resources),started=expectation(description:"started")
            await queue.configure(prepare:{ _ in },cancelWorker:{},footprint:{ condition == 1 ? 2 << 30 : 0 })
            let job=try await queue.submit(model:"fixture",operation:"fixture",budget:1 << 30) { _ in
                started.fulfill();try await Task.sleep(for:.seconds(30));return .init(data:Data())
            }
            await fulfillment(of:[started],timeout:2)
            if condition == 0 { resources.change { $0.swap = 300 << 20 } }
            if condition == 2 { resources.fail() }
            do { _ = try await queue.wait(job.id);XCTFail("Unsafe work continued") } catch {}
            let info=try await queue.job(job.id);XCTAssertEqual(info.state,.failed)
            await queue.shutdown()
        }
    }
}
extension JobQueueTests {
    func testWorkerFailureCleansInputAndDoesNotPoisonNextJob() async throws {
        let resources=MutableResources(),queue=queue(resources),folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to:folder)
        let failed=try await queue.submit(model:"worker",operation:"speech",budget:0,cleanup:{ try? FileManager.default.removeItem(at:folder) }) { _ in
            throw ModelAPIError.unavailable("Injected worker crash")
        }
        let next=try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in .init(data:Data([1])) }
        do { _ = try await queue.wait(failed.id);XCTFail("Worker crash cannot succeed") } catch {}
        _ = try await queue.wait(next.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath:folder.path))
        let owner=UUID();await queue.revoke(owner)
        do { _ = try await queue.submit(model:"fixture",operation:"fixture",owner:owner,budget:0) { _ in XCTFail("Revoked key admitted");return .init(data:Data()) };XCTFail("Revoked owner") } catch {}
        await queue.shutdown()
    }
}
extension JobQueueTests {
    func testNextJobWaitsForResourceReleaseAfterCancellation() async throws {
        let resources=MutableResources(),queue=queue(resources),log=OrderLog(),started=expectation(description:"Started")
        await queue.configure(prepare:{ _ in },cancelWorker:{
            try? await Task.sleep(for:.milliseconds(100));await log.add(1)
        })
        let first=try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in started.fulfill();try await Task.sleep(for:.seconds(30));return .init(data:Data()) }
        await fulfillment(of:[started],timeout:2)
        let second=try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in await log.add(2);return .init(data:Data()) }
        try await queue.cancel(first.id);_ = try await queue.wait(second.id)
        let order=await log.order;XCTAssertEqual(order,[1,2]);await queue.shutdown()
    }
}
extension JobQueueTests {
    func testElevatedPressureAndSwapWritesStopBeforeCriticalPressure() async throws {
        for swap in [false,true] {
            let resources=MutableResources(),queue=queue(resources),started=expectation(description:"Started")
            let job=try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in
                started.fulfill();try await Task.sleep(for:.seconds(30));return .init(data:Data())
            }
            await fulfillment(of:[started],timeout:2)
            resources.change { if swap { $0.swapActivityBytes=32 << 20 } else { $0.pressure=2 } }
            do { _ = try await queue.wait(job.id);XCTFail("Work continued while SSD/pressure safeguards were active") } catch {}
            let info=try await queue.job(job.id);XCTAssertEqual(info.state,.failed)
            await queue.shutdown()
        }
    }
    func testActiveSwappingNeverStartsAnotherJob() async throws {
        let resources=MutableResources();resources.change { $0.swapActivityBytes=32 << 20 }
        let queue=queue(resources,wait:0.03)
        let job=try await queue.submit(model:"fixture",operation:"fixture",budget:0) { _ in XCTFail("Inference started during SSD swapping");return .init(data:Data()) }
        do { _ = try await queue.wait(job.id);XCTFail("Unsafe admission") } catch {}
        let info=try await queue.job(job.id);XCTAssertTrue(info.resources?.reason?.contains("SSD") == true)
        await queue.shutdown()
    }
}
