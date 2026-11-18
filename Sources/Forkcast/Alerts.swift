import AppKit
import CoreGraphics
import Foundation
import ForkcastCore
import UserNotifications

/// Evaluates every alert type each tick. Conditions that must *hold* for N minutes track when they became true.
final class AlertEngine {
    private(set) var active: [String: AlertInfo] = [:]
    private var holdSince: [String: Date] = [:]
    private var instantExpiry: [String: Date] = [:]
    private var lastOnAC: Bool?
    private var lastChargerW: Double?
    private var lastMounted: [String: Bool] = [:]
    private var windowAlerted = Set<Int32>()
    private var uploadAlertDay: String?

    struct Output { var fired: [AlertInfo] = []; var cleared: [AlertInfo] = []; var events: [JobEvent] = [] }

    /// `subjects` lets an alert match by any of a group's names (label, job, registered group, kind).
    static func names(_ g: GroupInfo) -> [String] {
        [g.label, g.jobName, g.registeredGroup, g.kindKey, g.id].compactMap { $0?.lowercased() }
    }

    func evaluate(_ s: Status, groups: [GroupInfo], cfg: AlertConfig, now: Date) -> Output {
        var out = Output()
        var seen = Set<String>()

        func hold(_ type: String, _ subject: String?, _ isTrue: Bool, minutes: Double, severity: String = "warning",
                  _ message: @autoclosure () -> String) {
            let id = type + "|" + (subject ?? "")
            seen.insert(id)
            if isTrue {
                let since = holdSince[id] ?? now
                holdSince[id] = since
                if now.timeIntervalSince(since) >= minutes * 60 {
                    if var a = active[id] {
                        a.message = message()
                        active[id] = a
                    } else {
                        let a = AlertInfo(type: type, subject: subject, message: message(), severity: severity, since: since)
                        active[id] = a
                        out.fired.append(a)
                    }
                }
            } else {
                holdSince[id] = nil
                if let a = active.removeValue(forKey: id), instantExpiry[id] == nil { out.cleared.append(a) }
            }
        }
        func instant(_ type: String, _ subject: String?, _ message: String, severity: String = "warning", keep: Double = 900) {
            let a = AlertInfo(type: type, subject: subject, message: message, severity: severity, since: now)
            active[a.id] = a
            instantExpiry[a.id] = now.addingTimeInterval(keep)
            out.fired.append(a)
        }

        let p = s.power
        // Charger plugged / unplugged / wattage change (always on the timeline; alerts if enabled).
        if let was = lastOnAC, was != p.onAC {
            let msg = p.onAC ? "Charger connected (\(p.chargerW.map { "\(Int($0)) W" } ?? "?"))" : "Charger unplugged — on battery at \(p.batteryPct ?? 0)%"
            out.events.append(JobEvent(type: p.onAC ? "power.plugged" : "power.unplugged", subject: p.chargerName, message: msg))
            if cfg.chargerChange && !p.onAC { instant("charger_unplugged", nil, msg) }
        } else if p.onAC, let w = p.chargerW, let lw = lastChargerW, abs(w - lw) >= 1 {
            let msg = "Charger changed: \(Int(lw)) W → \(Int(w)) W"
            out.events.append(JobEvent(type: "power.charger", subject: p.chargerName, message: msg))
            if cfg.chargerChange { instant("charger_changed", nil, msg) }
        }
        lastOnAC = p.onAC
        if p.onAC, let w = p.chargerW { lastChargerW = w }

        if let m = cfg.pluggedDrainMinutes, let net = p.netBatteryW {
            hold("plugged_drain", nil, p.onAC && net < -0.3, minutes: m, severity: "critical",
                 "Battery draining while plugged in: \(String(format: "%.1f", net)) W (using \(Int(p.drawW ?? 0)) W on a \(Int(p.chargerW ?? 0)) W charger)")
        }
        if let pct = p.batteryPct {
            if let x = cfg.batteryLowOnBatteryPct {
                hold("battery_low", "battery", !p.onAC && Double(pct) <= x, minutes: 0, severity: pct <= 10 ? "critical" : "warning",
                     "Battery at \(pct)% on battery power" + (p.hoursToEmpty.map { " (~\(fmtDuration($0 * 3600)) left)" } ?? ""))
            }
            if let x = cfg.batteryLowOnACPct {
                hold("battery_low", "ac", p.onAC && Double(pct) <= x, minutes: 0,
                     "Battery at \(pct)% even though plugged in")
            }
        }
        if let x = cfg.diskFreeMinGB {
            hold("disk_free", "/", s.disk.freeInclPurgeableGB > 0 && s.disk.freeInclPurgeableGB < x, minutes: 0, severity: "critical",
                 "Only \(Int(s.disk.freeInclPurgeableGB)) GB free on the internal disk")
        }
        if let h = cfg.diskHoursToFloorMin {
            hold("disk_floor", "/", (s.disk.hoursToFloor ?? .infinity) < h, minutes: 0,
                 "Disk reaches the \(Int(s.disk.floorGB)) GB floor in ~\(fmtDuration((s.disk.hoursToFloor ?? 0) * 3600)) (\(String(format: "%.1f", s.disk.trendGBPerHour ?? 0)) GB/h)")
        }
        if let m = cfg.memoryRedMinutes {
            hold("memory_red", nil, s.memory.pressure == "red", minutes: m, severity: "critical",
                 "Memory pressure red for \(Int(m))+ min (swap \(String(format: "%.1f", s.memory.swapUsedGB)) GB)")
        }
        if let x = cfg.swapGrowthGBPerHour {
            hold("swap_growth", nil, (s.memory.swapGrowthGBPerHour ?? 0) > x, minutes: 0,
                 "Swap growing \(String(format: "%.1f", s.memory.swapGrowthGBPerHour ?? 0)) GB/h (now \(String(format: "%.1f", s.memory.swapUsedGB)) GB)")
        }
        if let m = cfg.throttlingMinutes {
            hold("throttling", nil, s.cpu.throttling, minutes: m, "Thermal state \(s.cpu.thermal): the CPU is being throttled")
        }

        // Volumes.
        for v in s.volumes where v.watched {
            if let was = lastMounted[v.path], was != v.mounted {
                out.events.append(JobEvent(type: v.mounted ? "volume.mounted" : "volume.unmounted", subject: v.name,
                                           message: "\(v.name) \(v.mounted ? "mounted" : "unmounted")"))
                if !v.mounted && cfg.volumeUnmounted { instant("volume_unmounted", v.name, "Watched volume \(v.name) was unmounted", severity: "critical") }
            }
            lastMounted[v.path] = v.mounted
        }

        // Jobs: stale while stale.
        for j in s.jobs {
            hold("job_stale", j.name, j.state == "stale", minutes: 0,
                 "\(j.name): no progress or log output for \(fmtDuration(j.secondsSinceActivity ?? 0))")
        }

        // CPU per group: muted groups and expected ranges.
        let muted = Set(cfg.cpu.muted.map { $0.lowercased() })
        for g in groups where g.kind != "system" {
            let names = Self.names(g)
            var expected: ExpectedRange?
            for (k, r) in cfg.expectedCPU where names.contains(k.lowercased()) { expected = r }
            if let r = expected {
                let low = r.minCPU.map { g.cpuPct < $0 } ?? false
                let high = r.maxCPU.map { g.cpuPct > $0 } ?? false
                hold("cpu_range", g.label, low || high, minutes: r.minutes,
                     low ? "\(g.label) at \(Int(g.cpuPct))% CPU, below its expected \(Int(r.minCPU ?? 0))% for \(Int(r.minutes)) min — hung?"
                         : "\(g.label) at \(Int(g.cpuPct))% CPU, above its expected \(Int(r.maxCPU ?? 0))%")
            } else if cfg.cpu.enabled && !names.contains(where: muted.contains) {
                hold("cpu", g.label, g.cpuPct >= cfg.cpu.percent, minutes: cfg.cpu.minutes,
                     "\(g.label) has used \(Int(g.cpuPct))% CPU for \(Int(cfg.cpu.minutes))+ min")
            }
        }

        // Daily upload.
        if let x = cfg.dailyUploadGB, s.network.todayUpGB > x {
            let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
            if uploadAlertDay != day {
                uploadAlertDay = day
                instant("upload_daily", nil, "Uploaded \(String(format: "%.1f", s.network.todayUpGB)) GB today (limit \(x) GB)")
            }
        }

        // Clear conditions that weren't evaluated (e.g. a group that went away) and expire instant alerts.
        for (id, a) in active where instantExpiry[id] == nil && !seen.contains(id) {
            active[id] = nil
            holdSince[id] = nil
            out.cleared.append(a)
        }
        for (id, exp) in instantExpiry where exp < now {
            instantExpiry[id] = nil
            active[id] = nil
        }
        return out
    }

    /// One-shot alerts raised from elsewhere (job ended, crash report, background window).
    func raise(_ type: String, _ subject: String?, _ message: String, severity: String = "warning") -> AlertInfo {
        let a = AlertInfo(type: type, subject: subject, message: message, severity: severity, since: Date())
        active[a.id] = a
        instantExpiry[a.id] = Date().addingTimeInterval(1800)
        return a
    }

    func dismiss(_ id: String) {
        active[id] = nil
        instantExpiry[id] = nil
    }

    /// A process inside a job group opened an on-screen window (unexpected pop-up from a headless job).
    func checkWindows(jobPids: [Int32: String]) -> [AlertInfo] {
        guard !jobPids.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as NSArray? as? [[String: Any]]
        else { return [] }
        var out: [AlertInfo] = []
        var nowSeen = Set<Int32>()
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let label = jobPids[pid] else { continue }
            nowSeen.insert(pid)
            if !windowAlerted.contains(pid) {
                windowAlerted.insert(pid)
                let owner = w[kCGWindowOwnerName as String] as? String ?? "process \(pid)"
                out.append(raise("background_window", label, "\(owner) (pid \(pid), in \(label)) opened a window"))
            }
        }
        windowAlerted = windowAlerted.intersection(nowSeen.union(Set(jobPids.keys)))
        return out
    }
}

// MARK: - Guards

final class GuardEngine {
    struct State { var trueSince: Date?; var fired = false; var pausedGroup: String?; var lastFired: Date?; var error: String? }
    private var states: [String: State] = [:]
    private var compiled: [String: Expr] = [:]

    private func compile(_ s: String) throws -> Expr {
        if let e = compiled[s] { return e }
        let e = try ExprParser.parse(s)
        compiled[s] = e
        return e
    }

    func validate(_ r: GuardRule) -> String? {
        do {
            _ = try compile(r.when)
            if let rw = r.resumeWhen { _ = try compile(rw) }
            guard ["pause", "resume", "notify"].contains(r.action) else { return "action must be pause, resume or notify" }
            if r.action != "notify" && (r.group ?? "").isEmpty { return "pause/resume guards need a group" }
            return nil
        } catch { return "\(error)" }
    }

    struct Action { let rule: GuardRule; let kind: String; let reason: String }

    func evaluate(_ rules: [GuardRule], ctx: ExprContext, now: Date) -> [Action] {
        var actions: [Action] = []
        for r in rules where r.enabled ?? true {
            var st = states[r.name] ?? State()
            do {
                let (ok, why) = try compile(r.when).evaluate(ctx)
                st.error = nil
                if ok {
                    st.trueSince = st.trueSince ?? now
                    if !st.fired, now.timeIntervalSince(st.trueSince!) >= (r.forSeconds ?? 0) {
                        st.fired = true
                        st.lastFired = now
                        if r.action == "pause" { st.pausedGroup = r.group }
                        actions.append(Action(rule: r, kind: r.action, reason: why ?? r.when))
                    }
                } else {
                    st.trueSince = nil
                    if st.pausedGroup == nil { st.fired = false }
                }
                if let g = st.pausedGroup, let rw = r.resumeWhen {
                    let (resume, why2) = try compile(rw).evaluate(ctx)
                    if resume {
                        actions.append(Action(rule: GuardRule(name: r.name, when: rw, action: "resume").with(group: g),
                                              kind: "resume", reason: why2 ?? rw))
                        st.pausedGroup = nil
                        st.fired = false
                    }
                }
            } catch {
                st.error = "\(error)"
            }
            states[r.name] = st
        }
        return actions
    }

    /// Group was resumed by hand: forget the guard's pause so it can fire again.
    func manualResume(group: String) {
        for (k, var s) in states where s.pausedGroup?.lowercased() == group.lowercased() {
            s.pausedGroup = nil
            s.fired = false
            states[k] = s
        }
    }

    func annotate(_ rules: [GuardRule]) -> [GuardRule] {
        rules.map { r in
            var r = r
            let st = states[r.name]
            r.active = st?.pausedGroup != nil || (st?.fired ?? false)
            r.lastFired = st?.lastFired
            r.error = st?.error ?? validate(r)
            return r
        }
    }
}

extension GuardRule {
    func with(group g: String) -> GuardRule { var c = self; c.group = g; return c }
}

// MARK: - Crash reports

/// Watches ~/Library/Logs/DiagnosticReports for new crash reports.
final class CrashWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var seen = Set<String>()
    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    var onReport: ((String, String, Int32?) -> Void)?   // path, process name, pid

    func start(queue: DispatchQueue) {
        seen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write], queue: queue)
        s.setEventHandler { [weak self] in self?.scan() }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }

    private func scan() {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where !seen.contains(f) {
            seen.insert(f)
            guard f.hasSuffix(".ips") || f.hasSuffix(".crash") else { continue }
            let path = dir.appendingPathComponent(f).path
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            var name = (f as NSString).deletingPathExtension
            if let firstLine = text.split(separator: "\n").first,
               let obj = try? JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any] {
                name = (obj["name"] as? String) ?? (obj["app_name"] as? String) ?? name
            }
            var pid: Int32?
            if let re = try? NSRegularExpression(pattern: "\"pid\"\\s*:\\s*(\\d+)"),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) { pid = Int32(text[r]) }
            onReport?(path, name, pid)
        }
    }
}

// MARK: - Delivery

enum Delivery {
    static func send(_ a: AlertInfo, cfg: DeliveryConfig) {
        let o = cfg.perType[a.type]
        if o?.notify ?? cfg.notify { notify(title: title(a), body: a.message) }
        if let hook = o?.webhook ?? cfg.webhook, let url = URL(string: hook) {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSON.encoder.encode(a)
            URLSession.shared.dataTask(with: req).resume()
        }
        if let cmd = o?.command ?? cfg.command {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            var env = ProcessInfo.processInfo.environment
            env["FORKCAST_ALERT_TYPE"] = a.type
            env["FORKCAST_ALERT_SUBJECT"] = a.subject ?? ""
            env["FORKCAST_ALERT_MESSAGE"] = a.message
            env["FORKCAST_ALERT_SEVERITY"] = a.severity
            env["FORKCAST_ALERT_JSON"] = JSON.string(a)
            p.environment = env
            try? p.run()
        }
    }

    static func title(_ a: AlertInfo) -> String {
        switch a.type {
        case "plugged_drain": return "Battery draining while plugged in"
        case "charger_unplugged": return "Charger unplugged"
        case "charger_changed": return "Charger changed"
        case "battery_low": return "Battery low"
        case "disk_free", "disk_floor": return "Disk filling up"
        case "memory_red", "swap_growth": return "Memory under pressure"
        case "throttling": return "Mac is throttling"
        case "volume_unmounted": return "Drive unmounted"
        case "job_stale": return "Job stalled"
        case "job_ended": return "Job ended"
        case "crash": return "Crash report"
        case "background_window": return "A background job opened a window"
        case "cpu", "cpu_range": return "CPU alert"
        case "guard": return "Guard fired"
        default: return "Forkcast"
        }
    }

    static func notify(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
            guard err != nil else { return }
            let clean = { (s: String) in s.replacingOccurrences(of: "\"", with: "'") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(clean(body))\" with title \"\(clean(title))\""]
            try? p.run()
        }
    }
}
