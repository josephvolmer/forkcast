import Foundation
import ForkcastCore
import IOKit

/// Reads Apple Silicon energy counters via the (private but sudo-free) IOReport "Energy Model" group.
/// This is the same data `powermetrics` reports for CPU / GPU / ANE / DRAM power.
final class EnergyModel {
    struct Reading {
        var seconds: Double
        var cpuJ: Double
        var gpuJ: Double
        var aneJ: Double
        var socJ: Double
    }

    private typealias CopyChannels = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                  UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetInt = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias GetStr = @convention(c) (CFDictionary) -> Unmanaged<CFString>?

    private var createSamples: CreateSamples?
    private var delta: Delta?
    private var getInt: GetInt?
    private var chName: GetStr?
    private var chUnit: GetStr?
    private var subscription: OpaquePointer?
    private var subbed: CFMutableDictionary?
    private var last: CFDictionary?
    private var lastTime = Date()

    static let socChannels: Set<String> = ["AMCC", "DCS", "DRAM", "DISP", "DISPEXT", "ISP", "AVE", "MSR",
                                           "SOC_AON", "SOC_REST", "AFR", "PCIE", "GPU SRAM"]

    var available: Bool { subscription != nil }

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String, _ t: T.Type) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: t) } }
        guard let copy = sym("IOReportCopyChannelsInGroup", CopyChannels.self),
              let sub = sym("IOReportCreateSubscription", CreateSub.self) else { return }
        createSamples = sym("IOReportCreateSamples", CreateSamples.self)
        delta = sym("IOReportCreateSamplesDelta", Delta.self)
        getInt = sym("IOReportSimpleGetIntegerValue", GetInt.self)
        chName = sym("IOReportChannelGetChannelName", GetStr.self)
        chUnit = sym("IOReportChannelGetUnitLabel", GetStr.self)
        guard let chans = copy("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(nil, 0, chans) else { return }
        var out: Unmanaged<CFMutableDictionary>?
        subscription = sub(nil, mutable, &out, 0, nil)
        subbed = out?.takeRetainedValue()
        if subscription != nil, let s = subbed, let cs = createSamples {
            last = cs(subscription!, s, nil)?.takeRetainedValue()
            lastTime = Date()
        }
    }

    /// Energy used since the previous call.
    func read() -> Reading? {
        guard let sub = subscription, let s = subbed, let cs = createSamples, let dl = delta,
              let gi = getInt, let cn = chName, let prev = last,
              let cur = cs(sub, s, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        let secs = now.timeIntervalSince(lastTime)
        last = cur
        lastTime = now
        guard secs > 0.05, let d = dl(prev, cur, nil)?.takeRetainedValue() as NSDictionary?,
              let chans = d["IOReportChannels"] as? [NSDictionary] else { return nil }
        var r = Reading(seconds: secs, cpuJ: 0, gpuJ: 0, aneJ: 0, socJ: 0)
        for c in chans {
            let cf = c as CFDictionary
            guard let name = cn(cf)?.takeUnretainedValue() as String? else { continue }
            let unit = chUnit?(cf)?.takeUnretainedValue() as String? ?? "mJ"
            let raw = Double(gi(cf, 0))
            let j: Double
            switch unit {
            case "nJ": j = raw / 1e9
            case "uJ", "µJ": j = raw / 1e6
            default: j = raw / 1e3
            }
            if name == "CPU Energy" { r.cpuJ += j }
            else if name == "GPU Energy" { r.gpuJ += j }
            else if name.hasPrefix("ANE") { r.aneJ += j }
            else if Self.socChannels.contains(name) { r.socJ += j }
        }
        return r
    }
}

/// Battery controller + charger via IOKit (AppleSmartBattery).
final class BatterySensor {
    private let service: io_service_t

    init() { service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")) }
    deinit { if service != 0 { IOObjectRelease(service) } }

    private func value(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
    private func num(_ key: String) -> NSNumber? { value(key) as? NSNumber }

    var hasBattery: Bool { service != 0 }

    /// Fills the battery / charger part of PowerInfo.
    func read(into p: inout PowerInfo) {
        guard service != 0 else { return }
        p.onAC = num("ExternalConnected")?.boolValue ?? false
        p.charging = num("IsCharging")?.boolValue ?? false
        p.fullyCharged = num("FullyCharged")?.boolValue ?? false
        if let cur = num("CurrentCapacity")?.intValue, let mx = num("MaxCapacity")?.intValue, mx > 0 {
            p.batteryPct = min(100, cur * 100 / mx)
        }
        if let m = num("TimeRemaining")?.intValue, m > 0, m < 65535 { p.macosMinutesRemaining = m }

        let mV = num("Voltage")?.doubleValue ?? 0
        let mA = Double(num("Amperage")?.int64Value ?? 0)
        if mV > 0 { p.netBatteryW = mV * mA / 1e6 }

        if mV > 0, let rawCur = num("AppleRawCurrentCapacity")?.doubleValue,
           let rawMax = num("AppleRawMaxCapacity")?.doubleValue, rawMax > 0 {
            p.batteryWh = rawCur * mV / 1e6
            p.batteryFullWh = rawMax * mV / 1e6
            if let net = p.netBatteryW {
                if net > 0.1 { p.hoursToFull = max(0, (rawMax - rawCur) * mV / 1e6 / net) }
                if net < -0.1 { p.hoursToEmpty = rawCur * mV / 1e6 / -net }
            }
        }

        if let tel = value("PowerTelemetryData") as? [String: Any],
           let load = (tel["SystemLoad"] as? NSNumber)?.doubleValue, load > 0 {
            p.drawW = load / 1000
        } else if !p.onAC, let net = p.netBatteryW {
            p.drawW = max(0, -net)
        }

        if p.onAC, let ad = value("AdapterDetails") as? [String: Any] {
            if let w = (ad["Watts"] as? NSNumber)?.doubleValue, w > 0 { p.chargerW = w }
            let name = (ad["Name"] as? String) ?? (ad["Description"] as? String)
            p.chargerName = name?.trimmingCharacters(in: .whitespaces)
        }
        if let c = p.chargerW, let d = p.drawW { p.marginW = c - d }
    }
}
