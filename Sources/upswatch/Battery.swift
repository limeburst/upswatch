import Foundation

/// Estimates how charged a lead-acid battery is from its voltage, which is
/// all these UPSes report.
///
/// A battery's voltage only says how charged it is while it is the one
/// powering the load: on line power the UPS's charger holds it at its float
/// voltage (13.5-13.8 V for 12 V), whatever its charge. So there is an
/// estimate only on battery. Even then the voltage reads low under load, by
/// the current times the battery's internal resistance (and its wiring's), so
/// that sag is added back, from the UPS's load and its rating, before the
/// voltage is looked up in the curve: what a sealed lead-acid (VRLA / AGM)
/// battery reads at rest at each charge. And just off the charger it reads
/// high for a minute or so (surface charge), which the curve's top clamps.
///
/// The readings come in 0.1 V steps and wander by a step or two, so the
/// compensated voltage is smoothed (an exponential average over about ten
/// seconds) before it is looked up.
struct BatteryModel {
    /// Resting voltage of a 12 V VRLA battery at each charge, lowest first.
    static let vrla12: [(volts: Double, percent: Double)] = [
        (10.50, 0), (11.51, 10), (11.66, 20), (11.81, 30), (11.96, 40), (12.10, 50),
        (12.24, 60), (12.37, 70), (12.50, 80), (12.62, 90), (12.73, 100),
    ]

    var curve = BatteryModel.vrla12
    /// The battery's nominal voltage (12, 24, ... or 2 for a per-cell
    /// reading); 0 to tell from the first reading.
    var nominal = 0.0
    /// The UPS's rating in watts, for the current drawn at a given load; 0
    /// for no load compensation.
    var upsWatts = 0.0
    /// The battery's internal resistance plus its wiring's, for 12 V.
    var ohms = 0.05
    /// The inverter's efficiency.
    var efficiency = 0.85
    var smoothing = 10.0

    private var smoothed: Double?

    static func parseCurve(_ s: String) -> [(volts: Double, percent: Double)]? {
        var points = [(volts: Double, percent: Double)]()
        for pair in s.split(separator: ",") {
            let p = pair.split(separator: ":")
            guard p.count == 2, let v = Double(p[0]), let c = Double(p[1]) else { return nil }
            points.append((v, c))
        }
        points.sort { $0.volts < $1.volts }
        return points.count >= 2 ? points : nil
    }

    /// The battery's nominal voltage, from a reading: a 12 V battery reads
    /// 10-14.5 V, a cell 1.7-2.4 V.
    static func nominal(for volts: Double) -> Double {
        if volts < 3 { return 2 }
        return max(1, (volts / 12.6).rounded()) * 12
    }

    /// The voltage the battery would read at rest, per 12 V.
    func restingVolts(_ s: Status) -> Double {
        let nominal = self.nominal > 0 ? self.nominal : BatteryModel.nominal(for: s.batteryVolts)
        let scale = nominal / 12
        var volts = s.batteryVolts
        if upsWatts > 0, volts > 0 {
            let amps = upsWatts * Double(s.loadPercent) / 100 / efficiency / volts
            volts += amps * ohms * scale
        }
        return volts / scale
    }

    func percent(atRest volts: Double) -> Double {
        guard let first = curve.first, let last = curve.last else { return 0 }
        if volts <= first.volts { return first.percent }
        if volts >= last.volts { return last.percent }
        for (a, b) in zip(curve, curve.dropFirst()) where volts <= b.volts {
            return a.percent + (volts - a.volts) / (b.volts - a.volts) * (b.percent - a.percent)
        }
        return last.percent
    }

    /// Takes a reading, interval seconds after the last, and returns the
    /// estimated charge, or nil on line power.
    mutating func update(_ s: Status, interval: Double) -> Double? {
        guard s.onBattery else { smoothed = nil; return nil }
        let v = restingVolts(s)
        let alpha = min(1, interval / max(interval, smoothing))
        smoothed = smoothed.map { $0 + alpha * (v - $0) } ?? v
        return percent(atRest: smoothed!)
    }
}
