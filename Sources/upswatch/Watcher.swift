import Foundation

/// Decides, from what the UPS says (and how long it has said nothing), when
/// to shut down, and runs the hooks.
final class Watcher {
    let o: Options
    let link: HIDLink

    private var last: Status?
    private var lastContact: Date?
    private var onBatterySince: Date?
    private var lost = false
    private var lastLogged = ""
    private var lastLoggedAt = Date.distantPast
    private var shutdownStarted = false

    init(_ o: Options) {
        self.o = o
        link = HIDLink(vendorID: o.vendorID, productID: o.productID)
    }

    func start() {
        link.onReply = { [unowned self] in reply($0) }
        link.onAttach = { log("UPS attached") }
        link.onDetach = { log("UPS detached") }
        link.onError = { log("UPS: \($0)") }
        let r = link.start()
        if r != kIOReturnSuccess { log("HID manager: \(hex(r))") }
        var settings = ["query \(o.query) every \(o.interval)s"]
        if o.onBatteryMax > 0 { settings.append("on-battery max \(Int(o.onBatteryMax))s") }
        if o.minBatteryVolts > 0 { settings.append("min battery \(o.minBatteryVolts)V") }
        if o.lostMax > 0 { settings.append("lost max \(Int(o.lostMax))s") }
        settings.append("\(o.shutdownHooks.count) shutdown hook(s)")
        if o.dryRun { settings.append("DRY RUN") }
        log(String(format: "upswatch %@ watching %04x:%04x: %@", version, o.vendorID, o.productID,
                   settings.joined(separator: ", ")))
        Timer.scheduledTimer(withTimeInterval: o.interval, repeats: true) { [unowned self] _ in tick() }
    }

    private func tick() {
        if link.attached { link.query(o.query, timeout: o.timeout) }
        let now = Date()

        let silentFor = now.timeIntervalSince(lastContact ?? now)
        if !lost, lastContact != nil, silentFor >= max(o.timeout, o.interval) * 2 + 1 {
            lost = true
            event("lost", "no answer from the UPS for \(Int(silentFor))s")
        }

        guard let s = last, s.onBattery else { return }
        if s.batteryLow {
            shutdown("the UPS says its battery is low")
        } else if o.minBatteryVolts > 0, s.batteryVolts <= o.minBatteryVolts {
            shutdown(String(format: "battery at %.1fV", s.batteryVolts))
        } else if o.onBatteryMax > 0, let since = onBatterySince,
                  now.timeIntervalSince(since) >= o.onBatteryMax {
            shutdown("on battery for \(Int(now.timeIntervalSince(since)))s")
        } else if o.lostMax > 0, lost, silentFor >= o.lostMax {
            shutdown("no answer from the UPS for \(Int(silentFor))s, last seen on battery")
        }
    }

    private func reply(_ line: String) {
        guard let s = Status(line) else { log("UPS: unexpected reply: \(line)"); return }
        let now = Date()
        lastContact = now
        if lost {
            lost = false
            event("found", "the UPS answers again: \(s.summary)", s)
        }
        let before = last
        last = s
        if s.onBattery, before?.onBattery != true {
            onBatterySince = now
            event("onbattery", "on battery: \(s.summary)", s)
        } else if !s.onBattery, before?.onBattery == true {
            onBatterySince = nil
            event("online", "back on line power: \(s.summary)", s)
            if shutdownStarted, o.dryRun { shutdownStarted = false }
        }
        if s.batteryLow, before?.batteryLow != true {
            event("lowbattery", "battery low: \(s.summary)", s)
        }

        let words = s.words.joined(separator: " ")
        if words != lastLogged || now.timeIntervalSince(lastLoggedAt) >= o.heartbeat {
            log(s.summary)
            lastLogged = words; lastLoggedAt = now
        }
        writeState(s)
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
            if o.dryRun {
                log("dry run: would run \(o.shutdownCommand)")
            } else {
                log("running \(o.shutdownCommand)")
                run(o.shutdownCommand, env: env) { _ in }
            }
        }
    }

    private func env(_ event: String, _ message: String, _ s: Status?) -> [String: String] {
        var e = ["UPSWATCH_EVENT": event, "UPSWATCH_MESSAGE": message]
        if let s { e["UPSWATCH_STATUS"] = s.summary }
        if o.dryRun { e["UPSWATCH_DRY_RUN"] = "1" }
        return e
    }

    private func writeState(_ s: Status) {
        guard let path = o.stateFile else { return }
        var j = s.json
        j["time"] = ISO8601DateFormatter().string(from: Date())
        if let since = onBatterySince { j["on_battery_since"] = ISO8601DateFormatter().string(from: since) }
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
