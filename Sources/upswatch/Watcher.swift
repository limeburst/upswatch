import Foundation

/// Decides, from what the UPS says (and how long it has said nothing), when
/// to shut down, and runs the hooks.
final class Watcher {
    private(set) var o: Options
    private let base: Options
    private var settingsStamp: Date?
    private var lastAction: [String: Any]?
    let link: HIDLink

    private var last: Status?
    private var lastContact: Date?
    private var onBatterySince: Date?
    private var lost = false
    private var lastLogged = ""
    private var lastLoggedAt = Date.distantPast
    private var shutdownStarted = false
    private var battery: BatteryModel
    private var charge: Double?

    init(_ o: Options) {
        self.o = o
        base = o
        link = HIDLink(vendorID: o.vendorID, productID: o.productID)
        battery = o.battery
    }

    func start() {
        link.onReply = { [unowned self] in reply($0) }
        link.onAttach = { log("UPS attached") }
        link.onDetach = { [unowned self] in detached() }
        link.onError = { log("UPS: \($0)") }
        let r = link.start()
        if r != kIOReturnSuccess { log("HID manager: \(hex(r))") }
        readSettings()
        log(String(format: "upswatch %@ watching %04x:%04x: query %@ every %.1fs, %@, %d shutdown hook(s)",
                   version, o.vendorID, o.productID, o.query, o.interval,
                   SettingsFile.describe(o), o.shutdownHooks.count))
        Timer.scheduledTimer(withTimeInterval: o.interval, repeats: true) { [unowned self] _ in tick() }
    }

    private func tick() {
        if link.attached { link.query(o.query, timeout: o.timeout) }
        let now = Date()
        defer { writeState() }
        if !shutdownStarted { readSettings() }
        runActions()

        let silentFor = now.timeIntervalSince(lastContact ?? now)
        // Not a reply or two missed: a USB send can time out now and then
        // (the VX600's bridge does a few times an hour), and the gap passes
        // a few seconds; --lost-after is how long a silence has to be.
        if !lost, lastContact != nil, silentFor >= max(o.lostAfter, max(o.timeout, o.interval) * 2 + 1) {
            lost = true
            event("lost", "no answer from the UPS for \(Int(silentFor))s")
        }

        guard let s = last, s.onBattery else { return }
        if s.batteryLow {
            shutdown("the UPS says its battery is low")
        } else if o.minBatteryVolts > 0, s.batteryVolts <= o.minBatteryVolts {
            shutdown(String(format: "battery at %.1fV", s.batteryVolts))
        } else if o.minCharge > 0, let c = charge, c <= o.minCharge {
            shutdown(String(format: "battery at about %.0f%%", c))
        } else if o.onBatteryMax > 0, let since = onBatterySince,
                  now.timeIntervalSince(since) >= o.onBatteryMax {
            shutdown("on battery for \(Int(now.timeIntervalSince(since)))s")
        } else if o.lostMax > 0, lastContact != nil, silentFor >= o.lostMax {
            shutdown("no answer from the UPS for \(Int(silentFor))s, last seen on battery")
        }
    }

    /// Off USB: unplugged, or its USB bridge dropped off the bus. Lost at
    /// once, rather than after the replies it no longer gives time out.
    private func detached() {
        log("UPS detached")
        guard !lost, lastContact != nil else { return }
        lost = true
        event("lost", "the UPS is off USB: unplugged, or its USB bridge dropped off the bus")
        writeState()
    }

    private func reply(_ line: String) {
        guard let s = Status(line) else { log("UPS: unexpected reply: \(line)"); return }
        let now = Date()
        lastContact = now
        if lost {
            lost = false
            event("found", "the UPS answers again: \(describe(s))", s)
        }
        let before = last
        last = s
        charge = battery.update(s, interval: o.interval)
        if s.onBattery, before?.onBattery != true {
            onBatterySince = now
            event("onbattery", (s.testing ? "on battery for a battery test: " : "on battery: ") + describe(s), s)
        } else if !s.onBattery, before?.onBattery == true {
            onBatterySince = nil
            event("online", "back on line power: \(describe(s))", s)
            if shutdownStarted, o.dryRun { shutdownStarted = false }
        }
        if s.batteryLow, before?.batteryLow != true {
            event("lowbattery", "battery low: \(describe(s))", s)
        }

        let words = s.words.joined(separator: " ")
        if words != lastLogged || now.timeIntervalSince(lastLoggedAt) >= o.heartbeat {
            log(describe(s))
            lastLogged = words; lastLoggedAt = now
        }
        writeState()
    }

    private func describe(_ s: Status) -> String {
        guard s.onBattery, let c = charge else { return s.summary }
        return s.summary + String(format: " charge=%.0f%%", c)
    }

    private func event(_ name: String, _ message: String, _ s: Status? = nil) {
        log(message)
        for hook in o.eventHooks {
            run(hook, env: env(name, message, s ?? last)) { _ in }
        }
    }

    private func shutdown(_ reason: String) {
        guard !shutdownStarted else { return }
        shutdownStarted = true
        let message = "shutting down: \(reason)"
        event("shutdown", message)
        let env = env("shutdown", message, last)
        DispatchQueue.global().async { [o] in
            let group = DispatchGroup()
            for hook in o.shutdownHooks {
                group.enter()
                run(hook, env: env, timeout: o.hookTimeout) { _ in group.leave() }
            }
            group.wait()
            if o.upsOffDelay > 0 { self.switchOff(o) }
            if o.dryRun {
                log("dry run: would run \(o.shutdownCommand)")
            } else {
                log("running \(o.shutdownCommand)")
                run(o.shutdownCommand, env: env) { _ in }
            }
        }
    }

    /// Tells the UPS to switch its outlets off (and on again later), and
    /// waits a few seconds for it to say so (its "shutdown active" bit). On
    /// a background queue, while the link lives on the main one.
    private func switchOff(_ o: Options) {
        let command = "S\(megatecDelay(o.upsOffDelay)!)R\(String(format: "%04d", o.upsRestore))"
        if o.dryRun {
            log("dry run: would tell the UPS \(command)")
            return
        }
        let sent = DispatchQueue.main.sync { link.send(command) }
        guard sent else {
            log("could not tell the UPS \(command): it is not on USB; its outlets stay on")
            return
        }
        log("told the UPS \(command): outlets off in \(o.upsOffDelay) min, on again \(o.upsRestore) min after that with line power")
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 1)
            if DispatchQueue.main.sync(execute: { last?.shuttingDown == true }) {
                log("the UPS confirms (SD)")
                return
            }
        }
        log("the UPS has not confirmed (no SD) in 5s")
    }

    /// The settings file, applied over the command line's options when it
    /// has changed since it was last read.
    private func readSettings() {
        guard let path = o.settingsFile else { return }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard stamp != settingsStamp else { return }
        settingsStamp = stamp
        guard stamp != nil, let data = FileManager.default.contents(atPath: path) else {
            if SettingsFile.describe(o) != SettingsFile.describe(base) {
                o = base
                log("settings: \(path) is gone; back to the command line's: \(SettingsFile.describe(o))")
            }
            return
        }
        switch SettingsFile.apply(data, to: base) {
        case .failure(let e):
            log("settings: \(path): \(e); keeping \(SettingsFile.describe(o))")
        case .success(let new):
            let before = SettingsFile.describe(o)
            o = new
            if SettingsFile.describe(o) != before { log("settings: \(SettingsFile.describe(o))") }
        }
    }

    /// Each request in the control directory, oldest first.
    private func runActions() {
        guard let dir = o.controlDir,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            let text = FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } ?? ""
            try? FileManager.default.removeItem(atPath: path)
            let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result: String
            if let action = Action(rawValue: asked) {
                result = link.send(action.command) ? "sent \(action.command)" : "the UPS is not on USB"
            } else {
                result = "unknown action (beeper, test or cancel)"
            }
            log("action \(asked.prefix(40)): \(result)")
            lastAction = ["action": String(asked.prefix(40)), "result": result,
                          "time": ISO8601DateFormatter().string(from: Date())]
        }
    }

    private func env(_ event: String, _ message: String, _ s: Status?) -> [String: String] {
        var e = ["UPSWATCH_EVENT": event, "UPSWATCH_MESSAGE": message]
        if let s { e["UPSWATCH_STATUS"] = describe(s) }
        if let charge { e["UPSWATCH_CHARGE"] = String(format: "%.0f", charge) }
        if o.dryRun { e["UPSWATCH_DRY_RUN"] = "1" }
        return e
    }

    /// The state file, written every interval: the last reading (as of
    /// "time"), and whether the UPS is on USB and answering now. Its own age
    /// says whether upswatch is running.
    private func writeState() {
        guard let path = o.stateFile else { return }
        let iso = ISO8601DateFormatter()
        var j: [String: Any] = last?.json ?? [:]
        j["usb_attached"] = link.attached
        j["answering"] = lastContact != nil && !lost
            && Date().timeIntervalSince(lastContact!) < max(o.timeout, o.interval) * 2 + 1
        if let t = lastContact { j["time"] = iso.string(from: t) }
        if let c = charge { j["charge_percent"] = Int(c.rounded()) }
        if let since = onBatterySince { j["on_battery_since"] = iso.string(from: since) }
        j["settings"] = SettingsFile.json(o)
        if let a = lastAction { j["last_action"] = a }
        guard let data = try? JSONSerialization.data(withJSONObject: j, options: [.sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// Runs command with /bin/sh, logging what it prints, and calls done with its
/// exit status; with a timeout, kills it after that long.
func run(_ command: String, env: [String: String], timeout: TimeInterval = 0,
         done: @escaping (Int32) -> Void) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    p.standardInput = FileHandle.nullDevice
    p.terminationHandler = { p in
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        for line in out.split(separator: "\n") { log("  | \(line)") }
        if p.terminationStatus != 0 { log("exit \(p.terminationStatus): \(command)") }
        done(p.terminationStatus)
    }
    do {
        try p.run()
    } catch {
        log("could not run \(command): \(error)")
        done(-1)
        return
    }
    if timeout > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if p.isRunning { log("timed out after \(Int(timeout))s: \(command)"); p.terminate() }
        }
    }
}
