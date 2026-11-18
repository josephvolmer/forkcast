import Foundation

// Shared, Codable data model. These structs ARE the JSON API: field names are stable.
// Units are in the field names (W, GB, MBs = MB/s, Pct = 0–100, cores = core-equivalents).

public struct SourceStamp: Codable, Sendable {
    public var source: String          // e.g. "IOReport Energy Model", "AppleSmartBattery (IOKit)", "libproc"
    public var sampledAt: Date
    public init(_ source: String, _ at: Date = Date()) { self.source = source; self.sampledAt = at }
}

public struct PowerInfo: Codable, Sendable {
    public var onAC: Bool = false
    public var charging: Bool = false
    public var fullyCharged: Bool = false
    public var chargerW: Double?            // adapter rating
    public var chargerName: String?
    public var drawW: Double?               // whole-system load (excludes battery charging)
    public var netBatteryW: Double?         // + = into battery, − = out of battery
    public var marginW: Double?             // chargerW − drawW (on AC)
    public var batteryPct: Int?
    public var batteryWh: Double?           // energy currently stored
    public var batteryFullWh: Double?
    public var hoursToFull: Double?         // at the current net flow
    public var hoursToEmpty: Double?        // at the current net flow
    public var macosMinutesRemaining: Int?  // macOS' own estimate, for comparison
    // Reconciliation: cpuW + gpuW + socW + otherW == drawW
    public var cpuW: Double?
    public var gpuW: Double?
    public var aneW: Double?
    public var socW: Double?                // DRAM, memory controller, display pipe, media engines, SoC rest
    public var otherW: Double?              // display backlight, SSD, Wi-Fi, audio, conversion losses
    public init() {}
}

public struct CPUInfo: Codable, Sendable {
    public var totalCores = 0
    public var pCores = 0
    public var eCores = 0
    public var busyCores = 0.0              // core-equivalents busy right now
    public var freeCoresP90: Double?        // cores free at the 90th-percentile load of the last 30 min
    public var pBusyPct = 0.0
    public var eBusyPct = 0.0
    public var loadAvg1 = 0.0
    public var thermal = "nominal"          // nominal | fair | serious | critical
    public var throttling = false
    public init() {}
}

public struct MemoryInfo: Codable, Sendable {
    public var pressure = "green"           // green | yellow | red
    public var totalGB = 0.0
    public var usedGB = 0.0                 // app + wired + compressed (like Activity Monitor)
    public var compressedGB = 0.0
    public var swapUsedGB = 0.0
    public var swapGrowthGBPerHour: Double?
    public var headroomGB = 0.0             // approx. memory left before pressure turns yellow
    public init() {}
}

public struct DiskInfo: Codable, Sendable {
    public var path = "/"
    public var totalGB = 0.0
    public var freeGB = 0.0                 // immediately free
    public var freeInclPurgeableGB = 0.0    // what macOS can make free (incl. caches, TM local snapshots)
    public var purgeableGB = 0.0
    public var tmLocalSnapshots: Int?
    public var trendGBPerHour: Double?      // negative = filling up
    public var floorGB = 40.0
    public var hoursToFloor: Double?
    public var readMBs = 0.0
    public var writeMBs = 0.0
    public var topIOProcess: String?
    public var topIOMBs: Double?
    public var ioPeakMBs: Double?           // highest read+write seen (for headroom)
    public init() {}
}

public struct VolumeInfo: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var mounted: Bool
    public var watched: Bool
    public var totalGB: Double?
    public var freeGB: Double?
    public var lastChange: Date?            // last time its free space changed (≈ last write)
    public init(name: String, path: String, mounted: Bool, watched: Bool) {
        self.name = name; self.path = path; self.mounted = mounted; self.watched = watched
    }
}

public struct NetworkInfo: Codable, Sendable {
    public var downMBs = 0.0
    public var upMBs = 0.0
    public var todayDownGB = 0.0
    public var todayUpGB = 0.0
    public var topProcess: String?          // only measured while the dashboard is open or via API
    public var topProcessMBs: Double?
    public init() {}
}

public struct FolderInfo: Codable, Sendable, Identifiable {
    public var id: String { path }
    public var path: String
    public var sizeGB: Double?
    public var growthGBPerHour: Double?
    public var scannedAt: Date?
    public init(path: String) { self.path = path }
}

public struct ProcInfo: Codable, Sendable, Identifiable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var name: String
    public var command: String?             // full command line (when readable)
    public var cwd: String?
    public var startTime: Date?
    public var watts = 0.0
    public var cpuPct = 0.0                 // 100 = one full core
    public var memMB = 0.0                  // physical footprint
    public var rssMB: Double?               // resident size (includes shared pages)
    public var diskReadMBs = 0.0
    public var diskWriteMBs = 0.0
    public var exitedChildrenCPUPct = 0.0   // CPU of short-lived children that exited since the last sample
    public var exitedChildrenWatts = 0.0
    public var stopped = false
    public init(pid: Int32, ppid: Int32, name: String) { self.pid = pid; self.ppid = ppid; self.name = name }
}

public struct GroupInfo: Codable, Sendable, Identifiable {
    public var id: String                   // stable while the group lives
    public var label: String
    public var kind: String                 // "registered" | "job" | "app" | "system"
    public var kindKey: String              // groups with the same kindKey are "instances" of one kind of job
    public var jobName: String?             // registered job name
    public var registeredGroup: String?
    public var rootPid: Int32?
    public var iconPath: String?
    public var command: String?
    public var cwd: String?
    public var parentChain: [String] = []
    public var startTime: Date?
    public var watts = 0.0
    public var cpuPct = 0.0
    public var memMB = 0.0
    public var diskReadMBs = 0.0
    public var diskWriteMBs = 0.0
    public var procCount = 0
    public var paused = false
    public var pausedNote: String?
    public var processes: [ProcInfo] = []
    public var children: [GroupInfo]?       // only for group_by=tree
    public init(id: String, label: String, kind: String, kindKey: String) {
        self.id = id; self.label = label; self.kind = kind; self.kindKey = kindKey
    }
}

public struct JobCost: Codable, Sendable {
    public var cpuPct = 0.0
    public var memMB = 0.0
    public var watts = 0.0
    public init() {}
}

public struct JobInfo: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var group: String
    public var pid: Int32?
    public var command: String?
    public var log: String?
    public var logRegex: String?
    public var staleAfterSeconds: Double?   // per-job stale timeout; 0 = never stale; nil = global default
    public var total: Double?
    public var done: Double?
    public var note: String?
    public var after: String?
    public var state: String = "running"    // queued | running | paused | stale | done-ok | done-error | killed | exited
    public var ratePerHour: Double?
    public var etaSeconds: Double?
    public var etaBasis: String?
    public var registeredAt: Date = Date()
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int32?
    public var exitSignal: Int32?
    public var lastProgressAt: Date?
    public var lastActivityAt: Date?        // progress, heartbeat or log write
    public var secondsSinceActivity: Double?
    public var cost = JobCost()
    public var pausedNote: String?
    public init(name: String, group: String) { self.name = name; self.group = group }

    public var isFinished: Bool { ["done-ok", "done-error", "killed", "exited"].contains(state) }
    public var fraction: Double? {
        guard let t = total, t > 0, let d = done else { return nil }
        return min(1, d / t)
    }
}

public struct GroupETA: Codable, Sendable {
    public var group: String
    public var jobs: [String]
    public var running: Int
    public var finished: Int
    public var queued: Int
    public var throughputPerHour: Double?
    public var etaSeconds: Double?
    public var etaDate: Date?
    public var basis: String
    public init(group: String, jobs: [String], running: Int, finished: Int, queued: Int, basis: String) {
        self.group = group; self.jobs = jobs; self.running = running; self.finished = finished
        self.queued = queued; self.basis = basis
    }
}

public struct AlertInfo: Codable, Sendable, Identifiable {
    public var id: String                   // type + subject
    public var type: String
    public var subject: String?
    public var message: String
    public var severity: String             // warning | critical
    public var since: Date
    public init(type: String, subject: String?, message: String, severity: String, since: Date) {
        self.id = type + "|" + (subject ?? ""); self.type = type; self.subject = subject
        self.message = message; self.severity = severity; self.since = since
    }
}

public struct CostCard: Codable, Sendable, Identifiable {
    public var id: String { kindKey }
    public var kindKey: String
    public var label: String
    public var instances: Int               // active instances (used CPU or disk in the last 2 min)
    public var waiting = 0                  // instances alive but idle (e.g. queued lanes waiting their turn)
    public var coresP90: Double
    public var memPeakGB: Double
    public var wattsP90: Double
    public var diskMBPerMin: Double
    public var samples: Int
    public var variation: Double            // coefficient of variation of CPU cost over the last hour
    public var estimateMore: Int?
    public var bottleneck: String?
    public var confidence: String           // high | medium | low
    public var estimateText: String
    public init(kindKey: String, label: String, instances: Int) {
        self.kindKey = kindKey; self.label = label; self.instances = instances
        coresP90 = 0; memPeakGB = 0; wattsP90 = 0; diskMBPerMin = 0; samples = 0; variation = 0
        confidence = "low"; estimateText = ""
    }
}

public struct Headroom: Codable, Sendable {
    public var freeCoresP90 = 0.0
    public var memHeadroomGB = 0.0
    public var powerMarginW: Double?
    public var diskIOMBs = 0.0
    public var diskIOPeakMBs: Double?
    public var cards: [CostCard] = []
    public var verdict = ""
    public init() {}
}

public struct EventInfo: Codable, Sendable, Identifiable {
    public var id: Int64
    public var time: Date
    public var type: String                 // e.g. power.plugged, job.finished, alert.fired, guard.pause …
    public var subject: String?
    public var message: String
    public init(id: Int64, time: Date, type: String, subject: String?, message: String) {
        self.id = id; self.time = time; self.type = type; self.subject = subject; self.message = message
    }
}

public struct GuardRule: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var when: String                 // expression
    public var forSeconds: Double?          // condition must hold this long
    public var action: String               // pause | resume | notify
    public var group: String?
    public var resumeWhen: String?
    public var enabled: Bool?
    // runtime (read-only in API responses)
    public var active: Bool?
    public var lastFired: Date?
    public var error: String?
    public init(name: String, when: String, action: String) { self.name = name; self.when = when; self.action = action }
}

public struct SelfCost: Codable, Sendable {
    public var cpuPct = 0.0
    public var memMB = 0.0
    public var watts = 0.0
    public var intervalS = 10.0
    public init() {}
}

public struct Status: Codable, Sendable {
    public var time = Date()
    public var warmingUp = true             // true until the first full measurement interval has completed
    public var power = PowerInfo()
    public var cpu = CPUInfo()
    public var memory = MemoryInfo()
    public var disk = DiskInfo()
    public var volumes: [VolumeInfo] = []
    public var network = NetworkInfo()
    public var folders: [FolderInfo] = []
    public var topGroups: [GroupInfo] = []  // without per-process detail
    public var jobs: [JobInfo] = []
    public var jobGroups: [GroupETA] = []    // combined ETA per registered job group, with its basis
    public var alerts: [AlertInfo] = []
    public var headroom = Headroom()
    public var monitor = SelfCost()
    public var sources: [String: SourceStamp] = [:]
    public init() {}
}

public struct WaitResult: Codable, Sendable {
    public var met: Bool
    public var timedOut: Bool
    public var fired: String?
    public var waitedSeconds: Double
    public var status: Status?
    public init(met: Bool, timedOut: Bool, fired: String?, waitedSeconds: Double, status: Status?) {
        self.met = met; self.timedOut = timedOut; self.fired = fired; self.waitedSeconds = waitedSeconds; self.status = status
    }
}

public struct HistoryPoint: Codable, Sendable {
    public var t: Date
    public var v: Double?
    public init(t: Date, v: Double?) { self.t = t; self.v = v }
}

public struct APIError: Codable, Sendable {
    public var error: String
    public init(_ e: String) { error = e }
}

// MARK: - JSON helpers

public enum JSON {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return e
    }()
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
    public static func string<T: Encodable>(_ v: T) -> String {
        (try? encoder.encode(v)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// Where the app publishes its API endpoint + token (file is chmod 600).
public enum APIConfig {
    public static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Forkcast", isDirectory: true)
    }
    public static var file: URL { supportDir.appendingPathComponent("api.json") }
    public struct Info: Codable { public var port: UInt16; public var token: String
        public init(port: UInt16, token: String) { self.port = port; self.token = token } }
    public static let defaultPort: UInt16 = 47_215
}

/// Parses "90", "90s", "10m", "3h", "1d" into seconds.
public func parseDuration(_ s: String) -> Double? {
    let t = s.trimmingCharacters(in: .whitespaces).lowercased()
    guard let last = t.last else { return nil }
    let mult: Double
    var num = t
    switch last {
    case "s": mult = 1; num.removeLast()
    case "m": mult = 60; num.removeLast()
    case "h": mult = 3600; num.removeLast()
    case "d": mult = 86400; num.removeLast()
    default: mult = 1
    }
    return Double(num).map { $0 * mult }
}
