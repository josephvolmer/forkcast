import Foundation
import ForkcastCore

struct ExpectedRange: Codable {
    var minCPU: Double?          // percent (100 = one core); alert when below for `minutes`
    var maxCPU: Double?
    var minutes: Double = 10
}

struct CPUAlertConfig: Codable {
    var enabled = true
    var percent = 80.0
    var minutes = 3.0
    var muted: [String] = []     // group / job / label names that are *supposed* to be busy
}

struct AlertConfig: Codable {
    var chargerChange = true
    var pluggedDrainMinutes: Double? = 5        // net battery flow < 0 while on AC for N min
    var batteryLowOnBatteryPct: Double? = 20
    var batteryLowOnACPct: Double? = 10
    var diskFreeMinGB: Double? = 30
    var diskHoursToFloorMin: Double? = 6
    var memoryRedMinutes: Double? = 2
    var swapGrowthGBPerHour: Double? = 4
    var throttlingMinutes: Double? = 5
    var volumeUnmounted = true
    var jobStaleMinutes = 15.0
    var jobEnded = true
    var crashReports = true
    var backgroundWindow = true
    var dailyUploadGB: Double? = nil
    var cpu = CPUAlertConfig()
    var expectedCPU: [String: ExpectedRange] = [:]
}

struct DeliveryTarget: Codable {
    var notify: Bool?
    var webhook: String?          // POSTed JSON {type, subject, message, severity, time}
    var command: String?          // run with /bin/sh -c; FORKCAST_ALERT_* env vars set
}

struct DeliveryConfig: Codable {
    var notify = true
    var webhook: String?
    var command: String?
    var perType: [String: DeliveryTarget] = [:]
}

struct SamplingConfig: Codable {
    var visibleSeconds = 1.0
    var backgroundSeconds = 10.0
}

/// Everything user-tunable. Lives in ~/Library/Application Support/Forkcast/config.json;
/// missing keys fall back to these defaults, so the file can stay small.
struct Config: Codable {
    var alerts = AlertConfig()
    var delivery = DeliveryConfig()
    var guards: [GuardRule] = []
    var labelRules: [LabelRule] = []          // e.g. {"match": {"exe": "python3*", "arg_regex": "…"}, "label": "…"}
    var containerNames: [String] = ["claude", "codex", "cursor-agent", "aider", "gemini", "opencode", "goose"]
    var terminalApps: [String] = ["Terminal", "iTerm", "iTerm2", "Warp", "Alacritty", "kitty", "WezTerm",
                                  "Ghostty", "Hyper", "Tabby", "Code", "Cursor", "Claude"]
    var diskFloorGB = 40.0
    var watchedVolumes: [String] = []
    var autoWatchVolumes = true
    var watchedFolders: [String] = []
    var sampling = SamplingConfig()
}

final class ConfigStore {
    private(set) var config = Config()
    private var loadedMTime: Date?
    let url = APIConfig.supportDir.appendingPathComponent("config.json")
    private(set) var lastError: String?

    init() {
        try? FileManager.default.createDirectory(at: APIConfig.supportDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { save() }
        reloadIfChanged(force: true)
    }

    /// Re-reads the file if it changed on disk (cheap stat; called every tick).
    @discardableResult
    func reloadIfChanged(force: Bool = false) -> Bool {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard force || mtime != loadedMTime else { return false }
        loadedMTime = mtime
        guard let data = try? Data(contentsOf: url) else { return false }
        do {
            // Merge the user's (possibly partial) JSON over the defaults, then decode.
            let defaults = try JSONSerialization.jsonObject(with: JSON.encoder.encode(Config())) as! [String: Any]
            let user = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            let merged = Self.merge(defaults, user)
            config = try JSON.decoder.decode(Config.self, from: JSONSerialization.data(withJSONObject: merged))
            lastError = nil
            return true
        } catch {
            lastError = "config.json: \(error.localizedDescription)"
            return false
        }
    }

    func update(_ change: (inout Config) -> Void) {
        change(&config)
        save()
    }

    func save() {
        if let d = try? JSON.encoder.encode(config) {
            try? d.write(to: url, options: .atomic)
            loadedMTime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
    }

    static func merge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let b = base[k] as? [String: Any], let o = v as? [String: Any], !k.hasPrefix("expected"), k != "perType" {
                out[k] = merge(b, o)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
