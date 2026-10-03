# 62 — Vibration: the motor belongs to the EC, and nothing in the machine can ask it to buzz

*2026-10-02. Goal 2's last open part, **deferred as unlikely**. The motor is real and works —
it fires on a tap of the capacitive Windows button and again at power-on. Both of those are the
**embedded controller** acting on its own. There is no ACPI method, no GPIO, no PWM, no HID output,
no WMI command and no EC register anywhere in this machine's firmware that drives it, and the
button that does drive it reaches Linux only as a notification that it has **already** happened.*

## One-paragraph summary

Earlier sessions searched for the vibrator the way you search for a device — by name, in ACPI and in
the HID descriptors — and found nothing, leaving one open lead: the SYNA7500 touchscreen's two HID
Output reports. That lead is dead; the two Output reports are the RMI4 register transport, not
haptics. The thing that actually cracked it was not a search but two facts from the owner: the motor
buzzes **when the capacitive Windows button is tapped**, and it buzzes **at power-on**. The second
one is decisive by itself — at power-on there is no OS to drive anything, so the buzz is firmware's.
A probe watching all 15 evdev devices and all three raw HID streams against one clock then caught
the tap: it arrives **only** as `intel-vbtn` scancode `0xC2`/`0xC3` → `KEY_LEFTMETA`, from the EC,
and the touch controller and sensor hub stay completely silent. The firmware handler for that
scancode — `_Q81` in the DSDT — sets one bit and raises one `Notify`. It does not touch a motor.
So the EC detects the button, buzzes the motor, and *then* tells the OS. The OS is downstream of
the buzz and has no way to get upstream of it.

## The two facts that reframed the problem

Everything before this session treated "the vibrator exists" as a bare claim. It is not — it has a
specific, reproducible trigger, and the trigger is the whole answer:

| Observation | What it rules out |
|---|---|
| Tapping the capacitive Windows button buzzes the motor | The motor is wired to whatever owns that button |
| The motor also buzzes **when powering the laptop on** | Any OS-driven path. At power-on the EC is running and nothing else is |

The power-on buzz is the load-bearing one. A driver, a daemon, an ACPI method and a HID report all
require an operating system; the EC is alive before any of them exist. Whatever drives the motor is
reachable by the EC with no help from software, which is exactly the shape of a device that software
cannot reach either.

## The measurement

[`bin/button-probe.py`](../bin/button-probe.py) opens every `/dev/input/event*` **and** every
`/dev/hidraw*` at once and timestamps them against one monotonic clock, so a single tap names its
own source. One tap, 900-second window:

```
  31.435 evdev  event7 [Intel Virtual Buttons]   MSC 4 194
  31.435 evdev  event7 [Intel Virtual Buttons]   KEY KEY_LEFTMETA 1
  31.665 evdev  event7 [Intel Virtual Buttons]   MSC 4 195
  31.665 evdev  event7 [Intel Virtual Buttons]   KEY KEY_LEFTMETA 0
```

Those four lines are the **entire** evdev yield of the window. Scancodes `0xC2`/`0xC3` are
`intel-vbtn`'s "Windows key press/release" pair, and `INT33D6:00` sits at
`/sys/devices/.../PNP0C09:00/INT33D6:00` — a child of the EC. Alongside them:

| Source | Traffic during the window |
|---|---|
| `hidraw1` — SYNA7500 touchscreen | **zero reports**, including at the tap |
| `hidraw2` — ITE8350 sensor hub | 9,735 reports, report IDs `01`/`02`/`04` only — ordinary sensor data, nothing new at the tap |
| every other evdev device | nothing |

So the button is not the digitizer's and not the hub's. It is the EC's.

## What the firmware does with the button, in full

`_Q81` is the EC query for the press and `_Q91` for the release (DSDT, inside
`\_SB.PCI0.LPCB.H_EC`). This is the complete handler:

```asl
Method (_Q81, 0, NotSerialized)
{
    P8XH (Zero, 0x10)                 // POST-code debug write
    If ((PB1E & 0x20))                // has the OS called VBDL yet?
    {
        ^VGBI.UPBT (One, One)         // set bit 1 in the virtual-button status word
        Notify (VGBI, 0xC2)           // tell intel-vbtn: Windows key down
        P8XH (Zero, 0x11)
    }
}
```

There is no motor write, no EC register poke, no haptic call — and nothing conditional that a
different OS could have taken. By the time `_Q81` runs, the EC has already buzzed. Note also the
`PB1E & 0x20` gate: if Linux had never called `VBDL`, the OS would get **no** event at all and the
motor would still buzz, which is the clearest possible statement of which side owns it.

## Everything now ruled out, and how

The earlier negative results are restated here because this session re-derived them independently
rather than trusting them, and two were previously recorded with incomplete reasoning.

| Candidate path | Result | How checked |
|---|---|---|
| ACPI device or method | **none** | All 7 tables decompiled; 155 `Device` blocks, 878 `Method`s; comment-stripped regex for `vibrat\|haptic\|rumble\|buzz\|motor\|VIBR\|HAPT\|RUMB\|BUZZ\|HPTC\|MOTR` → **0 hits** |
| GPIO line | **none** | Exactly **one** `GpioIo` exists in all seven tables, and it is spoken for: the enable pin (`0x11` on `GPI0`) that `GPS0._CRS` declares for a GPS receiver **this unit does not have** — `GPS0` is a family-wide firmware declaration, and the line was physically sniffed in [docs/13](13-gps.md). There is no second one |
| PWM | **none** | `/sys/class/pwm/` is empty |
| LED class (a common home for vibrators) | **none** | `hda::mute`, three keyboard-lock LEDs, `phy0-led` |
| force-feedback input device | **none** | No `B: FF=` line in `/proc/bus/input/devices` |
| I2C device | **none** | Only `i2c-ITE8350:00` and `i2c-SYNA7500:00`; the rest are i915/SMBus adapters |
| HP WMI / BIOS | **none** | The `\_SB.WMID` device has **71** methods — all battery, thermal, dock, security and BIOS-config; none haptic-shaped. `hp-bioscfg` exposes exactly two settings, `Sure_Start` and `pending_reboot` |
| EC RAM | **none** | `OperationRegion (ECF2, EmbeddedControl, 0, 0xFF)`'s named fields are battery, thermal, fan, lid and power only |
| SYNA7500 HID Output reports | **not haptics** | See below |
| ITE8350 vendor Feature report | **not involved** | See below |

### Correction 1 — the SYNA7500's Output reports are RMI4, not a haptic channel

[artifacts/hid/README.md](../artifacts/hid/README.md) left these as "the only output path on the
machine, and therefore the remaining HID candidate", with the right instinct to temper expectations.
Decoded, the vendor-`0xff00` collection is this:

| Report ID | Direction | Size | `hid-rmi.c` constant |
|---|---|---|---|
| `0x09` | Output | 20 | `RMI_WRITE_REPORT_ID` |
| `0x0a` | Output | 20 | `RMI_READ_ADDR_REPORT_ID` |
| `0x0b` | Input | 17 | `RMI_READ_DATA_REPORT_ID` |
| `0x0c` | Input | 17 | `RMI_ATTN_REPORT_ID` |
| `0x0f` | Feature | 3 | `RMI_SET_RMI_MODE_REPORT_ID` |

Five report IDs, matching directions, matching sizes: this is Synaptics' RMI4-over-HID transport —
a generic register read/write channel into the touch controller — and not a haptic output. It is
moot regardless, because the probe shows the touch controller never sees the button at all.

### Correction 2 — "no Output reports" was the wrong reason to clear the sensor hub

The same README cleared the ITE8350 because it "has no output path at all". That reasoning is
incomplete: HID **Feature** reports are writable with `SET_REPORT`, and the hub does have one on a
vendor page — report `0x5a`, 16 bytes, usage page `0xff83`, the unbound `HID-SENSOR-ff830080.1.auto`
mystery device. A 16-byte vendor mailbox on a controller made by an EC vendor is exactly the shape
of a "buzz for N ms" command, and it deserved to be the session's prime suspect.

It is still cleared, but now by measurement rather than by that argument: across 9,735 reports the
hub emitted only sensor report IDs `01`/`02`/`04`, and it produced nothing whatsoever at the tap.
The hub is not in the button's path, so it is not in the motor's path.

## What is left, and why it is not recommended

One avenue survives: the EC's own command and RAM space at I/O `0x62`/`0x66`. EC RAM offsets
`0x71`–`0x7D` are declared as bare `Offset()` gaps the firmware's ACPI code never uses, and HP ECs
accept vendor commands beyond the standard read/write pair. A buzz command could be in there.

Reaching it is the problem, and the cost is wrong:

- `CONFIG_ACPI_EC_DEBUGFS is not set` in this kernel, so `/sys/kernel/debug/ec/` does not exist and
  there is no supported way to read or write EC RAM. Building the module means layering on an
  rpm-ostree host.
- The unsupported way is `/dev/port` (`CONFIG_DEVPORT=y`) directly against `0x62`/`0x66`. That races
  the kernel's own ACPI EC driver, and a torn EC transaction is not a soft failure — **this EC owns
  charging, the fan and thermal**, on a machine whose battery already behaves badly
  ([docs/41](41-battery-cutoff.md)).
- Even with access, finding the command means blind-writing bytes to an EC with those
  responsibilities.

That is a large, genuinely risky search for a motor whose entire known repertoire is one short buzz.
**Do not start it without the owner deciding, explicitly, that the risk is acceptable.**

## Verdict

**Vibration cannot be delivered to Android on this machine.** Not because the Waydroid side is hard
— the Waydroid side was never the problem — but because there is nothing underneath it to call.
Checked on the running container rather than assumed:

```
[init.svc.vendor.vibrator-1-0]: [running]        pid 88, android.hardware.vibrator@1.0-service.waydroid
/vendor/lib{,64}/hw/vibrator.default.so          5,760 and 7,248 bytes -- stubs
```

The HAL is up and answering binder on both ABIs. It has nothing to drive. The motor is an EC
indicator, wired to the EC's own button and the EC's own power-on sequence, and the operating
system is not on the path at any point.

Goal 2's remaining part is therefore **deferred as unlikely** — not parked for lack of effort, but
because every interface the OS could reach has been checked and the one that remains is not worth
its risk. Treat it as closed in practice.

Two things would reopen it: evidence that something *other* than the EC can make the motor move, or
a decision that blind EC probing is acceptable after all. Neither is a reason to re-run the searches
in the table above — those are done, and re-running them is the trap this note exists to prevent.
