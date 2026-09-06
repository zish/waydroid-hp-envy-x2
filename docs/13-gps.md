# GPS: the receiver is not fitted

Investigated 2026-09-06, out of the goal order, because it was asked for directly. **Result: there
is no GPS receiver in this machine.** The `GPS0` device in the DSDT is a claim made by a firmware
image shared across the whole Envy x2 13 family, not a report about this unit. No changes were made
to the host; one GPIO was driven high for 24 seconds and put back.

This note also **corrects a wrong hypothesis** recorded in
[artifacts/acpi/README.md](../artifacts/acpi/README.md): the LPSS UARTs are not gated behind `_OSI`.
That is disproven below.

## What was believed going in

The previous session found `HPQC4752` / `GPS0` in the DSDT while hunting for a vibrator, noted that
its `_STA` reports `0x0F` (present, enabled, functioning), and found that the UART it hangs off —
`INT3434:00`, i.e. `\_SB.PCI0.UA00` — reports `_STA` = 0. It guessed the cause was an `_OSI` gate in
the firmware, fixable with an `acpi_osi=` kernel argument.

Both halves of that were wrong. The device status means nothing, and the gate is not `_OSI`.

## `GPS0._STA` is a hardcoded constant

```asl
Device (GPS0)
{
    Name (_HID, "HPQC4752")
    Method (_CRS, ...)   // UartSerialBusV2 115200 8N1 RTS/CTS on \_SB.PCI0.UA00
                         // + GpioIo output pin 0x11 on \_SB.PCI0.GPI0
    Method (_STA, 0, NotSerialized) { Return (0x0F) }
}
```

`_STA` branches on nothing. It cannot report absence, so `status=15` is not evidence that a receiver
exists — only that HP's DSDT always declares one. Everything downstream of that observation needed
re-checking.

## The UART is disabled in NVS, not by `_OSI`

`UA00`'s status method has two gates, not one:

```asl
Method (_STA, 0, NotSerialized)          // \_SB.PCI0.UA00, _HID INT3434
{
    If ((SMD5 == Zero))     { Return (Zero) }   // BIOS SerialIO mode byte, from ACPI NVS
    If ((OSYS < 0x07DD))    { Return (Zero) }   // "Windows 2013"
    Return (0x0F)
}
```

The second gate is the one the earlier note guessed at. It is not the one that fires, and the proof
needs no root access and no reboot — **`I2C0` carries the identical gate and works**:

```asl
Method (_STA, 0, NotSerialized)          // \_SB.PCI0.I2C0, _HID INT3432
{
    If ((SMD1 == Zero))     { Return (Zero) }
    If ((OSYS < 0x07DD))    { Return (Zero) }   // <- same test, same constant
    Return (0x0F)
}
```

On the host:

| ACPI device | `_HID` | `status` |
|---|---|---|
| `INT3430:00` | LPSS DMA | 0 |
| `INT3431:00` | SPI1 | 0 |
| **`INT3432:00`** | **I2C0** | **15** |
| `INT3433:00` | I2C1 | 15 |
| **`INT3434:00`** | **UART0 — the GPS's UART** | **0** |
| `INT3435:00` | UART1 | 0 |
| `INT3436:00` | SDIO | 0 |
| `INT3437:00` | GPIO | 15 |

`INT3432` returning 15 means it got past `OSYS < 0x07DD`, so `OSYS >= 0x07DD`. Linux answers
`_OSI("Windows 2013")` and the DSDT sets `OSYS = 0x07DD` when it does, exactly as expected. The
same gate therefore cannot be what stops `INT3434`. The only remaining term is `SMD5`, so:

> **`SMD5 == 0`.** The firmware has SerialIO UART0 set to *Disabled* in ACPI NVS.

`acpi_osi=` would have changed nothing. The enabled set — two I2C controllers for the sensor hub and
the touchscreen, plus GPIO — is exactly what this machine actually uses, and everything else is off.

### Reading NVS directly is blocked, and unnecessary

`SMD5` lives at a computable address: the DSDT declares `Name (PNVB, 0x9CFBDD98)` with
`OperationRegion (PNVA, SystemMemory, PNVB, PNVL)`, and walking the `Field (PNVA)` bit list gives
byte offsets that sum to exactly `PNVL` = 228, which is a self-check on the parse.

| Field | Offset | Address |
|---|---|---|
| `SMD0`…`SMD7` | 0x71–0x78 | 0x9CFBDE09–0x9CFBDE10 |
| `SMD5` (UART0) | 0x76 | **0x9CFBDE0E** |
| `SIR5` (UART0 IRQ) | 0x7E | 0x9CFBDE16 |
| `SB05` / `SB15` (UART0 BARs) | 0x95 / 0xB5 | 0x9CFBDE2D / 0x9CFBDE4D |

Reading them fails anyway: Fedora builds `CONFIG_IO_STRICT_DEVMEM=y`, so `/dev/mem` refuses the ACPI
NVS page even as root and even with `lockdown=[none]`. It would take an `iomem=relaxed` kernel
argument and a reboot. Not worth it — the `I2C0` control case already settles it, and the answer
below makes the value moot.

## The decisive test: listen to the wire

The interesting question was never "why is the UART off" but "is anything connected to it". That is
answerable without a reboot, because **the UART pads exist whether or not the controller does**.

On this PCH the SerialIO UART0 signals are pins 91–94 of `INT3437` (`gpiochip0`), and
`/sys/kernel/debug/pinctrl/INT3437:00/pins` shows them in native UART mode and *not* ACPI-owned:

```
pin  0 (GP0_UART1_RXD)   GPIO    0xc0000005      <- the other UART, repurposed as GPIO by HP
pin  4 (GP4_I2C0_SDA)    mode 0  0x80000004
pin 17 (GP17_MGPIO10)    GPIO    0x00000019      <- GPS0's enable line, output, driving low
pin 91 (GP91_UART0_RXD)  mode 0  0x00000000      <- GPS UART, native mode, host-owned
pin 92 (GP92_UART0_TXD)  mode 0  0x00000000
pin 93 (GP93_UART0_RTSB) mode 0  0x00000000
pin 94 (GP94_UART0_CTSB) mode 0  0x00000000
```

So [bin/gps-probe.py](../bin/gps-probe.py) steals pin 91, muxes it to a GPIO input via the
`/dev/gpiochip0` character device, and polls it. The logic is simply:

- an unpopulated or sleeping line idles high forever;
- a GPS streaming NMEA at 115200 baud pulls it low thousands of times a second.

Requesting the line through gpiolib makes `pinctrl-lynxpoint` switch the pad to GPIO mode, which is
all the muxing needed. Polling ran at **387,000 samples/s — 2.6 µs apart, against an 8.7 µs bit time
at 115200 baud** — so no byte could have slipped through unseen.

### Results

| Pass | Pin 17 (enable) | Duration | Samples | Reads low | Transitions |
|---|---|---|---|---|---|
| 1 baseline | low (as since boot) | 3 s | 1,162,000 | **0** | **0** |
| 2 enable high | high | 4 s | 1,546,000 | **0** | **0** |
| 3 soak | high | 20 s | 7,860,000 | **0** | **0** |

Ten and a half million samples. The line never moved.

Both polarities are covered: pin 17 had been low since boot, so if the enable were active-low the
module had hours to start talking before pass 1; pass 3 then held it high for 21 s, well beyond any
GNSS cold-start chatter delay. `GPS0._CRS` lists exactly one `GpioIo`, so per the firmware there is
no other control line to try.

Pin 17 was restored to low. Pin 91 stays muxed as a GPIO until the next reboot —
`pinctrl-lynxpoint`'s `disable_free` does not restore the native function — which costs nothing,
since UART0 is dead regardless, and a reboot puts it back.

## Corroboration

- **No WWAN anywhere.** `lspci` shows only the Intel Wireless 7265 (Wi-Fi + Bluetooth, no GNSS);
  `lsusb` shows the root hubs, the Bluetooth radio and the webcam. No `/dev/ttyUSB*`, `/dev/ttyACM*`,
  `/dev/cdc-wdm*` or `/dev/gnss*`.
- **The disabled set fits.** A BIOS that turned off UART0, UART1, SDIO, SPI1 and the LPSS DMA is
  describing a board with no serial peripherals fitted.
- **The SKU.** DMI reports `HP ENVY x2 Detachable PC 13`, SKU `J9M66UAR#ABA`. HP's published
  specification for the 13-j012dx lists Wi-Fi and Bluetooth 4.0 and no GPS or mobile broadband
  option.

## Conclusion, and what would change it

The kernel side was never the problem. This host has the whole GNSS stack already — `gnss.ko`,
`gnss-serial`, `gnss-sirf`, `gnss-ubx`, `gnss-mtk`, `gnss-usb`, `CONFIG_SERIAL_8250_DW=y` built in —
plus `CONFIG_ACPI_TABLE_UPGRADE=y`, `lockdown=[none]` and Secure Boot off, which together would make
a DSDT override entirely practical. There is simply nothing to drive.

**Do not spend a reboot on a DSDT override.** Forcing `UA00._STA` to return `0x0F` would at best
produce a `ttyS` on a controller the firmware power-gated, wired to a receiver that does not exist.

The only thing that would overturn this is physical evidence — an M.2 or soldered GNSS module found
on inspection, or a different unit of this family with WWAN fitted. If that ever happens, the route
is already scoped: patch `UA00._STA` to `Return (0x0F)` and give `_CRS` a fixed `Memory32Fixed`
in the free space above `0xFE106FFF` plus a shared level/low interrupt (both working LPSS devices
share IRQ 7), build a cpio with `kernel/firmware/acpi/dsdt.aml`, and add it as a second `initrd`
line in the BLS entry. `bin/gps-probe.py` re-runs in seconds and would answer it again.

## Ruled out

| Hypothesis | Verdict |
|---|---|
| LPSS UARTs are gated behind `_OSI` / need `acpi_osi="Windows 2013"` | **Wrong.** `I2C0` passes the identical `OSYS` gate, so `OSYS >= 0x07DD` already |
| `GPS0._STA` = 15 means a receiver is present | **Wrong.** `_STA` is a hardcoded `Return (0x0F)` and tests nothing |
| A missing driver is the blocker | No. Every GNSS and DW-UART driver this needs is already built or modular |
| The GPS is on USB, or behind the WWAN modem | No. Nothing on `lsusb`/`lspci` but Wi-Fi, Bluetooth and the webcam |
| The module is fitted but held in reset | No. Both polarities of the only enable line in `_CRS`, 10.5M samples, silent |
| `/dev/mem` can read the NVS byte to confirm `SMD5` | No — `CONFIG_IO_STRICT_DEVMEM=y`. Needs `iomem=relaxed` and a reboot, and is unnecessary |
