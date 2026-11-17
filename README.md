# upswatch

Shuts a Mac down when its UPS runs out of time, for the cheap line-interactive
UPSes that macOS cannot read on its own.

Many of them talk the Megatec / Voltronic serial protocol through a USB
bridge, most often INNO TECH's (Cypress) `0665:5161`, that calls itself a
vendor-defined HID device rather than a HID power device. macOS's HID driver
claims it and ignores it, so the UPS never shows up in Energy settings, and
macOS never shuts down for it. NUT's `nutdrv_qx` can read it, but only as root,
by taking the device from macOS through libusb.

upswatch reads it through macOS's own HID driver instead (`IOHIDDevice`): no
libusb, no detaching the kernel driver, and on an error it waits and asks
again. It never resets the device. Some of these bridges, reset while the
UPS switches between line power and battery, fall off the bus and stay off
until their USB port loses power, which is exactly when you need them.

It is one small binary, with no dependencies and no configuration file: its
settings are its arguments, in the launch daemon's plist.

## What it does

Once a second it sends the status query (`QS` by default, or `Q1`) and reads
the reply:

```
(226.5 226.5 224.4 004 60.1 13.5 30.0 00001001
```

It logs each change of state, and a heartbeat. It shuts the Mac down when the
UPS is on battery and:

- the UPS says its battery is low;
- it has been on battery for `--on-battery-max` seconds;
- the battery is at or under `--min-battery-volts`;
- its estimated charge is at or under `--min-charge` (below);
- or the UPS has stopped answering for `--lost-max` seconds (60 by default).
  The last one is for a UPS that drops off USB once on battery: it was last
  seen on battery, and will not be able to say its battery is low.

Before it shuts down it runs each `--shutdown-hook`, all at once, and waits
for them (up to `--hook-timeout`, 30 s): that is how one Mac on the USB cable
shuts down others on the same UPS, over ssh. Each `--event-hook` runs on every
event (`onbattery`, `online`, `lowbattery`, `lost`, `found`, `shutdown`),
without waiting, for notifications.

## How charged is the battery

These UPSes report the battery's voltage, not its charge, so upswatch
estimates it, and only on battery: on line power the charger holds the
battery at its float voltage (13.5-13.8 V for 12 V) whatever its charge.

On battery, the voltage reads low under load, by the current times the
battery's internal resistance (and its wiring's). With `--ups-watts` (the
UPS's rating in watts, not VA), upswatch adds that sag back, from the load the
UPS reports, before it looks the voltage up in a sealed lead-acid (VRLA / AGM)
battery's resting voltage curve, the kind nearly every small UPS uses. The
readings come in 0.1 V steps, so it averages them over about ten seconds.

It is a guide, good to perhaps ten or fifteen points: a battery reads high
for the first minute off the charger, and low just after a load step, and an
old battery has more resistance and less capacity than its voltage says. For
the shutdown itself, the UPS's own low-battery flag and a time limit on
battery (`--on-battery-max`) are the ones to rely on. Another chemistry, or
a better curve for yours: `--battery-curve 10.5:0,...,12.73:100` (volts per
12 V at rest, and percent).

The estimate is in the log, the state file (`charge_percent`) and the hooks'
`UPSWATCH_CHARGE`.

## The state file

With `--state-file`, upswatch rewrites it every interval, as JSON: the last
reading (`status`, the voltages, `load_percent`, `charge_percent` and
`on_battery_since` on battery, as of `time`), and whether the UPS is on USB
(`usb_attached`) and answering (`answering`) now. The file's own age says
whether upswatch is running. Unplugging the UPS's USB is `lost` at once: an
event, and `usb_attached: false`.

## Install

With Homebrew (it builds from source, with the Command Line Tools):

```bash
brew tap limeburst/upswatch https://github.com/limeburst/upswatch
brew install upswatch
```

Or build it yourself:

```bash
swift build -c release        # .build/release/upswatch
```

Check that it can read your UPS:

```bash
upswatch --once
```

```json
{
  "battery_volts" : 13.5,
  "frequency" : 60.2,
  "input_volts" : 222.3,
  "load_percent" : 0,
  "output_volts" : 222.3,
  "status" : "OL"
}
```

If it prints `no reply`, try `--query Q1`; if it finds nothing, look up your
UPS's USB IDs (`system_profiler SPUSBDataType`) and pass `--vendor-id` and
`--product-id`.

## Run it

It must run as root to shut the Mac down: a launch daemon. Copy
[`examples/upswatch.plist`](examples/upswatch.plist) to
`/Library/LaunchDaemons/`, change its arguments, and load it:

```bash
sudo install -m 644 -o root -g wheel upswatch.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/upswatch.plist
```

Or, with its defaults, `sudo brew services start upswatch`.

Try it first with `--dry-run`: it logs the shutdown and runs the hooks (with
`UPSWATCH_DRY_RUN=1` in their environment), and does not shut down. Pull the
UPS's plug, and watch the log.

### Shutting down other machines

Each machine on the same UPS gets a hook. With Tailscale SSH, or a key that
root on this Mac can use:

```
--shutdown-hook "ssh -o BatchMode=yes -o ConnectTimeout=10 root@other-mac /sbin/shutdown -h now"
```

They are shut down before this Mac, which waits for each hook to exit. Their
network has to outlast line power too: put the switch or router they talk
through on the UPS.

### Notifications

The hooks get `UPSWATCH_EVENT`, `UPSWATCH_MESSAGE` and `UPSWATCH_STATUS`:

```
--event-hook 'curl -fsS -H "Content-Type: application/json" -d "{\"content\": \"$UPSWATCH_MESSAGE\"}" "$(cat /etc/upswatch-webhook)"'
```

## Options

```
upswatch --help
```

## Things to know

- **USB.** If your UPS drops off USB when it switches to battery (macOS logs
  `transaction error` and then `terminateDevice ... reset API call`), try it
  behind a USB hub. On the Macs we tried, a port behind a hub (a Mac mini's
  front ports are behind an internal one) kept the bridge on the bus where a
  port straight on the controller lost it every time.
- **Coming back.** Once the Macs have shut down, the UPS keeps its outlets on
  until its battery is flat, so when line power returns first, the Macs stay
  off. Turn on *Start up automatically after a power failure*
  (`sudo pmset autorestart 1`) for when the battery does run flat.
- Only one program can talk to the UPS at a time: stop NUT, or anything else
  polling it, first.

## License

MIT
