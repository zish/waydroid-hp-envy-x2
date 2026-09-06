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
control is just as likely to sit inside a `_DSM` behind a UUID. The unexamined lead is
**`HPQC4752`**, the one HP-vendor `_HID` in the DSDT (everything else is stock Intel `INT33xx`/
`INT34xx` LPSS, plus `ITE8350`). Decompile and read that device first.
