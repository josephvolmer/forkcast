import AppKit
import Foundation
import ForkcastCore

/// What the UI gets each tick.
struct UISnapshot {
    var status: Status
    var groups: [GroupInfo]          // all groups, sorted by power; expanded ones carry processes
    var unattributedW: Double
    var events: [EventInfo]          // recent timeline
    var guards: [GuardRule]
    var configError: String?
    var staleMinutes: Double = 15
}

struct PauseRecord: Codable {
    var name: String
    var since: Date
    var by: String
    var pids: [Int32]
    var note: String {
        "paused since \(DateFormatter.localizedString(from: since, dateStyle: .none, timeStyle: .short)) (\(by))"
    }
}

/// Runs all sampling and logic on one utility-QoS queue. API and UI read the latest results.
final class Engine {
    let queue = DispatchQueue(label: "forkcast.engine", qos: .utility)
    private let table = ProcessTable()
    private let energy = EnergyModel()
    private let battery = BatterySensor()
    private let sensors = SystemSensors()
    let configStore = ConfigStore()
    let store = Store()
    private(set) lazy var jobs = JobRegistry(store: store)
    private let alerts = AlertEngine()
    private let guards = GuardEngine()
    private lazy var headroom = HeadroomTracker(store: store)
    private let crashes = CrashWatcher()

    private var timer: DispatchSourceTimer?
    private var interval = 10.0
    private var visible = false
    private var expanded = Set<String>()
    private var lastResult: GroupingResult?
    private var lastGroups: [String: GroupInfo] = [:]
    private var paused: [String: PauseRecord] = [:]   // key: lowercased target name

    // Latest results (read from any thread under the lock).
    private let lock = NSLock()
    private var _status = Status()
    var latestStatus: Status { lock.lock(); defer { lock.unlock() }; return _status }

    var onSnapshot: ((UISnapshot) -> Void)?

    // Per-minute metric accumulation.
    private var minute: Int64 = -1
    private var sums: [Metric: Double] = [:]
    private var counts: [Metric: Double] = [:]
    private var usage: [Bool: [String: (path: String?, energy: Double, cpu: Double)]] = [:]
    private var lastPrune = Date.distantPast
    private var todayKey = ""
    private var todayDownMB = 0.0
    private var todayUpMB = 0.0
    private var trendsAt = Date.distantPast
    private var diskTrend: Double?
    private var diskStep: DiskStep?
    private var diskSeriesStart: Int64 = 0           // first minute where disk_free_gb means "free now" (statvfs)
    private var diskSamples: [(t: Date, free: Double, purgeable: Double, snapshots: Int?)] = []   // one per minute, 90 min
    private var swapTrend: Double?
    private var netTop: (String, Double)?
    private var netTopAt = Date.distantPast
    private var apiDemandAt = Date.distantPast
    private var folders: [FolderInfo] = []
    private var foldersAt = Date.distantPast
    private var recentEvents: [EventInfo] = []
    private var lastEnergy: EnergyModel.Reading?
    private var windowsCheckedAt = Date.distantPast
    private let groupCache = GroupCache()
    private var configCheckedAt = Date.distantPast
    private var netTopRunning = false
    private let foreign = ForeignCPUSampler()
    private var foreignCPU: [String: Double] = [:]
    private var foreignAt = Date.distantPast
    private var foreignRunning = false

    // Long-polling waits.
    private struct Waiter { let id: UUID; let expr: Expr; let deadline: Date; let started: Date; let notBefore: Date; let done: (WaitResult) -> Void }
    private var waiters: [Waiter] = []
    private var waitTimer: DispatchSourceTimer?

    init() {
        if let v = store.get("diskSeriesV2Start").flatMap(Int64.init) { diskSeriesStart = v }
        else {
            diskSeriesStart = Int64(Date().timeIntervalSince1970 / 60) + 1
            store.set("diskSeriesV2Start", String(diskSeriesStart))
        }
        if let s = store.get("paused"), let d = try? JSON.decoder.decode([String: PauseRecord].self, from: Data(s.utf8)) { paused = d }
    }

    // MARK: Lifecycle

    func start() {
        queue.async {
            self.interval = self.configStore.config.sampling.backgroundSeconds
            self.recordBoot()
            self.loadToday()
            self.recentEvents = self.store.events(since: Date().addingTimeInterval(-7 * 86400), limit: 200)
            self.crashes.onReport = { [weak self] r in self?.crashReport(r) }
            self.crashes.start(queue: self.queue)
            // Priming sample: rates need two samples, so publish nothing until a real interval has passed.
            self.table.sample()
            _ = self.sensors.cpu()
            self.lastEnergy = self.energy.read()
            _ = self.sensors.network()
            _ = self.sensors.disk(floorGB: self.configStore.config.diskFloorGB)
            self.queue.asyncAfter(deadline: .now() + 1) { self.tick(); self.schedule() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.event("system.sleep", nil, "Mac went to sleep"); self?.flushMinute() }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.event("system.wake", nil, "Mac woke up"); self?.tick() }
        }
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.tick() }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.tick() }
        }
    }

    func shutdown() {
        queue.sync {
            event("monitor.stopped", nil, "Forkcast quit")
            flushMinute()
        }
    }

    private func recordBoot() {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        let boot = Double(tv.tv_sec)
        let last = Double(store.get("bootTime") ?? "") ?? 0
        if abs(boot - last) > 5 {
            if last > 0, let lm = store.lastMinute(), Double(lm * 60) < boot {
                store.addEvent(type: "system.shutdown", subject: nil, message: "Mac shut down or lost power (last data before boot)",
                               at: Date(timeIntervalSince1970: Double(lm * 60 + 60)))
            }
            store.addEvent(type: "system.boot", subject: nil, message: "Mac started", at: Date(timeIntervalSince1970: boot))
            store.set("bootTime", String(boot))
        }
        store.addEvent(type: "monitor.started", subject: nil, message: "Forkcast started")
    }

    private func loadToday() {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        todayKey = String(Int((midnight.timeIntervalSince1970 + 3600 + Double(TimeZone.current.secondsFromGMT(for: midnight))) / 86400))
        let from = Int64(midnight.timeIntervalSince1970 / 60)
        let to = Int64(Date().timeIntervalSince1970 / 60)
        todayDownMB = store.total(.net_down_mb, fromMinute: from, toMinute: to)
        todayUpMB = store.total(.net_up_mb, fromMinute: from, toMinute: to)
    }

    func setVisible(_ v: Bool, expanded e: Set<String>) {
        queue.async {
            let changed = v != self.visible
            self.visible = v
            self.expanded = e
            if changed {
                self.reschedule()
                if v { self.tick() }
            }
        }
    }

    func setExpanded(_ e: Set<String>) { queue.async { self.expanded = e; if self.visible { self.publishUI() } } }

    private var desiredInterval: Double {
        let c = configStore.config.sampling
        var i = visible ? c.visibleSeconds : c.backgroundSeconds
        if !waiters.isEmpty { i = min(i, 5) }
        return max(0.5, i)
    }

    private func reschedule() {
        let d = desiredInterval
        if d != interval || timer == nil { interval = d; schedule() }
    }

    private func schedule() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets macOS coalesce our wakeups with others.
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(interval * 200)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: The tick

    private var lastPublished: UISnapshot?
    private var lastStatusForUI: Status?

    private func tick() {
        let now = Date()
        if now.timeIntervalSince(configCheckedAt) >= 5 {
            configCheckedAt = now
            if configStore.reloadIfChanged() { reschedule() }
        }
        let cfg = configStore.config

        table.sample()
        var cpu = sensors.cpu()
        if let e = energy.read() { lastEnergy = e }
        var power = PowerInfo()
        battery.read(into: &power)
        if let e = lastEnergy, e.seconds > 0 {
            power.cpuW = e.cpuJ / e.seconds
            power.gpuW = e.gpuJ / e.seconds
            power.aneW = e.aneJ / e.seconds
            power.socW = e.socJ / e.seconds
            if let d = power.drawW {
                power.otherW = max(0, d - (power.cpuW ?? 0) - (power.gpuW ?? 0) - (power.aneW ?? 0) - (power.socW ?? 0))
            }
        }

        // Other users' processes (Spotlight, kernel, WindowServer…) via setuid ps: every 15 s while
        // someone is looking, every 60 s otherwise; off the engine queue.
        if !foreignRunning, now.timeIntervalSince(foreignAt) >= (visible || now.timeIntervalSince(apiDemandAt) < 120 ? 15 : 60) {
            foreignAt = now
            foreignRunning = true
            let f = foreign
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let r = f.sample()
                self?.queue.async {
                    if let r { self?.foreignCPU = r.cpu }
                    self?.foreignRunning = false
                }
            }
        }
        let pausedNotes = pausedNotesByGroup()
        let result = Grouper.group(table, GroupingInput(cpuPackageW: power.cpuW, busyCores: cpu.busyCores,
                                                        registered: jobs.roots, paused: pausedNotes, config: cfg,
                                                        foreignCPU: foreignCPU),
                                   cache: groupCache)
        lastResult = result
        var groupMap: [String: GroupInfo] = [:]
        for g in result.groups { groupMap[g.id] = g }
        lastGroups = groupMap

        // Jobs.
        for e in jobs.update(table: table, groups: groupMap, members: result.members,
                             staleMinutes: cfg.alerts.jobStaleMinutes, now: now) {
            jobEvent(e)
        }

        // Sensors.
        var mem = sensors.memory()
        var disk = sensors.disk(floorGB: cfg.diskFloorGB)
        var net = sensors.network()
        if cfg.autoWatchVolumes {
            let mounted = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
                .map(\.path).filter { $0.hasPrefix("/Volumes/") }
            let newOnes = mounted.filter { !cfg.watchedVolumes.contains($0) }
            if !newOnes.isEmpty { configStore.update { $0.watchedVolumes += newOnes } }
        }
        let volumes = sensors.volumes(watched: Set(configStore.config.watchedVolumes))

        // Network today + top process (nettop only when someone is looking).
        let dayKey = String(Int((now.timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT(for: now))) / 86400))
        if dayKey != todayKey { todayKey = dayKey; todayDownMB = 0; todayUpMB = 0 }
        todayDownMB += net.downMBs * table.seconds
        todayUpMB += net.upMBs * table.seconds
        net.todayDownGB = todayDownMB / 1000
        net.todayUpGB = todayUpMB / 1000
        if (visible || now.timeIntervalSince(apiDemandAt) < 120), now.timeIntervalSince(netTopAt) >= 15, !netTopRunning {
            netTopAt = now
            netTopRunning = true
            let sensors = self.sensors
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let top = sensors.topNetworkProcess()   // spawns nettop: keep it off the engine queue
                self?.queue.async { self?.netTop = top; self?.netTopRunning = false }
            }
        }
        net.topProcess = netTop?.0
        net.topProcessMBs = netTop?.1

        // Trends from history (every 5 min). One-off steps in free space are events, not part of the rate.
        if now.timeIntervalSince(trendsAt) > 300 {
            trendsAt = now
            let to = Int64(now.timeIntervalSince1970 / 60)
            let (trend, step) = Self.trendExcludingSteps(store.series(.disk_free_gb, fromMinute: max(to - 120, diskSeriesStart),
                                                                      toMinute: to, stepMinutes: 5))
            diskTrend = trend
            if let st = step, st.at != diskStep?.at {
                let key = String(Int(st.at.timeIntervalSince1970))
                if store.get("lastDiskStep") != key {
                    store.set("lastDiskStep", key)
                    let t = DateFormatter.localizedString(from: st.at, dateStyle: .none, timeStyle: .short)
                    event("disk.step", "/", String(format: "Free space %@ %.1f GB around %@ (%@): a one-off, left out of the disk trend",
                                                   st.deltaGB > 0 ? "jumped +" : "dropped", abs(st.deltaGB), t,
                                                   st.deltaGB > 0 ? "a cleanup, snapshot thinning or a deleted folder" : "a big copy or download"))
                }
            }
            diskStep = step
            swapTrend = slopePerHour(store.series(.swap_gb, fromMinute: to - 60, toMinute: to, stepMinutes: 5))
        }
        disk.trendGBPerHour = diskTrend
        disk.lastStep = diskStep
        if let t = diskTrend, t < -0.05 {
            disk.hoursToFloor = max(0, (disk.freeGB - disk.floorGB) / -t)
        }
        // Deletes that don't free space (Time Machine local snapshots holding the data), sampled once a minute.
        if diskSamples.last.map({ now.timeIntervalSince($0.t) >= 60 }) ?? true {
            diskSamples.append((now, disk.freeGB, disk.purgeableGB, disk.tmLocalSnapshots))
            diskSamples.removeAll { now.timeIntervalSince($0.t) > 5400 }
        }
        mem.swapGrowthGBPerHour = swapTrend
        // Top disk I/O process.
        if table.seconds > 0, let top = table.entries.values.max(by: { $0.readBytes + $0.writeBytes < $1.readBytes + $1.writeBytes }),
           top.readBytes + top.writeBytes > 0 {
            disk.topIOProcess = table.meta(top.pid)?.name ?? top.comm
            disk.topIOMBs = (top.readBytes + top.writeBytes) / table.seconds / 1e6
        }

        let waiting = jobs.waitingJobs
        headroom.record(busyCores: cpu.busyCores, groups: result.groups, diskMBs: disk.readMBs + disk.writeMBs, waiting: waiting, now: now)
        cpu.freeCoresP90 = headroom.freeCoresP90(total: cpu.totalCores)
        disk.ioPeakMBs = headroom.ioPeakMBs
        for e in headroom.throughputEvents(jobs: jobs, now: now) { event(e.type, e.subject, e.message) }

        // Watched folders (background scan every 10 min).
        if !cfg.watchedFolders.isEmpty, now.timeIntervalSince(foldersAt) > 600 {
            foldersAt = now
            scanFolders(cfg.watchedFolders)
        }

        // Status.
        var s = Status()
        s.time = now
        s.warmingUp = table.seconds <= 0 || lastEnergy == nil
        s.power = power
        s.cpu = cpu
        s.memory = mem
        s.disk = disk
        s.volumes = volumes
        s.network = net
        s.folders = folders.filter { cfg.watchedFolders.contains($0.path) }
        s.jobs = jobs.jobs
        s.jobGroups = jobs.groupNames.compactMap { jobs.eta(group: $0, now: now) }
        s.topGroups = Array(result.groups.filter { $0.kind != "system" || $0.watts > 0.05 }.prefix(15))
        for i in s.topGroups.indices { fillGroupHeader(&s.topGroups[i]) }
        s.monitor.cpuPct = result.selfCPU
        s.monitor.memMB = result.selfMem
        s.monitor.watts = result.selfW
        s.monitor.intervalS = interval
        s.headroom = headroom.compute(cpu: cpu, mem: mem, power: power, disk: disk, groups: result.groups, waiting: waiting, now: now)
        s.sources = [
            "power.cpu": SourceStamp(energy.available ? "IOReport Energy Model (CPU/GPU/ANE/DRAM)" : "unavailable", now),
            "power.battery": SourceStamp("AppleSmartBattery via IOKit (PowerTelemetryData, Voltage × Amperage)", now),
            "processes": SourceStamp("libproc: sysctl KERN_PROC_ALL + proc_pid_rusage incl. reaped-children CPU (power scaled to IOReport CPU)", table.sampledAt),
            "processes.other_users": SourceStamp("/bin/ps (setuid) for other users' processes, every 15–60 s", foreignAt),
            "cpu": SourceStamp("host_processor_info per-core ticks · ProcessInfo.thermalState", now),
            "memory": SourceStamp("host_statistics64 · kern.memorystatus_vm_pressure_level · vm.swapusage", now),
            "disk": SourceStamp("free now: statvfs(\"/\") like df · incl. purgeable: macOS' volumeAvailableCapacityForImportantUsage estimate (60 s) · tmutil listlocalsnapshots every 2 min", now),
            "disk.io": SourceStamp("IOBlockStorageDriver statistics · per-process rusage disk I/O", now),
            "network": SourceStamp("sysctl NET_RT_IFLIST2 (en* interfaces)", now),
            "network.top": SourceStamp("nettop (only while the dashboard is open or the API is in use)", netTopAt),
        ]

        // Alerts (need the status) and guards (need the expression context).
        let ctx = Context(status: s, engine: self)
        var extras = AlertEngine.Extras()
        extras.waitingJobs = waiting
        extras.unplugNote = batteryGuardNote(power, guards: cfg.guards)
        extras.snapshotHold = snapshotHold(disk, folders: s.folders, now: now)
        let out = alerts.evaluate(s, groups: result.groups, cfg: cfg.alerts, extras: extras, now: now)
        for e in out.events { event(e.type, e.subject, e.message) }
        for a in out.fired { deliver(a) }
        for a in out.cleared { event("alert.cleared", a.subject, "Cleared: \(a.message)") }
        if cfg.alerts.backgroundWindow, now.timeIntervalSince(windowsCheckedAt) >= 10 {
            windowsCheckedAt = now
            var jobPids: [Int32: String] = [:]
            for g in result.groups where g.kind == "job" || g.kind == "registered" {
                for p in result.members[g.id] ?? [] where table.meta(p)?.bundle == nil { jobPids[p] = g.label }
            }
            for a in alerts.checkWindows(jobPids: jobPids) { deliver(a) }
        }
        for act in guards.evaluate(cfg.guards, ctx: Context(status: s, engine: self), now: now) {
            let g = act.rule.group ?? ""
            switch act.kind {
            case "pause": _ = pause(g, by: "guard: \(act.rule.name)", reason: act.reason)
            case "resume": _ = resume(g, by: "guard: \(act.rule.name)", reason: act.reason)
            default:
                event("guard.notify", act.rule.name, "Guard \(act.rule.name): \(act.reason)")
                deliver(alerts.raise("guard", act.rule.name, "Guard \(act.rule.name) fired: \(act.reason)"))
            }
        }
        s.alerts = alerts.active.values.sorted { ($0.severity == "critical" ? 0 : 1, $0.since) < ($1.severity == "critical" ? 0 : 1, $1.since) }
        _ = ctx

        lock.lock(); _status = s; lock.unlock()

        accumulate(s, result: result, seconds: table.seconds, now: now)
        evaluateWaits()
        if visible || lastPublished == nil { publishUI() } else { publishMenuOnly() }
    }

    private struct Header { let command: String?; let cwd: String?; let chain: [String]; let at: Date }
    private var headerCache: [String: Header] = [:]

    /// Command line, cwd and parent chain of a group's root — cached (they rarely change).
    private func fillGroupHeader(_ g: inout GroupInfo) {
        guard let root = g.rootPid else { return }
        let key = g.id + ":\(root)"
        if let h = headerCache[key], Date().timeIntervalSince(h.at) < 30 {
            g.command = g.command ?? h.command; g.cwd = h.cwd; g.parentChain = h.chain
            return
        }
        let h = Header(command: g.command ?? table.commandLine(root), cwd: table.cwd(root),
                       chain: Grouper.parentChain(root, table), at: Date())
        if headerCache.count > 2000 { headerCache.removeAll() }
        headerCache[key] = h
        g.command = h.command; g.cwd = h.cwd; g.parentChain = h.chain
    }

    private func publishUI() {
        guard let r = lastResult else { return }
        var groups = r.groups
        for i in groups.indices where i < 40 || groups[i].kind == "job" || groups[i].kind == "registered" || expanded.contains(groups[i].id) {
            fillGroupHeader(&groups[i])
            if expanded.contains(groups[i].id) {
                Grouper.details(&groups[i], pids: r.members[groups[i].id] ?? [], table, r)
            }
        }
        let snap = UISnapshot(status: latestStatus, groups: groups, unattributedW: r.unattributedW,
                              events: recentEvents, guards: guards.annotate(configStore.config.guards),
                              configError: configStore.lastError, staleMinutes: configStore.config.alerts.jobStaleMinutes)
        lastPublished = snap
        onSnapshot?(snap)
    }

    /// While hidden, only the menu bar needs updating: send a snapshot without groups.
    private func publishMenuOnly() {
        let snap = UISnapshot(status: latestStatus, groups: [], unattributedW: 0, events: [], guards: [], configError: nil)
        onSnapshot?(snap)
    }

    // MARK: Metrics + usage

    private func accumulate(_ s: Status, result: GroupingResult, seconds dt: Double, now: Date) {
        let m = Int64(now.timeIntervalSince1970 / 60)
        if m != minute { flushMinute(); minute = m }
        guard dt > 0 else { return }
        func gauge(_ k: Metric, _ v: Double?) {
            guard let v, v.isFinite else { return }
            sums[k, default: 0] += v * dt
            counts[k, default: 0] += dt
        }
        func counter(_ k: Metric, _ mb: Double) { sums[k, default: 0] += mb; counts[k] = 1 }
        let p = s.power
        gauge(.battery, p.batteryPct.map(Double.init))
        gauge(.draw_w, p.drawW)
        gauge(.net_battery_w, p.netBatteryW)
        gauge(.charger_w, p.onAC ? p.chargerW : 0)
        gauge(.cpu_w, p.cpuW)
        gauge(.gpu_w, p.gpuW)
        gauge(.soc_w, (p.socW ?? 0) + (p.aneW ?? 0))
        gauge(.other_w, p.otherW)
        gauge(.on_ac, p.onAC ? 1 : 0)
        gauge(.cpu_busy_cores, s.cpu.busyCores)
        gauge(.p_busy_pct, s.cpu.pBusyPct)
        gauge(.e_busy_pct, s.cpu.eBusyPct)
        gauge(.thermal, ["nominal": 0, "fair": 1, "serious": 2, "critical": 3][s.cpu.thermal])
        gauge(.mem_pressure, ["green": 0, "yellow": 1, "red": 2][s.memory.pressure])
        gauge(.mem_used_gb, s.memory.usedGB)
        gauge(.swap_gb, s.memory.swapUsedGB)
        gauge(.compressed_gb, s.memory.compressedGB)
        gauge(.disk_free_gb, s.disk.freeGB > 0 ? s.disk.freeGB : nil)
        counter(.disk_read_mb, s.disk.readMBs * dt)
        counter(.disk_write_mb, s.disk.writeMBs * dt)
        counter(.net_down_mb, s.network.downMBs * dt)
        counter(.net_up_mb, s.network.upMBs * dt)

        let onBattery = !p.onAC
        var u = usage[onBattery] ?? [:]
        for g in result.groups where g.watts > 0 || g.cpuPct > 0 {
            var e = u[g.label] ?? (g.iconPath, 0, 0)
            e.energy += g.watts * dt
            e.cpu += g.cpuPct / 100 * dt
            u[g.label] = e
        }
        usage[onBattery] = u
    }

    private func flushMinute() {
        guard minute >= 0 else { return }
        var vals: [Metric: Double] = [:]
        for (k, s) in sums {
            let c = counts[k] ?? 0
            if k.isCounter { vals[k] = s } else if c > 0 { vals[k] = s / c }
        }
        store.writeMetrics(minute: minute, values: vals)
        for (onb, u) in usage { store.writeUsage(minute: minute, usage: u, onBattery: onb) }
        sums.removeAll(keepingCapacity: true)
        counts.removeAll(keepingCapacity: true)
        usage.removeAll(keepingCapacity: true)
        let now = Date()
        if now.timeIntervalSince(lastPrune) > 6 * 3600 { store.prune(now: now); lastPrune = now }
    }


    /// Linear trend (GB/h) of a 5-minute series after removing one-off steps (a jump far larger than the
    /// usual change between buckets). Returns the most recent step, if any.
    static func trendExcludingSteps(_ pts: [HistoryPoint]) -> (Double?, DiskStep?) {
        let xs = pts.compactMap { p in p.v.map { (p.t, $0) } }
        guard xs.count >= 2 else { return (nil, nil) }
        let deltas = zip(xs.dropFirst(), xs).map { $0.1 - $1.1 }
        let sortedAbs = deltas.map(abs).sorted()
        let median = sortedAbs[sortedAbs.count / 2]
        let threshold = max(3.0, median * 6)
        var offset = 0.0
        var adjusted: [HistoryPoint] = [HistoryPoint(t: xs[0].0, v: xs[0].1)]
        var step: DiskStep?
        for (i, d) in deltas.enumerated() {
            if abs(d) > threshold {
                offset += d
                step = DiskStep(at: xs[i + 1].0, deltaGB: d)
            }
            adjusted.append(HistoryPoint(t: xs[i + 1].0, v: xs[i + 1].1 - offset))
        }
        return (slopePerHourStatic(adjusted), step)
    }

    private func slopePerHour(_ pts: [HistoryPoint]) -> Double? { Self.slopePerHourStatic(pts) }

    static func slopePerHourStatic(_ pts: [HistoryPoint]) -> Double? {
        let xs = pts.compactMap { p in p.v.map { (p.t.timeIntervalSince1970 / 3600, $0) } }
        guard xs.count >= 4, let first = xs.first, let last = xs.last, last.0 - first.0 > 0.25 else { return nil }
        let mx = xs.map(\.0).reduce(0, +) / Double(xs.count)
        let my = xs.map(\.1).reduce(0, +) / Double(xs.count)
        let num = xs.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        let den = xs.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        return den > 0 ? num / den : nil
    }

    /// "the battery guard (<10%) pauses renders in ~2h45m" for pause guards with a `battery < X` condition.
    private func batteryGuardNote(_ p: PowerInfo, guards rules: [GuardRule]) -> String? {
        guard !p.onAC, let pct = p.batteryPct, let draw = p.drawW, draw > 0.5 else { return nil }
        func thresholds(_ e: Expr) -> [Double] {
            switch e {
            case let .compare("battery", op, v) where op == "<" || op == "<=": return [v]
            case let .and(a, b), let .or(a, b): return thresholds(a) + thresholds(b)
            default: return []
            }
        }
        var byThreshold: [Double: (names: [String], groups: [String])] = [:]
        for r in rules where (r.enabled ?? true) && r.action == "pause" {
            guard let e = try? ExprParser.parse(r.when), let x = thresholds(e).max(), Double(pct) > x else { continue }
            var cur = byThreshold[x] ?? ([], [])
            cur.names.append(r.name)
            if let g = r.group { cur.groups.append(g) }
            byThreshold[x] = cur
        }
        guard !byThreshold.isEmpty else { return nil }
        let parts = byThreshold.keys.sorted(by: >).map { x -> String in
            let v = byThreshold[x]!
            let hours: Double
            if let wh = p.batteryWh, let full = p.batteryFullWh, full > 0 {
                hours = max(0, wh - full * x / 100) / draw
            } else if let h = p.hoursToEmpty, pct > 0 {
                hours = h * (Double(pct) - x) / Double(pct)
            } else { return "" }
            let who = v.names.count == 1 ? "the \(v.names[0]) guard" : "guards \(v.names.joined(separator: ", "))"
            let groups = v.groups.isEmpty ? "its jobs" : Self.listText(Array(Set(v.groups)).sorted())
            return "\(who) (<\(Expr.fmt(x))%) pauses \(groups) in ~\(fmtDuration(hours * 3600))"
        }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    static func listText(_ xs: [String]) -> String {
        xs.count <= 1 ? (xs.first ?? "") : xs.dropLast().joined(separator: ", ") + " and " + xs.last!
    }

    /// Big deletes in the last hour that didn't raise free space, while local snapshots exist.
    /// "Deleted" comes from purgeable space growing (snapshot-held data becomes purgeable) and from
    /// watched folders shrinking; whichever is larger.
    private func snapshotHold(_ d: DiskInfo, folders: [FolderInfo], now: Date) -> AlertEngine.SnapshotHold? {
        guard let snaps = d.tmLocalSnapshots, snaps > 0,
              let old = diskSamples.first(where: { now.timeIntervalSince($0.t) <= 3900 }),
              now.timeIntervalSince(old.t) >= 1800 else { return nil }
        let freeChange = d.freeGB - old.free
        let purgeableGrowth = d.purgeableGB - old.purgeable
        var shrink = 0.0
        for f in configStore.config.watchedFolders {
            let h = store.folderHistory(path: f, since: now.addingTimeInterval(-3900))
            if let a = h.first, let b = h.last, a.1 > b.1 { shrink += a.1 - b.1 }
        }
        let deleted = max(purgeableGrowth, shrink)
        guard deleted >= 10, freeChange < deleted * 0.25 else { return nil }
        let mins = Int(now.timeIntervalSince(old.t) / 60)
        var basis = [String(format: "free %.1f → %.1f GB over %d min", old.free, d.freeGB, mins)]
        if purgeableGrowth > 1 { basis.append(String(format: "purgeable +%.1f GB", purgeableGrowth)) }
        if shrink > 1 { basis.append(String(format: "watched folders −%.1f GB", shrink)) }
        if let o = old.snapshots, o != snaps { basis.append("snapshots \(o) → \(snaps)") }
        return AlertEngine.SnapshotHold(deletedGB: deleted, freeChangeGB: freeChange, snapshots: snaps, basis: basis.joined(separator: ", "))
    }

    static func endSeverity(_ type: String) -> String {
        switch type {
        case "job.failed": return "critical"
        case "job.finished", "job.exited": return "info"     // ended normally, or exit code unknowable
        default: return "warning"
        }
    }

    private func scanFolders(_ paths: [String]) {
        DispatchQueue.global(qos: .background).async { [weak self] in
            var res: [FolderInfo] = []
            for p in paths {
                var f = FolderInfo(path: p)
                f.sizeGB = SystemSensors.folderSize(p)
                f.scannedAt = Date()
                res.append(f)
            }
            self?.queue.async {
                guard let self else { return }
                for var f in res {
                    if let gb = f.sizeGB {
                        self.store.addFolderSize(path: f.path, gb: gb, at: f.scannedAt ?? Date())
                        let hist = self.store.folderHistory(path: f.path, since: Date().addingTimeInterval(-3 * 3600))
                        if let a = hist.first, let b = hist.last, b.0.timeIntervalSince(a.0) > 300 {
                            f.growthGBPerHour = (b.1 - a.1) / (b.0.timeIntervalSince(a.0) / 3600)
                        }
                    }
                    self.folders.removeAll { $0.path == f.path }
                    self.folders.append(f)
                }
            }
        }
    }

    // MARK: Events

    @discardableResult
    func event(_ type: String, _ subject: String?, _ message: String) -> EventInfo {
        let e = store.addEvent(type: type, subject: subject, message: message)
        recentEvents.insert(e, at: 0)
        if recentEvents.count > 300 { recentEvents.removeLast(recentEvents.count - 300) }
        return e
    }

    private func deliver(_ a: AlertInfo) {
        if a.type != "job_ended" { event("alert.fired", a.subject, a.message) }
        let cfg = configStore.config.delivery
        DispatchQueue.main.async { Delivery.send(a, cfg: cfg) }
    }

    /// Crash reports are attributed to the registered job (or job group) whose process tree contains the
    /// crashed process or any of its ancestors, e.g. "crash in presets2 (headless-daw, faulting module HeartCore)".
    private func crashReport(_ c: CrashWatcher.Report) {
        let fname = (c.path as NSString).lastPathComponent
        var detail = [c.name]
        if let m = c.faultingModule { detail.append("faulting module \(m)") }
        if let e = c.exception, !e.isEmpty { detail.append(e) }
        let summary = detail.joined(separator: ", ")
        // The crashed pid is usually gone already: use the parent pid from the report, then live ancestors.
        var chain: [Int32] = [c.pid, c.parentPid].compactMap { $0 }
        var cur = c.parentPid ?? c.pid
        for _ in 0..<12 {
            guard let p = cur, let e = table.entries[p], e.ppid > 1 else { break }
            chain.append(e.ppid)
            cur = e.ppid
        }
        let pidText = c.pid.map { " (pid \($0)\(c.parentPid.map { ", parent \($0)\(c.parentName.map { " \($0)" } ?? "")" } ?? ""))" } ?? ""
        event("crash", c.name, "Crash report: \(summary)\(pidText) — \(fname)")
        guard configStore.config.alerts.crashReports else { return }
        if let job = jobs.jobContaining(chain) {
            if let e = jobs.markCrashed(job: job, pid: c.pid ?? -1, summary: summary) { event(e.type, e.subject, e.message) }
            deliver(alerts.raise("crash", job, "crash in \(job) (\(summary))", severity: "critical"))
            return
        }
        if let r = lastResult,
           let g = r.groups.first(where: { g in (g.kind == "job" || g.kind == "registered") && chain.contains { (r.members[g.id] ?? []).contains($0) } }) {
            deliver(alerts.raise("crash", g.label, "crash in \(g.label) (\(summary))", severity: "critical"))
        }
    }

    // MARK: Pause / resume

    private func pausedNotesByGroup() -> [String: String] {
        var out: [String: String] = [:]
        for (_, rec) in paused {
            for id in resolve(rec.name) { out[id] = rec.note }
        }
        return out
    }

    /// Group ids matching a name: registered group, job name, label, kind or id (case-insensitive).
    private func resolve(_ name: String) -> [String] {
        let n = name.lowercased()
        return lastGroups.values.filter { g in
            g.kind != "system" && AlertEngine.names(g).contains(n)
        }.map(\.id)
    }

    private func pidsFor(_ name: String) -> [Int32] {
        guard let r = lastResult else { return [] }
        var pids = Set<Int32>()
        for id in resolve(name) { pids.formUnion(r.members[id] ?? []) }
        let me = table.selfPid
        return pids.filter { pid in
            pid > 1 && pid != me && (table.entries[pid].map { $0.uid == table.myUid } ?? false)
        }.sorted()
    }

    func pause(_ name: String, by: String, reason: String? = nil) -> (Bool, String) {
        let pids = pidsFor(name)
        guard !pids.isEmpty else { return (false, "no running processes match '\(name)'") }
        for p in pids { kill(p, SIGSTOP) }
        let key = name.lowercased()
        var rec = paused[key] ?? PauseRecord(name: name, since: Date(), by: by, pids: [])
        rec.pids = Array(Set(rec.pids + pids)).sorted()
        rec.by = by
        paused[key] = rec
        savePaused()
        let msg = "Paused \(name) (\(pids.count) processes) — \(by)" + (reason.map { ": \($0)" } ?? "")
        event(by.hasPrefix("guard") ? "guard.pause" : "group.paused", name, msg)
        return (true, msg)
    }

    func resume(_ name: String, by: String, reason: String? = nil) -> (Bool, String) {
        let key = name.lowercased()
        let rec = paused.removeValue(forKey: key)
        let pids = Set((rec?.pids ?? []) + pidsFor(name))
        guard !pids.isEmpty else { savePaused(); return (false, "nothing to resume for '\(name)'") }
        for p in pids where p > 1 && p != table.selfPid { kill(p, SIGCONT) }
        savePaused()
        if !by.hasPrefix("guard") { guards.manualResume(group: name) }
        let msg = "Resumed \(name) (\(pids.count) processes) — \(by)" + (reason.map { ": \($0)" } ?? "")
        event(by.hasPrefix("guard") ? "guard.resume" : "group.resumed", name, msg)
        return (true, msg)
    }

    private func savePaused() {
        if let d = try? JSON.encoder.encode(paused), let s = String(data: d, encoding: .utf8) { store.set("paused", s) }
    }

    // MARK: Waits

    func wait(_ exprString: String, timeout: Double, done: @escaping (Result<WaitResult, ExprError>) -> Void) {
        let expr: Expr
        do { expr = try ExprParser.parse(exprString) } catch let e as ExprError { done(.failure(e)); return } catch { return }
        queue.async {
            self.apiDemandAt = Date()
            // Job conditions get a short grace: a client that just started a new run under the same name
            // (`forkcast run … &` then `forkcast wait 'job X done'`) may not have registered it yet.
            let now = Date()
            let w = Waiter(id: UUID(), expr: expr, deadline: now.addingTimeInterval(timeout), started: now,
                           notBefore: now.addingTimeInterval(expr.mentionsJob ? 3 : 0)) { done(.success($0)) }
            self.waiters.append(w)
            self.evaluateWaits()
            if !self.waiters.isEmpty {
                self.reschedule()
                if self.waitTimer == nil {
                    let t = DispatchSource.makeTimerSource(queue: self.queue)
                    t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
                    t.setEventHandler { [weak self] in self?.evaluateWaits() }
                    t.resume()
                    self.waitTimer = t
                }
            }
        }
    }

    private func evaluateWaits() {
        guard !waiters.isEmpty else { return }
        let ctx = Context(status: latestStatus, engine: self)
        let now = Date()
        waiters.removeAll { w in
            if now < w.notBefore && now < w.deadline { return false }
            let (ok, why) = w.expr.evaluate(ctx)
            if ok || now >= w.deadline {
                w.done(WaitResult(met: ok, timedOut: !ok, fired: why, waitedSeconds: now.timeIntervalSince(w.started), status: latestStatus))
                return true
            }
            return false
        }
        if waiters.isEmpty {
            waitTimer?.cancel()
            waitTimer = nil
            reschedule()
        }
    }

    /// Expression context over the latest status.
    struct Context: ExprContext {
        let status: Status
        unowned let engine: Engine

        func metric(_ name: String) -> Double? {
            let s = status
            switch name {
            case "battery": return s.power.batteryPct.map(Double.init)
            case "on_ac": return s.power.onAC ? 1 : 0
            case "charging": return s.power.charging ? 1 : 0
            case "net_battery_w": return s.power.netBatteryW
            case "draw_w": return s.power.drawW
            case "charger_w": return s.power.onAC ? (s.power.chargerW ?? 0) : 0
            case "margin_w": return s.power.marginW
            case "cpu_w": return s.power.cpuW
            case "gpu_w": return s.power.gpuW
            case "hours_to_full": return s.power.hoursToFull
            case "hours_to_empty": return s.power.hoursToEmpty
            case "cpu_busy_cores": return s.cpu.busyCores
            case "cpu_free_cores": return s.cpu.freeCoresP90 ?? Double(s.cpu.totalCores) - s.cpu.busyCores
            case "cpu_pct": return s.cpu.totalCores > 0 ? s.cpu.busyCores / Double(s.cpu.totalCores) * 100 : nil
            case "thermal": return ["nominal": 0, "fair": 1, "serious": 2, "critical": 3][s.cpu.thermal]
            case "throttling": return s.cpu.throttling ? 1 : 0
            case "mem_pressure": return ["green": 0, "yellow": 1, "red": 2][s.memory.pressure]
            case "mem_headroom_gb": return s.memory.headroomGB
            case "swap_gb": return s.memory.swapUsedGB
            case "swap_growth_gb_h": return s.memory.swapGrowthGBPerHour ?? 0
            case "disk_free_gb": return s.disk.freeGB
            case "disk_free_purgeable_gb": return s.disk.freeInclPurgeableGB
            case "disk_hours_to_floor": return s.disk.hoursToFloor ?? .infinity
            case "disk_read_mbs": return s.disk.readMBs
            case "disk_write_mbs": return s.disk.writeMBs
            case "net_down_mbs": return s.network.downMBs
            case "net_up_mbs": return s.network.upMBs
            case "net_today_up_gb": return s.network.todayUpGB
            case "net_today_down_gb": return s.network.todayDownGB
            case "alerts": return Double(s.alerts.count)
            default: return nil
            }
        }
        func jobState(_ name: String) -> String? { engine.jobs.job(name)?.state }
        func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
        func groupState(_ name: String) -> (busy: Bool, paused: Bool, alive: Int, finished: Int)? {
            let n = name.lowercased()
            let gs = engine.lastGroups.values.filter { $0.kind != "system" && AlertEngine.names($0).contains(n) }
            let reg = engine.jobs.jobs.filter { $0.group.lowercased() == n }
            if gs.isEmpty && reg.isEmpty { return nil }
            let cpu = gs.map(\.cpuPct).reduce(0, +)
            return (cpu >= 5, !gs.isEmpty && gs.allSatisfy(\.paused), gs.count, reg.filter(\.isFinished).count)
        }
        func processRunning(_ name: String) -> Bool {
            let n = name.lowercased()
            return engine.table.entries.values.contains { e in
                let names = [e.comm.lowercased(), engine.table.meta(e.pid)?.name.lowercased() ?? ""]
                return names.contains { $0 == n || (n.contains("*") && fnmatch(n, $0, 0) == 0) }
            }
        }
    }

    // MARK: API (all run on the engine queue)

    func sync<T>(_ f: () throws -> T) rethrows -> T {
        try queue.sync { apiDemandAt = Date(); return try f() }
    }

    func processes(groupBy: String, limit: Int) -> [GroupInfo] {
        sync {
            guard let r = lastResult else { return [] }
            switch groupBy {
            case "tree": return Grouper.tree(table, r)
            case "app": return Grouper.byApp(table, r)
            default:
                var gs = r.groups
                for i in gs.indices {
                    fillGroupHeader(&gs[i])
                    Grouper.details(&gs[i], pids: r.members[gs[i].id] ?? [], table, r, limit: limit)
                }
                return gs
            }
        }
    }

    func register(_ req: RegisterRequest) throws -> JobInfo {
        try sync {
            if table.entries[req.pid ?? 0] == nil { table.sample() }
            let (info, ev) = try jobs.register(req, table: table)
            event(ev.type, ev.subject, ev.message)
            return info
        }
    }
    func startQueued(_ name: String, pid: Int32?) throws -> JobInfo {
        try sync {
            if let pid, table.entries[pid] == nil { table.sample() }
            let (info, ev) = try jobs.start(name, pid: pid, table: table)
            if let ev { jobEvent(ev) }
            return info
        }
    }
    func progress(_ name: String, _ p: ProgressRequest) throws -> JobInfo {
        try sync {
            let (info, evs) = try jobs.progress(name, p)
            evs.forEach(jobEvent)
            return info
        }
    }
    /// Records a job event on the timeline, and raises the job-ended alert for a run that ended.
    private func jobEvent(_ e: JobEvent) {
        event(e.type, e.subject, e.message)
        if configStore.config.alerts.jobEnded, ["job.finished", "job.failed", "job.exited"].contains(e.type) {
            deliver(alerts.raise("job_ended", e.subject, e.message, severity: Self.endSeverity(e.type)))
        }
    }
    func beat(_ name: String) throws -> JobInfo { try sync { try jobs.beat(name) } }
    func exitJob(_ name: String, _ e: ExitRequest) throws -> JobInfo {
        try sync {
            let (info, ev, current) = try jobs.exit(name, e)
            event(ev.type, ev.subject, ev.message)
            if current, configStore.config.alerts.jobEnded {
                deliver(alerts.raise("job_ended", name, ev.message, severity: Self.endSeverity(ev.type)))
            }
            return info
        }
    }
    func setJobState(_ name: String, _ r: StateRequest) throws -> JobInfo {
        try sync {
            let (info, ev) = try jobs.setState(name, r)
            event(ev.type, ev.subject, ev.message)
            return info
        }
    }
    func forget(_ name: String) -> Bool { sync { jobs.forget(name) } }
    func jobList() -> [JobInfo] { sync { jobs.jobs } }
    func job(_ name: String) -> JobInfo? { sync { jobs.job(name) } }
    func groupETA(_ g: String) -> GroupETA? { sync { jobs.eta(group: g) } }
    func allETAs() -> [GroupETA] { sync { jobs.groupNames.compactMap { jobs.eta(group: $0) } } }
    func apiPause(_ g: String, resume r: Bool) -> (Bool, String) { sync { r ? resume(g, by: "manual") : pause(g, by: "manual") } }
    func events(since: Date, until: Date = .distantFuture, types: [String], limit: Int) -> [EventInfo] {
        sync { store.events(since: since, until: until, types: types, limit: limit) }
    }
    func guardList() -> [GuardRule] { sync { guards.annotate(configStore.config.guards) } }
    func addGuard(_ r: GuardRule) throws -> GuardRule {
        try sync {
            if let err = guards.validate(r) { throw ExprError(message: err) }
            configStore.update { c in
                c.guards.removeAll { $0.name == r.name }
                var clean = r
                clean.active = nil; clean.lastFired = nil; clean.error = nil
                c.guards.append(clean)
            }
            event("guard.added", r.name, "Guard \(r.name): when \(r.when) → \(r.action) \(r.group ?? "")")
            return guards.annotate([r]).first!
        }
    }
    func deleteGuard(_ name: String) -> Bool {
        sync {
            let before = configStore.config.guards.count
            configStore.update { $0.guards.removeAll { $0.name == name } }
            return configStore.config.guards.count < before
        }
    }
    func headroomFor(_ group: String?) -> Headroom {
        sync {
            var h = latestStatus.headroom
            if let g = group?.lowercased() {
                h.cards = h.cards.filter { $0.kindKey.lowercased().contains(g) || $0.label.lowercased().contains(g) }
            }
            return h
        }
    }
    func history(metric: Metric, rangeSeconds: Double, stepSeconds: Double, until: Date = Date()) -> [HistoryPoint] {
        sync {
            flushMinute()
            minute = Int64(Date().timeIntervalSince1970 / 60)
            let to = Int64(until.timeIntervalSince1970 / 60)
            return store.series(metric, fromMinute: to - Int64(rangeSeconds / 60), toMinute: to, stepMinutes: max(1, Int64(stepSeconds / 60)))
        }
    }
    func drains(from: Date, to: Date, batteryOnly: Bool) -> ([Drain], Double) {
        sync {
            let f = Int64(from.timeIntervalSince1970 / 60), t = Int64(to.timeIntervalSince1970 / 60)
            return (store.drains(fromMinute: f, toMinute: t, batteryOnly: batteryOnly, limit: 8),
                    store.total(.draw_w, fromMinute: f, toMinute: t, onBatteryOnly: batteryOnly))
        }
    }
    func dismissAlert(_ id: String) { queue.async { self.alerts.dismiss(id) } }
    func updateConfig(_ f: @escaping (inout Config) -> Void) {
        queue.async { self.configStore.update(f); self.reschedule() }
    }
    var config: Config { sync { configStore.config } }
}
