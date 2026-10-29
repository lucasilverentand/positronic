import Foundation
import Darwin
import ModelAPI

public struct ResourceSnapshot: Sendable {
    public var physical: Int64
    public var available: Int64
    public var disk: Int64
    public var swap: Int64
    public var pressure: Int32
    public var thermal: Int
    public var cpu: Double
    public init(physical: Int64, available: Int64, disk: Int64, swap: Int64 = 0, pressure: Int32 = 1, thermal: Int = 0, cpu: Double = 0) {
        self.physical = physical; self.available = available; self.disk = disk; self.swap = swap; self.pressure = pressure; self.thermal = thermal; self.cpu = cpu
    }
}
public enum ResourceMonitor {
    public static let diskReserve: Int64 = 25 * 1024 * 1024 * 1024
    public static func snapshot(at directory: URL = PrivateFiles.directory) throws -> ResourceSnapshot {
        var vm = vm_statistics64(); var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { throw ModelAPIError.unavailable("Memory telemetry is unavailable.") }
        var pressure: Int32 = 0; var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 else { throw ModelAPIError.unavailable("Memory-pressure telemetry is unavailable.") }
        var usage = xsw_usage(); size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { throw ModelAPIError.unavailable("Swap telemetry is unavailable.") }
        let path = FileManager.default.fileExists(atPath: directory.path) ? directory : FileManager.default.homeDirectoryForCurrentUser
        let disk = try path.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard let disk else { throw ModelAPIError.unavailable("Disk telemetry is unavailable.") }
        var cpu = host_cpu_load_info(); count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard cpuStatus == KERN_SUCCESS else { throw ModelAPIError.unavailable("CPU telemetry is unavailable.") }
        // Cumulative ticks are sampled by the scheduler to obtain interval utilization.
        let ticks = cpu.cpu_ticks
        let active = Double(ticks.0) + Double(ticks.1) + Double(ticks.3), total = active + Double(ticks.2)
        return .init(physical: Int64(ProcessInfo.processInfo.physicalMemory),
                     available: Int64(UInt64(vm.free_count) + UInt64(vm.inactive_count)) * Int64(getpagesize()),
                     disk: Int64(disk), swap: Int64(usage.xsu_used), pressure: pressure,
                     thermal: ProcessInfo.processInfo.thermalState.rawValue, cpu: CPUHistory.shared.sample(active: active, total: total))
    }
    public static func restriction(_ snapshot: ResourceSnapshot, budget: Int64?, diskBytes: Int64 = 0) -> ResourceStatus {
        let reserve = max(8 * 1024 * 1024 * 1024, snapshot.physical / 5)
        let required = (budget ?? 0) + reserve
        var reason: String?
        if budget == nil { reason = "No conservative memory budget is available for this model." }
        else if snapshot.pressure != 1 { reason = "Waiting for normal system memory pressure." }
        else if snapshot.thermal >= 2 { reason = "Waiting for the Mac to cool down." }
        else if snapshot.cpu > 0.90 { reason = "Waiting for CPU capacity." }
        else if snapshot.available < required { reason = "Waiting for enough RAM, including system headroom." }
        else if snapshot.disk < diskReserve + diskBytes { reason = "Waiting for disk space; 25 GiB must remain available." }
        return .init(availableMemoryBytes: snapshot.available, requiredMemoryBytes: required, availableDiskBytes: snapshot.disk, reason: reason)
    }
    public static func residentBytes(of pid: Int32) throws -> Int64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { throw ModelAPIError.unavailable("Worker memory telemetry is unavailable.") }
        return Int64(info.pti_resident_size)
    }
    public static func requireDisk(at directory: URL, additional: Int64) throws {
        let snapshot = try snapshot(at: directory)
        guard snapshot.disk >= diskReserve + additional else { throw ModelAPIError.unavailable("This operation must leave 25 GiB free on the destination drive.") }
    }
}

private final class CPUHistory: @unchecked Sendable {
    static let shared = CPUHistory()
    private let lock = NSLock()
    private var previous: (Double, Double)?
    private var saturatedSince: Date?
    private var lastUsage: Double = 0
    func sample(active: Double, total: Double) -> Double {
        lock.lock(); defer { previous = (active, total); lock.unlock() }
        guard let previous else { return total > 0 ? active / total : 1 }
        let elapsed = total - previous.1
        guard elapsed > 0 else { return lastUsage }
        let usage = min(1, max(0, (active - previous.0) / elapsed))
        if usage > 0.90 {
            if saturatedSince == nil { saturatedSince = Date() }
            lastUsage = Date().timeIntervalSince(saturatedSince!) >= 10 ? usage : 0
        } else { saturatedSince = nil; lastUsage = usage }
        return lastUsage
    }
}
