import Darwin
import Foundation
import ForkcastCore

/// One batched snapshot of every process: identity + parentage from a single `sysctl(KERN_PROC_ALL)`,
/// usage counters from `proc_pid_rusage` (readable for the user's own processes).
final class ProcessTable {
    struct Entry {
        let pid: Int32
        let ppid: Int32
        let uid: uid_t
        let start: Double          // unix seconds; (pid, start) identifies a process
        let comm: String
        let stopped: Bool
        var readable = false
        var energyJ = 0.0          // raw per-process energy counter delta (used for shares)
        var cpuSec = 0.0
        var memMB = 0.0            // physical footprint
        var readBytes = 0.0
        var writeBytes = 0.0
        var childCPUSec = 0.0      // CPU of children that exited (and were reaped) this interval, not seen before
    }

    struct Meta {
        let start: Double
        let path: String?
        let name: String           // display name of the executable
        let bundle: String?        // enclosing .app (outermost)
        var args: [String]?        // nil = not loaded / unreadable
        var argsLoaded = false
        var responsibleBundle: String??
    }

    private struct Counters { let start: UInt64; let energy: UInt64; let cpu: UInt64; let rd: UInt64; let wr: UInt64; let childCPU: UInt64 }

    private(set) var entries: [Int32: Entry] = [:]
    private(set) var seconds = 0.0
    private(set) var sampledAt = Date()
    private var counters: [Int32: Counters] = [:]
    private var meta: [Int32: Meta] = [:]
    private var lastUptime: UInt64 = 0
    private var lastWall: Double = 0
    private let ticksToNs: Double
    private var kinfoBuf = [kinfo_proc]()
    private var argBuf: [UInt8]
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private let responsibleFor: ResponsibleFn?
    let selfPid = getpid()
    let myUid = getuid()

    init() {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        ticksToNs = Double(tb.numer) / Double(tb.denom)
        if let h = dlopen(nil, RTLD_NOW), let s = dlsym(h, "responsibility_get_pid_responsible_for_pid") {
            responsibleFor = unsafeBitCast(s, to: ResponsibleFn.self)
        } else { responsibleFor = nil }
        var argmax: Int32 = 0
        var sz = MemoryLayout<Int32>.size
        sysctlbyname("kern.argmax", &argmax, &sz, nil, 0)
        argBuf = [UInt8](repeating: 0, count: Int(max(argmax, 262_144)))
    }

    func sample() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)   // excludes sleep
        let dt = lastUptime == 0 ? 0 : Double(now - lastUptime) / 1e9
        lastUptime = now
        seconds = dt
        sampledAt = Date()
        let prevWall = lastWall
        lastWall = sampledAt.timeIntervalSince1970

        // 1. All processes in one call.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        sysctl(&mib, 4, nil, &size, nil, 0)
        let needed = size / MemoryLayout<kinfo_proc>.stride + 32
        if kinfoBuf.count < needed { kinfoBuf = [kinfo_proc](repeating: kinfo_proc(), count: needed + 128) }
        size = kinfoBuf.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kinfoBuf, &size, nil, 0) == 0 else { return }
        let n = size / MemoryLayout<kinfo_proc>.stride

        var next: [Int32: Entry] = [:]
        next.reserveCapacity(n)
        var nextCounters: [Int32: Counters] = [:]
        nextCounters.reserveCapacity(n)
        for i in 0..<n {
            var kp = kinfoBuf[i]
            let pid = kp.kp_proc.p_pid
            let st = kp.kp_proc.p_un.__p_starttime
            let start = Double(st.tv_sec) + Double(st.tv_usec) / 1e6
            let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            var e = Entry(pid: pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid, start: start,
                          comm: comm, stopped: kp.kp_proc.p_stat == SSTOP)

            if pid > 0 {
                var ri = rusage_info_v6()
                let rc = withUnsafeMutablePointer(to: &ri) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
                }
                if rc == 0 {
                    e.readable = true
                    e.memMB = Double(ri.ri_phys_footprint) / 1_048_576
                    let c = Counters(start: ri.ri_proc_start_abstime, energy: ri.ri_energy_nj,
                                     cpu: ri.ri_user_time &+ ri.ri_system_time,
                                     rd: ri.ri_diskio_bytesread, wr: ri.ri_diskio_byteswritten,
                                     childCPU: ri.ri_child_user_time &+ ri.ri_child_system_time)
                    nextCounters[pid] = c
                    // Processes born since the last sample: their whole life falls inside this interval.
                    let born = Counters(start: c.start, energy: 0, cpu: 0, rd: 0, wr: 0, childCPU: 0)
                    let prev = counters[pid] ?? (dt > 0 && start >= prevWall ? born : nil)
                    if dt > 0, let p = prev, p.start == c.start,
                       c.energy >= p.energy, c.cpu >= p.cpu, c.rd >= p.rd, c.wr >= p.wr {
                        e.energyJ = Double(c.energy - p.energy) / 1e9
                        e.cpuSec = Double(c.cpu - p.cpu) * ticksToNs / 1e9
                        e.readBytes = Double(c.rd - p.rd)
                        e.writeBytes = Double(c.wr - p.wr)
                    }
                }
            }
            next[pid] = e
        }
        // Short-lived children: when a child exits, its parent's "reaped children" CPU counter grows by the
        // child's whole lifetime CPU. Credit the parent with the part we never saw while the child was alive
        // (children that vanished this interval are matched to the parent PID recorded when last seen).
        if dt > 0 {
            var alreadySeen: [Int32: UInt64] = [:]
            for (pid, c) in counters where nextCounters[pid]?.start != c.start {
                if let old = entries[pid] { alreadySeen[old.ppid, default: 0] &+= c.cpu &+ c.childCPU }
            }
            for (pid, c) in nextCounters {
                guard var e = next[pid] else { continue }
                let prev = counters[pid].flatMap { $0.start == c.start ? $0.childCPU : nil } ?? (e.start >= prevWall ? 0 : nil)
                guard let p = prev, c.childCPU > p else { continue }
                let delta = c.childCPU - p
                let seen = alreadySeen[pid] ?? 0
                if delta > seen {
                    e.childCPUSec = Double(delta - seen) * ticksToNs / 1e9
                    next[pid] = e
                }
            }
        }
        entries = next
        counters = nextCounters
        if meta.count > entries.count + 64 { meta = meta.filter { entries[$0.key] != nil } }
    }

    // MARK: Lazily cached per-process metadata

    func meta(_ pid: Int32) -> Meta? {
        guard let e = entries[pid] else { return nil }
        if let m = meta[pid], m.start == e.start { return m }
        let path = Self.path(of: pid)
        let name = path.map(Self.displayName(forExecutable:)) ?? e.comm
        var bundle: String?
        if let p = path, let r = p.range(of: ".app/") { bundle = String(p[..<r.lowerBound]) + ".app" }
        let m = Meta(start: e.start, path: path, name: name, bundle: bundle)
        meta[pid] = m
        return m
    }

    func args(_ pid: Int32) -> [String]? {
        guard var m = meta(pid) else { return nil }
        if m.argsLoaded { return m.args }
        m.args = readArgs(pid)
        m.argsLoaded = true
        meta[pid] = m
        return m.args
    }

    func responsibleBundle(_ pid: Int32) -> String? {
        guard var m = meta(pid) else { return nil }
        if let cached = m.responsibleBundle { return cached }
        var result: String?
        if let rp = responsibleFor?(pid), rp > 0, rp != pid, let rpath = Self.path(of: rp),
           let r = rpath.range(of: ".app/") {
            result = String(rpath[..<r.lowerBound]) + ".app"
        }
        m.responsibleBundle = .some(result)
        meta[pid] = m
        return result
    }

    func commandLine(_ pid: Int32) -> String? {
        guard let a = args(pid), !a.isEmpty else { return nil }
        return a.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }

    func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    func rssMB(_ pid: Int32) -> Double? {
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { return nil }
        return Double(ti.pti_resident_size) / 1_048_576
    }

    private func readArgs(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = argBuf.count
        guard sysctl(&mib, 3, &argBuf, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = argBuf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size && argBuf[i] != 0 { i += 1 }        // exec path
        while i < size && argBuf[i] == 0 { i += 1 }        // padding
        var out: [String] = []
        while out.count < argc && i < size {
            var j = i
            while j < size && argBuf[j] != 0 { j += 1 }
            out.append(String(decoding: argBuf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : nil
    }

    /// "/Users/x/.local/share/claude/versions/2.1.3" -> "claude"; "/usr/bin/python3" -> "python3"
    static func displayName(forExecutable path: String) -> String {
        let skip: Set<String> = ["versions", "bin", "sbin", "libexec", "MacOS", "Current", "current", "lib"]
        let parts = path.split(separator: "/").map(String.init)
        for part in parts.reversed() {
            if let f = part.first, f.isNumber { continue }
            if skip.contains(part) { continue }
            return part
        }
        return parts.last ?? path
    }
}

// MARK: - Other users' processes (root daemons, Spotlight, WindowServer…)

/// Our own rusage can't read other users' processes; /bin/ps is setuid and can. Sampled every 15–60 s,
/// off the engine queue, and used only to break the "system" row down by name.
final class ForeignCPUSampler {
    private var last: [Int32: (cpu: Double, name: String)] = [:]
    private var lastAt: Date?

    /// name → CPU % (100 = one core) over the interval since the previous call, plus pids per name.
    func sample() -> (cpu: [String: Double], pids: [String: [Int32]])? {
        guard let out = SystemSensors.run("/bin/ps", ["-A", "-o", "pid=,time=,comm="]) else { return nil }
        let now = Date()
        var cur: [Int32: (cpu: Double, name: String)] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            cur[pid] = (Self.seconds(String(parts[1])), Self.friendly(String(parts[2])))
        }
        defer { last = cur; lastAt = now }
        guard let at = lastAt, now.timeIntervalSince(at) > 1 else { return nil }
        let dt = now.timeIntervalSince(at)
        var cpu: [String: Double] = [:], pids: [String: [Int32]] = [:]
        for (pid, c) in cur {
            pids[c.name, default: []].append(pid)
            guard let p = last[pid], c.cpu >= p.cpu else { continue }
            cpu[c.name, default: 0] += (c.cpu - p.cpu) / dt * 100
        }
        return (cpu, pids)
    }

    /// "1:02.35", "12:01:02.35" or "1-02:03:04" → seconds
    static func seconds(_ s: String) -> Double {
        var days = 0.0, rest = Substring(s)
        if let dash = s.firstIndex(of: "-") { days = Double(s[..<dash]) ?? 0; rest = s[s.index(after: dash)...] }
        var total = 0.0
        for comp in rest.split(separator: ":") { total = total * 60 + (Double(comp) ?? 0) }
        return days * 86400 + total
    }

    static let names: [String: String] = [
        "mdworker_shared": "Spotlight indexing", "mdworker": "Spotlight indexing", "mds": "Spotlight indexing",
        "mds_stores": "Spotlight indexing", "mdbulkimport": "Spotlight indexing", "corespotlightd": "Spotlight indexing",
        "kernel_task": "macOS kernel", "WindowServer": "WindowServer (graphics)", "backupd": "Time Machine",
        "backupd-helper": "Time Machine", "softwareupdated": "Software Update", "apfsd": "APFS file system",
        "fseventsd": "File system events", "coreaudiod": "Core Audio", "launchd": "launchd",
        "syspolicyd": "Gatekeeper (syspolicyd)", "XprotectService": "XProtect malware scan", "photoanalysisd": "Photos analysis",
    ]
    static func friendly(_ comm: String) -> String {
        let base = (comm as NSString).lastPathComponent
        return names[base] ?? base
    }
}

// MARK: - Grouping

/// A registered job's process tree root (from the job registry).
struct RegisteredRoot {
    let job: String
    let group: String
    let pid: Int32
}

struct GroupingInput {
    var cpuPackageW: Double?       // measured CPU package power (IOReport)
    var busyCores: Double          // all processes, from per-core ticks
    var registered: [RegisteredRoot]
    var paused: [String: String]   // group id / name → note
    var config: Config
    var foreignCPU: [String: Double] = [:]   // other users' processes by friendly name → CPU % (from ps)
}

struct GroupingResult {
    var groups: [GroupInfo]                 // sorted by watts, every process assigned (processes NOT filled in)
    var members: [String: [Int32]]          // group id → pids
    var procWatts: [Int32: Double]
    var procCPU: [Int32: Double]
    var childWatts: [Int32: Double] = [:]   // exited short-lived children, credited to their parent
    var childCPU: [Int32: Double] = [:]
    var unattributedW: Double               // CPU power of processes we can't read (root daemons)
    var unattributedCPU: Double
    var readableCPUW: Double
    var selfCPU: Double
    var selfW: Double
    var selfMem: Double
}

enum Grouper {
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "xonsh"]
    static let wrappers: Set<String> = ["login", "sudo", "nohup", "caffeinate", "env", "time", "nice", "timeout",
                                        "gtimeout", "tmux", "screen", "sshd", "sshd-session", "script", "stdbuf",
                                        "unbuffer", "forkcast", "launchctl"]
    static let interpreters: [String] = ["python", "node", "ruby", "perl", "php", "Rscript", "deno", "bun", "lua", "julia", "swift"]

    /// Shells running a script are jobs; interactive / `-c` shells are transparent containers.
    static func isContainer(_ pid: Int32, _ t: ProcessTable, cfg: Config) -> Bool {
        if pid <= 1 { return true }
        guard let m = t.meta(pid) else { return true }
        let n = m.name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if m.bundle != nil { return true }                      // apps (Terminal, VS Code, Claude…) host jobs
        if wrappers.contains(n) { return true }
        if cfg.containerNames.contains(n) { return true }       // agent CLIs etc.
        if shells.contains(n) {
            guard let a = t.args(pid) else { return true }
            let rest = a.dropFirst()
            if rest.contains(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }) { return true }
            return !rest.contains(where: { !$0.hasPrefix("-") })   // no script argument → interactive
        }
        return false
    }

    static func group(_ t: ProcessTable, _ input: GroupingInput, cache: GroupCache) -> GroupingResult {
        // Assignments survive across ticks; recompute everything when registrations or rules change.
        let sig = input.registered.map { "\($0.job)=\($0.pid)" }.sorted().joined(separator: ",")
            + "|\(input.config.labelRules.count)|\(input.config.containerNames)|\(input.config.terminalApps)"
        if sig != cache.signature { cache.reset(); cache.signature = sig }
        if cache.assign.count > t.entries.count + 300 {
            cache.assign = cache.assign.filter { t.entries[$0.key]?.start == $0.value.start }
            let live = Set(cache.assign.values.map(\.gid))
            cache.templates = cache.templates.filter { live.contains($0.key) }
        }
        let cfg = input.config
        let dt = t.seconds
        var res = GroupingResult(groups: [], members: [:], procWatts: [:], procCPU: [:], unattributedW: 0,
                                 unattributedCPU: 0, readableCPUW: 0, selfCPU: 0, selfW: 0, selfMem: 0)

        // Power attribution: readable processes get (their CPU time share of all busy CPU) × package power,
        // split among them by their energy counters. The rest is "macOS system processes".
        var readableCPUsec = 0.0, rawEnergy = 0.0, childCPUsec = 0.0
        for e in t.entries.values where e.readable { readableCPUsec += e.cpuSec; rawEnergy += e.energyJ; childCPUsec += e.childCPUSec }
        let accountedSec = readableCPUsec + childCPUsec
        let busySec = max(input.busyCores * dt, accountedSec)
        let readableShare = busySec > 0 ? accountedSec / busySec : 1
        // Exited children have no energy counter: estimate it at the average energy per CPU-second this interval.
        let jPerCPUsec = readableCPUsec > 0 ? rawEnergy / readableCPUsec : 0
        let totalRaw = rawEnergy + childCPUsec * jPerCPUsec
        let pkgW = input.cpuPackageW
        let readableW: Double = pkgW.map { $0 * readableShare } ?? (dt > 0 ? rawEnergy / dt : 0)
        res.readableCPUW = readableW
        res.unattributedW = pkgW.map { max(0, $0 - readableW) } ?? 0
        res.unattributedCPU = dt > 0 ? max(0, busySec - accountedSec) / dt * 100 : 0
        for e in t.entries.values where e.readable && dt > 0 {
            let share = totalRaw > 0 ? e.energyJ / totalRaw : (accountedSec > 0 ? e.cpuSec / accountedSec : 0)
            res.procWatts[e.pid] = readableW * share
            res.procCPU[e.pid] = e.cpuSec / dt * 100
            if e.childCPUSec > 0 {
                let cshare = totalRaw > 0 ? e.childCPUSec * jPerCPUsec / totalRaw : e.childCPUSec / max(accountedSec, 1e-9)
                res.childWatts[e.pid] = readableW * cshare
                res.childCPU[e.pid] = e.childCPUSec / dt * 100
            }
        }
        if let s = t.entries[t.selfPid] {
            res.selfCPU = res.procCPU[s.pid] ?? 0
            res.selfW = res.procWatts[s.pid] ?? 0
            res.selfMem = s.memMB
        }

        // Registered job membership: root pid and all its descendants.
        var regByPid: [Int32: RegisteredRoot] = [:]
        for r in input.registered where t.entries[r.pid] != nil { regByPid[r.pid] = r }

        var groups: [String: GroupInfo] = [:]
        var assignCache: [Int32: String] = [:]

        func registeredAncestor(_ pid: Int32) -> RegisteredRoot? {
            var p = pid
            var hops = 0
            while p > 1, hops < 64 {
                if let r = regByPid[p] { return r }
                guard let e = t.entries[p] else { return nil }
                p = e.ppid
                hops += 1
            }
            return nil
        }

        /// A bundle process is an app (or an app's helper) when launchd or another app process started it;
        /// when a script / CLI started it (e.g. a headless renderer inside a .app), it belongs to that job.
        func launchedAsApp(_ e: ProcessTable.Entry) -> Bool {
            if e.ppid <= 1 { return true }
            guard let pm = t.meta(e.ppid) else { return true }
            return pm.bundle != nil
        }

        func groupID(for pid: Int32) -> String {
            if let g = assignCache[pid] { return g }
            let gid: String
            guard let e = t.entries[pid], let m = t.meta(pid) else { return "sys:unknown" }
            if let c = cache.assign[pid], c.start == e.start, let tpl = cache.templates[c.gid] {
                if groups[c.gid] == nil { groups[c.gid] = tpl }
                assignCache[pid] = c.gid
                return c.gid
            }
            if let r = registeredAncestor(pid) {
                gid = "job:" + r.job
                if groups[gid] == nil {
                    var g = GroupInfo(id: gid, label: r.job, kind: "registered", kindKey: "reg:" + r.group)
                    g.jobName = r.job
                    g.registeredGroup = r.group
                    g.rootPid = r.pid
                    groups[gid] = g
                }
            } else if !e.readable || e.uid != t.myUid && e.uid == 0 {
                gid = "sys:root"
                if groups[gid] == nil {
                    groups[gid] = GroupInfo(id: gid, label: "Kernel, system & short-lived processes", kind: "system", kindKey: "sys")
                }
            } else if let bundle = m.bundle, launchedAsApp(e) {
                let app = t.responsibleBundle(pid).flatMap { cfg.terminalApps.contains(appName($0)) ? nil : $0 } ?? bundle
                gid = "app:" + appName(app)
                if groups[gid] == nil {
                    var g = GroupInfo(id: gid, label: appName(app), kind: "app", kindKey: "app:" + appName(app))
                    g.iconPath = app
                    groups[gid] = g
                }
            } else if m.bundle == nil, isContainer(pid, t, cfg: cfg) {
                // Idle shells & wrappers: count toward the app hosting them (e.g. Terminal).
                let host = t.responsibleBundle(pid).map(appName) ?? m.name
                gid = "app:" + host
                if groups[gid] == nil {
                    var g = GroupInfo(id: gid, label: host, kind: "app", kindKey: "app:" + host)
                    g.iconPath = t.responsibleBundle(pid)
                    groups[gid] = g
                }
            } else {
                // Walk up to the job root: the highest ancestor whose parent is a container.
                var root = pid
                var hops = 0
                while hops < 64, let re = t.entries[root], re.ppid > 1, !isContainer(re.ppid, t, cfg: cfg) {
                    root = re.ppid
                    hops += 1
                }
                let rootEntry = t.entries[root] ?? e
                let rootMeta = t.meta(root) ?? m
                let isDaemon = rootEntry.ppid <= 1 && (rootMeta.path.map(isSystemPath) ?? true)
                if isDaemon {
                    gid = "app:" + rootMeta.name
                    if groups[gid] == nil {
                        groups[gid] = GroupInfo(id: gid, label: rootMeta.name, kind: "app", kindKey: "app:" + rootMeta.name)
                    }
                } else {
                    gid = "auto:\(root):\(Int(rootEntry.start))"
                    if groups[gid] == nil {
                        let args = t.args(root) ?? [rootMeta.name]
                        let (label, kind) = Labeler.label(exe: rootMeta.name, args: args, rules: cfg.labelRules)
                        var g = GroupInfo(id: gid, label: label, kind: "job", kindKey: kind)
                        g.rootPid = root
                        g.command = t.commandLine(root)
                        g.startTime = Date(timeIntervalSince1970: rootEntry.start)
                        groups[gid] = g
                    }
                }
            }
            assignCache[pid] = gid
            cache.assign[pid] = (e.start, gid)
            if cache.templates[gid] == nil, let g = groups[gid] { cache.templates[gid] = g }
            return gid
        }

        // Accumulate numbers separately (copying GroupInfo per process is expensive).
        struct Acc { var w = 0.0, cpu = 0.0, mem = 0.0, rd = 0.0, wr = 0.0, n = 0 }
        var acc: [String: Acc] = [:]
        acc.reserveCapacity(256)
        for e in t.entries.values where e.pid > 0 {
            let gid = groupID(for: e.pid)
            var a = acc[gid] ?? Acc()
            a.w += (res.procWatts[e.pid] ?? 0) + (res.childWatts[e.pid] ?? 0)
            a.cpu += (res.procCPU[e.pid] ?? 0) + (res.childCPU[e.pid] ?? 0)
            a.mem += e.memMB
            if dt > 0 { a.rd += e.readBytes / dt / 1e6; a.wr += e.writeBytes / dt / 1e6 }
            a.n += 1
            acc[gid] = a
            res.members[gid, default: []].append(e.pid)
        }
        for (gid, a) in acc {
            guard var g = groups[gid] else { continue }
            g.watts = a.w; g.cpuPct = a.cpu; g.memMB = a.mem
            g.diskReadMBs = a.rd; g.diskWriteMBs = a.wr; g.procCount = a.n
            groups[gid] = g
        }
        // Root daemons' CPU power can't be read per process: show it on the system row…
        if var sys = groups["sys:root"] {
            sys.watts += res.unattributedW
            sys.cpuPct += res.unattributedCPU
            // …broken down by name where `ps` could measure it (e.g. Spotlight indexing your output files).
            let totalCPU = sys.cpuPct, totalW = sys.watts
            var remainingCPU = totalCPU
            let otherUsers = Set(t.entries.values.filter { !$0.readable }.map { ForeignCPUSampler.friendly(t.meta($0.pid)?.name ?? $0.comm) })
            for (name, pct) in input.foreignCPU.sorted(by: { $0.value > $1.value })
            where pct >= 2 && remainingCPU > 1 && otherUsers.contains(name) {
                let c = min(pct, remainingCPU)
                var g = GroupInfo(id: "sys:" + name, label: name, kind: "system", kindKey: "sys:" + name)
                g.cpuPct = c
                g.watts = totalCPU > 0 ? totalW * c / totalCPU : 0
                g.command = "measured with /bin/ps (another user's process: CPU only; power is its share of the system row)"
                let pids = t.entries.values.filter { !$0.readable && ForeignCPUSampler.friendly(t.meta($0.pid)?.name ?? $0.comm) == name }.map(\.pid)
                g.procCount = max(pids.count, 1)
                groups[g.id] = g
                res.members[g.id] = pids
                remainingCPU -= c
                sys.cpuPct -= c
                sys.watts -= g.watts
                sys.procCount -= pids.count
                res.members["sys:root"]?.removeAll { pids.contains($0) }
            }
            groups["sys:root"] = sys
        }
        for (id, var g) in groups {
            let members = res.members[id] ?? []
            g.paused = !members.isEmpty && members.allSatisfy { t.entries[$0]?.stopped ?? false }
            g.pausedNote = input.paused[id] ?? g.jobName.flatMap { input.paused["job:" + $0] }
                ?? g.registeredGroup.flatMap { input.paused["reg:" + $0] }
            groups[id] = g
        }
        res.groups = groups.values.sorted { ($0.watts, $0.cpuPct) > ($1.watts, $1.cpuPct) }
        return res
    }

    /// Fills in per-process detail for a group (only done for displayed / requested groups).
    static func details(_ g: inout GroupInfo, pids: [Int32], _ t: ProcessTable, _ r: GroupingResult, limit: Int = 400) {
        let dt = t.seconds
        var procs: [ProcInfo] = []
        for pid in pids {
            guard let e = t.entries[pid] else { continue }
            var p = ProcInfo(pid: pid, ppid: e.ppid, name: t.meta(pid)?.name ?? e.comm)
            p.watts = r.procWatts[pid] ?? 0
            p.cpuPct = r.procCPU[pid] ?? 0
            p.exitedChildrenCPUPct = r.childCPU[pid] ?? 0
            p.exitedChildrenWatts = r.childWatts[pid] ?? 0
            p.memMB = e.memMB
            p.stopped = e.stopped
            if dt > 0 { p.diskReadMBs = e.readBytes / dt / 1e6; p.diskWriteMBs = e.writeBytes / dt / 1e6 }
            p.startTime = Date(timeIntervalSince1970: e.start)
            procs.append(p)
        }
        procs.sort { ($0.watts + $0.exitedChildrenWatts, $0.cpuPct + $0.exitedChildrenCPUPct, $0.memMB)
            > ($1.watts + $1.exitedChildrenWatts, $1.cpuPct + $1.exitedChildrenCPUPct, $1.memMB) }
        if procs.count > limit { procs = Array(procs.prefix(limit)) }
        // Expensive extras only for the processes we return.
        for i in procs.indices {
            procs[i].command = t.commandLine(procs[i].pid)
            procs[i].rssMB = t.rssMB(procs[i].pid)
            if i < 40 { procs[i].cwd = t.cwd(procs[i].pid) }
        }
        g.processes = procs
        if let root = g.rootPid {
            g.command = g.command ?? t.commandLine(root)
            g.cwd = t.cwd(root)
            g.parentChain = parentChain(root, t)
            if let e = t.entries[root] { g.startTime = Date(timeIntervalSince1970: e.start) }
        }
    }

    static func parentChain(_ pid: Int32, _ t: ProcessTable) -> [String] {
        var out: [String] = []
        var p = pid
        var hops = 0
        while let e = t.entries[p], hops < 32 {
            out.append("\(t.meta(p)?.name ?? e.comm) (\(p))")
            if e.ppid <= 0 || e.ppid == p { break }
            p = e.ppid
            hops += 1
        }
        return out
    }

    /// group_by=tree: nested process tree (top-level = children of launchd).
    static func tree(_ t: ProcessTable, _ r: GroupingResult) -> [GroupInfo] {
        var kids: [Int32: [Int32]] = [:]
        for e in t.entries.values where e.pid > 1 { kids[e.ppid, default: []].append(e.pid) }
        func node(_ pid: Int32, depth: Int) -> GroupInfo {
            let e = t.entries[pid]!
            let name = t.meta(pid)?.name ?? e.comm
            var g = GroupInfo(id: "pid:\(pid)", label: name, kind: "process", kindKey: name)
            g.rootPid = pid
            g.command = depth < 6 ? t.commandLine(pid) : nil
            g.watts = (r.procWatts[pid] ?? 0) + (r.childWatts[pid] ?? 0)
            g.cpuPct = (r.procCPU[pid] ?? 0) + (r.childCPU[pid] ?? 0)
            g.memMB = e.memMB
            g.procCount = 1
            g.paused = e.stopped
            if depth < 30 {
                let ch = (kids[pid] ?? []).map { node($0, depth: depth + 1) }
                for c in ch {
                    g.watts += c.watts; g.cpuPct += c.cpuPct; g.memMB += c.memMB; g.procCount += c.procCount
                }
                g.children = ch.sorted { $0.watts > $1.watts }
            }
            return g
        }
        return (kids[1] ?? []).map { node($0, depth: 0) }.sorted { $0.watts > $1.watts }
    }

    /// group_by=app: the classic Activity-Monitor style grouping (helpers folded into their app).
    static func byApp(_ t: ProcessTable, _ r: GroupingResult) -> [GroupInfo] {
        var groups: [String: GroupInfo] = [:]
        for e in t.entries.values where e.pid > 0 {
            let m = t.meta(e.pid)
            let bundle = t.responsibleBundle(e.pid) ?? m?.bundle
            let name = bundle.map(appName) ?? (e.readable ? (m?.name ?? e.comm) : "macOS system processes")
            var g = groups[name] ?? GroupInfo(id: "app:" + name, label: name, kind: "app", kindKey: "app:" + name)
            g.iconPath = bundle
            g.watts += (r.procWatts[e.pid] ?? 0) + (r.childWatts[e.pid] ?? 0)
            g.cpuPct += (r.procCPU[e.pid] ?? 0) + (r.childCPU[e.pid] ?? 0)
            g.memMB += e.memMB
            g.procCount += 1
            groups[name] = g
        }
        return groups.values.sorted { $0.watts > $1.watts }
    }

    static func appName(_ bundle: String) -> String {
        ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static func isSystemPath(_ p: String) -> Bool {
        p.hasPrefix("/System/") || p.hasPrefix("/usr/libexec/") || p.hasPrefix("/usr/sbin/")
            || p.hasPrefix("/Library/Apple/") || p.hasPrefix("/sbin/")
    }
}

// MARK: - Labels from command lines

struct LabelRule: Codable {
    struct Match: Codable {
        var exe: String?          // glob, e.g. "python3*"
        var arg_regex: String?    // matched against the arguments joined by spaces
    }
    var match: Match
    var label: String             // template: {0} = whole match, {1}… = capture groups, {exe}
    var kind: String?             // optional template for the "kind" (instances of the same kind of job)
}

/// Group assignments and group templates kept between ticks (grouping is the most expensive part of a tick).
final class GroupCache {
    var assign: [Int32: (start: Double, gid: String)] = [:]
    var templates: [String: GroupInfo] = [:]
    var signature = ""
    func reset() { assign.removeAll(); templates.removeAll() }
}

enum Labeler {
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let regexLock = NSLock()
    static func regex(_ p: String) -> NSRegularExpression? {
        regexLock.lock(); defer { regexLock.unlock() }
        if let r = regexCache[p] { return r }
        let r = try? NSRegularExpression(pattern: p)
        regexCache[p] = r
        return r
    }

    static func label(exe: String, args: [String], rules: [LabelRule]) -> (String, String) {
        let argv0 = args.first.map { ($0 as NSString).lastPathComponent } ?? exe
        let rest = Array(args.dropFirst())
        let joined = rest.joined(separator: " ")
        for r in rules {
            if let g = r.match.exe, fnmatch(g, exe, 0) != 0, fnmatch(g, argv0, 0) != 0 { continue }
            var groups: [String] = [joined]
            if let pat = r.match.arg_regex {
                guard let re = regex(pat),
                      let m = re.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)) else { continue }
                groups = (0..<m.numberOfRanges).map { i in
                    Range(m.range(at: i), in: joined).map { String(joined[$0]) } ?? ""
                }
            }
            func fill(_ tpl: String) -> String {
                var s = tpl.replacingOccurrences(of: "{exe}", with: exe)
                for (i, v) in groups.enumerated() { s = s.replacingOccurrences(of: "{\(i)}", with: v) }
                return s
            }
            let l = fill(r.label)
            return (l, r.kind.map(fill) ?? l)
        }
        return heuristic(exe: exe, argv0: argv0, rest: rest)
    }

    static func short(_ s: String) -> String {
        var b = (s as NSString).lastPathComponent
        for ext in [".vst3", ".component", ".app", ".wav", ".aiff", ".flac", ".json", ".txt", ".yaml", ".csv"]
            where b.lowercased().hasSuffix(ext) { b = String(b.dropLast(ext.count)) }
        return b.count > 28 ? String(b.prefix(27)) + "…" : b
    }

    /// Positional arguments, skipping flags and their values (a flag followed by a non-flag word).
    static func positionals(_ rest: [String], valueFlags: Set<String> = []) -> [String] {
        var out: [String] = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a.hasPrefix("-") {
                if valueFlags.contains(a) { i += 2; continue }
                if !a.contains("="), a.hasPrefix("--"), i + 1 < rest.count, !rest[i + 1].hasPrefix("-"),
                   !rest[i + 1].contains("/") && !rest[i + 1].contains(".") { i += 2; continue }
                i += 1
                continue
            }
            out.append(a)
            i += 1
        }
        return out
    }

    static func heuristic(exe: String, argv0: String, rest: [String]) -> (String, String) {
        let lower = exe.lowercased()
        if lower == "java" {
            let all = rest.joined(separator: " ").lowercased()
            let tool = all.contains("ghidra") ? "java (Ghidra)" : "java"
            var main: String?
            if let j = rest.firstIndex(of: "-jar"), j + 1 < rest.count { main = short(rest[j + 1]) }
            let pos = positionals(rest, valueFlags: ["-cp", "-classpath", "--class-path", "-jar", "-Xss", "-p"])
            if main == nil { main = pos.first.map { $0.split(separator: ".").last.map(String.init) ?? $0 } }
            let extra = pos.dropFirst().first.map(short)
            let label = [tool, tool == "java" ? main : extra ?? main].compactMap { $0 }.joined(separator: " · ")
            return (label, tool)
        }
        let isInterp = Grouper.shells.contains(lower) || Grouper.interpreters.contains { lower.hasPrefix($0.lowercased()) }
        if isInterp {
            let pos = positionals(rest, valueFlags: ["-m", "-c", "-W", "-X", "-e", "-r", "--require"])
            var script: String?
            if let mi = rest.firstIndex(of: "-m"), mi + 1 < rest.count { script = "-m " + rest[mi + 1] }
            else if rest.contains("-c") || rest.contains("-e") { script = "(inline)" }
            else { script = pos.first.map { ($0 as NSString).lastPathComponent } }
            let args = (script?.hasPrefix("-m") == true || script == "(inline)" ? pos : Array(pos.dropFirst()))
                .prefix(2).map(short)
            let label = ([exe, script].compactMap { $0 } + args).joined(separator: " ")
            return (label, [exe, script].compactMap { $0 }.joined(separator: " "))
        }
        let pos = positionals(rest)
        if let first = pos.first {
            return ("\(exe) · \(short(first))", exe)
        }
        return (exe, exe)
    }
}
