import AppKit
import ForkcastCore
import ServiceManagement
import SwiftUI

/// Palette taken from the app icon.
enum Palette {
    static let teal = Color(red: 0.24, green: 0.88, blue: 0.64)
    static let purple = Color(red: 0.62, green: 0.45, blue: 1.0)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.26)
    static let cream = Color(red: 0.95, green: 0.91, blue: 0.82)
    static let red = Color(red: 1.0, green: 0.36, blue: 0.36)
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.2)
    static let blue = Color(red: 0.35, green: 0.62, blue: 1.0)
}

enum ChartRange: Int, CaseIterable, Identifiable {
    case h1 = 3600, h6 = 21600, h24 = 86400, d7 = 604_800, d30 = 2_592_000
    var id: Int { rawValue }
    var label: String { ["1H", "6H", "24H", "7D", "30D"][Self.allCases.firstIndex(of: self)!] }
    var phrase: String { ["last hour", "last 6 hours", "last 24 hours", "last 7 days", "last 30 days"][Self.allCases.firstIndex(of: self)!] }
}

/// Live data, updated every sample while a dashboard is visible.
@MainActor
final class LiveModel: ObservableObject {
    @Published var snap: UISnapshot?
    @Published var expanded: Set<String> = [] { didSet { AppModel.shared.engine.setExpanded(expanded) } }
    @Published var groupBy = "job" { didSet { AppModel.shared.refreshAppGroups() } }
    @Published var appGroups: [GroupInfo] = []
    @Published var lastLooked: Date = Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: "lastLooked"))
}

/// History for the charts and sparklines. Refreshed every minute while visible.
@MainActor
final class ChartsModel: ObservableObject {
    @Published var range: ChartRange = .h24 { didSet { selection = nil; AppModel.shared.loadCharts() } }
    @Published var selection: ClosedRange<Date>? { didSet { AppModel.shared.scheduleDrains() } }
    @Published var hover: Date?
    @Published var batteryOnly = false { didSet { AppModel.shared.loadDrains() } }
    @Published var series: [Metric: [HistoryPoint]] = [:]
    @Published var spark: [Metric: [HistoryPoint]] = [:]
    @Published var events: [EventInfo] = []
    @Published var drains: [Drain] = []
    @Published var drainTotalJ = 0.0
    @Published var start = Date().addingTimeInterval(-86400)
    @Published var end = Date()

    nonisolated static let chartMetrics: [Metric] = [.battery, .on_ac, .net_battery_w, .draw_w, .cpu_w, .gpu_w, .soc_w, .other_w,
                                         .cpu_busy_cores, .thermal, .mem_pressure, .swap_gb, .mem_used_gb, .disk_free_gb]
    nonisolated static let sparkMetrics: [Metric] = [.draw_w, .net_battery_w, .cpu_busy_cores, .mem_used_gb, .disk_free_gb,
                                         .net_down_mb, .disk_write_mb]

    func value(_ m: Metric, at d: Date) -> Double? {
        guard let pts = series[m], !pts.isEmpty else { return nil }
        var best: HistoryPoint?
        var bestDist = Double.infinity
        for p in pts {
            let dist = abs(p.t.timeIntervalSince(d))
            if dist < bestDist { bestDist = dist; best = p }
        }
        let step = Double(range.rawValue) / 240
        return bestDist <= max(120, step * 1.5) ? best?.v : nil
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let engine = Engine()
    lazy var api = APIServer(engine: engine)
    let live = LiveModel()
    let charts = ChartsModel()

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var launchError: String?
    private var hosts = Set<ObjectIdentifier>()
    private var chartTimer: Timer?
    private var drainWork: DispatchWorkItem?
    private var sparkAt = Date.distantPast
    var isVisible: Bool { !hosts.isEmpty }

    func start() {
        engine.onSnapshot = { [weak self] snap in
            DispatchQueue.main.async { self?.apply(snap) }
        }
        engine.start()
        api.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [engine] _ in
            engine.shutdown()
        }
        UNUserNotificationCenterBridge.request()
    }

    private func apply(_ snap: UISnapshot) {
        if isVisible, !snap.groups.isEmpty { live.snap = snap }
    }

    // MARK: Visibility (menu bar panel and/or dashboard window)

    func setHost(_ id: ObjectIdentifier, visible: Bool) {
        let was = isVisible
        if visible { hosts.insert(id) } else { hosts.remove(id) }
        guard was != isVisible else { return }
        engine.setVisible(isVisible, expanded: live.expanded)
        if isVisible {
            loadCharts()
            chartTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { AppModel.shared.loadCharts() }
            }
            chartTimer?.tolerance = 10
        } else {
            chartTimer?.invalidate()
            chartTimer = nil
            live.lastLooked = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastLooked")
        }
    }

    // MARK: History loading (off the main thread)

    func loadCharts() {
        let range = charts.range
        let engine = self.engine
        let needSpark = Date().timeIntervalSince(sparkAt) > 300
        if needSpark { sparkAt = Date() }
        DispatchQueue.global(qos: .userInitiated).async {
            let step = max(60, Double(range.rawValue) / 240)
            var s: [Metric: [HistoryPoint]] = [:]
            for m in ChartsModel.chartMetrics { s[m] = engine.history(metric: m, rangeSeconds: Double(range.rawValue), stepSeconds: step) }
            var sp: [Metric: [HistoryPoint]] = [:]
            if needSpark {
                for m in ChartsModel.sparkMetrics { sp[m] = engine.history(metric: m, rangeSeconds: 86400, stepSeconds: 900) }
            }
            let evs = engine.events(since: Date().addingTimeInterval(-Double(range.rawValue)), types: [], limit: 400)
            let series = s, sparks = sp
            DispatchQueue.main.async {
                let c = AppModel.shared.charts
                c.end = Date()
                c.start = c.end.addingTimeInterval(-Double(range.rawValue))
                c.series = series
                if needSpark { c.spark = sparks }
                c.events = evs
                AppModel.shared.loadDrains()
            }
        }
    }

    func scheduleDrains() {
        drainWork?.cancel()
        let w = DispatchWorkItem { AppModel.shared.loadDrains() }
        drainWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    func loadDrains() {
        let sel = charts.selection
        let from = sel?.lowerBound ?? charts.start
        let to = sel?.upperBound ?? Date()
        let bo = charts.batteryOnly
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let (d, total) = engine.drains(from: from, to: to, batteryOnly: bo)
            DispatchQueue.main.async {
                AppModel.shared.charts.drains = d
                AppModel.shared.charts.drainTotalJ = total
            }
        }
    }

    func refreshAppGroups() {
        guard live.groupBy == "app" else { return }
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async {
            let gs = engine.processes(groupBy: "app", limit: 0)
            DispatchQueue.main.async { AppModel.shared.live.appGroups = gs }
        }
    }

    // MARK: Actions

    func togglePause(_ name: String, paused: Bool) {
        let engine = self.engine
        DispatchQueue.global(qos: .userInitiated).async { _ = engine.apiPause(name, resume: paused) }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch { launchError = error.localizedDescription }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    static func copyJSON<T: Encodable>(_ v: T) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(JSON.string(v), forType: .string)
    }
}

import UserNotifications
enum UNUserNotificationCenterBridge {
    static func request() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - Formatting

func fmtW(_ w: Double?) -> String {
    guard let w else { return "–" }
    let a = abs(w)
    if a >= 10 { return String(format: "%.0f W", w) }
    if a >= 0.095 { return String(format: "%.1f W", w) }
    if a >= 0.005 { return String(format: "%.2f W", w) }
    return "0 W"
}
func fmtSignedW(_ w: Double) -> String { (w >= 0 ? "+" : "−") + fmtW(abs(w)) }
func fmtCPU(_ c: Double) -> String { c >= 10 ? "\(Int(c.rounded()))%" : String(format: "%.1f%%", c) }
func fmtMem(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : "\(Int(mb.rounded())) MB" }
func fmtGB(_ gb: Double?) -> String {
    guard let gb else { return "–" }
    return gb >= 100 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
}
func fmtEnergy(_ j: Double) -> String {
    let wh = j / 3600
    if wh >= 10 { return String(format: "%.0f Wh", wh) }
    if wh >= 0.1 { return String(format: "%.1f Wh", wh) }
    if wh >= 0.001 { return String(format: "%.0f mWh", wh * 1000) }
    return "<1 mWh"
}
func fmtTime(_ d: Date) -> String { DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) }
func fmtAgo(_ d: Date?) -> String { d.map { fmtDuration(Date().timeIntervalSince($0)) + " ago" } ?? "–" }

/// Power colour relative to the charger: green margin > 5 W, amber 0–5 W, red when the battery drains on AC.
func marginColor(_ p: PowerInfo) -> Color {
    guard p.onAC, let m = p.marginW else { return .primary }
    return m > 5 ? Palette.teal : m >= 0 ? Palette.amber : Palette.red
}
func severityColor(_ s: String) -> Color { s == "critical" ? Palette.red : s == "info" ? .secondary : Palette.amber }
