import Foundation
import Darwin
import XCTest
@testable import ModelAPI
@testable import ModelService

final class MemoryAccountingTests: XCTestCase {
    func testFileCacheIncludesActivePagesAndCountsSpeculationOnce() throws {
        var vm=vm_statistics64()
        vm.free_count=10;vm.speculative_count=4;vm.external_page_count=50;vm.purgeable_count=7
        vm.inactive_count=2;vm.internal_page_count=30
        let result=try ResourceMonitor.memoryEstimate(vm,physical:1000,pageSize:1)
        XCTAssertEqual(result.freeBytes,10);XCTAssertEqual(result.fileCacheBytes,46)
        XCTAssertEqual(result.purgeableBytes,7);XCTAssertEqual(result.availableBytes,63)
        vm.inactive_count=200
        XCTAssertEqual(try ResourceMonitor.memoryEstimate(vm,physical:1000,pageSize:1).availableBytes,63)
    }
    func testCompressedAndNonpurgeableAnonymousMemoryAreNotAvailable() throws {
        var vm=vm_statistics64();vm.free_count=5;vm.inactive_count=60;vm.internal_page_count=60
        vm.wire_count=10;vm.compressor_page_count=20
        let result=try ResourceMonitor.memoryEstimate(vm,physical:100,pageSize:1)
        XCTAssertEqual(result.availableBytes,5);XCTAssertEqual(result.compressedBytes,20)
        vm.free_count=80;vm.external_page_count=50;vm.purgeable_count=10
        XCTAssertEqual(try ResourceMonitor.memoryEstimate(vm,physical:100,pageSize:1).availableBytes,70)
        XCTAssertThrowsError(try ResourceMonitor.memoryEstimate(vm,physical:100,pageSize:0))
    }
    func testCacheCanAdmitWorkWithoutLoweringRealMemoryRequirement() throws {
        var vm=vm_statistics64();vm.free_count=1;vm.external_page_count=12
        let memory=try ResourceMonitor.memoryEstimate(vm,physical:36 << 30,pageSize:1 << 30)
        let snapshot=ResourceSnapshot(physical:36 << 30,available:memory.availableBytes,disk:100 << 30,memory:memory)
        let result=ResourceMonitor.restriction(snapshot,budget:6 << 30)
        XCTAssertNil(result.reason);XCTAssertEqual(result.memory?.fileCacheBytes,12 << 30)
        XCTAssertEqual(result.systemHeadroomBytes,(36 << 30)/10)
        XCTAssertNotNil(ResourceMonitor.restriction(snapshot,budget:12 << 30).reason)
    }
    func testIdleSwapDoesNotBlockButSSDChurnDoes() {
        let history=SwapHistory()
        XCTAssertEqual(history.sample(used:4 << 30,writtenPages:100,pageSize:16384,now:0),0)
        XCTAssertEqual(history.sample(used:4 << 30,writtenPages:100,pageSize:16384,now:1),0)
        let activity=history.sample(used:4 << 30,writtenPages:2148,pageSize:16384,now:2)
        XCTAssertEqual(activity,32 << 20)
        let snapshot=ResourceSnapshot(physical:36 << 30,available:30 << 30,disk:100 << 30,swap:4 << 30,swapActivityBytes:activity)
        XCTAssertEqual(ResourceMonitor.restriction(snapshot,budget:1 << 30).reason,"Waiting for SSD swap activity to settle.")
        _ = history.sample(used:4 << 30,writtenPages:2148,pageSize:16384,now:33)
        XCTAssertEqual(history.sample(used:4 << 30,writtenPages:2148,pageSize:16384,now:34),0)
        XCTAssertEqual(history.sample(used:0,writtenPages:0,pageSize:16384,now:35),0)
    }
    func testMemoryStatusRemainsCompatibleWithOlderJobJSON() throws {
        let data=Data(#"{"availableMemoryBytes":1,"requiredMemoryBytes":2,"availableDiskBytes":3}"#.utf8)
        let result=try JSONDecoder().decode(ResourceStatus.self,from:data)
        XCTAssertNil(result.memory);XCTAssertNil(result.systemHeadroomBytes);XCTAssertNil(result.swapActivityBytes)
    }
    func testLiveReadOnlyMemoryBreakdown() throws {
        let snapshot=try ResourceMonitor.snapshot()
        let memory=try XCTUnwrap(snapshot.memory)
        XCTAssertEqual(snapshot.available,memory.availableBytes)
        print("MAC_MEMORY physical=\(snapshot.physical) available=\(snapshot.available) free=\(memory.freeBytes) fileCache=\(memory.fileCacheBytes) purgeable=\(memory.purgeableBytes) compressed=\(memory.compressedBytes) headroom=\(ResourceMonitor.headroom(physical:snapshot.physical)) swapActivity=\(snapshot.swapActivityBytes)")
    }
}
