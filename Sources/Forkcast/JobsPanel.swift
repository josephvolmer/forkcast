import ForkcastCore
import SwiftUI

func groupTooltip(_ g: GroupInfo) -> String {
    var lines: [String] = []
    if let c = g.command { lines.append("$ " + c) }
    if let p = g.rootPid { lines.append("PID \(p)") }
    if !g.parentChain.isEmpty { lines.append("Parents: " + g.parentChain.joined(separator: " ← ")) }
    if let t = g.startTime { lines.append("Started " + DateFormatter.localizedString(from: t, dateStyle: .short, timeStyle: .medium)) }
    if let d = g.cwd { lines.append("Working dir: " + d) }
    lines.append(String(format: "%d processes · %@ footprint · disk r %.1f / w %.1f MB/s", g.procCount, fmtMem(g.memMB), g.diskReadMBs, g.diskWriteMBs))
    if let n = g.pausedNote { lines.append(n) }
    return lines.joined(separator: "\n")
}

func jobHealth(_ j: JobInfo, staleMinutes: Double) -> Color {
    switch j.state {
    case "stale", "done-error", "killed": return Palette.red
    case "paused": return Palette.blue
    case "queued", "waiting", "done-ok", "exited": return .secondary
    default:
        let limit = j.staleAfterSeconds ?? staleMinutes * 60
        if limit > 0, let s = j.secondsSinceActivity, s > limit / 2 { return Palette.amber }
        return Palette.teal
    }
}

struct JobsPanel: View {
    @ObservedObject var live: LiveModel

    var body: some View {
        ScrollView {
            if let snap = live.snap {
                VStack(alignment: .leading, spacing: 14) {
                    RegisteredJobsSection(snap: snap, live: live)
                    ProcessesSection(snap: snap, live: live)
                }
                .padding(12)
            } else {
                ProgressView().padding(40)
            }
        }
    }
}

// MARK: Registered jobs

struct RegisteredJobsSection: View {
    let snap: UISnapshot
    @ObservedObject var live: LiveModel
    @State private var showOld = false

    var body: some View {
        let s = snap.status
        let recent = s.jobs.filter { !$0.isFinished || ($0.endedAt.map { Date().timeIntervalSince($0) < 6 * 3600 } ?? true) }
        let shown = showOld ? s.jobs : recent
        let names = Array(Set(shown.map(\.group))).sorted { a, b in
            let ra = shown.contains { $0.group == a && !$0.isFinished }, rb = shown.contains { $0.group == b && !$0.isFinished }
            return ra != rb ? ra : a < b
        }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Jobs")
                Spacer()
                if s.jobs.count > recent.count {
                    Button(showOld ? "Hide old" : "Show \(s.jobs.count - recent.count) older") { showOld.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                CopyJSONButton { s.jobGroups }
            }
            if names.isEmpty {
                Text("No registered jobs. Register one with `forkcast run --name x --group g -- cmd …` or `forkcast register --name x --pid 123` (see `forkcast help`).")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            ForEach(names, id: \.self) { g in
                JobGroupBlock(name: g, jobs: shown.filter { $0.group == g }, eta: s.jobGroups.first { $0.group == g },
                              snap: snap, live: live)
            }
        }
    }
}

struct JobGroupBlock: View {
    let name: String
    let jobs: [JobInfo]
    let eta: GroupETA?
    let snap: UISnapshot
    @ObservedObject var live: LiveModel

    var body: some View {
        let paused = jobs.contains { $0.state == "paused" }
        let active = jobs.contains { !$0.isFinished && $0.state != "queued" }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(Palette.purple)
                Text(name).font(.system(size: 13, weight: .bold))
                if let e = eta {
                    Text("\(e.running) running · \(e.queued) queued · \(e.finished) done").font(.caption).foregroundStyle(.secondary)
                    if let t = e.throughputPerHour, t > 0 { Text("\(fmtNum(t))/h").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer()
                    if let secs = e.etaSeconds, let d = e.etaDate {
                        Text(e.etaIsLowerBound
                             ? "ETA ≥ \(fmtDuration(secs)) (\(fmtTime(d))) · \(e.jobsWithoutETA.count) without ETA"
                             : "ETA \(fmtDuration(secs)) (\(fmtTime(d)))").font(.caption.weight(.semibold).monospacedDigit())
                            .help("Basis: " + e.basis)
                    } else if e.running + e.queued == 0 {
                        Text("all done").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(e.jobsWithoutETA.isEmpty ? "ETA unknown" : "ETA unknown · \(e.jobsWithoutETA.count) without total")
                            .font(.caption).foregroundStyle(.secondary).help(e.basis)
                    }
                } else { Spacer() }
                if active || paused {
                    Button(paused ? "Resume" : "Pause") { AppModel.shared.togglePause(name, paused: paused) }
                        .controlSize(.small)
                        .help(paused ? "Send SIGCONT to every process in this group" : "Send SIGSTOP to every process in this group (shown as paused until resumed)")
                }
                CopyJSONButton { AnyEncodableBox(["eta": AnyEncodableBox(eta), "jobs": AnyEncodableBox(jobs)]) }
            }
            ForEach(jobs) { j in
                JobRow(job: j, group: snap.groups.first { $0.id == "job:" + j.name },
                       staleMinutes: snap.staleMinutes,
                       expanded: live.expanded.contains("job:" + j.name))
                    .onTapGesture {
                        let id = "job:" + j.name
                        if live.expanded.contains(id) { live.expanded.remove(id) } else { live.expanded.insert(id) }
                    }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
    }
}

struct JobRow: View {
    let job: JobInfo
    let group: GroupInfo?
    let staleMinutes: Double
    let expanded: Bool

    var staleHelp: String {
        let limit = job.staleAfterSeconds ?? staleMinutes * 60
        return limit > 0 ? "Stale after \(fmtDuration(limit)) without activity." : "This job never goes stale (--stale never)."
    }

    var body: some View {
        let health = jobHealth(job, staleMinutes: staleMinutes)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Dot(color: health)
                Text(job.name + ((job.run ?? 1) > 1 ? " #\(job.run!)" : "")).font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(job.name)
                Tag(text: job.displayState, color: health == .secondary ? .gray : health)
                if let w = job.waitingOn { Text("for \(w)").font(.caption2).foregroundStyle(.secondary) }
                if job.logMissing == true { Text("log not found").font(.caption2).foregroundStyle(Palette.amber).help(job.log ?? "") }
                if let n = job.pausedNote { Text(n).font(.caption2).foregroundStyle(Palette.blue) }
                Spacer(minLength: 4)
                if !job.isFinished && job.state != "queued" && job.pid == nil {
                    Text("no process").font(.caption2).foregroundStyle(.tertiary)
                        .help("Started with `forkcast start`: tracked by its progress, heartbeats or log, not by a process")
                } else if !job.isFinished && job.state != "queued" {
                    Text(String(format: "%.1f cores · %@ · %@", job.cost.cpuPct / 100, fmtMem(job.cost.memMB), fmtW(job.cost.watts)))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let c = job.exitCode { Text("exit \(c)").font(.caption2.monospacedDigit()).foregroundStyle(c == 0 ? Color.secondary : Palette.red) }
            }
            if let f = job.fraction { Bar(fraction: f, color: health == .secondary ? .gray : health, height: 5) }
            HStack(spacing: 8) {
                if let d = job.done {
                    Text("\(fmtNum(d))\(job.total.map { "/" + fmtNum($0) } ?? "")\(job.fraction.map { " (\(Int($0 * 100))%)" } ?? "")")
                }
                if let r = job.ratePerHour { Text("\(fmtNum(r))/h") }
                if let e = job.etaSeconds { Text("ETA \(fmtDuration(e)) (\(fmtTime(Date().addingTimeInterval(e))))").help(job.etaBasis ?? "") }
                else if !job.isFinished, let b = job.etaBasis { Text("no ETA").foregroundStyle(.secondary).help(b) }
                if let note = job.note { Text(note).lineLimit(1).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                if let a = job.secondsSinceActivity {
                    Text("active \(fmtDuration(a)) ago").foregroundStyle(health == Palette.teal ? Color.secondary : health)
                        .help("Time since the last progress update, heartbeat or log line. " + staleHelp)
                } else if let e = job.endedAt {
                    Text("ended \(fmtTime(e))").foregroundStyle(.secondary)
                }
            }
            .font(.caption.monospacedDigit())
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    if let c = job.command {
                        Text("$ " + c).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).lineLimit(4)
                    }
                    if let log = job.log { Text("log: " + log).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
                    if let g = group, !g.processes.isEmpty { ProcessList(procs: g.processes) }
                    if job.isFinished {
                        Button("Forget this job") { _ = AppModel.shared.engine.forget(job.name) }.buttonStyle(.link).font(.caption)
                    }
                }
                .padding(.leading, 14)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(group.map(groupTooltip) ?? (job.command ?? job.name))
    }
}

// MARK: Unregistered processes

struct ProcessesSection: View {
    let snap: UISnapshot
    @ObservedObject var live: LiveModel
    @State private var showAll = false

    var body: some View {
        let s = snap.status
        let groups: [GroupInfo] = live.groupBy == "app" ? live.appGroups : snap.groups.filter { $0.kind != "registered" }
        let visible = groups.filter { $0.watts >= 0.005 || $0.cpuPct >= 1 || $0.kind == "job" }
        let rows = showAll ? groups : Array(visible.prefix(25))
        let maxW = max(groups.first?.watts ?? 0, 0.5)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(live.groupBy == "app" ? "Processes by app" : "Other processes (grouped by job tree)")
                Spacer()
                Picker("", selection: $live.groupBy) {
                    Text("Job").tag("job")
                    Text("App").tag("app")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                CopyJSONButton { rows }
            }
            HStack {
                Text("").frame(width: 18)
                Spacer()
                Text("POWER").frame(width: 58, alignment: .trailing)
                Text("CPU").frame(width: 46, alignment: .trailing)
                Text("").frame(width: 22)
            }
            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.tertiary)
            ForEach(rows) { g in
                GroupRow(g: g, maxW: maxW, expanded: live.expanded.contains(g.id))
                    .onTapGesture {
                        if live.expanded.contains(g.id) { live.expanded.remove(g.id) } else { live.expanded.insert(g.id) }
                    }
            }
            if groups.count > rows.count || showAll {
                Button(showAll ? "Show fewer" : "Show all \(groups.count) groups") { showAll.toggle() }
                    .buttonStyle(.link).font(.caption)
            }
            Divider()
            PowerSplitRows(p: s.power)
            Text("Memory = physical footprint (what Activity Monitor calls Memory). Hover a process for its resident size (RSS). Click a row for its processes.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

struct GroupRow: View {
    let g: GroupInfo
    let maxW: Double
    let expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                AppIcon(path: g.iconPath, kind: g.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.label).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(subtitle).font(.caption2).foregroundStyle(g.paused ? Palette.blue : .secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(fmtW(g.watts))
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(g.watts >= 5 ? Palette.red : g.watts >= 1.5 ? Palette.orange : .primary)
                    .frame(width: 58, alignment: .trailing)
                Text(fmtCPU(g.cpuPct)).font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
                Group {
                    if g.kind == "job" {
                        Button {
                            AppModel.shared.togglePause(g.id, paused: g.paused)
                        } label: { Image(systemName: g.paused ? "play.fill" : "pause.fill").font(.system(size: 9)) }
                            .buttonStyle(.borderless)
                            .help(g.paused ? "Resume (SIGCONT) this job tree" : "Pause (SIGSTOP) this job tree")
                    } else { Color.clear }
                }
                .frame(width: 22)
            }
            Bar(fraction: g.watts / maxW, color: g.watts >= 5 ? Palette.red : g.watts >= 1.5 ? Palette.orange : Palette.teal, height: 3)
                .padding(.leading, 26).padding(.trailing, 130)
            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let c = g.command { Text("$ " + c).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled).lineLimit(3) }
                    if g.processes.isEmpty { Text("Loading processes…").font(.caption2).foregroundStyle(.secondary) }
                    else { ProcessList(procs: g.processes) }
                }
                .padding(.leading, 26)
            }
        }
        .contentShape(Rectangle())
        .help(groupTooltip(g))
    }

    var subtitle: String {
        if g.id == "sys:Spotlight indexing" && g.cpuPct >= 20 {
            return "\(g.procCount) proc · indexing new files — exclude output folders in System Settings › Spotlight › Privacy"
        }
        if g.kind == "system" && g.id != "sys:root" { return "\(g.procCount) proc · other user · CPU via ps" }
        var parts = ["\(g.procCount) proc", fmtMem(g.memMB)]
        let io = g.diskReadMBs + g.diskWriteMBs
        if io >= 0.1 { parts.append(String(format: "disk %.1f MB/s", io)) }
        if let n = g.pausedNote ?? (g.paused ? "paused" : nil) { parts.append(n) }
        return parts.joined(separator: " · ")
    }
}

struct ProcessList: View {
    let procs: [ProcInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PROCESS")
                Spacer()
                Text("MEMORY").frame(width: 58, alignment: .trailing).help("Physical footprint")
                Text("POWER").frame(width: 52, alignment: .trailing)
                Text("CPU").frame(width: 44, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            if procs.count > 10 { ScrollView { rows }.frame(height: 10 * 17) } else { rows }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(procs) { p in
                let idle = p.watts < 0.005 && p.cpuPct < 0.05
                HStack(spacing: 5) {
                    Text(p.name).lineLimit(1).truncationMode(.middle)
                    Text("\(p.pid)").foregroundStyle(.tertiary)
                    if p.exitedChildrenCPUPct >= 0.5 {
                        Text("+\(fmtCPU(p.exitedChildrenCPUPct)) exited children").foregroundStyle(Palette.purple)
                            .help("CPU of short-lived child processes that started and exited since the last sample, credited to this parent.")
                    }
                    if p.stopped { Tag(text: "T", color: Palette.blue) }
                    Spacer(minLength: 4)
                    Text(fmtMem(p.memMB)).frame(width: 58, alignment: .trailing)
                        .help("Footprint \(fmtMem(p.memMB))" + (p.rssMB.map { " · resident (RSS) \(fmtMem($0)), includes shared pages" } ?? ""))
                    Text(idle ? "idle" : fmtW(p.watts)).frame(width: 52, alignment: .trailing)
                    Text(idle ? "" : fmtCPU(p.cpuPct)).frame(width: 44, alignment: .trailing)
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(idle ? .tertiary : .secondary)
                .frame(height: 15)
                .help(([p.command.map { "$ " + $0 }, p.cwd.map { "cwd: " + $0 },
                        p.startTime.map { "started " + DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) }]
                       .compactMap { $0 }).joined(separator: "\n"))
            }
        }
    }
}

/// The non-process part of the power budget, so the rows add up to the total.
struct PowerSplitRows: View {
    let p: PowerInfo
    var body: some View {
        VStack(spacing: 3) {
            row("cpu", "GPU", p.gpuW, "IOReport GPU energy")
            row("memorychip", "Memory & SoC", (p.socW ?? 0) + (p.aneW ?? 0), "DRAM, memory controller, display pipeline, media engines, Neural Engine (IOReport)")
            row("display", "Display & other", p.otherW, "Backlight, SSD, Wi-Fi, audio, conversion losses: system load minus everything measured above")
        }
    }
    func row(_ icon: String, _ label: String, _ w: Double?, _ help: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary)
            Text(label).font(.system(size: 12))
            Spacer()
            Text(fmtW(w)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
            Color.clear.frame(width: 68)
        }
        .help(help)
    }
}
