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
