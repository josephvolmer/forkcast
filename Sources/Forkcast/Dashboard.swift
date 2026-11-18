import AppKit
import ForkcastCore
import SwiftUI

/// Full one-page dashboard (window).
struct Dashboard: View {
    @MainActor var model: AppModel { AppModel.shared }

    var body: some View {
        VStack(spacing: 8) {
            HeaderRow(live: model.live, charts: model.charts)
            VerdictBar(live: model.live)
            HSplitView {
                JobsPanel(live: model.live)
                    .frame(minWidth: 430, idealWidth: 540, maxWidth: 760)
                ChartsPanel(charts: model.charts)
                    .frame(minWidth: 520)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
            BottomPanel(live: model.live, charts: model.charts)
                .frame(height: 210)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
            Footer(live: model.live)
        }
        .padding(10)
        .frame(minWidth: 1180, minHeight: 820)
        .background(VisibilityReader { id, v in AppModel.shared.setHost(id, visible: v) })
    }
}

struct Footer: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var app = AppModel.shared

    var body: some View {
        HStack(spacing: 14) {
            if let s = live.snap?.status {
                Label(String(format: "Forkcast itself: %@ CPU · %@ · %@ · sampling every %.0f s",
                             fmtCPU(s.monitor.cpuPct), fmtW(s.monitor.watts), fmtMem(s.monitor.memMB), s.monitor.intervalS),
                      systemImage: "leaf")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Sampling slows down when no Forkcast window is open (every 10 s by default).")
                Text("API 127.0.0.1:\(String(app.api.port)) · `forkcast status`").font(.caption).foregroundStyle(.tertiary)
                    .help("Token: \(APIConfig.file.path)")
                CopyJSONButton { s }
                    .help("Copy the full status as JSON")
            }
            if let e = app.launchError { Text(e).font(.caption).foregroundStyle(Palette.red).lineLimit(1) }
            Spacer()
            Toggle("Open at login", isOn: Binding(get: { app.launchAtLogin }, set: { app.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox).font(.caption)
            Button("Quit Forkcast") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 4)
    }
}

/// Compact view for the menu bar.
struct CompactView: View {
    @ObservedObject var live = AppModel.shared.live

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let snap = live.snap {
                let s = snap.status
                CompactHeader(s: s)
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.dots.needle.33percent").foregroundStyle(Palette.purple)
                    Text(s.headroom.verdict).font(.caption.weight(.semibold)).lineLimit(2)
                }
                if !s.alerts.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(s.alerts.prefix(3)) { a in
                            Label(a.message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(severityColor(a.severity)).lineLimit(2)
                        }
                    }
                }
                let active = s.jobs.filter { !$0.isFinished }
                if !active.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle("Jobs")
                        ForEach(active.prefix(6)) { j in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Dot(color: jobHealth(j, staleMinutes: snap.staleMinutes))
                                    Text("\(j.group)/\(j.name)").font(.caption.weight(.semibold)).lineLimit(1)
                                    Spacer()
                                    Text(j.etaSeconds.map { "ETA \(fmtDuration($0))" } ?? j.state).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                if let f = j.fraction { Bar(fraction: f, color: jobHealth(j, staleMinutes: snap.staleMinutes), height: 3) }
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    SectionTitle("Using power now")
                    ForEach(snap.groups.filter { $0.kind != "system" }.prefix(5)) { g in
                        HStack(spacing: 6) {
                            AppIcon(path: g.iconPath, kind: g.kind)
                            Text(g.label).font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(fmtW(g.watts)).font(.caption.monospacedDigit().weight(.semibold))
                            Text(fmtCPU(g.cpuPct)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                        }
                        .help(groupTooltip(g))
                    }
                }
                Divider()
                HStack {
                    Button("Open dashboard") { AppDelegate.showWindow() }.keyboardShortcut("d")
                    CopyJSONButton { s }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
            } else {
                ProgressView("Measuring…").frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .padding(14)
        .frame(width: 400)
        .background(VisibilityReader { id, v in AppModel.shared.setHost(id, visible: v) })
    }
}

struct CompactHeader: View {
    let s: Status
    var body: some View {
        let p = s.power
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(p.batteryPct.map { "\($0)%" } ?? "–").font(.system(size: 24, weight: .bold, design: .rounded))
                if let n = p.netBatteryW {
                    Text(fmtSignedW(n)).font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(n >= 0.05 ? Palette.teal : p.onAC ? Palette.red : Palette.orange)
                }
                Spacer()
                Text(fmtW(p.drawW)).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(marginColor(p))
            }
            HStack {
                Text(p.onAC ? "Charger \(p.chargerW.map { "\(Int($0)) W" } ?? "?")" : "On battery")
                if let h = p.hoursToFull { Text("· full in ~\(fmtDuration(h * 3600))") }
                if let h = p.hoursToEmpty { Text("· empty in ~\(fmtDuration(h * 3600))") }
                Spacer()
                Text(String(format: "%.1f/%d cores · mem %@ · disk %@", s.cpu.busyCores, s.cpu.totalCores, s.memory.pressure, fmtGB(s.disk.freeInclPurgeableGB)))
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}
