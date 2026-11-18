import Foundation

let version = "0.3.0"

let usage = """
usage: upswatch [options]
       upswatch --once [--vendor-id ID] [--product-id ID] [--query CMD]

Watches a Megatec / Voltronic UPS on USB (by default the common INNO TECH /
Cypress bridge, 0665:5161) through macOS's HID driver, and shuts the Mac
down when the UPS runs out of time. Runs as root, from launchd.

It shuts down when, on battery:
  - the UPS says its battery is low;
  - it has been on battery for --on-battery-max seconds;
  - the battery voltage is at or under --min-battery-volts;
  - the estimated charge is at or under --min-charge;
  - the UPS has not answered for --lost-max seconds.

UPS:
  --vendor-id ID          USB vendor ID (default 0x0665)
  --product-id ID         USB product ID (default 0x5161)
  --query CMD             status query: QS or Q1 (default QS)
  --interval SECONDS      between queries (default 1)
  --timeout SECONDS       for a reply (default 3)

When to shut down:
  --on-battery-max SECONDS   0 for no limit (default 0)
  --min-battery-volts VOLTS  0 for none (default 0)
  --min-charge PERCENT       0 for none (default 0)
  --lost-max SECONDS         0 to never shut down for it (default 60)

The battery (the charge is estimated on battery only, from its voltage):
  --ups-watts WATTS          the UPS's rating in watts, to correct the
                             voltage for the sag under load (default 0: none)
  --battery-ohms OHMS        its internal resistance and wiring's, per 12 V
                             (default 0.05)
  --battery-nominal VOLTS    12, 24, ..., or 2 for per-cell readings
                             (default: from the first reading)
  --battery-curve V:%,...    resting voltage per 12 V at each charge (default
                             sealed lead-acid: 10.5:0,11.51:10,...,12.73:100)

What to run:
  --shutdown-hook CMD     run with /bin/sh before shutting down, e.g. to shut
                          down other machines on the same UPS; repeatable,
                          all at once, each waited for up to --hook-timeout
  --event-hook CMD        run with /bin/sh on each event, not waited for;
                          repeatable. UPSWATCH_EVENT is online, onbattery,
                          lowbattery, lost, found or shutdown, UPSWATCH_MESSAGE
                          says what happened, UPSWATCH_STATUS is the last reading,
                          UPSWATCH_CHARGE the estimated charge (on battery)
  --hook-timeout SECONDS  (default 30)
  --shutdown-command CMD  (default "/sbin/shutdown -h now")
  --dry-run               log the shutdown, run the hooks with
                          UPSWATCH_DRY_RUN=1, and do not shut down (nor
                          switch the UPS off)

The UPS's outlets, after a shutdown:
  --ups-off-delay MINUTES    once the shutdown hooks are done, tell the UPS to
                             switch its outlets off this long after (0.2 to
                             0.9, or 1 to 10), so that the Macs lose power
                             and start again, with "Start up automatically
                             after a power failure", when it comes back
                             (default 0: leave the outlets on)
  --ups-restore MINUTES      and to switch them back on this long after
                             that, once line power is there (1 to 9999,
                             default 1)

Other:
  --state-file PATH       keep the state there, as JSON, rewritten every
                          interval: the last reading (as of "time"),
                          usb_attached and answering
  --heartbeat SECONDS     log the reading at least this often (default 300)
  --once                  print one reading as JSON and exit (1 when none)
  --send CMD              send CMD to the UPS, print its reply if any, and
                          exit: C cancels a shutdown the UPS was told of.
                          Stop upswatch first; two cannot share the UPS
  --version, --help
"""

struct Options {
    var vendorID = 0x0665
    var productID = 0x5161
    var query = "QS"
    var interval = 1.0
    var timeout = 3.0
    var onBatteryMax = 0.0
    var minBatteryVolts = 0.0
    var lostMax = 60.0
    var minCharge = 0.0
    var battery = BatteryModel()
    var shutdownHooks = [String]()
    var eventHooks = [String]()
    var hookTimeout = 30.0
    var shutdownCommand = "/sbin/shutdown -h now"
    var dryRun = false
    var stateFile: String?
    var heartbeat = 300.0
    var once = false
    var upsOffDelay = 0.0
    var upsRestore = 1
    var send: String?

    init(_ args: [String]) throws {
        var it = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw OptionError("\(flag) needs a value") }
            return v
        }
        func number(_ flag: String) throws -> Double {
            let v = try value(flag)
            guard let n = Double(v), n >= 0 else { throw OptionError("\(flag): not a number: \(v)") }
            return n
        }
        func id(_ flag: String) throws -> Int {
            let v = try value(flag)
            let digits = v.lowercased().hasPrefix("0x") ? String(v.dropFirst(2)) : v
            guard let n = Int(digits, radix: 16), (0...0xffff).contains(n) else {
                throw OptionError("\(flag): not a hex USB ID: \(v)")
            }
            return n
        }
        while let a = it.next() {
            switch a {
            case "--vendor-id": vendorID = try id(a)
            case "--product-id": productID = try id(a)
            case "--query": query = try value(a)
            case "--interval": interval = max(0.2, try number(a))
            case "--timeout": timeout = max(0.5, try number(a))
            case "--on-battery-max": onBatteryMax = try number(a)
            case "--min-battery-volts": minBatteryVolts = try number(a)
            case "--lost-max": lostMax = try number(a)
            case "--min-charge": minCharge = try number(a)
            case "--ups-watts": battery.upsWatts = try number(a)
            case "--battery-ohms": battery.ohms = try number(a)
            case "--battery-nominal": battery.nominal = try number(a)
            case "--battery-curve":
                let v = try value(a)
                guard let c = BatteryModel.parseCurve(v) else { throw OptionError("\(a): not V:%,V:%,...: \(v)") }
                battery.curve = c
            case "--shutdown-hook": shutdownHooks.append(try value(a))
            case "--event-hook": eventHooks.append(try value(a))
            case "--hook-timeout": hookTimeout = try number(a)
            case "--shutdown-command": shutdownCommand = try value(a)
            case "--dry-run": dryRun = true
            case "--state-file": stateFile = try value(a)
            case "--heartbeat": heartbeat = try number(a)
            case "--once": once = true
            case "--send": send = try value(a)
            case "--ups-off-delay":
                upsOffDelay = try number(a)
                guard upsOffDelay == 0 || megatecDelay(upsOffDelay) != nil else {
                    throw OptionError("\(a): 0.2 to 0.9, or 1 to 10 minutes")
                }
            case "--ups-restore":
                let n = Int(try number(a))
                guard (1...9999).contains(n) else { throw OptionError("\(a): 1 to 9999 minutes") }
                upsRestore = n
            case "--version": print("upswatch \(version)"); exit(0)
            case "-h", "--help": print(usage); exit(0)
            default: throw OptionError("unknown option: \(a)")
            }
        }
    }
}

/// A Megatec shutdown delay: .2 to .9 of a minute, or 01 to 10 minutes.
func megatecDelay(_ minutes: Double) -> String? {
    if minutes < 1 {
        let tenths = Int((minutes * 10).rounded())
        return (2...9).contains(tenths) ? ".\(tenths)" : nil
    }
    let whole = Int(minutes.rounded())
    return (1...10).contains(whole) && abs(minutes - Double(whole)) < 0.01
        ? String(format: "%02d", whole) : nil
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
