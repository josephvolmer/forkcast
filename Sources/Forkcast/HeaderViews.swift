import ForkcastCore
import SwiftUI

func sourceHelp(_ s: Status, _ keys: [String]) -> String {
    keys.compactMap { k in
        s.sources[k].map { "\($0.source) · sampled \(fmtDuration(Date().timeIntervalSince($0.sampledAt))) ago" }
    }.joined(separator: "\n")
}

struct HeaderRow: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var charts: ChartsModel

    var body: some View {
        if let s = live.snap?.status {
            HStack(alignment: .top, spacing: 8) {
                BatteryTile(s: s).frame(minWidth: 230)
                PowerTile(s: s, spark: charts.spark[.draw_w] ?? []).frame(minWidth: 250)
                CPUTile(s: s, spark: charts.spark[.cpu_busy_cores] ?? [])
                MemoryTile(s: s, spark: charts.spark[.mem_used_gb] ?? [])
                DiskTile(s: s, spark: charts.spark[.disk_free_gb] ?? [])
                IOTile(s: s, spark: charts.spark[.net_down_mb] ?? [])
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BatteryTile: View {
    let s: Status
    var body: some View {
        let p = s.power
        Tile(title: "Battery", source: sourceHelp(s, ["power.battery"]), json: { AnyEncodableBox(p) }) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.batteryPct.map { "\($0)%" } ?? "–")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                if let n = p.netBatteryW {
                    Text(fmtSignedW(n))
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(n >= 0.05 ? Palette.teal : n <= -0.05 ? (p.onAC ? Palette.red : Palette.orange) : .secondary)
                        .help("Net battery flow = battery voltage × current. + into the battery, − out of it. This is the truth even when macOS says \"charging\".")
                    Text(n >= 0 ? "into battery" : "out of battery").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(p.onAC ? "Charger \(p.chargerW.map { "\(Int($0)) W" } ?? "?") · Using \(fmtW(p.drawW))" : "On battery · Using \(fmtW(p.drawW))")
                .font(.callout)
            Group {
                if p.fullyCharged { Text("Fully charged") }
                else if let h = p.hoursToFull { Text("Full in ~\(fmtDuration(h * 3600)) at current flow") }
                else if let h = p.hoursToEmpty { Text("Empty in ~\(fmtDuration(h * 3600)) at current draw").foregroundStyle(p.onAC ? Palette.red : .secondary) }
                else { Text(p.onAC ? "Holding steady" : "–") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(p.macosMinutesRemaining.map { "macOS' own estimate: \(fmtDuration(Double($0) * 60))" } ?? "")
        }
    }
}

struct PowerTile: View {
    let s: Status
    let spark: [HistoryPoint]
    var body: some View {
        let p = s.power
        Tile(title: "Total draw", source: sourceHelp(s, ["power.battery", "power.cpu"]), json: { AnyEncodableBox(p) }) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fmtW(p.drawW))
                    .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(marginColor(p))
                if let m = p.marginW, p.onAC {
                    Text(m >= 0 ? "\(Int(m)) W under the charger" : "\(Int(-m)) W over the charger")
                        .font(.caption).foregroundStyle(marginColor(p))
                }
            }
            Text(reconciliation(p))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .help("CPU, GPU and memory/SoC are measured by the chip's energy counters (IOReport). \"Display & other\" is the remainder of the battery controller's system load: backlight, SSD, Wi-Fi, audio, conversion losses.")
            Sparkline(points: spark, color: Palette.orange).equatable()
        }
    }

    func reconciliation(_ p: PowerInfo) -> String {
        guard let d = p.drawW else { return "" }
        let soc = (p.socW ?? 0) + (p.aneW ?? 0)
        return "CPU \(fmtW(p.cpuW)) · GPU \(fmtW(p.gpuW)) · mem/SoC \(fmtW(soc)) · display & other ~\(fmtW(p.otherW)) = \(fmtW(d))"
    }
}

struct CPUTile: View {
    let s: Status
    let spark: [HistoryPoint]
    var body: some View {
        let c = s.cpu
        Tile(title: "CPU", source: sourceHelp(s, ["cpu"]), json: { AnyEncodableBox(c) }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(String(format: "%.1f", c.busyCores)).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                Text("/ \(c.totalCores) cores busy").font(.caption).foregroundStyle(.secondary)
            }
            Text("P \(Int(c.pBusyPct))% · E \(Int(c.eBusyPct))%").font(.caption.monospacedDigit())
            HStack(spacing: 4) {
                Tag(text: c.thermal, color: c.thermal == "nominal" ? Palette.teal : c.thermal == "fair" ? Palette.amber : Palette.red)
                if c.throttling { Tag(text: "THROTTLING", color: Palette.red) }
            }
            Sparkline(points: spark, color: Palette.purple).equatable()
        }
    }
}

struct MemoryTile: View {
    let s: Status
    let spark: [HistoryPoint]
    var body: some View {
        let m = s.memory
        let col = m.pressure == "red" ? Palette.red : m.pressure == "yellow" ? Palette.amber : Palette.teal
        Tile(title: "Memory", source: sourceHelp(s, ["memory"]), json: { AnyEncodableBox(m) }) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Dot(color: col, size: 10)
                Text(m.pressure).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(col)
            }
            Text("\(fmtGB(m.usedGB)) of \(Int(m.totalGB)) GB · compr. \(fmtGB(m.compressedGB))").font(.caption.monospacedDigit())
            Text("swap \(fmtGB(m.swapUsedGB))" + (m.swapGrowthGBPerHour.map { String(format: " (%+.1f GB/h)", $0) } ?? ""))
                .font(.caption.monospacedDigit())
                .foregroundStyle((m.swapGrowthGBPerHour ?? 0) > 1 ? Palette.amber : .secondary)
            Sparkline(points: spark, color: Palette.blue).equatable()
        }
    }
}

struct DiskTile: View {
    let s: Status
    let spark: [HistoryPoint]
    var body: some View {
        let d = s.disk
        let low = d.freeInclPurgeableGB < d.floorGB * 1.25
        Tile(title: "Disk (internal)", source: sourceHelp(s, ["disk"]), json: { AnyEncodableBox(d) }) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(fmtGB(d.freeInclPurgeableGB)).font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(low ? Palette.red : .primary)
                Text("free").font(.caption).foregroundStyle(.secondary)
            }
            Group {
                if let h = d.hoursToFloor {
                    Text(String(format: "%+.1f GB/h · hits %d GB in ~%@", d.trendGBPerHour ?? 0, Int(d.floorGB), fmtDuration(h * 3600)))
                        .foregroundStyle(h < 12 ? Palette.amber : .secondary)
                } else if let t = d.trendGBPerHour {
                    Text(String(format: "%+.1f GB/h · floor %d GB", t, Int(d.floorGB))).foregroundStyle(.secondary)
                } else {
                    Text("trend after ~15 min · floor \(Int(d.floorGB)) GB").foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            Text("purgeable \(fmtGB(d.purgeableGB))" + (d.tmLocalSnapshots.map { " · \($0) TM snapshot\($0 == 1 ? "" : "s")" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
                .help("Purgeable space includes caches and Time Machine local snapshots; macOS frees it when needed.")
            Sparkline(points: spark, color: Palette.cream).equatable()
        }
    }
}

struct IOTile: View {
    let s: Status
    let spark: [HistoryPoint]
    var body: some View {
        let n = s.network, d = s.disk
        Tile(title: "Network · Disk I/O · Drives", source: sourceHelp(s, ["network", "network.top", "disk.io"]),
             json: { AnyEncodableBox(["network": AnyEncodableBox(n), "volumes": AnyEncodableBox(s.volumes), "folders": AnyEncodableBox(s.folders)]) }) {
            Text(String(format: "↓ %.1f  ↑ %.1f MB/s", n.downMBs, n.upMBs)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            Text(String(format: "today ↓%.1f ↑%.1f GB", n.todayDownGB, n.todayUpGB) + (n.topProcess.map { " · \($0)" } ?? ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            Text(String(format: "disk r %.0f · w %.0f MB/s", d.readMBs, d.writeMBs) + (d.topIOProcess.map { " · \($0)" } ?? ""))
                .font(.caption.monospacedDigit()).lineLimit(1)
            ForEach(s.volumes.prefix(3)) { v in
                HStack(spacing: 4) {
                    Image(systemName: v.mounted ? "externaldrive.fill" : "externaldrive.badge.xmark")
                        .foregroundStyle(v.mounted ? Color.secondary : Palette.red)
                    Text(v.name).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(v.mounted ? fmtGB(v.freeGB) : "unmounted").foregroundStyle(v.mounted ? Color.secondary : Palette.red)
                }
                .font(.caption2.monospacedDigit())
                .help(v.lastChange.map { "Last change in free space: \(fmtAgo($0))" } ?? "No writes seen since Forkcast started")
            }
            ForEach(s.folders) { f in
                HStack(spacing: 4) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(fmtGB(f.sizeGB) + (f.growthGBPerHour.map { String(format: " %+.1f/h", $0) } ?? "")).foregroundStyle(.secondary)
                }
                .font(.caption2.monospacedDigit())
                .help(f.path)
            }
        }
    }
}

/// "Can I add more?" in plain words, with the cost cards one click away.
struct VerdictBar: View {
    @ObservedObject var live: LiveModel
    @State private var showCards = false

    var body: some View {
        if let s = live.snap?.status {
            let h = s.headroom
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Palette.purple)
                    Text(h.verdict).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(freeLine(h)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if !h.cards.isEmpty {
                        Button(showCards ? "Hide cost cards" : "Cost cards (\(h.cards.count))") { showCards.toggle() }
                            .buttonStyle(.link).font(.caption)
                    }
                    CopyJSONButton { h }
                }
                if showCards {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) { ForEach(h.cards) { CostCardView(c: $0) } }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.purple.opacity(0.08)))
            .help("Free CPU is the 90th-percentile over the last 30 min. Estimates are floor(free ÷ per-instance p90 cost) for each resource; the smallest names the bottleneck.")
        }
    }

    func freeLine(_ h: Headroom) -> String {
        var parts = [String(format: "free %.1f cores (p90)", h.freeCoresP90), "\(fmtGB(h.memHeadroomGB)) memory"]
        if let m = h.powerMarginW { parts.append(String(format: "%+.0f W power", m)) }
        if let peak = h.diskIOPeakMBs { parts.append(String(format: "I/O %.0f/%.0f MB/s", h.diskIOMBs, peak)) }
        return parts.joined(separator: " · ")
    }
}

struct CostCardView: View {
    let c: CostCard
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(c.label) (\(c.instances) active\(c.waiting > 0 ? ", \(c.waiting) waiting" : ""))").font(.caption.weight(.semibold)).lineLimit(1)
            Text(String(format: "each ≈ %.2f cores (p90) · %.1f GB peak · %.1f W · %.0f MB/min disk", c.coresP90, c.memPeakGB, c.wattsP90, c.diskMBPerMin))
                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            Text(c.estimateText).font(.caption2).foregroundStyle(c.confidence == "high" ? Palette.teal : c.confidence == "medium" ? Palette.amber : .secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(width: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
