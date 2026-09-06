# ACPI tables from bigtab01

Pulled 2026-09-06 straight from `/sys/firmware/acpi/tables/` (readable with `sudo cat` — `acpidump`
is not required, though it is now installed). Kernel `7.1.13-200.fc44.x86_64`, firmware as shipped.

| File | Bytes |
|---|---|
| `DSDT.aml` | 66,080 |
| `SSDT1.aml` … `SSDT6.aml` | 24,633 / 13,357 / 1,564 / 1,139 / 2,932 / 23,601 |

Captured for the **vibrator hunt** (goal 2). Decompile with `iasl -d DSDT.aml`; `iasl` comes from
`acpica-tools` and lives on the **dev box**, not bigtab01 — see the build policy in
[docs/06-next-session.md](../../docs/06-next-session.md).

## What has already been searched, and found nothing

A raw AML scan of **all seven tables** for four-character ACPI NameSegs `VIBR`, `HAPT`, `VBRT`,
`MOTR`, `BUZZ`, `HPTC`, `RUMB`, `VIBE`, `HPTM`, `PWM0`, `PWM1` returned **zero hits**.

That is a weak negative and does **not** rule ACPI out — a method can be named anything, and
control is just as likely to sit inside a `_DSM` behind a UUID. **21 `_DSM` methods in the DSDT and
3 in SSDT6** remain unread, and reading them needs `iasl`.

### `HPQC4752` is a GPS receiver — not haptics

The one HP-vendor `_HID` in the DSDT looked like the obvious lead. It is not. Decoding the AML by
hand at byte offset `22032` (`0x5610`) resolves it:

```
5b 82 4b 08  GPS0                       <- DeviceOp, device name GPS0
   _HID  0d "HPQC4752" 00               <- 0x0D = StringPrefix
   _HRV
   _CRS  ... \_SB.PCI0.UA00 ... \_SB.PCI0.GPI0    <- a UART and a GPIO
   _STA  -> 0x0F                        <- looked like present, enabled, functioning
```

So it is a **GPS module on a UART**, and everything else in the DSDT is stock Intel `INT33xx`/
`INT34xx` LPSS plus `ITE8350`. **Do not re-chase this device for the vibrator.**

> **Correction, 2026-09-06 (later that day).** Read with `iasl`, `GPS0._STA` turns out to be a
> hardcoded `Method (_STA) { Return (0x0F) }` — it branches on nothing, so it cannot report absence
> and `status=15` is not evidence a receiver exists. **There is no GPS in this machine**; the wire
> was sniffed directly and is silent. See [docs/13-gps.md](../../docs/13-gps.md). The two sections
> below are left as written, but the hypothesis in the second one is **disproven** — see the note
> at its end.

## The GPS is wired to a UART the firmware has disabled

Followed up 2026-09-06. The blocker is **not** a missing driver — this kernel ships everything
needed:

| Component | State |
|---|---|
| GNSS subsystem | `gnss.ko`, `gnss-serial.ko`, `gnss-sirf.ko`, `gnss-ubx.ko`, `gnss-mtk.ko`, `gnss-usb.ko` all present |
| LPSS UART driver | `/sys/bus/platform/drivers/dw-apb-uart` exists |
| `GPS0` (`HPQC4752:00`) | `status=15` — present, enabled, functioning. `driver=NONE`, `physical_node=none` |
| **`INT3434:00`, `INT3435:00`** (the two Broadwell LPSS UARTs) | **`status=0`** |

`_STA` = 0 means **not present**. The firmware is reporting both LPSS UARTs as absent, so no driver
binds, no serial port is created, and `GPS0`'s `_CRS` — which points at `\_SB.PCI0.UA00` — refers to
a UART that does not exist as far as Linux is concerned.

Every `/dev/ttyS0`…`ttyS17` node is a legacy static `serial8250` platform placeholder with no
hardware behind it (`/sys/class/tty/ttySN/device` → `serial8250:0.N`). `dmesg` registers the 8250
core's 32 ports and never enumerates a real one. So the GPS has no tty to talk on.

### It is `SMD5`, not `_OSI` — and `acpi_osi=` will not help

An earlier note in this file guessed an `_OSI` gate and suggested `acpi_osi="Windows 2013"`.
**That guess was wrong.** Decompiling settles it. `_STA` has two gates:

```
Method (_STA, 0, NotSerialized)
{
    If ((SMD5 == Zero))   { Return (Zero) }     // gate 1: firmware NVS
    If ((OSYS < 0x07DD))  { Return (Zero) }     // gate 2: OS year < 2013
    Return (0x0F)
}
```

Gate 2 passes. The `_INI` ladder contains `If (_OSI ("Windows 2013")) { OSYS = 0x07DD }`, and Linux
claims `Windows 2013`, so `OSYS` is exactly `0x07DD` and `OSYS < 0x07DD` is false.

So **gate 1 is the one firing: `SMD5 == 0`.** `SMD5`/`SMD6` are firmware NVS variables selecting the
UART's mode, and the DSDT shows `SMD5 == 0x02` means PCI mode (it then gives `UA00` an `_ADR` of
`0x00150005`). `lspci -s 00:15` returns **nothing**, so it is not in PCI mode either. `SMD5` is zero:
**the firmware has the UART switched off entirely.**

That makes the GPS unreachable from the OS side. No kernel argument, driver or quirk changes an NVS
value the firmware set before Linux booted — it would need a BIOS setup option (if one is even
exposed on this machine) or firmware modification. **Do not spend time on `acpi_osi=`.**

## The vibrator is not in ACPI at all

Searched the **decompiled source** of all seven tables — 136 devices — not just raw bytes:

| Search | Result |
|---|---|
| text `vibrat`/`haptic`/`rumble`/`buzzer`/`motor` | **zero hits** |
| device names matching `VIB`/`HAP`/`MOT`/`BUZ`/`RUM`/`HPT` | **none** |
| the 24 `_DSM` methods | all owned by `PEPD`, PCIe root ports `RP01`–`RP08`, processors `PR15`/`PR17`, and I2C buses — all stock platform plumbing, no haptic candidate |
| HP-specific `_HID`s | only `HPQC4752` (the GPS) and `HPQOEM` (the standard HP OEM table signature) |

**ACPI is ruled out as the vibrator's control path.** Combined with the sensor hub having no HID
Output reports, the remaining candidate is the SYNA7500 touchscreen's two Output reports on vendor
page `0xff00` — see [../hid/README.md](../hid/README.md).
