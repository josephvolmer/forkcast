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
    var cwd: String?         // caller's working directory: relative --log paths are resolved against it
    var managed: Bool?       // started by `forkcast run` (it will report the exit code)
    var staleAfter: Double?  // seconds without activity before the job counts as stale; 0 = never
}

struct ProgressRequest: Codable {
    var done: Double?
    var total: Double?
    var note: String?
    var progress: String?    // "412/1721" alternative
    var log: String?         // attach (or change) a log file to read progress from
    var logRegex: String?
    var cwd: String?
    var staleAfter: Double?
}

struct ExitRequest: Codable {
    var code: Int32?
    var signal: Int32?
    var run: Int?            // the run this exit belongs to (an older run may exit after a new one registered)
}

struct StateRequest: Codable {
    var state: String        // waiting | running
    var on: String?          // what it waits for: a job name or "pid N"
}

struct JobEvent {
    let type: String
    let subject: String?
    let message: String
}

/// Resolves a log path from a client: ~ is expanded and relative paths are taken from the client's cwd.
func resolveClientPath(_ p: String, cwd: String?) -> String {
    let t = (p as NSString).expandingTildeInPath
    if t.hasPrefix("/") { return (t as NSString).standardizingPath }
    guard let cwd, cwd.hasPrefix("/") else { return t }
    return ((cwd as NSString).appendingPathComponent(t) as NSString).standardizingPath
}

/// Registered jobs: what a process *is* and how far along it is.
/// Keyed by name: registering a name again starts a new run and keeps the old one in `history`.
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
        var history: [JobRunSummary]? = nil
    }

    static let historyLimit = 10
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

    /// Job names currently marked as waiting (excluded from stale alerts and cost cards).
    var waitingJobs: Set<String> { Set(recs.values.filter { $0.info.state == "waiting" }.map(\.info.name)) }

    /// The job whose process tree contains the first of these pids (most specific first).
    func jobContaining(_ pids: [Int32]) -> String? {
        for p in pids {
            if let hit = recs.values.first(where: { !$0.info.isFinished && ($0.info.pid == p || $0.members.contains(p)) }) {
                return hit.info.name
            }
        }
        for p in pids {   // a job that just ended (the crash may have ended it)
            if let hit = recs.values.first(where: { $0.info.pid == p || $0.members.contains(p) }) { return hit.info.name }
        }
        return nil
    }

    // MARK: API mutations

    func register(_ req: RegisterRequest, table: ProcessTable) throws -> (JobInfo, JobEvent) {
        let name = req.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { throw ExprError(message: "job name must be non-empty and contain no '/'") }
        var info = JobInfo(name: name, group: req.group ?? "default")
        info.cwd = req.cwd
        info.log = req.log.map { resolveClientPath($0, cwd: req.cwd) }
        info.logMissing = info.log.map { !FileManager.default.fileExists(atPath: $0) }
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

        // Same name again: this is a new run; the previous one moves to history.
        var supersedes = ""
        if let old = recs[name] {
            let oldRun = old.info.run ?? 1
            rec.info.run = oldRun + 1
            rec.history = Array(([JobRunSummary(old.info)] + (old.history ?? [])).prefix(Self.historyLimit))
            supersedes = old.info.isFinished
                ? " — replaces run #\(oldRun) (\(old.info.displayState))"
                : " — replaces run #\(oldRun), which was still \(old.info.displayState) and is no longer tracked"
        } else {
            rec.info.run = 1
        }
        rec.info.previousRuns = rec.history
        recs[name] = rec
        persist(name)
        let runTag = (rec.info.run ?? 1) > 1 ? " run #\(rec.info.run!)" : ""
        let msg = "registered \(name)\(runTag) in \(rec.info.group)"
            + (req.pid.map { " (pid \($0))" } ?? " (queued" + (req.after.map { " after \($0)" } ?? "") + ")") + supersedes
        return (rec.info, JobEvent(type: "job.registered", subject: name, message: msg))
    }

    func progress(_ name: String, _ p: ProgressRequest) throws -> JobInfo {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        var done = p.done, total = p.total
        if let s = p.progress, !s.isEmpty {
            let parts = s.split(separator: "/").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.allSatisfy({ $0 != nil }) else { throw ExprError(message: "progress must look like 412 or 412/1721") }
            done = parts.first ?? nil
            if parts.count > 1 { total = parts[1] }
        }
        let now = Date()
        if let t = total {
            r.info.total = t
            if r.info.done == nil, t > 0 { r.info.done = 0 }
        }
        if let l = p.log {
            r.info.log = l.isEmpty ? nil : resolveClientPath(l, cwd: p.cwd ?? r.info.cwd)
            r.info.logMissing = r.info.log.map { !FileManager.default.fileExists(atPath: $0) }
            r.logMTime = nil      // re-read it on the next tick
        }
        if let re = p.logRegex {
            guard re.isEmpty || (try? NSRegularExpression(pattern: re)) != nil else { throw ExprError(message: "invalid --regex") }
            r.info.logRegex = re.isEmpty ? nil : re
            r.logMTime = nil
        }
        if let st = p.staleAfter { r.info.staleAfterSeconds = st }
        if let d = done {
            r.info.done = d
            r.info.lastProgressAt = now
            r.points.append([now.timeIntervalSince1970, d])
            if r.points.count > 400 { r.points.removeFirst(r.points.count - 400) }
        }
        if let n = p.note { r.info.note = n }
        if done != nil || p.note != nil { r.info.lastActivityAt = now }
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

    /// `forkcast state NAME waiting --on X` / `forkcast state NAME running`.
    func setState(_ name: String, _ req: StateRequest) throws -> (JobInfo, JobEvent) {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        guard !r.info.isFinished else { throw ExprError(message: "\(name) has already ended") }
        let now = Date()
        switch req.state.lowercased() {
        case "waiting":
            let on = req.on.map(Self.normalizeTarget) ?? "something"
            r.info.waitingOn = on
            r.info.state = r.info.state == "paused" ? "paused" : "waiting"
            r.info.lastActivityAt = now
            recs[name] = r
            persist(name)
            return (r.info, JobEvent(type: "job.waiting", subject: name, message: "\(name) is waiting for \(on)"))
        case "running":
            r.info.waitingOn = nil
            if r.info.state == "waiting" { r.info.state = "running" }
            r.info.lastActivityAt = now
            recs[name] = r
            persist(name)
            return (r.info, JobEvent(type: "job.ready", subject: name, message: "\(name) is running again (no longer waiting)"))
        default:
            throw ExprError(message: "state must be 'waiting' or 'running'")
        }
    }

    /// "1234" or "pid 1234" → "pid 1234" when no job has that name; anything else is a job name.
    static func normalizeTarget(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("pid ") || t.lowercased().hasPrefix("pid:") {
            return "pid " + t.dropFirst(4).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    /// Whether what a waiting job waits for has ended (a job that finished or doesn't exist, or a dead pid).
    private func targetEnded(_ on: String) -> (Bool, String) {
        if on.hasPrefix("pid "), let pid = Int32(on.dropFirst(4)) {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            return (!alive, "pid \(pid) exited")
        }
        if let pid = Int32(on), recs[on] == nil {
            let alive = kill(pid, 0) == 0 || errno == EPERM
            return (!alive, "pid \(pid) exited")
        }
        guard let j = recs[on] else { return (false, "") }   // unknown target: wait until told otherwise
        return (j.info.isFinished, "\(on) \(j.info.displayState)")
    }

    /// Reported by `forkcast run` when the child exits. `current` is false when an older run exited.
    func exit(_ name: String, _ e: ExitRequest) throws -> (JobInfo, JobEvent, current: Bool) {
        guard var r = recs[name] else { throw ExprError(message: "unknown job '\(name)'") }
        let state: String
        if let sig = e.signal, sig != 0 { state = "killed" } else { state = (e.code ?? 0) == 0 ? "done-ok" : "done-error" }
        if let run = e.run, let cur = r.info.run, run != cur {
            // An earlier run ended after this name was registered again: record it in history only.
            if var h = r.history, let i = h.firstIndex(where: { $0.run == run }) {
                h[i].state = state; h[i].exitCode = e.code; h[i].endedAt = Date()
                r.history = h
                r.info.previousRuns = h
            }
            recs[name] = r
            persist(name)
            let what = state == "killed" ? "was killed (signal \(e.signal ?? 0))" : "exited with code \(e.code.map(String.init) ?? "?")"
            return (r.info, JobEvent(type: "job.run_ended", subject: name,
                                     message: "\(name) run #\(run) \(what) (superseded by run #\(cur))"), false)
        }
        r.info.exitCode = e.code
        r.info.exitSignal = e.signal
        r.info.endedAt = Date()
        r.info.state = state
        r.info.waitingOn = nil
        recs[name] = r
        persist(name)
        return (r.info, finishEvent(r.info), true)
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

    func markCrashed(job name: String, pid: Int32, summary: String) -> JobEvent? {
        guard var r = recs[name] else { return nil }
        let root = r.info.pid == pid
        r.info.note = "crash: \(summary)"
        if root && !r.info.isFinished {
            r.info.state = "done-error"
            r.info.endedAt = Date()
        }
        recs[name] = r
        persist(name)
        return JobEvent(type: "job.crashed", subject: name, message: "crash in \(name): \(summary)")
    }

    private func finishEvent(_ i: JobInfo) -> JobEvent {
        let dur = i.startedAt.map { fmtDuration((i.endedAt ?? Date()).timeIntervalSince($0)) } ?? "?"
        let run = (i.run ?? 1) > 1 ? " (run #\(i.run!))" : ""
        switch i.state {
        case "done-ok": return JobEvent(type: "job.finished", subject: i.name, message: "\(i.name)\(run) finished OK after \(dur)")
        case "killed": return JobEvent(type: "job.failed", subject: i.name, message: "\(i.name)\(run) was killed (signal \(i.exitSignal ?? 0)) after \(dur)")
        case "done-error": return JobEvent(type: "job.failed", subject: i.name, message: "\(i.name)\(run) failed (exit \(i.exitCode.map(String.init) ?? "?")) after \(dur)")
        default: return JobEvent(type: "job.exited", subject: i.name, message: "\(i.name)\(run) ended after \(dur)")
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

            // Records from before paths were resolved at registration: resolve against the job's own cwd.
            if let log = r.info.log, !log.hasPrefix("/"), let pid = r.info.pid, !r.info.isFinished,
               let cwd = r.info.cwd ?? table.cwd(pid) {
                r.info.log = resolveClientPath(log, cwd: cwd)
                r.info.cwd = cwd
                r.logMTime = nil
                changed = true
            }
            // Progress from the log file.
            if let log = r.info.log {
                let attrs = try? FileManager.default.attributesOfItem(atPath: log)
                let missing = attrs == nil
                if r.info.logMissing != missing { r.info.logMissing = missing; changed = true }
                if let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970, mtime != r.logMTime {
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
                    // Waiting for another job or pid: done once that ends.
                    if let on = r.info.waitingOn {
                        let (ended, why) = targetEnded(on)
                        if ended {
                            r.info.waitingOn = nil
                            r.info.lastActivityAt = now
                            events.append(JobEvent(type: "job.ready", subject: name, message: "\(name) done waiting (\(why))"))
                            changed = true
                        }
                    }
                    let paused = g?.paused ?? false
                    r.info.pausedNote = g?.pausedNote
                    let last = [r.info.lastActivityAt, r.info.lastProgressAt, r.lastBeat, r.info.startedAt]
                        .compactMap { $0 }.max() ?? r.info.registeredAt
                    r.info.secondsSinceActivity = now.timeIntervalSince(last)
                    // A log that doesn't exist (yet) is not evidence of a stall.
                    let logSource = r.info.log != nil && r.info.logMissing != true
                    let hasSource = logSource || r.info.lastProgressAt != nil || r.lastBeat != nil
                    let limit = r.info.staleAfterSeconds ?? staleMinutes * 60   // 0 = never stale
                    if paused { r.info.state = "paused" }
                    else if r.info.waitingOn != nil { r.info.state = "waiting" }
                    else if hasSource && limit > 0 && now.timeIntervalSince(last) > limit { r.info.state = "stale" }
                    else { r.info.state = "running" }
                } else {
                    if r.managed, r.goneSince == nil { r.goneSince = now }
                    // Give `forkcast run` a few seconds to report the exit code.
                    if !r.managed || now.timeIntervalSince(r.goneSince ?? now) > 15 {
                        if let t = r.info.total, let d = r.info.done, d >= t { r.info.state = "done-ok" }
                        else { r.info.state = "exited" }
                        r.info.endedAt = now
                        r.info.waitingOn = nil
                        r.info.cost = JobCost()
                    }
                }
            } else if r.info.state == "queued", let after = r.info.after, let a = recs[after], a.info.isFinished {
                r.info.note = "waiting to start (\(after) finished)"
            }

            // Rate and ETA. An ETA is only shown while the job is actually progressing.
            if let (rate, basis) = Self.rate(r.points, now: now) {
                r.info.ratePerHour = rate
                if let t = r.info.total, let d = r.info.done, !r.info.isFinished {
                    if rate > 0 {
                        r.info.etaSeconds = max(0, (t - d) / rate * 3600)
                        r.info.etaBasis = "\(fmtNum(d))/\(fmtNum(t)) at \(fmtNum(rate))/h (\(basis))"
                    } else {
                        r.info.etaSeconds = nil
                        r.info.etaBasis = "no progress \(basis): no ETA until it moves again"
                    }
                }
            } else if r.info.total == nil {
                r.info.etaSeconds = nil
                r.info.etaBasis = nil
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
        // No progress for much longer than this job's usual reporting interval: the current rate is 0.
        let recent = pts.suffix(10).map { $0[0] }
        let gaps = zip(recent.dropFirst(), recent).map { $0 - $1 }.sorted()
        let typical = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
        let quiet = now.timeIntervalSince1970 - last[0]
        if quiet > max(1800, typical * 3) { return (0, "for \(fmtDuration(quiet))") }
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
        var seen = Set<String>()
        unknown = unknown.filter { seen.insert($0).inserted }
        e.jobsWithoutETA = unknown
        if let mx = finishAt.values.max(), mx > 0 || unknown.isEmpty, !(running.isEmpty && queued.isEmpty) {
            e.etaSeconds = mx
            e.etaDate = now.addingTimeInterval(mx)
            e.etaIsLowerBound = !unknown.isEmpty
        }
        if running.isEmpty && queued.isEmpty { basis = ["all \(js.count) jobs finished"] }
        if !unknown.isEmpty {
            if e.etaIsLowerBound { basis.insert("at least this long: \(unknown.count) job\(unknown.count == 1 ? "" : "s") without an ETA", at: 0) }
            basis.append("no ETA for: \(unknown.joined(separator: ", ")) (needs a total and progress: `forkcast progress NAME --total N`, or --log/--regex)")
        }
        e.basis = basis.joined(separator: "; ")
        return e
    }

    static func etaText(_ e: GroupETA) -> String {
        guard let s = e.etaSeconds else {
            return e.jobsWithoutETA.isEmpty ? "–" : "– (\(e.jobsWithoutETA.count) job\(e.jobsWithoutETA.count == 1 ? "" : "s") without ETA)"
        }
        return e.etaIsLowerBound
            ? "≥ \(fmtDuration(s)), \(e.jobsWithoutETA.count) job\(e.jobsWithoutETA.count == 1 ? "" : "s") without ETA"
            : fmtDuration(s)
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
