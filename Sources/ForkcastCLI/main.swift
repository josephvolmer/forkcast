import Darwin
import Foundation
import ForkcastCore

// forkcast — command-line client for Forkcast.app. All help text lives in Help.swift.

func die(_ msg: String, _ code: Int32 = 1) -> Never {
    fputs("forkcast: \(msg)\n", stderr)
    exit(code)
}

// MARK: - Argument parsing (strict: unknown options are errors)

struct Parsed {
    var positional: [String] = []
    var values: [String: String] = [:]
    var flags = Set<String>()
    var passthrough: [String] = []      // after `--` (forkcast run)
    func value(_ k: String) -> String? { values[k] }
    func has(_ k: String) -> Bool { flags.contains(k) }
}

func parse(_ cmd: Command, _ argv: [String]) -> Parsed {
    var p = Parsed()
    var valueOpts = Set<String>(), boolOpts = Set<String>()
    for o in cmd.options {
        let name = String(o.flag.split(separator: " ")[0])
        if o.flag.contains(" ") { valueOpts.insert(name) } else { boolOpts.insert(name) }
    }
    var i = 0
    while i < argv.count {
        let a = argv[i]
        if a == "--" { p.passthrough = Array(argv[(i + 1)...]); break }
        if a == "-h" || a == "--help" { print(commandText(cmd)); exit(0) }
        if a.hasPrefix("--") {
            var key = a, inline: String?
            if let eq = a.firstIndex(of: "=") { key = String(a[..<eq]); inline = String(a[a.index(after: eq)...]) }
            if valueOpts.contains(key) {
                if let v = inline { p.values[key] = v }
                else {
                    guard i + 1 < argv.count else { die("\(key) needs a value — see `forkcast \(cmd.name) --help`", 2) }
                    p.values[key] = argv[i + 1]
                    i += 1
                }
            } else if boolOpts.contains(key) {
                p.flags.insert(key)
            } else {
                let known = (valueOpts.union(boolOpts)).sorted().joined(separator: " ")
                die("unknown option \(key) for `\(cmd.name)`" + (known.isEmpty ? "" : " (options: \(known))") + " — see `forkcast \(cmd.name) --help`", 2)
            }
        } else {
            p.positional.append(a)
        }
        i += 1
    }
    return p
}

func need(_ p: Parsed, _ idx: Int, _ what: String, _ cmd: Command) -> String {
    guard idx < p.positional.count else { die("missing \(what)\nusage: \(cmd.synopsis)", 2) }
    return p.positional[idx]
}

// MARK: - HTTP client

struct Client {
    let base: String
    let token: String

    static func readInfo() -> APIConfig.Info? {
        guard let d = try? Data(contentsOf: APIConfig.file) else { return nil }
        return try? JSONDecoder().decode(APIConfig.Info.self, from: d)
    }

    /// Connects to the running app; starts it (in the background) if needed.
    static func connect(launch: Bool = true) -> Client? {
        if let info = readInfo() {
            let c = Client(base: "http://127.0.0.1:\(info.port)", token: info.token)
            if c.ping() { return c }
        }
        guard launch else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-b", "local.forkcast"]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        for _ in 0..<40 {
            usleep(250_000)
            if let info = readInfo() {
                let c = Client(base: "http://127.0.0.1:\(info.port)", token: info.token)
                if c.ping() { return c }
            }
        }
        return nil
    }

    static func load() -> Client {
        guard let c = connect() else {
            die("can't reach Forkcast and couldn't start it. Is /Applications/Forkcast.app installed?", 3)
        }
        return c
    }

    func ping() -> Bool { raw("GET", "/metrics", timeout: 2).0 == 200 }

    func raw(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, timeout: Double = 30) -> (Int, Data) {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data) = (0, Data())
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, err in
            result = err != nil ? (0, Data((err?.localizedDescription ?? "").utf8)) : ((resp as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }

    func call(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil, timeout: Double = 30) -> (Int, Data) {
        let r = raw(method, path, query: query, body: body, timeout: timeout)
        if r.0 == 0 { die("lost connection to Forkcast at \(base) (\(String(data: r.1, encoding: .utf8) ?? ""))", 3) }
        return r
    }

    func get<T: Decodable>(_ path: String, _ t: T.Type, query: [String: String] = [:], timeout: Double = 30) -> (T, Data) {
        let (code, data) = call("GET", path, query: query, timeout: timeout)
        return (decodeOrDie(code, data, t), data)
    }

    func send<T: Decodable>(_ method: String, _ path: String, _ body: Encodable?, _ t: T.Type) -> (T, Data) {
        let b = body.flatMap { try? JSON.encoder.encode(AnyEncodable($0)) }
        let (code, data) = call(method, path, body: b)
        return (decodeOrDie(code, data, t), data)
    }
}

struct AnyEncodable: Encodable {
    let v: Encodable
    init(_ v: Encodable) { self.v = v }
    func encode(to e: Encoder) throws { try v.encode(to: e) }
}

func decodeOrDie<T: Decodable>(_ code: Int, _ data: Data, _ t: T.Type) -> T {
    if code >= 400 {
        let msg = (try? JSON.decoder.decode(APIError.self, from: data))?.error ?? String(data: data, encoding: .utf8) ?? "error"
        die(msg, code == 400 ? 2 : 1)
    }
    do { return try JSON.decoder.decode(t, from: data) } catch { die("unexpected response: \(error)") }
}

func path(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s }
func printJSON(_ d: Data) { print(String(data: d, encoding: .utf8) ?? "") }

// MARK: - Formatting

func f1(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
func f0(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "–" }
func dur(_ s: Double?) -> String {
    guard let s, s.isFinite else { return "–" }
    if s < 90 { return "\(Int(s))s" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86400 { return "\(Int(s / 3600))h\(String(format: "%02d", Int(s.truncatingRemainder(dividingBy: 3600) / 60)))m" }
    return "\(Int(s / 86400))d\(Int(s.truncatingRemainder(dividingBy: 86400) / 3600))h"
}
func pad(_ s: String, _ n: Int) -> String { s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count) }
let timeFmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d HH:mm:ss"; return f }()

func printStatus(_ s: Status) {
    let p = s.power
    var line = "Power    "
    if p.onAC { line += "Charger \(f0(p.chargerW)) W · " }
    line += "Using \(f1(p.drawW)) W"
    if let n = p.netBatteryW { line += " · \(n >= 0 ? "+" : "")\(f1(n)) W \(n >= 0 ? "into" : "out of") battery" }
    if let pct = p.batteryPct { line += " · \(pct)%" }
    if let h = p.hoursToFull { line += " · full in ~\(dur(h * 3600))" }
    if let h = p.hoursToEmpty { line += " · empty in ~\(dur(h * 3600))" }
    print(line)
    print("         CPU \(f1(p.cpuW)) W · GPU \(f1(p.gpuW)) W · memory/SoC \(f1((p.socW ?? 0) + (p.aneW ?? 0))) W · display & other \(f1(p.otherW)) W")
    let c = s.cpu
    print("CPU      \(f1(c.busyCores))/\(c.totalCores) cores busy · P \(f0(c.pBusyPct))% · E \(f0(c.eBusyPct))% · free (p90) \(f1(c.freeCoresP90)) · thermal \(c.thermal)\(c.throttling ? " · THROTTLING" : "")")
    let m = s.memory
    print("Memory   pressure \(m.pressure) · \(f1(m.usedGB))/\(f0(m.totalGB)) GB used · compressed \(f1(m.compressedGB)) GB · swap \(f1(m.swapUsedGB)) GB\(m.swapGrowthGBPerHour.map { " (\($0 >= 0 ? "+" : "")\(f1($0)) GB/h)" } ?? "") · headroom ~\(f1(m.headroomGB)) GB")
    let d = s.disk
    var dl = "Disk     \(f0(d.freeGB)) GB free now, \(f0(d.freeInclPurgeableGB)) GB incl. purgeable (macOS estimate"
    if let n = d.tmLocalSnapshots { dl += "; \(n) TM local snapshot\(n == 1 ? "" : "s")" }
    dl += ")"
    if let t = d.trendGBPerHour { dl += " · \(t >= 0 ? "+" : "")\(f1(t)) GB/h" }
    if let st = d.lastStep { dl += " (excl. a one-off \(st.deltaGB >= 0 ? "+" : "")\(f1(st.deltaGB)) GB step at \(shortTime.string(from: st.at)))" }
    if let h = d.hoursToFloor { dl += " · hits \(f0(d.floorGB)) GB in ~\(dur(h * 3600))" }
    dl += " · I/O r \(f1(d.readMBs)) w \(f1(d.writeMBs)) MB/s"
    if let t = d.topIOProcess { dl += " (top: \(t))" }
    print(dl)
    for v in s.volumes { print("Volume   \(v.name): \(v.mounted ? "\(f0(v.freeGB)) GB free" : "NOT MOUNTED")\(v.watched ? " · watched" : "")") }
    let n = s.network
    print("Network  ↓\(f1(n.downMBs)) ↑\(f1(n.upMBs)) MB/s · today ↓\(f1(n.todayDownGB)) ↑\(f1(n.todayUpGB)) GB\(n.topProcess.map { " · top: \($0)" } ?? "")")
    for f in s.folders { print("Folder   \(f.path): \(f1(f.sizeGB)) GB\(f.growthGBPerHour.map { " (\($0 >= 0 ? "+" : "")\(f1($0)) GB/h)" } ?? "")") }
    print("Headroom \(s.headroom.verdict)")
    for a in s.alerts { print("\(a.severity == "info" ? "NOTE " : "ALERT")    [\(a.severity)] \(a.message)") }
    print("\nTop groups:")
    for g in s.topGroups.prefix(8) {
        print("  \(pad(g.label, 44)) \(pad(f1(g.watts) + " W", 8)) \(pad(f0(g.cpuPct) + "%", 6)) \(pad(f0(g.memMB) + " MB", 9)) \(g.procCount) proc\(g.paused ? " · PAUSED" : "")")
    }
    if !s.jobs.isEmpty { print("\nJobs:"); printJobs(s.jobs) }
    for e in s.jobGroups where e.running + e.queued > 0 {
        print("  ETA \(e.group): \(etaText(e))\(e.etaDate.map { " (\(e.etaIsLowerBound ? "not before " : "")\(timeFmt.string(from: $0)))" } ?? "")")
    }
}

let shortTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()

/// "7h20m", "≥ 7h20m, 3 jobs without ETA", or "– (3 jobs without ETA)".
func etaText(_ e: GroupETA) -> String {
    let n = e.jobsWithoutETA.count
    let jobsTxt = "\(n) job\(n == 1 ? "" : "s") without ETA"
    guard let s = e.etaSeconds else { return n == 0 ? "–" : "– (\(jobsTxt))" }
    return e.etaIsLowerBound ? "≥ \(dur(s)), \(jobsTxt)" : dur(s)
}

/// Full names, never truncated: columns are as wide as the longest value.
func jobLabel(_ j: JobInfo) -> String {
    let run: String = (j.run ?? 1) > 1 ? " #\(j.run ?? 1)" : ""
    return j.group + "/" + j.name + run
}

func printJobs(_ js: [JobInfo]) {
    let labels: [String] = js.map(jobLabel)
    let nameW: Int = max(10, labels.map(\.count).max() ?? 0)
    let stateW: Int = max(7, js.map(\.displayState.count).max() ?? 0)
    for (i, j) in js.enumerated() {
        var l = "  \(pad(labels[i], nameW)) \(pad(j.displayState, stateW))"
        if let d = j.done { l += " \(pad(f0(d) + (j.total.map { "/" + f0($0) } ?? ""), 12))" }
        if let r = j.ratePerHour, !j.isFinished {
            l += " \(f0(r))/h"
            if let e = j.etaSeconds { l += " → ETA \(dur(e))" }
            else if j.total != nil && r <= 0 { l += " (no ETA while stalled)" }
        } else if !j.isFinished, j.total == nil, j.state != "queued" {
            l += " (no total: no ETA)"
        }
        if let w = j.waitingOn { l += " · waiting for \(w)" }
        if let a = j.secondsSinceActivity { l += " · last activity \(dur(a)) ago" }
        if !j.isFinished && j.state != "queued" { l += " · \(f0(j.cost.cpuPct))% CPU \(f0(j.cost.memMB)) MB \(f1(j.cost.watts)) W" }
        if let c = j.exitCode { l += " · exit \(c)" }
        if j.logMissing == true { l += " · LOG NOT FOUND" }
        print(l)
    }
}

/// Resolves a --log path the way the app will (relative to this shell's cwd) and warns if it doesn't exist.
func clientLogPath(_ v: String?) -> String? {
    guard let v else { return nil }
    let t = (v as NSString).expandingTildeInPath
    let abs = t.hasPrefix("/") ? t : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(t)
    let p = (abs as NSString).standardizingPath
    if !FileManager.default.fileExists(atPath: p) {
        fputs("forkcast: note: log \(p) doesn't exist yet — it won't count as activity until it does\n", stderr)
    }
    return p
}
let clientCwd = FileManager.default.currentDirectoryPath

func printTree(_ gs: [GroupInfo], depth: Int = 0) {
    for g in gs where g.watts > 0.001 || g.cpuPct > 0.1 || depth == 0 {
        print(String(repeating: "  ", count: depth) + "\(g.label) [\(g.rootPid ?? 0)] \(f1(g.watts)) W \(f0(g.cpuPct))% \(f0(g.memMB)) MB")
        if let ch = g.children, depth < 12 { printTree(ch, depth: depth + 1) }
    }
}

func printETA(_ e: GroupETA) {
    print("\(pad(e.group, 20)) ETA \(etaText(e))\(e.etaDate.map { " (\(e.etaIsLowerBound ? "not before " : "")\(timeFmt.string(from: $0)))" } ?? "") · \(e.running) running, \(e.queued) queued, \(e.finished) done · \(f0(e.throughputPerHour))/h")
    print("    basis: \(e.basis)")
}

/// --stale DUR | never  →  seconds (0 = never stale), nil when not given.
func staleOption(_ a: Parsed) -> Double? {
    guard let v = a.value("--stale") else { return nil }
    if ["never", "off", "0"].contains(v.lowercased()) { return 0 }
    guard let s = parseDuration(v), s > 0 else { die("--stale takes a duration like 45m or 3h, or 'never'", 2) }
    return s
}

// MARK: - Dispatch

var argv = Array(CommandLine.arguments.dropFirst())
guard let first = argv.first else { print(overviewText()); exit(0) }
argv.removeFirst()

switch first {
case "-h", "--help": print(overviewText()); exit(0)
case "-v", "--version": print("forkcast \(version)"); exit(0)
default: break
}

guard let cmd = findCommand(first) else {
    let close = commands.map(\.name).filter { $0.hasPrefix(String(first.prefix(2))) }
    die("unknown command '\(first)'" + (close.isEmpty ? "" : " — did you mean \(close.joined(separator: " or "))?") + "\nRun `forkcast help` for the list of commands.", 2)
}
let a = parse(cmd, argv)
let json = a.has("--json")

switch cmd.name {
case "help":
    if a.has("--json") { print(helpJSON()) }
    else if a.has("--man") { print(manPage()) }
    else if let topic = a.positional.first {
        if let c = findCommand(topic) { print(commandText(c)) }
        else if let t = topicText(topic) { print(t) }
        else { die("no help for '\(topic)'. Commands: \(commands.map(\.name).joined(separator: ", ")). Topics: \(topics.keys.sorted().joined(separator: ", "))", 2) }
    } else { print(overviewText()) }

case "version":
    print("forkcast \(version)")

case "status":
    let c = Client.load()
    var (s, data) = c.get("/status", Status.self)
    for _ in 0..<12 where s.warmingUp {          // just started: give it a moment for the first real interval
        usleep(250_000)
        (s, data) = c.get("/status", Status.self)
    }
    if json { printJSON(data) }
    else if s.warmingUp { print("Forkcast is warming up (it needs two samples to measure rates) — try again in a few seconds.") }
    else { printStatus(s) }

case "ps":
    let by = a.value("--by") ?? "job"
    guard ["job", "app", "tree"].contains(by) else { die("--by must be job, app or tree", 2) }
    let limit = Int(a.value("--limit") ?? "30") ?? 30
    let sort = a.value("--sort") ?? "power"
    guard ["power", "cpu", "mem"].contains(sort) else { die("--sort must be power, cpu or mem", 2) }
    let c = Client.load()
    if let s = Optional(c.get("/status", Status.self).0), s.warmingUp { usleep(1_500_000) }
    let (all, data) = c.get("/processes", [GroupInfo].self, query: ["group_by": by, "limit": String(max(limit, 1))])
    func key(_ g: GroupInfo) -> (Double, Double) {
        switch sort {
        case "cpu": return (g.cpuPct, g.watts)
        case "mem": return (g.memMB, g.cpuPct)
        default: return (g.watts, g.cpuPct)
        }
    }
    var gs = all.sorted { key($0) > key($1) }
    let hidden = a.has("--all") ? 0 : gs.filter { $0.kind != "registered" && $0.cpuPct < 0.5 && $0.watts < 0.01 }.count
    if !a.has("--all") { gs = gs.filter { $0.kind == "registered" || $0.cpuPct >= 0.5 || $0.watts >= 0.01 } }
    if json { printJSON(data) } else if by == "tree" { printTree(gs) } else {
        print("\(pad("GROUP", 46)) \(pad("POWER", 8)) \(pad("CPU", 6)) \(pad("MEMORY", 9)) PROCS")
        defer { if hidden > 0 { print("(\(hidden) idle groups hidden — use --all)") } }
        for g in gs.prefix(limit) {
            print("\(pad(g.label, 46)) \(pad(f1(g.watts) + " W", 8)) \(pad(f0(g.cpuPct) + "%", 6)) \(pad(f0(g.memMB) + " MB", 9)) \(g.procCount)\(g.paused ? " PAUSED" : "")")
            if let c = g.command, g.kind == "job" || g.kind == "registered" { print("    $ \(c.prefix(150))") }
        }
    }

case "headroom":
    var q: [String: String] = [:]
    if let g = a.value("--group") { q["group"] = g }
    let (h, data) = Client.load().get("/headroom", Headroom.self, query: q)
    if json { printJSON(data) } else {
        print(h.verdict)
        print("Free: \(f1(h.freeCoresP90)) cores (p90) · \(f1(h.memHeadroomGB)) GB memory · power margin \(h.powerMarginW.map { f1($0) + " W" } ?? "n/a (on battery)") · disk I/O \(f1(h.diskIOMBs)) of ~\(f0(h.diskIOPeakMBs)) MB/s peak")
        for c in h.cards {
            print("\n\(c.label) (\(c.instances) active\(c.waiting > 0 ? ", \(c.waiting) waiting" : ""))")
            print("  each ≈ \(String(format: "%.2f", c.coresP90)) cores (p90) · \(f1(c.memPeakGB)) GB peak · \(f1(c.wattsP90)) W · \(f0(c.diskMBPerMin)) MB/min disk")
            print("  \(c.estimateText)")
        }
    }

case "history":
    let metric = need(a, 0, "METRIC (see `forkcast metrics`)", cmd)
    guard historyMetrics.contains(metric) else { die("unknown metric '\(metric)'. History metrics: \(historyMetrics.joined(separator: ", "))", 2) }
    let q = ["metric": metric, "range": a.value("--range") ?? "24h", "step": a.value("--step") ?? "60s"]
    let (pts, data) = Client.load().get("/history", [HistoryPoint].self, query: q)
    if json { printJSON(data) } else { for p in pts { print("\(timeFmt.string(from: p.t))  \(p.v.map { String(format: "%.3f", $0) } ?? "–")") } }

case "events":
    var q = ["since": a.value("--since") ?? "1h"]
    if let t = a.value("--types") { q["types"] = t }
    let (es, data) = Client.load().get("/events", [EventInfo].self, query: q)
    if json { printJSON(data) } else if es.isEmpty { print("No events in this window.") } else {
        for e in es.reversed() { print("\(timeFmt.string(from: e.time))  \(pad(e.type, 18)) \(e.message)") }
    }

case "changes":
    let (code, data) = Client.load().call("GET", "/changes", query: ["since": a.value("--since") ?? "1h"])
    if code >= 400 { _ = decodeOrDie(code, data, APIError.self) }
    if json { printJSON(data) } else if let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        for k in ["started", "finished", "failed", "stale", "crashed"] {
            let v = (o[k] as? [String]) ?? []
            print("\(pad(k, 9)) \(v.isEmpty ? "—" : v.joined(separator: ", "))")
        }
        for r in (o["earlierRuns"] as? [String]) ?? [] { print("earlier   \(r)") }
        for al in (o["alerts"] as? [String]) ?? [] { print("alert     \(al)") }
    }

case "open":
    let running = Client.connect(launch: false) != nil
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = running ? ["-b", "local.forkcast"] : ["-b", "local.forkcast", "--args", "--window"]
    try? p.run()
    p.waitUntilExit()

case "jobs":
    var q: [String: String] = [:]
    if let g = a.value("--group") { q["group"] = g }
    let (js, data) = Client.load().get("/jobs", [JobInfo].self, query: q)
    json ? printJSON(data) : (js.isEmpty ? print("No registered jobs. Start one with: forkcast run --name N --group G -- command …") : printJobs(js))

case "job":
    let name = need(a, 0, "job NAME", cmd)
    let (j, data) = Client.load().get("/jobs/" + path(name), JobInfo.self)
    if json { printJSON(data) } else {
        printJobs([j])
        if let b = j.etaBasis { print("  ETA basis: \(b)") }
        if let c = j.command { print("  $ \(c)") }
        if let l = j.log { print("  log: \(l)\(j.logMissing == true ? "  (NOT FOUND — doesn't count as activity)" : "")") }
        if let n = j.note { print("  note: \(n)") }
        for r in j.previousRuns ?? [] {
            print("  run #\(r.run): \(r.state == "exited" ? "ended" : r.state)\(r.exitCode.map { " (exit \($0))" } ?? "")\(r.done.map { " · \(f0($0))\(r.total.map { "/" + f0($0) } ?? "")" } ?? "")\(r.endedAt.map { " · ended \(timeFmt.string(from: $0))" } ?? "")")
        }
    }

case "eta":
    let c = Client.load()
    if let g = a.positional.first {
        let (e, data) = c.get("/groups/\(path(g))/eta", GroupETA.self)
        json ? printJSON(data) : printETA(e)
    } else {
        let (es, data) = c.get("/groups", [GroupETA].self)
        json ? printJSON(data) : (es.isEmpty ? print("No registered job groups.") : es.forEach(printETA))
    }

case "forget":
    let name = need(a, 0, "job NAME", cmd)
    let (code, data) = Client.load().call("DELETE", "/jobs/" + path(name))
    if code >= 400 { _ = decodeOrDie(code, data, APIError.self) }
    print("forgot \(name)")

case "register":
    guard let name = a.value("--name") else { die("--name is required\nusage: \(cmd.synopsis)", 2) }
    var pid: Int32?
    if let s = a.value("--pid") { guard let v = Int32(s) else { die("--pid must be a number", 2) }; pid = v }
    let req: [String: AnyEncodable] = [
        "name": AnyEncodable(name), "group": AnyEncodable(a.value("--group") ?? "default"), "pid": AnyEncodable(pid),
        "log": AnyEncodable(clientLogPath(a.value("--log"))), "logRegex": AnyEncodable(a.value("--regex")),
        "total": AnyEncodable(a.value("--total").flatMap(Double.init)), "after": AnyEncodable(a.value("--after")),
        "staleAfter": AnyEncodable(staleOption(a)), "cwd": AnyEncodable(clientCwd),
    ]
    let (j, data) = Client.load().send("POST", "/jobs/register", req, JobInfo.self)
    json ? printJSON(data) : print("registered \(j.group)/\(j.name)\((j.run ?? 1) > 1 ? " run #\(j.run!)" : "") (\(j.state))\(j.log.map { " · log \($0)" } ?? "")")

case "progress":
    let name = need(a, 0, "job NAME", cmd)
    let prog = a.positional.count > 1 ? a.positional[1] : nil
    var total: Double?
    if let t = a.value("--total") { guard let v = Double(t) else { die("--total must be a number", 2) }; total = v }
    guard prog != nil || total != nil || a.value("--log") != nil || a.value("--regex") != nil || a.value("--note") != nil || a.value("--stale") != nil else {
        die("give DONE[/TOTAL], or at least one of --total, --log, --regex, --stale, --note\nusage: \(cmd.synopsis)", 2)
    }
    let req: [String: AnyEncodable] = ["progress": AnyEncodable(prog), "note": AnyEncodable(a.value("--note")),
                                       "total": AnyEncodable(total), "log": AnyEncodable(clientLogPath(a.value("--log"))),
                                       "logRegex": AnyEncodable(a.value("--regex")), "cwd": AnyEncodable(clientCwd),
                                       "staleAfter": AnyEncodable(staleOption(a))]
    let (j, data) = Client.load().send("POST", "/jobs/\(path(name))/progress", req, JobInfo.self)
    if json { printJSON(data) } else {
        print("\(j.name): \(f0(j.done))\(j.total.map { "/" + f0($0) } ?? "")\(j.etaSeconds.map { " · ETA \(dur($0))" } ?? "")\(j.log.map { " · log \($0)" } ?? "")")
    }

case "state":
    let name = need(a, 0, "job NAME", cmd)
    let st = need(a, 1, "STATE (waiting or running)", cmd).lowercased()
    guard st == "waiting" || st == "running" else { die("STATE must be waiting or running", 2) }
    var on = a.value("--on")
    if st == "waiting", on == nil, a.positional.count > 2 { on = a.positional[2...].joined(separator: " ") }
    let (j, data) = Client.load().send("POST", "/jobs/\(path(name))/state", ["state": st, "on": on], JobInfo.self)
    json ? printJSON(data) : print("\(j.name): \(j.displayState)\(j.waitingOn.map { " (waiting for \($0))" } ?? "")")

case "beat":
    let name = need(a, 0, "job NAME", cmd)
    _ = Client.load().send("POST", "/jobs/\(path(name))/beat", nil as String?, JobInfo.self)

case "wait":
    let e = need(a, 0, "EXPRESSION (see `forkcast help expressions`)", cmd)
    do { _ = try ExprParser.parse(e) } catch { die("\(error) — see `forkcast help expressions`", 2) }
    guard let timeoutS = parseDuration(a.value("--timeout") ?? "1h") else { die("bad --timeout (use e.g. 90s, 30m, 3h)", 2) }
    let (w, data) = Client.load().get("/wait", WaitResult.self, query: ["until": e, "timeout": String(Int(timeoutS))], timeout: timeoutS + 30)
    if json { printJSON(data) } else if w.met { print("met: \(w.fired ?? e) (after \(dur(w.waitedSeconds)))") } else { print("timed out after \(dur(w.waitedSeconds))") }
    exit(w.met ? 0 : 124)

case "check":
    let e = need(a, 0, "EXPRESSION", cmd)
    do { print("OK: \(try ExprParser.parse(e))") } catch { die("\(error) — see `forkcast help expressions`", 2) }

case "pause", "resume":
    let g = need(a, 0, "GROUP", cmd)
    struct R: Codable { var ok: Bool; var message: String }
    let (r, _) = Client.load().send("POST", "/groups/\(path(g))/\(cmd.name)", nil as String?, R.self)
    print(r.message)

case "guards":
    let (gs, data) = Client.load().get("/guards", [GuardRule].self)
    if json { printJSON(data) } else if gs.isEmpty { print("No guards. Add one with `forkcast guard add …` (see `forkcast guard --help`).") } else {
        for g in gs {
            print("\(g.name): when \(g.when)\(g.forSeconds.map { " for \(dur($0))" } ?? "") → \(g.action) \(g.group ?? "")\(g.resumeWhen.map { " · resume when \($0)" } ?? "")\(g.active == true ? " · ACTIVE" : "")\(g.enabled == false ? " · disabled" : "")\(g.error.map { " · ERROR: \($0)" } ?? "")")
        }
    }

case "guard":
    let sub = need(a, 0, "'add' or 'rm'", cmd)
    switch sub {
    case "rm":
        let n = need(a, 1, "guard NAME", cmd)
        let (code, data) = Client.load().call("DELETE", "/guards/" + path(n))
        if code >= 400 { _ = decodeOrDie(code, data, APIError.self) }
        print("removed guard \(n)")
    case "add":
        guard let name = a.value("--name"), let when = a.value("--when"), let action = a.value("--action") else {
            die("guard add needs --name, --when and --action\nusage: \(cmd.synopsis)", 2)
        }
        do { _ = try ExprParser.parse(when) } catch { die("--when: \(error)", 2) }
        var g = GuardRule(name: name, when: when, action: action)
        g.group = a.value("--group")
        if let f = a.value("--for") { guard let s = parseDuration(f) else { die("bad --for duration", 2) }; g.forSeconds = s }
        g.resumeWhen = a.value("--resume-when")
        let (r, _) = Client.load().send("POST", "/guards", g, GuardRule.self)
        print("added guard \(r.name)\(r.error.map { " (error: \($0))" } ?? "")")
    default:
        die("use `forkcast guard add …` or `forkcast guard rm NAME`", 2)
    }

case "metrics":
    print("Expression metrics (wait, check, guards):")
    for (k, v) in Expr.metrics.sorted(by: { $0.key < $1.key }) { print("  \(pad(k, 22)) \(v)") }
    print("\nHistory metrics (forkcast history):\n  " + historyMetrics.joined(separator: " "))

case "run":
    var command = a.passthrough
    guard !command.isEmpty else { die("no command given — usage: \(cmd.synopsis)", 2) }
    let name = a.value("--name") ?? (command[0] as NSString).lastPathComponent
    let group = a.value("--group") ?? "default"
    let after = a.value("--after")
    let log = clientLogPath(a.value("--log"))
    let cmdline = command.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    let stale = staleOption(a)
    let client = Client.connect()
    if client == nil { fputs("forkcast: Forkcast isn't reachable — running \(name) untracked\n", stderr) }
    func reg(pid: Int32?) -> [String: AnyEncodable] {
        ["name": AnyEncodable(name), "group": AnyEncodable(group), "pid": AnyEncodable(pid), "after": AnyEncodable(after),
         "log": AnyEncodable(log), "logRegex": AnyEncodable(a.value("--regex")), "total": AnyEncodable(a.value("--total").flatMap(Double.init)),
         "command": AnyEncodable(cmdline), "managed": AnyEncodable(true), "staleAfter": AnyEncodable(stale),
         "cwd": AnyEncodable(clientCwd)]
    }
    var runId: Int?
    if let after {
        // --after takes a job name, or a pid ("1234" when no job has that name, or "pid 1234").
        var cond = "job \(after) done"
        let lower = after.lowercased()
        if lower.hasPrefix("pid ") || lower.hasPrefix("pid:") { cond = "pid \(after.dropFirst(4).trimmingCharacters(in: .whitespaces)) exits" }
        else if Int32(after) != nil, client.map({ $0.call("GET", "/jobs/" + path(after)).0 == 404 }) ?? true { cond = "pid \(after) exits" }
        if let c = client {
            runId = c.send("POST", "/jobs/register", reg(pid: nil), JobInfo.self).0.run
            fputs("forkcast: \(name) queued — waiting until \(cond)…\n", stderr)
            while true {
                let (w, _) = c.get("/wait", WaitResult.self, query: ["until": cond, "timeout": "3600"], timeout: 3700)
                if w.met { break }
            }
        } else if cond.hasPrefix("pid "), let p = Int32(cond.split(separator: " ")[1]) {
            while kill(p, 0) == 0 || errno == EPERM { sleep(2) }
        }
    }
    var pid: pid_t = 0
    var cargs: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
    let rc = posix_spawnp(&pid, command[0], nil, nil, &cargs, environ)
    for p in cargs { free(p) }
    command.removeAll()
    guard rc == 0 else { die("can't start \(a.passthrough[0]): \(String(cString: strerror(rc)))", 127) }
    if let c = client {
        if after != nil { runId = c.send("POST", "/jobs/\(path(name))/start", ["pid": pid], JobInfo.self).0.run ?? runId }
        else { runId = c.send("POST", "/jobs/register", reg(pid: pid), JobInfo.self).0.run }
    }
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { kill(pid, sig) }
        src.resume()
        sources.append(src)
    }
    DispatchQueue.global().async {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        let code: Int32? = exited ? (status >> 8) & 0xff : nil
        let sig: Int32? = exited ? nil : status & 0x7f
        struct Exit: Encodable { var code: Int32?; var signal: Int32?; var run: Int? }
        if let c = client { _ = c.raw("POST", "/jobs/\(path(name))/exit", body: try? JSON.encoder.encode(Exit(code: code, signal: sig, run: runId))) }
        exit(code ?? (128 + (sig ?? 0)))
    }
    withExtendedLifetime(sources) { dispatchMain() }

default:
    die("'\(cmd.name)' is not implemented", 1)
}
