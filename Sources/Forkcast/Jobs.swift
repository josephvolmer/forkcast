import Foundation
import ForkcastCore

struct RegisterRequest: Codable {
    var name: String
    var group: String?
    var pid: Int32?
    var log: String?
    var logRegex: String?
    var total: Double?
    var after: String?
    var command: String?
    var managed: Bool?       // started by `forkcast run` (it will report the exit code)
    var staleAfter: Double?  // seconds without activity before the job counts as stale; 0 = never
}

struct ProgressRequest: Codable {
    var done: Double?
    var total: Double?
    var note: String?
    var progress: String?    // "412/1721" alternative
}

struct ExitRequest: Codable {
    var code: Int32?
    var signal: Int32?
}

struct JobEvent {
    let type: String
    let subject: String?
    let message: String
}

/// Registered jobs: what a process *is* and how far along it is.
final class JobRegistry {
    struct Rec: Codable {
        var info: JobInfo
        var pidStart: Double?
        var managed = false
        var points: [[Double]] = []      // [unix ts, done]
        var lastBeat: Date?
        var logMTime: Double?
        var goneSince: Date?
        var members: [Int32] = []
    }

    private(set) var recs: [String: Rec] = [:]
    private let store: Store

    init(store: Store) {
        self.store = store
        for json in store.loadJobs() {
            if let r = try? JSON.decoder.decode(Rec.self, from: Data(json.utf8)) { recs[r.info.name] = r }
        }
    }

    private func persist(_ name: String) {
        if let r = recs[name], let d = try? JSON.encoder.encode(r), let s = String(data: d, encoding: .utf8) {
            store.saveJob(name: name, json: s)
        }
    }

    var jobs: [JobInfo] {
        recs.values.map(\.info).sorted {
            ($0.isFinished ? 1 : 0, $0.group, $0.registeredAt) < ($1.isFinished ? 1 : 0, $1.group, $1.registeredAt)
        }
    }

    func job(_ name: String) -> JobInfo? { recs[name]?.info }

    /// Registered roots for process grouping (running jobs only).
    var roots: [RegisteredRoot] {
        recs.values.compactMap { r in
            guard let pid = r.info.pid, !r.info.isFinished else { return nil }
            return RegisteredRoot(job: r.info.name, group: r.info.group, pid: pid)
        }
    }

    // MARK: API mutations

    func register(_ req: RegisterRequest, table: ProcessTable) throws -> (JobInfo, JobEvent) {
        let name = req.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { throw ExprError(message: "job name must be non-empty and contain no '/'") }
        var info = JobInfo(name: name, group: req.group ?? "default")
        info.log = req.log.map { ($0 as NSString).expandingTildeInPath }
        info.logRegex = req.logRegex
        info.total = req.total
        info.after = req.after
        info.staleAfterSeconds = req.staleAfter
        var rec = Rec(info: info)
        rec.managed = req.managed ?? false
        if let pid = req.pid {
            guard let e = table.entries[pid] else { throw ExprError(message: "no process with pid \(pid)") }
            rec.info.pid = pid
            rec.pidStart = e.start
            rec.info.startedAt = Date(timeIntervalSince1970: e.start)
            rec.info.command = req.command ?? table.commandLine(pid)
            rec.info.state = "running"
        } else {
            rec.info.command = req.command
            rec.info.state = "queued"
        }
        if let t = req.total, t > 0 { rec.info.done = 0 }
        recs[name] = rec
        persist(name)
        let msg = "registered \(name) in \(rec.info.group)" + (req.pid.map { " (pid \($0))" } ?? " (queued" + (req.after.map { " after \($0)" } ?? "") + ")")
        return (rec.info, JobEvent(type: "job.registered", subject: name, message: msg))
    }

    func progress(_ name: String, _ p: ProgressRequest) throws -> JobInfo {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        var done = p.done, total = p.total
        if let s = p.progress {
            let parts = s.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            done = parts.first ?? nil
            if parts.count > 1 { total = parts[1] }
        }
        let now = Date()
        if let t = total { r.info.total = t }
        if let d = done {
            r.info.done = d
            r.info.lastProgressAt = now
            r.points.append([now.timeIntervalSince1970, d])
            if r.points.count > 400 { r.points.removeFirst(r.points.count - 400) }
        }
        if let n = p.note { r.info.note = n }
        r.info.lastActivityAt = now
        recs[name] = r
        persist(name)
        return r.info
    }

    func beat(_ name: String) throws -> JobInfo {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        r.lastBeat = Date()
        r.info.lastActivityAt = r.lastBeat
        recs[name] = r
        persist(name)
        return r.info
    }

    /// Reported by `forkcast run` when the child exits.
    func exit(_ name: String, _ e: ExitRequest) throws -> (JobInfo, JobEvent) {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        r.info.exitCode = e.code
        r.info.exitSignal = e.signal
        r.info.endedAt = Date()
        if let sig = e.signal, sig != 0 { r.info.state = "killed" }
        else { r.info.state = (e.code ?? 0) == 0 ? "done-ok" : "done-error" }
        recs[name] = r
        persist(name)
        return (r.info, finishEvent(r.info))
    }

    func forget(_ name: String) -> Bool {
        guard recs.removeValue(forKey: name) != nil else { return false }
        store.deleteJob(name)
        return true
    }

    /// Attach a pid to a queued job (used by `forkcast run --after`).
    func start(_ name: String, pid: Int32, table: ProcessTable) throws -> JobInfo {
        guard var r = recs[name], let e = table.entries[pid] else { throw ExprError(message: "unknown job or pid") }
        r.info.pid = pid
        r.pidStart = e.start
        r.info.startedAt = Date(timeIntervalSince1970: e.start)
        r.info.command = r.info.command ?? table.commandLine(pid)
        r.info.state = "running"
        r.info.note = nil
        recs[name] = r
        persist(name)
        return r.info
    }

    func markCrashed(pid: Int32, report: String) -> JobEvent? {
        guard let hit = recs.first(where: { $0.value.info.pid == pid || $0.value.members.contains(pid) }) else { return nil }
        let name = hit.key
        var r = hit.value
        let root = r.info.pid == pid
        r.info.note = "crash report: \((report as NSString).lastPathComponent)"
        if root && !r.info.isFinished {
            r.info.state = "done-error"
            r.info.endedAt = Date()
        }
        recs[name] = r
        persist(name)
        return JobEvent(type: "job.crashed", subject: name,
                        message: "\(name): process \(pid) crashed (\((report as NSString).lastPathComponent))")
    }

    private func finishEvent(_ i: JobInfo) -> JobEvent {
        let dur = i.startedAt.map { fmtDuration((i.endedAt ?? Date()).timeIntervalSince($0)) } ?? "?"
        switch i.state {
        case "done-ok": return JobEvent(type: "job.finished", subject: i.name, message: "\(i.name) finished OK after \(dur)")
        case "killed": return JobEvent(type: "job.failed", subject: i.name, message: "\(i.name) was killed (signal \(i.exitSignal ?? 0)) after \(dur)")
        case "done-error": return JobEvent(type: "job.failed", subject: i.name, message: "\(i.name) failed (exit \(i.exitCode.map(String.init) ?? "?")) after \(dur)")
        default: return JobEvent(type: "job.exited", subject: i.name, message: "\(i.name) exited after \(dur) (exit code unknown)")
        }
    }

    // MARK: Per-tick update

    func update(table: ProcessTable, groups: [String: GroupInfo], members: [String: [Int32]],
                staleMinutes: Double, now: Date) -> [JobEvent] {
        var events: [JobEvent] = []
        for name in Array(recs.keys) {
            guard var r = recs[name] else { continue }
            let before = r.info.state
            var changed = false

            // Progress from the log file.
            if let log = r.info.log,
               let attrs = try? FileManager.default.attributesOfItem(atPath: log),
               let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
               mtime != r.logMTime {
                r.logMTime = mtime
                r.info.lastActivityAt = max(r.info.lastActivityAt ?? .distantPast, Date(timeIntervalSince1970: mtime))
                if let (d, t) = Self.progressFromLog(log, regex: r.info.logRegex), d != r.info.done {
                    r.info.done = d
                    if let t { r.info.total = t }
                    r.info.lastProgressAt = Date(timeIntervalSince1970: mtime)
                    r.points.append([mtime, d])
                    if r.points.count > 400 { r.points.removeFirst(r.points.count - 400) }
                }
                changed = true
            }

            if !r.info.isFinished, let pid = r.info.pid {
                let alive = table.entries[pid].map { abs($0.start - (r.pidStart ?? $0.start)) < 1 } ?? false
                if alive {
                    r.goneSince = nil
                    let g = groups["job:" + name]
                    r.members = members["job:" + name] ?? [pid]
                    if let g {
                        r.info.cost.cpuPct = g.cpuPct
                        r.info.cost.memMB = g.memMB
                        r.info.cost.watts = g.watts
                    }
                    let paused = g?.paused ?? false
                    r.info.pausedNote = g?.pausedNote
                    let last = [r.info.lastActivityAt, r.info.lastProgressAt, r.lastBeat, r.info.startedAt]
                        .compactMap { $0 }.max() ?? r.info.registeredAt
                    r.info.secondsSinceActivity = now.timeIntervalSince(last)
                    let hasSource = r.info.log != nil || r.info.lastProgressAt != nil || r.lastBeat != nil
                    let limit = r.info.staleAfterSeconds ?? staleMinutes * 60   // 0 = never stale
                    if paused { r.info.state = "paused" }
                    else if hasSource && limit > 0 && now.timeIntervalSince(last) > limit { r.info.state = "stale" }
                    else { r.info.state = "running" }
                } else {
                    if r.managed, r.goneSince == nil { r.goneSince = now }
                    // Give `forkcast run` a few seconds to report the exit code.
                    if !r.managed || now.timeIntervalSince(r.goneSince ?? now) > 15 {
                        if let t = r.info.total, let d = r.info.done, d >= t { r.info.state = "done-ok" }
                        else { r.info.state = "exited" }
                        r.info.endedAt = now
                        r.info.cost = JobCost()
                    }
                }
            } else if r.info.state == "queued", let after = r.info.after, let a = recs[after], a.info.isFinished {
                r.info.note = "waiting to start (\(after) finished)"
            }

            // Rate and ETA.
            if let (rate, basis) = Self.rate(r.points, now: now) {
                r.info.ratePerHour = rate
                if let t = r.info.total, let d = r.info.done, rate > 0, !r.info.isFinished {
                    r.info.etaSeconds = max(0, (t - d) / rate * 3600)
                    r.info.etaBasis = "\(fmtNum(d))/\(fmtNum(t)) at \(fmtNum(rate))/h (\(basis))"
                }
            }
            if r.info.isFinished { r.info.etaSeconds = nil; r.info.secondsSinceActivity = nil }

            if r.info.state != before {
                changed = true
                if r.info.isFinished { events.append(finishEvent(r.info)) }
                else if r.info.state == "stale" {
                    events.append(JobEvent(type: "job.stale", subject: name,
                                           message: "\(name): no progress or log output for \(fmtDuration(r.info.secondsSinceActivity ?? 0))"))
                } else if before == "stale" && r.info.state == "running" {
                    events.append(JobEvent(type: "job.recovered", subject: name, message: "\(name) is making progress again"))
                }
            }
            recs[name] = r
            if changed { persist(name) }
        }
        return events
    }

    /// Items/hour over the last 30 minutes (or since the first point).
    static func rate(_ pts: [[Double]], now: Date) -> (Double, String)? {
        guard let last = pts.last, pts.count >= 2 else { return nil }
        let windowStart = now.timeIntervalSince1970 - 1800
        let first = pts.first(where: { $0[0] >= windowStart && $0[0] < last[0] }) ?? pts[max(0, pts.count - 2)]
        let dt = last[0] - first[0]
        guard dt > 1 else { return nil }
        let r = (last[1] - first[1]) / dt * 3600
        return (r, first[0] >= windowStart ? "last \(fmtDuration(dt))" : "since \(fmtDuration(now.timeIntervalSince1970 - first[0])) ago")
    }

    static func progressFromLog(_ path: String, regex: String?) -> (Double, Double?)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let off = size > 16384 ? size - 16384 : 0
        try? fh.seek(toOffset: off)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        guard let re = try? NSRegularExpression(pattern: regex ?? "(\\d+)\\s*/\\s*(\\d+)") else { return nil }
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).reversed()
        for line in lines.prefix(200) {
            let s = String(line)
            guard let m = re.matches(in: s, range: NSRange(s.startIndex..., in: s)).last else { continue }
            func grp(_ i: Int) -> Double? {
                guard i < m.numberOfRanges, let r = Range(m.range(at: i), in: s) else { return nil }
                return Double(s[r])
            }
            if let d = grp(1) { return (d, grp(2)) }
        }
        return nil
    }

    // MARK: Group ETAs

    var groupNames: [String] { Array(Set(recs.values.map(\.info.group))).sorted() }

    func eta(group g: String, now: Date = Date()) -> GroupETA? {
        let js = recs.values.map(\.info).filter { $0.group == g }
        guard !js.isEmpty else { return nil }
        let running = js.filter { !$0.isFinished && $0.state != "queued" }
        let queued = js.filter { $0.state == "queued" }
        var e = GroupETA(group: g, jobs: js.map(\.name).sorted(), running: running.count,
                         finished: js.filter(\.isFinished).count, queued: queued.count, basis: "")
        let rates = js.compactMap(\.ratePerHour).filter { $0 > 0 }
        e.throughputPerHour = running.compactMap(\.ratePerHour).reduce(0, +)
        let avgRate = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)

        var finishAt: [String: Double] = [:]
        var basis: [String] = []
        var unknown: [String] = []
        for j in running {
            if let s = j.etaSeconds {
                finishAt[j.name] = s
                basis.append("\(j.name): \(fmtDuration(s)) — \(j.etaBasis ?? "")")
            } else { unknown.append(j.name) }
        }
        for j in js where j.isFinished { finishAt[j.name] = 0 }
        // Queued jobs: start when their predecessor finishes, run at the group's average per-job rate.
        var pending = queued
        var guardLoop = 0
        while !pending.isEmpty && guardLoop < 50 {
            guardLoop += 1
            var progressed = false
            for (i, j) in pending.enumerated().reversed() {
                let start: Double? = j.after.map { finishAt[$0] } ?? 0
                guard let st = start else { continue }
                if let t = j.total, let r = avgRate, r > 0 {
                    finishAt[j.name] = st + t / r * 3600
                    basis.append("\(j.name) (queued after \(j.after ?? "—")): \(fmtDuration(finishAt[j.name]!)) assuming the group's average \(fmtNum(r))/h")
                } else { unknown.append(j.name) }
                pending.remove(at: i)
                progressed = true
            }
            if !progressed { unknown.append(contentsOf: pending.map(\.name)); break }
        }
        if let mx = finishAt.values.max(), unknown.isEmpty || mx > 0, !(running.isEmpty && queued.isEmpty) {
            e.etaSeconds = mx
            e.etaDate = now.addingTimeInterval(mx)
        }
        if running.isEmpty && queued.isEmpty { basis = ["all \(js.count) jobs finished"] }
        if !unknown.isEmpty { basis.append("no ETA for: \(unknown.joined(separator: ", ")) (needs --total and progress)") }
        e.basis = basis.joined(separator: "; ")
        return e
    }
}

// MARK: - Formatting helpers (shared with the UI)

func fmtDuration(_ s: Double) -> String {
    let s = max(0, s)
    if s < 90 { return "\(Int(s))s" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h\(String(format: "%02d", Int(s.truncatingRemainder(dividingBy: 3600) / 60)))m" }
    return "\(Int(s / 86400))d\(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h"
}

func fmtNum(_ v: Double) -> String {
    if abs(v) >= 100 || v == v.rounded() { return String(Int(v.rounded())) }
    return String(format: "%.1f", v)
}
