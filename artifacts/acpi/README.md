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
   _STA  -> 0x0F                        <- present, enabled, functioning
```

So it is a **GPS module on a UART**, and everything else in the DSDT is stock Intel `INT33xx`/
`INT34xx` LPSS plus `ITE8350`. **Do not re-chase this device for the vibrator.**

Worth noting for a different reason: bigtab01 has a GPS receiver, reported present and functioning.
Android has a location HAL, so this is a plausible future capability well beyond the current goal
list — recorded here so it is not forgotten.
