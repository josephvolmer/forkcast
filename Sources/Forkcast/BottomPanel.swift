import AppKit
import ForkcastCore
import SwiftUI

struct BottomPanel: View {
    @ObservedObject var live: LiveModel
    @ObservedObject var charts: ChartsModel
    @State private var showSettings = false
    @State private var showAddGuard = false

    var body: some View {
        if let snap = live.snap {
            HStack(alignment: .top, spacing: 12) {
                AlertsColumn(alerts: snap.status.alerts, configError: snap.configError, showSettings: $showSettings)
                    .frame(width: 330)
                Divider()
                TimelineColumn(events: snap.events, charts: charts, lastLooked: live.lastLooked)
                Divider()
                GuardsColumn(guards: snap.guards, showAdd: $showAddGuard)
                    .frame(width: 330)
            }
            .padding(12)
            .sheet(isPresented: $showSettings) { SettingsSheet() }
            .sheet(isPresented: $showAddGuard) { AddGuardSheet() }
        }
    }
}

struct AlertsColumn: View {
    let alerts: [AlertInfo]
    let configError: String?
    @Binding var showSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Active alerts")
                Spacer()
                Button("Alert settings…") { showSettings = true }.buttonStyle(.link).font(.caption)
                CopyJSONButton { alerts }
            }
            if let e = configError { Text(e).font(.caption).foregroundStyle(Palette.red) }
            if alerts.isEmpty {
                Label("All clear", systemImage: "checkmark.circle").font(.callout).foregroundStyle(Palette.teal)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(alerts) { a in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: a.severity == "critical" ? "exclamationmark.octagon.fill" : a.severity == "info" ? "info.circle" : "exclamationmark.triangle.fill")
                                .foregroundStyle(severityColor(a.severity))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(a.message).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                                Text("since \(fmtTime(a.since)) · \(a.type)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Button { AppModel.shared.engine.dismissAlert(a.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.borderless).help("Dismiss (it comes back if the condition is still true)")
                        }
                    }
                }
            }
        }
    }
}

struct TimelineColumn: View {
    let events: [EventInfo]
    @ObservedObject var charts: ChartsModel
    let lastLooked: Date

    var body: some View {
        let inWindow = charts.selection.map { sel in events.filter { sel.contains($0.time) } } ?? events
        let since = events.filter { $0.time > lastLooked && $0.type.hasPrefix("job") || ($0.time > lastLooked && ["crash", "alert.fired", "guard.pause"].contains($0.type)) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle(charts.selection == nil ? "Timeline" : "Timeline · selected window")
                Spacer()
                CopyJSONButton { inWindow }
            }
            if lastLooked.timeIntervalSince1970 > 0 {
                Text(sinceSummary(since))
                    .font(.caption).foregroundStyle(since.isEmpty ? Color.secondary : Palette.purple)
                    .help("Jobs that started, finished, failed or went stale — and alerts — since you last closed Forkcast (\(fmtTime(lastLooked))). API: GET /changes?since=…")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(inWindow.prefix(200)) { e in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: eventIcon(e.type)).font(.system(size: 10)).foregroundStyle(eventColor(e.type)).frame(width: 14)
                            Text(DateFormatter.localizedString(from: e.time, dateStyle: Date().timeIntervalSince(e.time) > 86400 ? .short : .none, timeStyle: .short))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(e.message).font(.system(size: 11.5)).lineLimit(2)
                                .foregroundStyle(e.time > lastLooked ? Color.primary : Color.primary.opacity(0.75))
                        }
                        .help(e.type)
                    }
                }
            }
        }
    }

    func sinceSummary(_ evs: [EventInfo]) -> String {
        guard !evs.isEmpty else { return "Nothing new since you last looked (\(fmtTime(lastLooked)))" }
        func n(_ t: [String]) -> Int { evs.filter { t.contains($0.type) }.count }
        let parts = [("started", n(["job.registered", "job.started"])), ("finished", n(["job.finished", "job.exited"])),
                     ("failed", n(["job.failed", "job.crashed", "crash"])), ("went stale", n(["job.stale"])),
                     ("alerts", n(["alert.fired"])), ("guard pauses", n(["guard.pause"]))]
            .filter { $0.1 > 0 }.map { "\($0.1) \($0.0)" }
        return "Since \(fmtTime(lastLooked)): " + parts.joined(separator: " · ")
    }
}

struct GuardsColumn: View {
    let guards: [GuardRule]
    @Binding var showAdd: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Guards")
                Spacer()
                Button("Add guard…") { showAdd = true }.buttonStyle(.link).font(.caption)
                CopyJSONButton { guards }
            }
            if guards.isEmpty {
                Text("Guards pause or resume a group automatically, e.g. pause \"renders\" when the battery drains on AC for 10 min, resume above 30%.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(guards) { g in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Dot(color: g.error != nil ? Palette.red : g.active == true ? Palette.blue : (g.enabled ?? true) ? Palette.teal : .gray)
                                Text(g.name).font(.system(size: 12, weight: .semibold))
                                if g.active == true { Tag(text: "ACTIVE", color: Palette.blue) }
                                Spacer()
                                Toggle("", isOn: Binding(get: { g.enabled ?? true }, set: { on in
                                    AppModel.shared.engine.updateConfig { c in
                                        if let i = c.guards.firstIndex(where: { $0.name == g.name }) { c.guards[i].enabled = on }
                                    }
                                })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                Button { _ = AppModel.shared.engine.deleteGuard(g.name) } label: { Image(systemName: "trash").font(.system(size: 10)) }
                                    .buttonStyle(.borderless)
                            }
                            Text("when \(g.when)\(g.forSeconds.map { " for \(fmtDuration($0))" } ?? "") → \(g.action) \(g.group ?? "")")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                            if let r = g.resumeWhen { Text("resume when \(r)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary) }
                            if let l = g.lastFired { Text("last fired \(fmtAgo(l))").font(.caption2).foregroundStyle(.tertiary) }
                            if let e = g.error { Text(e).font(.caption2).foregroundStyle(Palette.red) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: Sheets

struct AddGuardSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var when = "net_battery_w < 0 and on_ac"
    @State private var forText = "10m"
    @State private var action = "pause"
    @State private var group = ""
    @State private var resumeWhen = "battery > 30"
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add guard").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("When", text: $when).font(.system(.body, design: .monospaced))
                TextField("For (e.g. 10m)", text: $forText)
                Picker("Action", selection: $action) { Text("pause").tag("pause"); Text("resume").tag("resume"); Text("notify").tag("notify") }
                TextField("Group (registered group, job or row label)", text: $group)
                TextField("Resume when (optional)", text: $resumeWhen).font(.system(.body, design: .monospaced))
            }
            Text("Expressions: battery > 25 · on_ac · net_battery_w < 0 · disk_free_gb < 50 · mem_pressure == red · job x done · group g idle · process_running('installer') · combine with and/or/not")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(Palette.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    var g = GuardRule(name: name.isEmpty ? "guard-\(Int(Date().timeIntervalSince1970) % 100000)" : name, when: when, action: action)
                    g.forSeconds = parseDuration(forText)
                    g.group = group.isEmpty ? nil : group
                    g.resumeWhen = resumeWhen.isEmpty || action != "pause" ? nil : resumeWhen
                    do { _ = try AppModel.shared.engine.addGuard(g); dismiss() } catch { self.error = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
    }
}

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var cfg = Config()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Alerts & settings").font(.headline)
            ScrollView {
                Form {
                    Section("Power") {
                        Toggle("Charger unplugged / wattage changed", isOn: $cfg.alerts.chargerChange)
                        optional("Battery drains while plugged in for (min)", $cfg.alerts.pluggedDrainMinutes, 5)
                        optional("Battery below % on battery", $cfg.alerts.batteryLowOnBatteryPct, 20)
                        optional("Battery below % on AC", $cfg.alerts.batteryLowOnACPct, 10)
                    }
                    Section("Disk & memory") {
                        number("Disk floor (GB)", $cfg.diskFloorGB)
                        optional("Disk free below (GB)", $cfg.alerts.diskFreeMinGB, 30)
                        optional("Time to floor below (h)", $cfg.alerts.diskHoursToFloorMin, 6)
                        optional("Memory pressure red for (min)", $cfg.alerts.memoryRedMinutes, 2)
                        optional("Swap growth above (GB/h)", $cfg.alerts.swapGrowthGBPerHour, 4)
                        optional("Thermal throttling for (min)", $cfg.alerts.throttlingMinutes, 5)
                        Toggle("Watched volume unmounted", isOn: $cfg.alerts.volumeUnmounted)
                        Toggle("Auto-watch new external volumes", isOn: $cfg.autoWatchVolumes)
                    }
                    Section("Jobs") {
                        number("Job stale after (min)", $cfg.alerts.jobStaleMinutes)
                        Toggle("Job ended (exit code)", isOn: $cfg.alerts.jobEnded)
                        Toggle("New crash report in a job", isOn: $cfg.alerts.crashReports)
                        Toggle("A background job opened a window", isOn: $cfg.alerts.backgroundWindow)
                    }
                    Section("CPU") {
                        Toggle("Group above CPU % for N min", isOn: $cfg.alerts.cpu.enabled)
                        number("CPU %", $cfg.alerts.cpu.percent)
                        number("Minutes", $cfg.alerts.cpu.minutes)
                        TextField("Muted groups (comma-separated)", text: Binding(
                            get: { cfg.alerts.cpu.muted.joined(separator: ", ") },
                            set: { cfg.alerts.cpu.muted = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                        Text("Expected CPU ranges per group (e.g. alert when a render group sits at 0% for 10 min) live in config.json → alerts.expectedCPU.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Network & delivery") {
                        optional("Daily upload above (GB)", $cfg.alerts.dailyUploadGB, 50)
                        Toggle("macOS notifications", isOn: $cfg.delivery.notify)
                        TextField("Webhook URL (POST JSON)", text: Binding(get: { cfg.delivery.webhook ?? "" }, set: { cfg.delivery.webhook = $0.isEmpty ? nil : $0 }))
                        TextField("Shell command (gets FORKCAST_ALERT_* env)", text: Binding(get: { cfg.delivery.command ?? "" }, set: { cfg.delivery.command = $0.isEmpty ? nil : $0 }))
                    }
                    Section("Watched folders") {
                        ForEach(cfg.watchedFolders, id: \.self) { f in
                            HStack {
                                Text(f).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Remove") { cfg.watchedFolders.removeAll { $0 == f } }.buttonStyle(.link)
                            }
                        }
                        Button("Add folder…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true
                            p.canChooseFiles = false
                            if p.runModal() == .OK, let u = p.url { cfg.watchedFolders.append(u.path) }
                        }
                    }
                    Section("Sampling") {
                        number("Seconds between samples while visible", $cfg.sampling.visibleSeconds)
                        number("Seconds between samples in the background", $cfg.sampling.backgroundSeconds)
                    }
                }
                .formStyle(.grouped)
            }
            HStack {
                Button("Open config.json") { NSWorkspace.shared.open(AppModel.shared.engine.configStore.url) }
                Text("Label rules, container names, expected CPU ranges and per-alert delivery live there.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let c = cfg
                    AppModel.shared.engine.updateConfig { $0 = c }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 640)
        .onAppear { cfg = AppModel.shared.engine.config }
    }

    func number(_ label: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: v, format: .number).frame(width: 80).multilineTextAlignment(.trailing)
        }
    }

    func optional(_ label: String, _ v: Binding<Double?>, _ def: Double) -> some View {
        HStack {
            Toggle(label, isOn: Binding(get: { v.wrappedValue != nil }, set: { v.wrappedValue = $0 ? def : nil }))
            Spacer()
            if v.wrappedValue != nil {
                TextField("", value: Binding(get: { v.wrappedValue ?? def }, set: { v.wrappedValue = $0 }), format: .number)
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
        }
    }
}
