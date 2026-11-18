import Foundation
import ForkcastCore

/// "Can I add more work?" — free resources (p90 over the last 30 min), per-kind job cost cards,
/// an estimate of how many more instances fit, and measured throughput after instance changes.
final class HeadroomTracker {
    private struct Sample { let t: Date; let cores: Double; let memGB: Double; let watts: Double; let diskMBmin: Double }
    private var busy: [(Date, Double)] = []
    private var perKind: [String: [Sample]] = [:]
    private var labels: [String: String] = [:]
    private(set) var ioPeakMBs: Double
    private var instances: [String: Int] = [:]
    private var lastActive: [String: Date] = [:]      // group id → last time it used CPU or disk
    static let activeWindow: TimeInterval = 120
    private var pending: [String: (at: Date, before: Double, from: Int, to: Int)] = [:]
    private let store: Store

    init(store: Store) {
        self.store = store
        ioPeakMBs = Double(store.get("ioPeakMBs") ?? "") ?? 0
    }

    func record(busyCores: Double, groups: [GroupInfo], diskMBs: Double, waiting: Set<String> = [], now: Date) {
        busy.append((now, busyCores))
        busy.removeAll { now.timeIntervalSince($0.0) > 1800 }
        if diskMBs > ioPeakMBs * 1.05 {
            ioPeakMBs = diskMBs
            store.set("ioPeakMBs", String(diskMBs))
        }
        var alive = Set<String>()
        for g in groups where g.kind == "job" || g.kind == "registered" {
            alive.insert(g.id)
            if let j = g.jobName, waiting.contains(j) { continue }   // declared waiting: not a cost sample
            // Idle instances (e.g. a lane waiting for an earlier lane) must not dilute the per-instance cost.
            guard g.cpuPct >= 3 || g.diskReadMBs + g.diskWriteMBs >= 0.2 else { continue }
            lastActive[g.id] = now
            let k = g.kindKey
            labels[k] = g.registeredGroup ?? (k.hasPrefix("reg:") ? String(k.dropFirst(4)) : k)
            perKind[k, default: []].append(Sample(t: now, cores: g.cpuPct / 100, memGB: g.memMB / 1024, watts: g.watts,
                                                  diskMBmin: (g.diskReadMBs + g.diskWriteMBs) * 60))
        }
        lastActive = lastActive.filter { alive.contains($0.key) }
        for k in Array(perKind.keys) {
            perKind[k]!.removeAll { now.timeIntervalSince($0.t) > 3600 }
            if perKind[k]!.isEmpty { perKind[k] = nil; labels[k] = nil }
        }
    }

    static func p90(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.down)))]
    }

    func freeCoresP90(total: Int) -> Double? {
        guard busy.count >= 3 else { return nil }
        return max(0, Double(total) - Self.p90(busy.map(\.1)))
    }

    func compute(cpu: CPUInfo, mem: MemoryInfo, power: PowerInfo, disk: DiskInfo, groups: [GroupInfo],
                 waiting: Set<String> = [], now: Date) -> Headroom {
        var h = Headroom()
        h.freeCoresP90 = freeCoresP90(total: cpu.totalCores) ?? max(0, Double(cpu.totalCores) - cpu.busyCores)
        h.memHeadroomGB = mem.headroomGB
        h.powerMarginW = power.onAC ? power.marginW : nil
        h.diskIOMBs = disk.readMBs + disk.writeMBs
        h.diskIOPeakMBs = ioPeakMBs > 0 ? ioPeakMBs : nil

        var live: [String: Int] = [:], idle: [String: Int] = [:]
        for g in groups where g.kind == "job" || g.kind == "registered" {
            if let j = g.jobName, waiting.contains(j) { idle[g.kindKey, default: 0] += 1 }
            else if let t = lastActive[g.id], now.timeIntervalSince(t) <= Self.activeWindow { live[g.kindKey, default: 0] += 1 }
            else { idle[g.kindKey, default: 0] += 1 }
        }

        for (k, n) in live {
            guard let all = perKind[k], !all.isEmpty else { continue }
            let recent = all.filter { now.timeIntervalSince($0.t) <= 1800 }
            let registered = k.hasPrefix("reg:")
            if !registered, Self.p90(recent.map(\.cores)) < 0.03, (recent.map(\.memGB).max() ?? 0) < 0.1 { continue }
            var c = CostCard(kindKey: k, label: labels[k] ?? k, instances: n)
            c.waiting = idle[k] ?? 0
            c.samples = recent.count
            c.coresP90 = Self.p90(recent.map(\.cores))
            c.memPeakGB = recent.map(\.memGB).max() ?? 0
            c.wattsP90 = Self.p90(recent.map(\.watts))
            c.diskMBPerMin = Self.p90(recent.map(\.diskMBmin))
            let cs = all.map(\.cores)
            let mean = cs.reduce(0, +) / Double(cs.count)
            let sd = sqrt(cs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(cs.count))
            c.variation = mean > 0.01 ? sd / mean : 0
            c.confidence = c.samples < 20 ? "low" : c.variation < 0.2 ? "high" : c.variation < 0.5 ? "medium" : "low"

            var limits: [(String, Int)] = []
            if c.coresP90 > 0.05 { limits.append(("CPU", Int((h.freeCoresP90 / c.coresP90).rounded(.down)))) }
            if c.memPeakGB > 0.05 { limits.append(("memory", Int((h.memHeadroomGB / c.memPeakGB).rounded(.down)))) }
            if let m = h.powerMarginW, c.wattsP90 > 0.3 { limits.append(("power", max(0, Int((m / c.wattsP90).rounded(.down))))) }
            if let peak = h.diskIOPeakMBs, c.diskMBPerMin > 60 {
                limits.append(("disk I/O", max(0, Int(((peak - h.diskIOMBs) * 60 / c.diskMBPerMin).rounded(.down)))))
            }
            if let best = limits.min(by: { $0.1 < $1.1 }) {
                c.estimateMore = best.1
                c.bottleneck = best.0
            }
            let why = c.samples < 20 ? "only \(c.samples) samples so far" : "cost varied ±\(Int(c.variation * 100))% last hour"
            if let more = c.estimateMore, let b = c.bottleneck {
                c.estimateText = more > 0
                    ? "≈\(more) more like \"\(c.label)\" — \(b)-bound — \(c.confidence) confidence (\(why))"
                    : "no room for another \"\(c.label)\" — \(b) is the limit — \(c.confidence) confidence (\(why))"
            } else {
                c.estimateText = "not enough load from \"\(c.label)\" to estimate"
            }
            h.cards.append(c)
        }
        // Registered groups first, then the kinds using the most CPU in total.
        h.cards.sort { a, b in
            let ra = a.kindKey.hasPrefix("reg:"), rb = b.kindKey.hasPrefix("reg:")
            if ra != rb { return ra }
            return a.coresP90 * Double(a.instances) > b.coresP90 * Double(b.instances)
        }

        if let top = h.cards.first, let more = top.estimateMore, let b = top.bottleneck {
            h.verdict = more > 0
                ? "Room for ~\(more) more \(top.label) — \(b)-bound (\(top.confidence) confidence)"
                : "No room for another \(top.label) — \(b) is the limit"
        } else {
            var parts = [String(format: "%.1f cores", h.freeCoresP90), String(format: "%.1f GB memory", h.memHeadroomGB)]
            if let m = h.powerMarginW { parts.append(String(format: "%+.0f W power", m)) }
            h.verdict = "Free: " + parts.joined(separator: " · ")
        }
        return h
    }

    /// Records group throughput before/after an instance is added or removed (ground truth for headroom).
    func throughputEvents(jobs: JobRegistry, now: Date) -> [JobEvent] {
        var out: [JobEvent] = []
        for g in jobs.groupNames {
            guard let eta = jobs.eta(group: g, now: now) else { continue }
            let n = eta.running
            let rate = eta.throughputPerHour ?? 0
            if let prev = instances[g], prev != n, prev > 0, n > 0, pending[g] == nil {
                pending[g] = (now, rate, prev, n)
            }
            instances[g] = n
            if let p = pending[g], now.timeIntervalSince(p.at) >= 900 {
                pending[g] = nil
                guard p.before > 0, n == p.to else { continue }
                let gain = (rate - p.before) / p.before
                let perBefore = p.before / Double(p.from), perAfter = rate / Double(p.to)
                let perChange = (perAfter - perBefore) / perBefore
                let delta = p.to - p.from
                let t = DateFormatter.localizedString(from: p.at, dateStyle: .none, timeStyle: .short)
                var msg = "\(t) \(delta > 0 ? "added" : "removed") \(abs(delta)) instance\(abs(delta) == 1 ? "" : "s") → \(g) "
                    + "\(fmtNum(p.before)) → \(fmtNum(rate)) items/h (\(String(format: "%+.0f", gain * 100))%); "
                    + "per-instance rate \(String(format: "%+.0f", perChange * 100))%"
                let saturated = delta > 0 && gain < 0.10
                if saturated { msg += " — ⚠ saturated: more instances barely raised throughput" }
                out.append(JobEvent(type: saturated ? "headroom.saturated" : "headroom.throughput", subject: g, message: msg))
            }
        }
        return out
    }
}
