import Foundation

/// The settings file (--settings): when to shut down, and whether for real,
/// as JSON, reread whenever it changes. Numbers and switches only, never a
/// command, so that whoever may write it (it need not be root's) can change
/// when upswatch shuts down but not what it runs:
///
///     {"on_battery_max": 180, "min_charge": 40, "min_battery_volts": 0,
///      "lost_max": 30, "dry_run": false, "ups_off_delay": 0, "ups_restore": 1}
///
/// A key left out keeps what the command line says. A file that does not
/// parse, or a value out of range, is logged and changes nothing.
enum SettingsFile {
    static let keys = ["on_battery_max", "min_charge", "min_battery_volts", "lost_max",
                       "dry_run", "ups_off_delay", "ups_restore"]

    /// base with the file's settings applied, or why not.
    static func apply(_ data: Data, to base: Options) -> Result<Options, OptionError> {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(OptionError("not a JSON object"))
        }
        if let unknown = j.keys.first(where: { !keys.contains($0) }) {
            return .failure(OptionError("unknown setting \(unknown)"))
        }
        var o = base
        // JSONSerialization gives numbers and true/false alike as NSNumber,
        // and Swift lets an NSNumber of 0 or 1 pass `is Bool`: only
        // CFBoolean's type tells a JSON true/false from a number.
        func isBool(_ v: Any) -> Bool { CFGetTypeID(v as CFTypeRef) == CFBooleanGetTypeID() }
        func number(_ key: String, _ range: ClosedRange<Double>) throws -> Double? {
            guard let v = j[key] else { return nil }
            guard let n = (v as? NSNumber)?.doubleValue, !isBool(v), range.contains(n) else {
                throw OptionError("\(key): not a number from \(range.lowerBound) to \(range.upperBound)")
            }
            return n
        }
        do {
            if let n = try number("on_battery_max", 0...86400) { o.onBatteryMax = n }
            if let n = try number("min_charge", 0...100) { o.minCharge = n }
            if let n = try number("min_battery_volts", 0...100) { o.minBatteryVolts = n }
            if let n = try number("lost_max", 0...86400) { o.lostMax = n }
            if let n = try number("ups_off_delay", 0...10) {
                guard n == 0 || megatecDelay(n) != nil else {
                    throw OptionError("ups_off_delay: 0, 0.2 to 0.9, or 1 to 10")
                }
                o.upsOffDelay = n
            }
            if let n = try number("ups_restore", 1...9999) { o.upsRestore = Int(n) }
            if let v = j["dry_run"] {
                guard isBool(v), let b = v as? Bool else { throw OptionError("dry_run: true or false") }
                o.dryRun = b
            }
        } catch let e as OptionError {
            return .failure(e)
        } catch {
            return .failure(OptionError("\(error)"))
        }
        return .success(o)
    }

    static func json(_ o: Options) -> [String: Any] {
        ["on_battery_max": o.onBatteryMax, "min_charge": o.minCharge,
         "min_battery_volts": o.minBatteryVolts, "lost_max": o.lostMax,
         "dry_run": o.dryRun, "ups_off_delay": o.upsOffDelay, "ups_restore": o.upsRestore]
    }

    static func describe(_ o: Options) -> String {
        var s = ["on battery max \(Int(o.onBatteryMax))s", "min charge \(Int(o.minCharge))%"]
        if o.minBatteryVolts > 0 { s.append("min battery \(o.minBatteryVolts)V") }
        s.append("lost max \(Int(o.lostMax))s")
        if o.upsOffDelay > 0 { s.append("then UPS off after \(o.upsOffDelay) min, on \(o.upsRestore) min after") }
        if o.dryRun { s.append("DRY RUN") }
        return s.joined(separator: ", ")
    }
}

/// Requests in the control directory (--control-dir): a file each, named
/// anything, holding the name of one action. upswatch runs it, says so in
/// its log and state file, and removes the request. Only these, never a raw
/// command:
enum Action: String, CaseIterable {
    /// Turn the UPS's beeper on or off (Megatec Q).
    case beeper
    /// A 10-second battery test: the UPS runs on battery for it (T).
    case test
    /// Cancel a shutdown of the UPS's outlets it was told of (C).
    case cancel

    var command: String {
        switch self {
        case .beeper: "Q"
        case .test: "T"
        case .cancel: "C"
        }
    }
}
