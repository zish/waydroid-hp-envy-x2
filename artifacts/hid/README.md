# HID report descriptors from bigtab01

Pulled 2026-09-06 from `/sys/bus/hid/devices/*/report_descriptor`. Captured for the vibrator hunt.

| File | Device | Bytes |
|---|---|---|
| `ite8350-sensorhub.rd` | `0018:048D:8350` — ITE8350 HID sensor hub (all five IIO sensors) | 2,271 |
| `syna7500-touch.rd` | `0018:06CB:0E1B` — Synaptics SYNA7500 touchscreen + stylus | 573 |

The HP Bluetooth keyboard (`0005:0461:4E5C`) returns a **zero-byte** descriptor and was not kept.

## Why these matter

A vibrator driven over HID needs an **Output** report (item tag `0x91`). What the descriptors say:

| Device | Output items | Vendor usage pages | HID Haptics page (`05 0e`) |
|---|---|---|---|
| ITE8350 sensor hub | **0** | `0xff83` (one) | absent |
| SYNA7500 touch | **2** | `0xff00` (one) | absent |

So the **sensor hub cannot drive a vibrator** — it has no output path at all; its 59 Feature
reports (`b100`/`b102`) are ordinary HID-sensor configuration, and its `0xff83` collection is
claimed by the kernel's HID-sensor framework as `HID-SENSOR-ff830080` (a vendor-defined *sensor*
with no driver bound, purpose unknown).

**The SYNA7500's two Output reports on vendor page `0xff00` are the only output path on the
machine**, and therefore the remaining HID candidate. Temper expectations: a vendor collection on a
Synaptics touch controller is most often the RMI4/firmware-update channel used by `hid-rmi`, not
haptics. Worth decoding before assuming either way.

**Beware a false lead:** `05 09` appears in some descriptors and is Usage Page **Button**, not a
vibrator. A naive hex grep looks like a hit.

---

## Resolved 2026-10-02 — neither device drives the vibrator, and one reason above was wrong

See [docs/62](../../docs/62-vibration-ec-owned.md). The motor belongs to the **embedded
controller**, which buzzes it on its own capacitive-button and power-on handling; no HID device is
involved. Two corrections to what is written above:

**The SYNA7500's two Output reports are the RMI4 transport, not a haptic channel.** Decoded, the
vendor-`0xff00` collection is Synaptics' RMI4-over-HID register protocol, matching `hid-rmi.c`'s
constants on report ID, direction *and* size:

| Report ID | Direction | Size | `hid-rmi.c` constant |
|---|---|---|---|
| `0x09` | Output | 20 | `RMI_WRITE_REPORT_ID` |
| `0x0a` | Output | 20 | `RMI_READ_ADDR_REPORT_ID` |
| `0x0b` | Input | 17 | `RMI_READ_DATA_REPORT_ID` |
| `0x0c` | Input | 17 | `RMI_ATTN_REPORT_ID` |
| `0x0f` | Feature | 3 | `RMI_SET_RMI_MODE_REPORT_ID` |

So the "temper expectations" warning above was right: it is the register/firmware-update channel.

**"The sensor hub has no output path at all" was the wrong reason to clear the ITE8350.** HID
*Feature* reports are writable with `SET_REPORT`, and the hub has one on a vendor page — report
`0x5a`, 16 bytes, usage page `0xff83`, which is the unbound `HID-SENSOR-ff830080.1.auto` device.
A 16-byte vendor mailbox on a controller from an EC vendor is exactly the shape of a "buzz for N ms"
command, and counting Output items missed it. The hub is still cleared, but by measurement:
[`bin/button-probe.py`](../../bin/button-probe.py) tapped its raw stream across a button press and
saw only sensor report IDs `01`/`02`/`04` in 9,735 reports, and nothing at all at the tap.
