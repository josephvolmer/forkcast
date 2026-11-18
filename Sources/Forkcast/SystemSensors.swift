import Darwin
import Foundation
import ForkcastCore
import IOKit

/// CPU, memory, disk, I/O, network and volume sensors. Not thread-safe: used from the engine queue only.
final class SystemSensors {
    let pCores: Int
    let eCores: Int
    let totalCores: Int
    let pageSize = Double(vm_kernel_page_size)
    let totalMemGB: Double

    private var lastTicks: [UInt32] = []
    private var lastIO: (read: UInt64, write: UInt64, at: Date)?
    private var lastNet: (down: UInt64, up: UInt64, at: Date)?
    private var lastNettop: [Int32: (inB: UInt64, outB: UInt64, name: String)] = [:]
    private var lastNettopAt: Date?
    private(set) var cachedDisk = DiskInfo()
    private var diskCheckedAt = Date.distantPast
    private var tmCheckedAt = Date.distantPast
    private var importantGB = 0.0
    private var volumeFree: [String: (free: Double, changed: Date)] = [:]

    init() {
        func sysInt(_ n: String) -> Int {
            var v: Int32 = 0
            var s = MemoryLayout<Int32>.size
            return sysctlbyname(n, &v, &s, nil, 0) == 0 ? Int(v) : 0
        }
        let total = ProcessInfo.processInfo.activeProcessorCount
        let p = sysInt("hw.perflevel0.logicalcpu")
        let e = sysInt("hw.perflevel1.logicalcpu")
        totalCores = total
        pCores = p > 0 ? p : total
        eCores = p > 0 ? e : 0
        totalMemGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    // MARK: CPU

    /// Per-core busy fractions since the last call (E cores first on Apple Silicon).
    func cpu() -> CPUInfo {
        var info = CPUInfo()
        info.totalCores = totalCores
        info.pCores = pCores
        info.eCores = eCores
        var count: natural_t = 0
        var arr: processor_info_array_t?
        var arrCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &arr, &arrCount) == KERN_SUCCESS,
              let a = arr else { return info }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: a), vm_size_t(arrCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(arrCount)).map { UInt32(bitPattern: a[$0]) }
        if lastTicks.count == ticks.count {
            var eBusy = 0.0, pBusy = 0.0
            for c in 0..<Int(count) {
                let b = c * Int(CPU_STATE_MAX)
                let user = Double(ticks[b + Int(CPU_STATE_USER)] &- lastTicks[b + Int(CPU_STATE_USER)])
                let sys = Double(ticks[b + Int(CPU_STATE_SYSTEM)] &- lastTicks[b + Int(CPU_STATE_SYSTEM)])
                let nice = Double(ticks[b + Int(CPU_STATE_NICE)] &- lastTicks[b + Int(CPU_STATE_NICE)])
                let idle = Double(ticks[b + Int(CPU_STATE_IDLE)] &- lastTicks[b + Int(CPU_STATE_IDLE)])
                let tot = user + sys + nice + idle
                let busy = tot > 0 ? (user + sys + nice) / tot : 0
                if c < eCores { eBusy += busy } else { pBusy += busy }
            }
            info.busyCores = eBusy + pBusy
            info.eBusyPct = eCores > 0 ? eBusy / Double(eCores) * 100 : 0
            info.pBusyPct = pCores > 0 ? pBusy / Double(pCores) * 100 : 0
        }
        lastTicks = ticks
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { info.loadAvg1 = load[0] }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: info.thermal = "nominal"
        case .fair: info.thermal = "fair"
        case .serious: info.thermal = "serious"
        case .critical: info.thermal = "critical"
        @unknown default: info.thermal = "nominal"
        }
        info.throttling = info.thermal == "serious" || info.thermal == "critical"
        return info
    }

    // MARK: Memory

    func memory() -> MemoryInfo {
        var m = MemoryInfo()
        m.totalGB = totalMemGB
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) == KERN_SUCCESS
            }
        }
        if ok {
            let gb = pageSize / 1_073_741_824
            let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
            m.compressedGB = Double(stats.compressor_page_count) * gb
            m.usedGB = (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * gb
            let reclaimable = Double(stats.free_count) + Double(stats.speculative_count)
                + Double(stats.external_page_count) + Double(stats.purgeable_count)
            m.headroomGB = max(0, reclaimable * gb - totalMemGB * 0.08)
        }
        var level: Int32 = 0
        var s = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &s, nil, 0) == 0 {
            m.pressure = level >= 4 ? "red" : level >= 2 ? "yellow" : "green"
        }
        if m.pressure != "green" { m.headroomGB = 0 }
        var swap = xsw_usage()
        var ss = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &ss, nil, 0) == 0 {
            m.swapUsedGB = Double(swap.xsu_used) / 1_073_741_824
        }
        return m
    }

    // MARK: Disk (internal)

    func disk(floorGB: Double, force: Bool = false) -> DiskInfo {
        let now = Date()
        // Local snapshots: cheap enough every 2 min. A change in the count means purgeable space changed too.
        var refresh = force
        if now.timeIntervalSince(tmCheckedAt) > 120 {
            tmCheckedAt = now
            let n = Self.countLocalSnapshots()
            if n != cachedDisk.tmLocalSnapshots { refresh = true }
            cachedDisk.tmLocalSnapshots = n
        }
        // Free right now: statvfs, exactly what `df` and scripts' own guards see. Cheap, so every tick.
        var vfs = statvfs()
        if statvfs("/", &vfs) == 0 {
            cachedDisk.freeGB = Double(vfs.f_bavail) * Double(vfs.f_frsize) / 1e9
            cachedDisk.totalGB = Double(vfs.f_blocks) * Double(vfs.f_frsize) / 1e9
        }
        // macOS' "available for important usage" (incl. purgeable) is relatively expensive: once a minute.
        if refresh || now.timeIntervalSince(diskCheckedAt) > 60 {
            diskCheckedAt = now
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                if let t = v.volumeTotalCapacity, t > 0 { cachedDisk.totalGB = Double(t) / 1e9 }
                importantGB = Double(v.volumeAvailableCapacityForImportantUsage ?? 0) / 1e9
            }
        }
        cachedDisk.freeInclPurgeableGB = max(importantGB, cachedDisk.freeGB)
        cachedDisk.purgeableGB = max(0, cachedDisk.freeInclPurgeableGB - cachedDisk.freeGB)
        cachedDisk.floorGB = floorGB
        var d = cachedDisk
        // Block-device byte counters (all drives).
        let (r, w) = Self.blockStorageBytes()
        if let last = lastIO, now.timeIntervalSince(last.at) > 0 {
            let dt = now.timeIntervalSince(last.at)
            d.readMBs = Double(r &- last.read) / dt / 1e6
            d.writeMBs = Double(w &- last.write) / dt / 1e6
        }
        lastIO = (r, w, now)
        return d
    }

    private static func blockStorageBytes() -> (UInt64, UInt64) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var r: UInt64 = 0, w: UInt64 = 0
        while case let s = IOIteratorNext(it), s != 0 {
            if let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                r &+= (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w &+= (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
        }
        return (r, w)
    }

    private static func countLocalSnapshots() -> Int? {
        let out = run("/usr/bin/tmutil", ["listlocalsnapshots", "/"])
        guard let out else { return nil }
        return out.split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }

    // MARK: Network (interface counters, 64-bit)

    func network() -> NetworkInfo {
        var n = NetworkInfo()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return n }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return n }
        var down: UInt64 = 0, up: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.load(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil {
                        let s = String(cString: name)
                        if s.hasPrefix("en") {   // physical Wi-Fi / Ethernet (VPN tunnels would double count)
                            down &+= h2.ifm_data.ifi_ibytes
                            up &+= h2.ifm_data.ifi_obytes
                        }
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        let now = Date()
        if let last = lastNet, now.timeIntervalSince(last.at) > 0, down >= last.down, up >= last.up {
            let dt = now.timeIntervalSince(last.at)
            n.downMBs = Double(down - last.down) / dt / 1e6
            n.upMBs = Double(up - last.up) / dt / 1e6
        }
        lastNet = (down, up, now)
        return n
    }

    /// Per-process network via `nettop` (cheap, ~20 ms). Returns the top process by total rate.
    func topNetworkProcess() -> (String, Double)? {
        guard let out = Self.run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]) else { return nil }
        let now = Date()
        var cur: [Int32: (UInt64, UInt64, String)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3 else { continue }
            let ident = String(cols[0])
            guard let dot = ident.lastIndex(of: "."), let pid = Int32(ident[ident.index(after: dot)...]) else { continue }
            cur[pid] = (UInt64(cols[1]) ?? 0, UInt64(cols[2]) ?? 0, String(ident[..<dot]))
        }
        defer {
            lastNettop = cur.mapValues { (inB: $0.0, outB: $0.1, name: $0.2) }
            lastNettopAt = now
        }
        guard let lastAt = lastNettopAt else { return nil }
        let dt = now.timeIntervalSince(lastAt)
        guard dt > 0 else { return nil }
        var best: (String, Double)?
        for (pid, v) in cur {
            guard let p = lastNettop[pid], v.0 >= p.inB, v.1 >= p.outB else { continue }
            let rate = Double((v.0 - p.inB) + (v.1 - p.outB)) / dt / 1e6
            if rate > (best?.1 ?? 0.001) { best = (v.2, rate) }
        }
        return best
    }

    // MARK: External volumes

    func volumes(watched: Set<String>) -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var out: [VolumeInfo] = []
        var seen = Set<String>()
        let now = Date()
        for u in urls where u.path.hasPrefix("/Volumes/") {
            let v = try? u.resourceValues(forKeys: Set(keys))
            var info = VolumeInfo(name: v?.volumeName ?? u.lastPathComponent, path: u.path, mounted: true,
                                  watched: watched.contains(u.path))
            info.totalGB = v?.volumeTotalCapacity.map { Double($0) / 1e9 }
            info.freeGB = v?.volumeAvailableCapacity.map { Double($0) / 1e9 }
            if let f = info.freeGB {
                if let prev = volumeFree[u.path], abs(prev.free - f) < 0.001 {
                    info.lastChange = prev.changed
                } else {
                    let changed = volumeFree[u.path] == nil ? nil : now
                    volumeFree[u.path] = (f, changed ?? Date.distantPast)
                    info.lastChange = changed
                }
                if info.lastChange == Date.distantPast { info.lastChange = nil }
            }
            seen.insert(u.path)
            out.append(info)
        }
        for w in watched.sorted() where !seen.contains(w) {
            out.append(VolumeInfo(name: (w as NSString).lastPathComponent, path: w, mounted: false, watched: true))
        }
        return out
    }

    // MARK: Watched folders

    /// Allocated size of a folder tree (runs on a background queue).
    static func folderSize(_ path: String) -> Double? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                     options: [], errorHandler: { _, _ in true }) else { return nil }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return Double(total) / 1e9
    }

    // MARK: helpers

    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
