import Foundation

/// One reply to the Megatec / Voltronic status query ("Q1" or "QS"):
///
///     (226.5 226.5 224.4 004 60.1 13.5 30.0 00001001
///
/// input voltage, input fault voltage, output voltage, load (%), frequency
/// (Hz), battery voltage, temperature (°C), then eight status bits, b7 first.
struct Status: Equatable {
    var inputVolts: Double
    var outputVolts: Double
    var loadPercent: Int
    var frequency: Double
    var batteryVolts: Double
    var temperature: Double?

    var onBattery: Bool      // b7 utility fail
    var batteryLow: Bool     // b6
    var bypass: Bool         // b5 bypass / boost or buck active
    var failed: Bool         // b4 UPS failed
    var standby: Bool        // b3 standby (offline) type
    var testing: Bool        // b2 test in progress
    var shuttingDown: Bool   // b1 shutdown active
    var beeper: Bool         // b0

    init?(_ line: String) {
        guard line.first == "(" else { return nil }
        let f = line.dropFirst().split(separator: " ")
        guard f.count >= 8, f[7].count == 8, f[7].allSatisfy({ $0 == "0" || $0 == "1" }),
              let input = Double(f[0]), let output = Double(f[2]), let load = Int(f[3]),
              let freq = Double(f[4]), let batt = Double(f[5])
        else { return nil }
        inputVolts = input
        outputVolts = output
        loadPercent = load
        frequency = freq
        batteryVolts = batt
        temperature = Double(f[6])
        let b = Array(f[7]).map { $0 == "1" }
        onBattery = b[0]; batteryLow = b[1]; bypass = b[2]; failed = b[3]
        standby = b[4]; testing = b[5]; shuttingDown = b[6]; beeper = b[7]
    }

    /// NUT-style status words: OL or OB, then LB, BYPASS, FAULT, TEST, SD.
    var words: [String] {
        var w = [onBattery ? "OB" : "OL"]
        if batteryLow { w.append("LB") }
        if bypass { w.append("BYPASS") }
        if failed { w.append("FAULT") }
        if testing { w.append("TEST") }
        if shuttingDown { w.append("SD") }
        return w
    }

    var summary: String {
        String(format: "%@ in=%.1fV out=%.1fV load=%d%% batt=%.1fV",
               words.joined(separator: " "), inputVolts, outputVolts, loadPercent, batteryVolts)
    }

    var json: [String: Any] {
        func d(_ x: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", x)) }
        var j: [String: Any] = [
            "status": words.joined(separator: " "),
            "input_volts": d(inputVolts), "output_volts": d(outputVolts),
            "load_percent": loadPercent, "frequency": d(frequency),
            "battery_volts": d(batteryVolts),
        ]
        if let t = temperature { j["temperature"] = d(t) }
        return j
    }
}
