import Foundation

let version = "0.1.0"

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
  --lost-max SECONDS         0 to never shut down for it (default 60)

What to run:
  --shutdown-hook CMD     run with /bin/sh before shutting down, e.g. to shut
                          down other machines on the same UPS; repeatable,
                          all at once, each waited for up to --hook-timeout
  --event-hook CMD        run with /bin/sh on each event, not waited for;
                          repeatable. UPSWATCH_EVENT is online, onbattery,
                          lowbattery, lost, found or shutdown, UPSWATCH_MESSAGE
                          says what happened, UPSWATCH_STATUS is the last reading
  --hook-timeout SECONDS  (default 30)
  --shutdown-command CMD  (default "/sbin/shutdown -h now")
  --dry-run               log the shutdown, run the hooks with
                          UPSWATCH_DRY_RUN=1, and do not shut down

Other:
  --state-file PATH       keep the last reading there, as JSON
  --heartbeat SECONDS     log the reading at least this often (default 300)
  --once                  print one reading as JSON and exit (1 when none)
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
    var shutdownHooks = [String]()
    var eventHooks = [String]()
    var hookTimeout = 30.0
    var shutdownCommand = "/sbin/shutdown -h now"
    var dryRun = false
    var stateFile: String?
    var heartbeat = 300.0
    var once = false

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
            case "--shutdown-hook": shutdownHooks.append(try value(a))
            case "--event-hook": eventHooks.append(try value(a))
            case "--hook-timeout": hookTimeout = try number(a)
            case "--shutdown-command": shutdownCommand = try value(a)
            case "--dry-run": dryRun = true
            case "--state-file": stateFile = try value(a)
            case "--heartbeat": heartbeat = try number(a)
            case "--once": once = true
            case "--version": print("upswatch \(version)"); exit(0)
            case "-h", "--help": print(usage); exit(0)
            default: throw OptionError("unknown option: \(a)")
            }
        }
    }
}

struct OptionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
