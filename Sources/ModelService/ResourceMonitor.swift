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
    public var memory: MemoryBreakdown?
    public var swapActivityBytes: Int64
    public init(physical: Int64, available: Int64, disk: Int64, swap: Int64 = 0, pressure: Int32 = 1, thermal: Int = 0, cpu: Double = 0, memory: MemoryBreakdown? = nil, swapActivityBytes: Int64 = 0) {
        self.physical = physical; self.available = available; self.disk = disk; self.swap = swap; self.pressure = pressure; self.thermal = thermal; self.cpu = cpu; self.memory = memory; self.swapActivityBytes = swapActivityBytes
    }
}
public enum ResourceMonitor {
    // Downloads keep staging headroom; installed inference only reserves temporary writes.
    public static let diskReserve: Int64 = 25 * 1024 * 1024 * 1024
    public static let inferenceDiskReserve: Int64 = 2 * 1024 * 1024 * 1024
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
        let disk = try availableDisk(at: path)
        var cpu = host_cpu_load_info(); count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let cpuStatus = withUnsafeMutablePointer(to: &cpu) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard cpuStatus == KERN_SUCCESS else { throw ModelAPIError.unavailable("CPU telemetry is unavailable.") }
        // Cumulative ticks are sampled by the scheduler to obtain interval utilization.
        let ticks = cpu.cpu_ticks
        let active = Double(ticks.0) + Double(ticks.1) + Double(ticks.3), total = active + Double(ticks.2)
        let physical = Int64(ProcessInfo.processInfo.physicalMemory)
        let memory = try memoryEstimate(vm, physical: physical, pageSize: Int64(getpagesize()))
        return .init(physical: physical,
                     available: memory.availableBytes,
                     disk: Int64(disk), swap: Int64(usage.xsu_used), pressure: pressure,
                     thermal: ProcessInfo.processInfo.thermalState.rawValue, cpu: CPUHistory.shared.sample(active: active, total: total), memory: memory, swapActivityBytes: SwapHistory.shared.sample(used: Int64(usage.xsu_used), writtenPages: vm.swapouts, pageSize: Int64(getpagesize())))
    }
    /// Uses public HOST_VM_INFO64 counters, not the iOS-only per-process memory limit.
    public static func memoryEstimate(_ vm: vm_statistics64, physical: Int64, pageSize: Int64) throws -> MemoryBreakdown {
        guard physical > 0, pageSize > 0, pageSize <= physical else { throw ModelAPIError.unavailable("Invalid memory telemetry.") }
        func bytes(_ pages: UInt32) -> Int64 { min(Int64(pages), physical / pageSize) * pageSize }
        let wired = bytes(vm.wire_count), compressed = bytes(vm.compressor_page_count)
        // Treat these categories as unavailable; never count compressed or app memory as a cache.
        let capacity = max(0, physical - wired - compressed)
        let free = min(bytes(vm.free_count), capacity)
        // XNU's public free_count already contains speculative pages. They are also
        // file-backed, so subtract them from external_page_count to count them once.
        let cachePages = vm.external_page_count > vm.speculative_count ? vm.external_page_count - vm.speculative_count : 0
        let cached = min(bytes(cachePages), capacity - free)
        // Volatile purgeable pages are anonymous, separate from the file cache.
        let purgeable = min(bytes(vm.purgeable_count), capacity - free - cached)
        return .init(freeBytes: free, fileCacheBytes: cached, purgeableBytes: purgeable, wiredBytes: wired, compressedBytes: compressed)
    }
    // Preserve responsiveness without reserving a quarter of a 36 GiB Mac.
    public static func headroom(physical: Int64) -> Int64 { max(2 * 1024 * 1024 * 1024, physical / 10) }
    public static let swapActivityLimit: Int64 = 32 * 1024 * 1024
    public static func restriction(_ snapshot: ResourceSnapshot, budget: Int64?, diskBytes: Int64 = 0) -> ResourceStatus {
        let reserve = headroom(physical: snapshot.physical)
        let required = (budget ?? 0) + reserve
        var reason: String?
        if budget == nil { reason = "No conservative memory budget is available for this model." }
        else if snapshot.pressure != 1 { reason = "Waiting for normal system memory pressure." }
        else if snapshot.swapActivityBytes >= swapActivityLimit { reason = "Waiting for SSD swap activity to settle." }
        else if snapshot.thermal >= 2 { reason = "Waiting for the Mac to cool down." }
        else if snapshot.cpu > 0.90 { reason = "Waiting for CPU capacity." }
        else if snapshot.available < required { let shortfall = ByteCountFormatter.string(fromByteCount: required - snapshot.available, countStyle: .memory)
            reason = "Waiting for \(shortfall) more estimated RAM after counting reclaimable cache and preserving system headroom." }
        else if snapshot.disk < inferenceDiskReserve + diskBytes {
            let shortfall = ByteCountFormatter.string(fromByteCount: inferenceDiskReserve + diskBytes - snapshot.disk, countStyle: .memory)
            let available = ByteCountFormatter.string(fromByteCount: snapshot.disk, countStyle: .memory)
            reason = "Waiting for \(shortfall) more disk space (\(available) available); 2 GiB must remain after projected temporary writes."
        }
        return .init(availableMemoryBytes: snapshot.available, requiredMemoryBytes: required, availableDiskBytes: snapshot.disk, reason: reason, memory: snapshot.memory, systemHeadroomBytes: reserve, swapActivityBytes: snapshot.swapActivityBytes)
    }
    public static func residentBytes(of pid: Int32) throws -> Int64 {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { throw ModelAPIError.unavailable("Worker memory telemetry is unavailable.") }
        return Int64(info.pti_resident_size)
    }
    /// URL resource values can remain cached while a long download blocks its
    /// run loop. Query fresh, unprivileged filesystem capacity on every check.
    public static func availableDisk(at directory: URL) throws -> Int64 {
        let fd = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw ModelAPIError.unavailable("Disk telemetry is unavailable.") }
        defer { Darwin.close(fd) }
        var info = statfs()
        let result = Darwin.fstatfs(fd, &info)
        guard result == 0, info.f_bsize > 0 else { throw ModelAPIError.unavailable("Disk telemetry is unavailable.") }
        let blocks = UInt64(info.f_bavail), blockSize = UInt64(info.f_bsize)
        guard blocks <= UInt64(Int64.max) / blockSize else { throw ModelAPIError.unavailable("Invalid filesystem capacity.") }
        return Int64(blocks * blockSize)
    }
    public static func requireDisk(at directory: URL, additional: Int64, reserve: Int64 = inferenceDiskReserve) throws {
        let snapshot = try snapshot(at: directory)
        guard additional >= 0, reserve >= 0, additional <= Int64.max - reserve, snapshot.disk >= reserve + additional else { throw ModelAPIError.unavailable("Not enough disk space for projected writes and the destination reserve.") }
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

/// Uses swap-out counters as well as net swap growth: a stable swap-file size can
/// still hide SSD churn. Existing idle swap alone does not block inference.
final class SwapHistory: @unchecked Sendable {
    static let shared = SwapHistory()
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, used: Int64, pages: UInt64)] = []
    func sample(used: Int64, writtenPages: UInt64, pageSize: Int64, now: TimeInterval = Date.timeIntervalSinceReferenceDate) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        if let last = samples.last, writtenPages < last.pages || now < last.time { samples = [] }
        samples.append((now, used, writtenPages))
        // Keep one sample immediately preceding the window boundary.
        while samples.count > 1, samples[1].time <= now - 30 { samples.removeFirst() }
        if samples.count > 512 { samples.removeSubrange(1..<(samples.count - 511)) }
        guard let first = samples.first, pageSize > 0 else { return 0 }
        let pageDelta = writtenPages - first.pages
        let writes = pageDelta > UInt64(Int64.max / pageSize) ? Int64.max : Int64(pageDelta) * pageSize
        return max(writes, max(0, used - first.used))
    }
}
