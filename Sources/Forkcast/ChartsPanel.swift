import Charts
import ForkcastCore
import SwiftUI

func eventColor(_ type: String) -> Color {
    if type.hasPrefix("power") { return Palette.teal }
    if type.hasPrefix("system") { return .gray }
    if type.hasPrefix("alert.fired") || type == "crash" || type == "job.failed" || type == "job.crashed" { return Palette.red }
    if type.hasPrefix("guard") || type.hasPrefix("group") { return Palette.blue }
    if type.hasPrefix("job") { return Palette.purple }
    if type.hasPrefix("volume") || type.hasPrefix("headroom") { return Palette.amber }
    return .secondary
}

func eventIcon(_ type: String) -> String {
    switch type {
    case "power.plugged": return "powerplug.fill"
    case "power.unplugged": return "powerplug"
    case "power.charger": return "bolt.badge.clock"
    case "system.sleep": return "moon.zzz"
    case "system.wake": return "sun.max"
    case "system.boot", "monitor.started": return "power"
    case "system.shutdown", "monitor.stopped": return "power.dotted"
    case "alert.fired": return "exclamationmark.triangle.fill"
    case "alert.cleared": return "checkmark.circle"
    case "crash": return "ant.fill"
    case "volume.mounted": return "externaldrive.fill.badge.plus"
    case "volume.unmounted": return "externaldrive.badge.xmark"
    default:
        if type.hasPrefix("guard") { return "shield.lefthalf.filled" }
        if type.hasPrefix("group.paused") { return "pause.circle" }
        if type.hasPrefix("group.resumed") { return "play.circle" }
        if type.hasPrefix("job.finished") { return "checkmark.seal" }
        if type.hasPrefix("job.failed") || type.hasPrefix("job.crashed") { return "xmark.octagon" }
        if type.hasPrefix("job.stale") { return "hourglass" }
        if type.hasPrefix("job") { return "shippingbox" }
        if type.hasPrefix("headroom") { return "gauge.with.dots.needle.67percent" }
        return "circle.fill"
    }
}

/// Events worth drawing as markers on the charts.
let markerTypes: Set<String> = ["power.plugged", "power.unplugged", "power.charger", "system.sleep", "system.wake",
                                "system.boot", "system.shutdown", "alert.fired", "guard.pause", "guard.resume",
                                "group.paused", "group.resumed", "job.registered", "job.finished", "job.failed",
                                "job.crashed", "crash", "volume.unmounted", "headroom.saturated"]

struct Span: Identifiable { var id: Date { start }; let start: Date; let end: Date; let level: Double }

func spans(_ pts: [HistoryPoint], step: Double, where cond: (Double) -> Bool) -> [Span] {
    var out: [Span] = []
    var s: Date?
    var lvl = 0.0
    for (i, p) in pts.enumerated() {
        let on = p.v.map(cond) ?? false
        if on { if s == nil { s = p.t }; lvl = max(lvl, p.v ?? 0) }
        let gap = i + 1 < pts.count && pts[i + 1].t.timeIntervalSince(p.t) > step * 3
        if let st = s, !on || gap || i == pts.count - 1 {
            out.append(Span(start: st, end: on ? p.t.addingTimeInterval(step) : p.t, level: lvl))
            s = nil
            lvl = 0
        }
    }
    return out
}

struct ChartsPanel: View {
    @ObservedObject var charts: ChartsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionTitle("History")
                if let s = charts.selection {
                    Text("selected \(fmtTime(s.lowerBound)) – \(fmtTime(s.upperBound))").font(.caption).foregroundStyle(Palette.purple)
                    Button("Clear") { charts.selection = nil }.buttonStyle(.link).font(.caption)
                } else {
                    Text("drag across any chart to inspect a window").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("", selection: $charts.range) {
                    ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                CopyJSONButton { Dictionary(uniqueKeysWithValues: charts.series.map { ($0.key.apiName, $0.value) }) }
            }
            HoverReadout(charts: charts)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    BatteryChart(charts: charts)
                    NetFlowChart(charts: charts)
                    PowerSplitChart(charts: charts)
                    CPUChart(charts: charts)
                    MemoryChart(charts: charts)
                    DiskChart(charts: charts)
                    DrainsList(charts: charts).padding(.top, 8)
                }
                .padding(.trailing, 4)
            }
        }
        .padding(12)
    }
}

/// Values of every chart at the crosshair.
struct HoverReadout: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        Group {
            if let h = charts.hover {
                let v = { (m: Metric) in charts.value(m, at: h) }
                let parts: [String] = [
                    v(.battery).map { "battery \(Int($0))%" },
                    v(.net_battery_w).map { "net \(fmtSignedW($0))" },
                    v(.draw_w).map { "draw \(fmtW($0))" },
                    v(.cpu_w).map { "CPU \(fmtW($0))" },
                    v(.cpu_busy_cores).map { String(format: "%.1f cores busy", $0) },
                    v(.swap_gb).map { String(format: "swap %.1f GB", $0) },
                    v(.disk_free_gb).map { "disk \(fmtGB($0)) free" },
                ].compactMap { $0 }
                let near = charts.events.filter { abs($0.time.timeIntervalSince(h)) < max(90, Double(charts.range.rawValue) / 200) && markerTypes.contains($0.type) }
                HStack(spacing: 6) {
                    Text(DateFormatter.localizedString(from: h, dateStyle: charts.range.rawValue > 86400 ? .short : .none, timeStyle: .short))
                        .fontWeight(.semibold)
                    Text(parts.joined(separator: " · "))
                    if let e = near.first { Text("· \(e.message)").foregroundStyle(eventColor(e.type)).lineLimit(1) }
                }
            } else {
                Text("Hover the charts for values at a point in time · lines mark events (plug, sleep, alerts, jobs, guards)")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
        .frame(height: 16)
    }
}

// MARK: Shared overlays + interaction

struct OverlayMarks: ChartContent {
    let events: [EventInfo]
    let selection: ClosedRange<Date>?
    let hover: Date?
    let yLo: Double
    let yHi: Double
    @MainActor init(charts: ChartsModel, yLo: Double, yHi: Double) {
        events = charts.events.filter { markerTypes.contains($0.type) && $0.time >= charts.start }
        selection = charts.selection
        hover = charts.hover
        self.yLo = yLo
        self.yHi = yHi
    }
    var body: some ChartContent {
        ForEach(events) { e in
            RuleMark(x: .value("event", e.time))
                .foregroundStyle(eventColor(e.type).opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        if let s = selection {
            RectangleMark(xStart: .value("s", s.lowerBound), xEnd: .value("e", s.upperBound),
                          yStart: .value("lo", yLo), yEnd: .value("hi", yHi))
                .foregroundStyle(Palette.purple.opacity(0.14))
        }
        if let h = hover {
            RuleMark(x: .value("hover", h))
                .foregroundStyle(Color.gray.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }
}

struct TimeInteraction: ViewModifier {
    let charts: ChartsModel
    var showX = false
    func body(content: Content) -> some View {
        content
            .chartXScale(domain: charts.start...charts.end)
            .chartXAxis(showX ? .automatic : .hidden)
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let origin = proxy.plotFrame.map { geo[$0].origin } ?? .zero
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(pt): charts.hover = proxy.value(atX: pt.x - origin.x, as: Date.self)
                            case .ended: charts.hover = nil
                            }
                        }
                        .gesture(DragGesture(minimumDistance: 4).onChanged { v in
                            if let a: Date = proxy.value(atX: v.startLocation.x - origin.x),
                               let b: Date = proxy.value(atX: v.location.x - origin.x) {
                                charts.selection = min(a, b)...max(a, b)
                            }
                        })
                }
            }
    }
}

func axis(_ fmt: @escaping (Double) -> String) -> some AxisContent {
    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
        AxisValueLabel { Text(fmt(v.as(Double.self) ?? 0)).font(.system(size: 9).monospacedDigit()).frame(width: 40, alignment: .leading) }
    }
}

struct ChartTitle: View {
    let text: String
    var color: Color = .secondary
    var body: some View { Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(color) }
}

@MainActor func points(_ charts: ChartsModel, _ m: Metric) -> [(Date, Double)] {
    (charts.series[m] ?? []).compactMap { p in p.v.map { (p.t, $0) } }
}

// MARK: The six charts

struct BatteryChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let pts = points(charts, .battery)
        let step = max(60, Double(charts.range.rawValue) / 240)
        let plugged = spans(charts.series[.on_ac] ?? [], step: step) { $0 >= 0.5 }
        VStack(alignment: .leading, spacing: 1) {
            HStack { ChartTitle(text: "Battery %"); Text("green = plugged in").font(.system(size: 9)).foregroundStyle(Palette.teal.opacity(0.8)) }
            Chart {
                ForEach(plugged) { s in
                    RectangleMark(xStart: .value("s", s.start), xEnd: .value("e", s.end), yStart: .value("lo", 0), yEnd: .value("hi", 100))
                        .foregroundStyle(Palette.teal.opacity(0.10))
                }
                ForEach(pts, id: \.0) { p in
                    LineMark(x: .value("t", p.0), y: .value("%", p.1)).foregroundStyle(Palette.teal).lineStyle(StrokeStyle(lineWidth: 2))
                }
                OverlayMarks(charts: charts, yLo: 0, yHi: 100)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { axis { "\(Int($0))%" } }
            .modifier(TimeInteraction(charts: charts))
            .frame(height: 92)
        }
    }
}

struct NetFlowChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let pts = points(charts, .net_battery_w)
        let lo = min(0, pts.map(\.1).min() ?? 0) - 1, hi = max(0, pts.map(\.1).max() ?? 0) + 1
        VStack(alignment: .leading, spacing: 1) {
            ChartTitle(text: "Net battery flow (W) — above 0 charging, below 0 draining")
            Chart {
                ForEach(pts, id: \.0) { p in
                    AreaMark(x: .value("t", p.0), yStart: .value("0", 0), yEnd: .value("W", max(0, p.1)), series: .value("s", "in"))
                        .foregroundStyle(Palette.teal.opacity(0.5))
                    AreaMark(x: .value("t", p.0), yStart: .value("0", 0), yEnd: .value("W", min(0, p.1)), series: .value("s", "out"))
                        .foregroundStyle(Palette.red.opacity(0.55))
                }
                RuleMark(y: .value("zero", 0)).foregroundStyle(Color.primary.opacity(0.3))
                OverlayMarks(charts: charts, yLo: lo, yHi: hi)
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis { axis { String(format: "%+.0f", $0) } }
            .modifier(TimeInteraction(charts: charts))
            .frame(height: 70)
        }
    }
}

struct PowerSplitChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let parts: [(String, Metric, Color)] = [("CPU", .cpu_w, Palette.orange), ("GPU", .gpu_w, Palette.purple),
                                                ("Memory/SoC", .soc_w, Palette.blue), ("Display & other", .other_w, Palette.cream)]
        let maxDraw = (points(charts, .draw_w).map(\.1).max() ?? 10) * 1.1
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                ChartTitle(text: "Total power (W)")
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 3) { Dot(color: p.2, size: 6); Text(p.0) }.font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            Chart {
                ForEach(parts, id: \.0) { part in
                    ForEach(points(charts, part.1), id: \.0) { p in
                        AreaMark(x: .value("t", p.0), y: .value("W", p.1), stacking: .standard)
                            .foregroundStyle(by: .value("part", part.0))
                    }
                }
                OverlayMarks(charts: charts, yLo: 0, yHi: maxDraw)
            }
            .chartForegroundStyleScale(domain: parts.map(\.0), range: parts.map { $0.2.opacity(0.75) })
            .chartYScale(domain: 0...max(5, maxDraw))
            .chartYAxis { axis { "\(Int($0))" } }
            .modifier(TimeInteraction(charts: charts))
            .frame(height: 80)
        }
    }
}

struct CPUChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let pts = points(charts, .cpu_busy_cores)
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let step = max(60, Double(charts.range.rawValue) / 240)
        let hot = spans(charts.series[.thermal] ?? [], step: step) { $0 >= 0.5 }
        VStack(alignment: .leading, spacing: 1) {
            HStack { ChartTitle(text: "CPU busy (cores)"); Text("shaded = thermal fair or worse").font(.system(size: 9)).foregroundStyle(Palette.amber.opacity(0.8)) }
            Chart {
                ForEach(hot) { s in
                    RectangleMark(xStart: .value("s", s.start), xEnd: .value("e", s.end), yStart: .value("lo", 0), yEnd: .value("hi", cores))
                        .foregroundStyle((s.level >= 1.5 ? Palette.red : Palette.amber).opacity(0.13))
                }
                ForEach(pts, id: \.0) { p in
                    AreaMark(x: .value("t", p.0), y: .value("cores", p.1)).foregroundStyle(Palette.purple.opacity(0.25))
                    LineMark(x: .value("t", p.0), y: .value("cores", p.1)).foregroundStyle(Palette.purple)
                }
                OverlayMarks(charts: charts, yLo: 0, yHi: cores)
            }
            .chartYScale(domain: 0...cores)
            .chartYAxis { axis { "\(Int($0))" } }
            .modifier(TimeInteraction(charts: charts))
            .frame(height: 70)
        }
    }
}

struct MemoryChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let used = points(charts, .mem_used_gb), swap = points(charts, .swap_gb)
        let step = max(60, Double(charts.range.rawValue) / 240)
        let pressure = spans(charts.series[.mem_pressure] ?? [], step: step) { $0 >= 0.5 }
        let hi = max(ProcessInfo.processInfo.physicalMemory > 0 ? Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 : 16,
                     (swap.map(\.1).max() ?? 0) + 1)
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                ChartTitle(text: "Memory (GB)")
                HStack(spacing: 3) { Dot(color: Palette.blue, size: 6); Text("used") }.font(.system(size: 9)).foregroundStyle(.secondary)
                HStack(spacing: 3) { Dot(color: Palette.orange, size: 6); Text("swap") }.font(.system(size: 9)).foregroundStyle(.secondary)
                Text("shaded = pressure yellow/red").font(.system(size: 9)).foregroundStyle(Palette.amber.opacity(0.8))
            }
            Chart {
                ForEach(pressure) { s in
                    RectangleMark(xStart: .value("s", s.start), xEnd: .value("e", s.end), yStart: .value("lo", 0), yEnd: .value("hi", hi))
                        .foregroundStyle((s.level >= 1.5 ? Palette.red : Palette.amber).opacity(0.15))
                }
                ForEach(used, id: \.0) { p in
                    LineMark(x: .value("t", p.0), y: .value("GB", p.1), series: .value("s", "used")).foregroundStyle(Palette.blue)
                }
                ForEach(swap, id: \.0) { p in
                    LineMark(x: .value("t", p.0), y: .value("GB", p.1), series: .value("s", "swap")).foregroundStyle(Palette.orange)
                }
                OverlayMarks(charts: charts, yLo: 0, yHi: hi)
            }
            .chartYScale(domain: 0...hi)
            .chartYAxis { axis { "\(Int($0))" } }
            .modifier(TimeInteraction(charts: charts))
            .frame(height: 70)
        }
    }
}

struct DiskChart: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let pts = points(charts, .disk_free_gb)
        let floor = AppModel.shared.live.snap?.status.disk.floorGB ?? 40
        let lo = max(0, min(floor, pts.map(\.1).min() ?? floor) - 10), hi = (pts.map(\.1).max() ?? floor + 50) + 10
        VStack(alignment: .leading, spacing: 1) {
            ChartTitle(text: "Disk free (GB) — dashed line = floor")
            Chart {
                ForEach(pts, id: \.0) { p in
                    LineMark(x: .value("t", p.0), y: .value("GB", p.1)).foregroundStyle(Palette.cream)
                }
                RuleMark(y: .value("floor", floor)).foregroundStyle(Palette.red.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                OverlayMarks(charts: charts, yLo: lo, yHi: hi)
            }
            .chartYScale(domain: lo...hi)
            .chartYAxis { axis { "\(Int($0))" } }
            .modifier(TimeInteraction(charts: charts, showX: true))
            .frame(height: 78)
        }
    }
}

// MARK: What drained

struct DrainsList: View {
    @ObservedObject var charts: ChartsModel
    var body: some View {
        let title = charts.selection.map { "What used the energy · \(fmtTime($0.lowerBound)) – \(fmtTime($0.upperBound))" }
            ?? "What used the energy · \(charts.range.phrase)"
        let maxJ = max(charts.drains.first?.joules ?? 1, 0.001)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                SectionTitle(title)
                Spacer()
                Toggle("On battery only", isOn: $charts.batteryOnly).toggleStyle(.checkbox).font(.caption)
                CopyJSONButton { charts.drains }
            }
            if charts.drains.isEmpty {
                Text(charts.batteryOnly ? "No time on battery in this window." : "No data for this window yet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(charts.drains) { d in
                HStack(spacing: 8) {
                    AppIcon(path: d.path, kind: d.path == nil ? "job" : "app")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Bar(fraction: d.joules / maxJ, color: Palette.purple, height: 3)
                    }
                    Text(fmtEnergy(d.joules)).font(.system(size: 11, weight: .semibold).monospacedDigit()).frame(width: 62, alignment: .trailing)
                    Text(charts.drainTotalJ > 0 ? "\(max(0, Int((d.joules / charts.drainTotalJ * 100).rounded())))%" : "")
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                        .help("Share of the whole Mac's energy in this window")
                }
            }
            if charts.drainTotalJ > 0 {
                Text("Whole Mac used \(fmtEnergy(charts.drainTotalJ)) in this window, including the screen.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
