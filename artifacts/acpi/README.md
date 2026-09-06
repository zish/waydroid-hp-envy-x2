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

### The likely cause, and how to test it

This pattern — vendor devices present but their LPSS bus disabled — is usually an **`_OSI` gate**
in the DSDT: the firmware only enables LPSS UARTs when the OS identifies as a particular Windows
version, and returns 0 from `_STA` otherwise. It is common on HP and Lenovo machines of this era.

Confirm by decompiling the DSDT (`iasl -d DSDT.aml`) and reading the `_STA` method for `INT3434`/
`INT3435` to see whether it branches on `_OSI`. If it does, the standard workaround is an
`acpi_osi=` kernel parameter (e.g. `acpi_osi="Windows 2013"`), which on an rpm-ostree host means
`rpm-ostree kargs --append=...`.

**This is out of scope for goals 1-4** and is recorded only so the finding is not lost. Note also
that even with NMEA flowing on the host, exposing it to Android would need a GPS HAL in Waydroid —
a separate project again.

> **Disproven, 2026-09-06.** The test above was run and the `_OSI` hypothesis is **wrong**.
> `UA00._STA` has *two* gates, and the one that fires is the first: `If (SMD5 == Zero)`, a BIOS
> byte in ACPI NVS. The `OSYS` gate is provably not it — `I2C0` (`INT3432`) carries the identical
> `If (OSYS < 0x07DD)` test and reports `status=15`, so `OSYS >= 0x07DD` already and `acpi_osi=`
> would change nothing. The firmware simply has SerialIO UART0 set to *Disabled*.
>
> It is moot anyway: the UART0 pads were muxed to GPIO and sniffed directly, and nothing is
> transmitting on them — 10.5M samples across both polarities of the enable line, all high. There
> is no GPS receiver fitted. Full write-up and the reasoning in
> [docs/13-gps.md](../../docs/13-gps.md); annotated AML in
> [lpss-uart-gps.dsl](lpss-uart-gps.dsl).
