import Foundation

/// The condition language used by `forkcast wait`, `GET /wait` and guard rules.
///
///   battery > 25
///   on_ac and net_battery_w > 0
///   disk_free_gb < 50 or mem_pressure == red
///   job batch7 done            (done | ok | failed | running | waiting | stale | paused | exists | started)
///                              always the latest run of that name
///   pid 12345 exits          (exits | running)
///   group renders idle      (idle | busy | paused | running | done | exists)
///   file /path/done.flag exists      (exists | missing)
///   process_running('installer')     or: process installer running
///   not (a or b) and c
public indirect enum Expr: CustomStringConvertible, Sendable {
    case and(Expr, Expr)
    case or(Expr, Expr)
    case not(Expr)
    case compare(String, String, Double)     // metric, op, value
    case flag(String)                        // bare boolean metric
    case job(String, String)
    case pid(Int32, String)
    case group(String, String)
    case file(String, Bool)                  // path, mustExist
    case process(String)

    public var description: String {
        switch self {
        case let .and(a, b): return "(\(a) and \(b))"
        case let .or(a, b): return "(\(a) or \(b))"
        case let .not(a): return "not \(a)"
        case let .compare(m, op, v): return "\(m) \(op) \(Self.fmt(v))"
        case let .flag(m): return m
        case let .job(n, s): return "job \(n) \(s)"
        case let .pid(p, s): return "pid \(p) \(s)"
        case let .group(g, s): return "group \(g) \(s)"
        case let .file(p, e): return "file \(p) \(e ? "exists" : "missing")"
        case let .process(n): return "process_running('\(n)')"
        }
    }

    public static func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }

    public static let metrics: [String: String] = [
        "battery": "battery percent", "on_ac": "1 when on the charger", "charging": "1 when charging",
        "net_battery_w": "W into (+) / out of (−) the battery", "draw_w": "whole-system power",
        "charger_w": "charger rating", "margin_w": "charger W − draw W", "cpu_w": "CPU package power",
        "gpu_w": "GPU power", "hours_to_full": "at current net flow", "hours_to_empty": "at current net flow",
        "cpu_busy_cores": "busy core-equivalents", "cpu_free_cores": "free cores (p90, 30 min)",
        "cpu_pct": "busy % of all cores", "thermal": "0 nominal … 3 critical", "throttling": "1 when throttling",
        "mem_pressure": "0 green, 1 yellow, 2 red", "mem_headroom_gb": "memory left before yellow",
        "swap_gb": "swap used", "swap_growth_gb_h": "swap growth per hour",
        "disk_free_gb": "free on / right now (statvfs, same as df)",
        "disk_free_purgeable_gb": "free on / incl. what macOS says it can purge (caches, TM snapshots)",
        "disk_hours_to_floor": "hours until disk hits the floor", "disk_read_mbs": "MB/s",
        "disk_write_mbs": "MB/s", "net_down_mbs": "MB/s", "net_up_mbs": "MB/s",
        "net_today_up_gb": "uploaded today", "net_today_down_gb": "downloaded today", "alerts": "active alert count",
    ]

    static let constants: [String: Double] = [
        "green": 0, "yellow": 1, "red": 2,
        "nominal": 0, "fair": 1, "serious": 2, "critical": 3,
        "true": 1, "false": 0, "yes": 1, "no": 0,
    ]

    static let jobStates: Set<String> = ["done", "finished", "ok", "failed", "running", "waiting", "stale", "paused", "exists", "started"]
    static let pidStates: Set<String> = ["exits", "exited", "dead", "running", "alive"]
    static let groupStates: Set<String> = ["idle", "busy", "paused", "running", "done", "exists"]
}

public struct ExprError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// What an expression can ask about the world.
public protocol ExprContext {
    func metric(_ name: String) -> Double?
    func jobState(_ name: String) -> String?                 // JobInfo.state, nil if unknown job
    func pidAlive(_ pid: Int32) -> Bool
    func groupState(_ name: String) -> (busy: Bool, paused: Bool, alive: Int, finished: Int)?
    func processRunning(_ name: String) -> Bool
}

// MARK: - Parser

public enum ExprParser {
    enum Tok: Equatable { case word(String), str(String), op(String), lp, rp, comma }

    static func tokenize(_ s: String) throws -> [Tok] {
        var out: [Tok] = []
        let chars = Array(s)
        var i = 0
        func isWord(_ c: Character) -> Bool {
            c.isLetter || c.isNumber || "_./-~:@+%*".contains(c)
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { i += 1; continue }
            if c == "(" { out.append(.lp); i += 1; continue }
            if c == ")" { out.append(.rp); i += 1; continue }
            if c == "," { out.append(.comma); i += 1; continue }
            if c == "'" || c == "\"" {
                var j = i + 1
                var buf = ""
                while j < chars.count && chars[j] != c { buf.append(chars[j]); j += 1 }
                if j >= chars.count { throw ExprError(message: "unterminated string") }
                out.append(.str(buf)); i = j + 1; continue
            }
            if "<>=!".contains(c) {
                var op = String(c)
                if i + 1 < chars.count, chars[i + 1] == "=" { op.append("="); i += 1 }
                if op == "=" { op = "==" }
                if op == "!" { throw ExprError(message: "unexpected '!' (use 'not')") }
                out.append(.op(op)); i += 1; continue
            }
            if c == "&" || c == "|" {   // allow && and ||
                let dbl = i + 1 < chars.count && chars[i + 1] == c
                out.append(.word(c == "&" ? "and" : "or")); i += dbl ? 2 : 1; continue
            }
            if isWord(c) {
                var j = i
                var buf = ""
                while j < chars.count && isWord(chars[j]) { buf.append(chars[j]); j += 1 }
                out.append(.word(buf)); i = j; continue
            }
            throw ExprError(message: "unexpected character '\(c)'")
        }
        return out
    }

    public static func parse(_ s: String) throws -> Expr {
        let toks = try tokenize(s)
        if toks.isEmpty { throw ExprError(message: "empty expression") }
        var p = Parser(toks: toks)
        let e = try p.parseOr()
        if p.i < toks.count { throw ExprError(message: "unexpected '\(p.describe(toks[p.i]))'") }
        return e
    }

    struct Parser {
        let toks: [Tok]
        var i = 0

        func describe(_ t: Tok) -> String {
            switch t {
            case let .word(w): return w
            case let .str(s): return "'\(s)'"
            case let .op(o): return o
            case .lp: return "("
            case .rp: return ")"
            case .comma: return ","
            }
        }

        mutating func next() -> Tok? { i < toks.count ? toks[i] : nil }
        mutating func take() throws -> Tok {
            guard i < toks.count else { throw ExprError(message: "expression ends too early") }
            defer { i += 1 }
            return toks[i]
        }
        mutating func word() throws -> String {
            switch try take() {
            case let .word(w): return w
            case let .str(s): return s
            case let t: throw ExprError(message: "expected a name, got '\(describe(t))'")
            }
        }
        func peekWord(_ w: String) -> Bool {
            if i < toks.count, case let .word(x) = toks[i], x.lowercased() == w { return true }
            return false
        }

        mutating func parseOr() throws -> Expr {
            var e = try parseAnd()
            while peekWord("or") { i += 1; e = .or(e, try parseAnd()) }
            return e
        }
        mutating func parseAnd() throws -> Expr {
            var e = try parseNot()
            while peekWord("and") { i += 1; e = .and(e, try parseNot()) }
            return e
        }
        mutating func parseNot() throws -> Expr {
            if peekWord("not") { i += 1; return .not(try parseNot()) }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> Expr {
            let t = try take()
            if t == .lp {
                let e = try parseOr()
                guard try take() == .rp else { throw ExprError(message: "missing ')'") }
                return e
            }
            guard case let .word(raw) = t else { throw ExprError(message: "unexpected '\(describe(t))'") }
            let w = raw.lowercased()
            switch w {
            case "job":
                let name = try word()
                let st = try word().lowercased()
                guard Expr.jobStates.contains(st) else {
                    throw ExprError(message: "job state must be one of: \(Expr.jobStates.sorted().joined(separator: ", "))")
                }
                return .job(name, st)
            case "pid":
                guard let p = Int32(try word()) else { throw ExprError(message: "pid must be a number") }
                let st = try word().lowercased()
                guard Expr.pidStates.contains(st) else { throw ExprError(message: "use 'pid N exits' or 'pid N running'") }
                return .pid(p, st)
            case "group":
                let name = try word()
                let st = try word().lowercased()
                guard Expr.groupStates.contains(st) else {
                    throw ExprError(message: "group state must be one of: \(Expr.groupStates.sorted().joined(separator: ", "))")
                }
                return .group(name, st)
            case "file":
                let path = try word()
                let st = try word().lowercased()
                guard st == "exists" || st == "missing" else { throw ExprError(message: "use 'file PATH exists' or 'file PATH missing'") }
                return .file(path, st == "exists")
            case "process_running":
                guard try take() == .lp else { throw ExprError(message: "use process_running('name')") }
                let name = try word()
                guard try take() == .rp else { throw ExprError(message: "missing ')'") }
                return .process(name)
            case "process":
                let name = try word()
                guard peekWord("running") else { throw ExprError(message: "use 'process NAME running'") }
                i += 1
                return .process(name)
            default:
                guard Expr.metrics[w] != nil else {
                    throw ExprError(message: "unknown metric '\(raw)'. Known: \(Expr.metrics.keys.sorted().joined(separator: ", "))")
                }
                if i < toks.count, case let .op(op) = toks[i] {
                    i += 1
                    let vt = try word().lowercased()
                    guard let v = Double(vt) ?? Expr.constants[vt] else {
                        throw ExprError(message: "'\(vt)' is not a number")
                    }
                    return .compare(w, op, v)
                }
                return .flag(w)
            }
        }
    }
}

// MARK: - Evaluation

public extension Expr {
    /// Returns whether the expression holds and, if so, the leaf conditions that made it true.
    func evaluate(_ ctx: ExprContext) -> (Bool, String?) {
        switch self {
        case let .and(a, b):
            let (x, dx) = a.evaluate(ctx)
            guard x else { return (false, nil) }
            let (y, dy) = b.evaluate(ctx)
            return y ? (true, [dx, dy].compactMap { $0 }.joined(separator: " and ")) : (false, nil)
        case let .or(a, b):
            let (x, dx) = a.evaluate(ctx)
            if x { return (true, dx) }
            return b.evaluate(ctx)
        case let .not(a):
            let (x, _) = a.evaluate(ctx)
            return x ? (false, nil) : (true, description)
        case let .compare(m, op, v):
            guard let cur = ctx.metric(m) else { return (false, nil) }
            let ok: Bool
            switch op {
            case ">": ok = cur > v
            case "<": ok = cur < v
            case ">=": ok = cur >= v
            case "<=": ok = cur <= v
            case "==": ok = abs(cur - v) < 1e-9
            case "!=": ok = abs(cur - v) >= 1e-9
            default: ok = false
            }
            return ok ? (true, "\(m) \(op) \(Expr.fmt(v)) (now \(String(format: "%.2f", cur)))") : (false, nil)
        case let .flag(m):
            let ok = (ctx.metric(m) ?? 0) != 0
            return ok ? (true, m) : (false, nil)
        case let .job(name, st):
            guard let s = ctx.jobState(name) else { return (false, nil) }
            let finished = ["done-ok", "done-error", "killed", "exited"].contains(s)
            let ok: Bool
            switch st {
            case "done", "finished": ok = finished
            case "ok": ok = s == "done-ok"
            case "failed": ok = s == "done-error" || s == "killed"
            case "running": ok = s == "running" || s == "stale" || s == "waiting"
            case "started": ok = s != "queued"
            case "exists": ok = true
            default: ok = s == st
            }
            return ok ? (true, "job \(name) \(st) (state \(s))") : (false, nil)
        case let .pid(p, st):
            let alive = ctx.pidAlive(p)
            let ok = ["running", "alive"].contains(st) ? alive : !alive
            return ok ? (true, description) : (false, nil)
        case let .group(g, st):
            let info = ctx.groupState(g)
            let ok: Bool
            switch st {
            case "exists": ok = info != nil
            case "idle": ok = info.map { !$0.busy } ?? true
            case "busy": ok = info?.busy ?? false
            case "paused": ok = info?.paused ?? false
            case "running": ok = (info?.alive ?? 0) > 0 && !(info?.paused ?? false)
            case "done": ok = info.map { $0.alive == 0 } ?? true
            default: ok = false
            }
            return ok ? (true, description) : (false, nil)
        case let .file(path, mustExist):
            let p = (path as NSString).expandingTildeInPath
            let ok = FileManager.default.fileExists(atPath: p) == mustExist
            return ok ? (true, description) : (false, nil)
        case let .process(name):
            return ctx.processRunning(name) ? (true, description) : (false, nil)
        }
    }

    /// True if the expression asks about a registered job (its record may be replaced by a new run).
    var mentionsJob: Bool {
        switch self {
        case let .and(a, b), let .or(a, b): return a.mentionsJob || b.mentionsJob
        case let .not(a): return a.mentionsJob
        case .job: return true
        default: return false
        }
    }

    /// True if evaluating needs only cheap local checks (pid/file), so it can be polled every second.
    var isLocalOnly: Bool {
        switch self {
        case let .and(a, b), let .or(a, b): return a.isLocalOnly && b.isLocalOnly
        case let .not(a): return a.isLocalOnly
        case .pid, .file: return true
        default: return false
        }
    }
}
