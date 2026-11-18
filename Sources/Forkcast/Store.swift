import Foundation
import ForkcastCore
import SQLite3

private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Per-minute metrics (one wide row per minute). Gauges are averaged, counters (MB) summed.
enum Metric: String, CaseIterable {
    case battery = "pct", draw_w, net_battery_w = "net_w", charger_w, cpu_w, gpu_w, soc_w, other_w
    case cpu_busy_cores = "cpu_busy", p_busy_pct = "p_busy", e_busy_pct = "e_busy", thermal
    case mem_pressure, mem_used_gb, swap_gb, compressed_gb, disk_free_gb
    case disk_read_mb, disk_write_mb, net_down_mb, net_up_mb, on_ac = "external"

    var column: String { rawValue }
    /// Public metric name used by the API.
    var apiName: String { String(describing: self) }
    var isCounter: Bool { [.disk_read_mb, .disk_write_mb, .net_down_mb, .net_up_mb].contains(self) }
}

struct Drain: Identifiable, Codable {
    var id: String { name }
    let name: String
    let path: String?
    let joules: Double
    let cpuSec: Double
}

/// SQLite history: metrics, per-group energy, timeline events, job registry, folder sizes. 30-day retention.
final class Store {
    private var db: OpaquePointer?
    static let retentionDays = 30.0

    init() {
        let dir = APIConfig.supportDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("history.sqlite").path
        let fresh = !FileManager.default.fileExists(atPath: path)
        if sqlite3_open(path, &db) != SQLITE_OK { db = nil; return }
        let cols = Metric.allCases.map { "\($0.column) REAL" }.joined(separator: ", ")
        exec("""
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS metrics(minute INTEGER PRIMARY KEY, \(cols));
        CREATE TABLE IF NOT EXISTS usage(
            bucket INTEGER NOT NULL, name TEXT NOT NULL, onbatt INTEGER NOT NULL,
            path TEXT, energy REAL NOT NULL, cpu REAL NOT NULL,
            PRIMARY KEY(bucket, name, onbatt)) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL,
            type TEXT NOT NULL, subject TEXT, message TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
        CREATE TABLE IF NOT EXISTS jobs(name TEXT PRIMARY KEY, json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS folders(ts REAL NOT NULL, path TEXT NOT NULL, gb REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS kv(k TEXT PRIMARY KEY, v TEXT);
        """)
        if fresh { migrateFromPowerMonitor() }
    }

    deinit { sqlite3_close(db) }

    /// One-time import of history from the app's previous name.
    private func migrateFromPowerMonitor() {
        let old = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerMonitor/history.sqlite").path
        guard FileManager.default.fileExists(atPath: old) else { return }
        exec("ATTACH DATABASE '\(old.replacingOccurrences(of: "'", with: "''"))' AS old")
        exec("""
        INSERT OR IGNORE INTO metrics(minute, pct, draw_w, external)
            SELECT minute, pct, CASE WHEN secs > 0 THEN energy / secs END, external FROM old.battery;
        INSERT OR IGNORE INTO usage SELECT * FROM old.usage;
        INSERT INTO events(ts, type, subject, message)
            SELECT ts, 'alert.fired', name, name || ' averaged ' || CAST(ROUND(cpu) AS INT) || '% CPU' FROM old.alerts;
        """)
        exec("DETACH DATABASE old")
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void = { _ in }, row: (OpaquePointer) -> Void = { _ in }) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else { return }
        defer { sqlite3_finalize(s) }
        bind(s)
        while sqlite3_step(s) == SQLITE_ROW { row(s) }
    }

    private static func text(_ s: OpaquePointer, _ i: Int32) -> String? {
        sqlite3_column_text(s, i).map { String(cString: $0) }
    }
    private static func optDouble(_ s: OpaquePointer, _ i: Int32) -> Double? {
        sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i)
    }

    // MARK: metrics

    func writeMetrics(minute: Int64, values: [Metric: Double]) {
        guard !values.isEmpty else { return }
        let ms = Array(values.keys)
        let cols = ms.map(\.column).joined(separator: ",")
        let qs = ms.map { _ in "?" }.joined(separator: ",")
        let upd = ms.map { m in
            m.isCounter ? "\(m.column)=COALESCE(\(m.column),0)+excluded.\(m.column)" : "\(m.column)=excluded.\(m.column)"
        }.joined(separator: ",")
        run("INSERT INTO metrics(minute,\(cols)) VALUES(?,\(qs)) ON CONFLICT(minute) DO UPDATE SET \(upd)", bind: { s in
            sqlite3_bind_int64(s, 1, minute)
            for (i, m) in ms.enumerated() { sqlite3_bind_double(s, Int32(i + 2), values[m]!) }
        })
    }

    func series(_ m: Metric, fromMinute: Int64, toMinute: Int64, stepMinutes: Int64) -> [HistoryPoint] {
        var out: [HistoryPoint] = []
        let agg = m.isCounter ? "SUM" : "AVG"
        run("""
            SELECT (minute / ?1) * ?1 AS b, \(agg)(\(m.column)) FROM metrics
            WHERE minute BETWEEN ?2 AND ?3 AND \(m.column) IS NOT NULL GROUP BY b ORDER BY b
            """, bind: { s in
            sqlite3_bind_int64(s, 1, max(1, stepMinutes))
            sqlite3_bind_int64(s, 2, fromMinute)
            sqlite3_bind_int64(s, 3, toMinute)
        }, row: { s in
            out.append(HistoryPoint(t: Date(timeIntervalSince1970: Double(sqlite3_column_int64(s, 0)) * 60),
                                    v: Self.optDouble(s, 1)))
        })
        return out
    }

    /// Sum of a counter metric, or energy (W × 60 s) of a power metric, over a window.
    func total(_ m: Metric, fromMinute: Int64, toMinute: Int64, onBatteryOnly: Bool = false) -> Double {
        var v = 0.0
        let expr = m.isCounter ? "SUM(\(m.column))" : "SUM(\(m.column)) * 60"
        run("SELECT \(expr) FROM metrics WHERE minute BETWEEN ?1 AND ?2 AND (?3 = 0 OR external < 0.5)", bind: { s in
            sqlite3_bind_int64(s, 1, fromMinute)
            sqlite3_bind_int64(s, 2, toMinute)
            sqlite3_bind_int(s, 3, onBatteryOnly ? 1 : 0)
        }, row: { s in v = sqlite3_column_double(s, 0) })
        return v
    }

    func lastMinute() -> Int64? {
        var v: Int64?
        run("SELECT MAX(minute) FROM metrics", row: { s in
            if sqlite3_column_type(s, 0) != SQLITE_NULL { v = sqlite3_column_int64(s, 0) }
        })
        return v
    }

    // MARK: per-group energy (drains)

    func writeUsage(minute: Int64, usage: [String: (path: String?, energy: Double, cpu: Double)], onBattery: Bool) {
        exec("BEGIN")
        for (name, u) in usage where u.energy > 0.3 || u.cpu > 0.3 {
            run("""
                INSERT INTO usage(bucket,name,onbatt,path,energy,cpu) VALUES(?,?,?,?,?,?)
                ON CONFLICT(bucket,name,onbatt) DO UPDATE SET energy=energy+excluded.energy, cpu=cpu+excluded.cpu
                """, bind: { s in
                sqlite3_bind_int64(s, 1, minute / 5)
                sqlite3_bind_text(s, 2, name, -1, TRANSIENT)
                sqlite3_bind_int(s, 3, onBattery ? 1 : 0)
                if let p = u.path { sqlite3_bind_text(s, 4, p, -1, TRANSIENT) } else { sqlite3_bind_null(s, 4) }
                sqlite3_bind_double(s, 5, u.energy)
                sqlite3_bind_double(s, 6, u.cpu)
            })
        }
        exec("COMMIT")
    }

    func drains(fromMinute: Int64, toMinute: Int64, batteryOnly: Bool, limit: Int) -> [Drain] {
        var out: [Drain] = []
        run("""
            SELECT name, MAX(path), SUM(energy), SUM(cpu) FROM usage
            WHERE bucket BETWEEN ?1 AND ?2 AND (?3 = 0 OR onbatt = 1)
            GROUP BY name ORDER BY 3 DESC LIMIT ?4
            """, bind: { s in
            sqlite3_bind_int64(s, 1, fromMinute / 5)
            sqlite3_bind_int64(s, 2, toMinute / 5)
            sqlite3_bind_int(s, 3, batteryOnly ? 1 : 0)
            sqlite3_bind_int(s, 4, Int32(limit))
        }, row: { s in
            out.append(Drain(name: Self.text(s, 0) ?? "?", path: Self.text(s, 1),
                             joules: sqlite3_column_double(s, 2), cpuSec: sqlite3_column_double(s, 3)))
        })
        return out
    }

    // MARK: events (written immediately; synchronous=FULL survives power loss)

    @discardableResult
    func addEvent(type: String, subject: String?, message: String, at: Date = Date()) -> EventInfo {
        run("INSERT INTO events(ts,type,subject,message) VALUES(?,?,?,?)", bind: { s in
            sqlite3_bind_double(s, 1, at.timeIntervalSince1970)
            sqlite3_bind_text(s, 2, type, -1, TRANSIENT)
            if let sub = subject { sqlite3_bind_text(s, 3, sub, -1, TRANSIENT) } else { sqlite3_bind_null(s, 3) }
            sqlite3_bind_text(s, 4, message, -1, TRANSIENT)
        })
        return EventInfo(id: sqlite3_last_insert_rowid(db), time: at, type: type, subject: subject, message: message)
    }

    func events(since: Date, until: Date = .distantFuture, types: [String] = [], limit: Int = 500) -> [EventInfo] {
        var out: [EventInfo] = []
        run("SELECT id, ts, type, subject, message FROM events WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts DESC LIMIT ?3", bind: { s in
            sqlite3_bind_double(s, 1, since.timeIntervalSince1970)
            sqlite3_bind_double(s, 2, min(until.timeIntervalSince1970, 1e12))
            sqlite3_bind_int(s, 3, Int32(limit * (types.isEmpty ? 1 : 4)))
        }, row: { s in
            let type = Self.text(s, 2) ?? ""
            if !types.isEmpty && !types.contains(where: { type == $0 || type.hasPrefix($0 + ".") }) { return }
            out.append(EventInfo(id: sqlite3_column_int64(s, 0), time: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                                 type: type, subject: Self.text(s, 3), message: Self.text(s, 4) ?? ""))
        })
        return Array(out.prefix(limit))
    }

    // MARK: jobs

    func saveJob(name: String, json: String) {
        run("INSERT INTO jobs(name,json) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET json=excluded.json", bind: { s in
            sqlite3_bind_text(s, 1, name, -1, TRANSIENT)
            sqlite3_bind_text(s, 2, json, -1, TRANSIENT)
        })
    }
    func deleteJob(_ name: String) {
        run("DELETE FROM jobs WHERE name=?", bind: { sqlite3_bind_text($0, 1, name, -1, TRANSIENT) })
    }
    func loadJobs() -> [String] {
        var out: [String] = []
        run("SELECT json FROM jobs", row: { s in if let t = Self.text(s, 0) { out.append(t) } })
        return out
    }

    // MARK: folders

    func addFolderSize(path: String, gb: Double, at: Date) {
        run("INSERT INTO folders(ts,path,gb) VALUES(?,?,?)", bind: { s in
            sqlite3_bind_double(s, 1, at.timeIntervalSince1970)
            sqlite3_bind_text(s, 2, path, -1, TRANSIENT)
            sqlite3_bind_double(s, 3, gb)
        })
    }
    func folderHistory(path: String, since: Date) -> [(Date, Double)] {
        var out: [(Date, Double)] = []
        run("SELECT ts, gb FROM folders WHERE path=? AND ts>=? ORDER BY ts", bind: { s in
            sqlite3_bind_text(s, 1, path, -1, TRANSIENT)
            sqlite3_bind_double(s, 2, since.timeIntervalSince1970)
        }, row: { s in out.append((Date(timeIntervalSince1970: sqlite3_column_double(s, 0)), sqlite3_column_double(s, 1))) })
        return out
    }

    // MARK: key/value

    func get(_ k: String) -> String? {
        var v: String?
        run("SELECT v FROM kv WHERE k=?", bind: { sqlite3_bind_text($0, 1, k, -1, TRANSIENT) }, row: { v = Self.text($0, 0) })
        return v
    }
    func set(_ k: String, _ v: String) {
        run("INSERT INTO kv(k,v) VALUES(?,?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", bind: { s in
            sqlite3_bind_text(s, 1, k, -1, TRANSIENT)
            sqlite3_bind_text(s, 2, v, -1, TRANSIENT)
        })
    }

    func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.retentionDays * 86400
        let cm = Int64(cutoff / 60)
        run("DELETE FROM metrics WHERE minute < ?", bind: { sqlite3_bind_int64($0, 1, cm) })
        run("DELETE FROM usage WHERE bucket < ?", bind: { sqlite3_bind_int64($0, 1, cm / 5) })
        run("DELETE FROM events WHERE ts < ?", bind: { sqlite3_bind_double($0, 1, cutoff) })
        run("DELETE FROM folders WHERE ts < ?", bind: { sqlite3_bind_double($0, 1, cutoff) })
    }
}
