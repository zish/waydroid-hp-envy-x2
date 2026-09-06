#!/usr/bin/env python3
"""Is a GPS chip actually fitted on bigtab01?  Answer without a reboot.

Background
----------
The DSDT declares `GPS0` (_HID "HPQC4752") under `\\_SB.PCI0.UA00` -- LPSS
UART0 -- with a 115200-baud UartSerialBusV2 and an enable line on
`\\_SB.PCI0.GPI0` pin 17.  The firmware reports UART0 absent (`SMD5 == 0` in
ACPI NVS), so no tty is ever created and the module cannot be talked to.

But the UART0 *pads* exist regardless of the controller.  On this PCH they are
pins 91-94 of INT3437 (gpiochip0), currently in native UART mode and not
ACPI-owned.  So we can steal UART0_RXD, mux it to a GPIO input and simply look
at it:

  * nothing fitted, or fitted and asleep  -> line idles high, forever
  * a GPS talking NMEA at 115200 baud     -> line is pulled low constantly

That is a direct yes/no on "is there a chip on the other end of this UART",
which is the question that decides whether enabling the UART is worth a reboot.

Usage
-----
  sudo ./gps-probe.py                 # report line info only (no state change)
  sudo ./gps-probe.py --sample 3      # mux pin 91 to GPIO input, sample 3 s
  sudo ./gps-probe.py --sample 3 --enable-gps
                                      # also drive pin 17 high while sampling,
                                      # then restore it to the level found

Caveats
-------
* Requesting pin 91 leaves it muxed as GPIO until the next reboot: the
  lynxpoint pinctrl driver does not restore the native function on release.
  UART0 is dead anyway, so nothing is lost, and a reboot puts it back.
* A negative result is suggestive, not proof -- a module that needs a command
  on TX before it will talk would also stay silent.  A positive result is
  conclusive.
"""

import argparse, fcntl, os, struct, sys, time

CHIP = "/dev/gpiochip0"
PIN_RXD, PIN_ENABLE = 91, 17          # GP91_UART0_RXD, GP17 (GPS0 _CRS GpioIo)

# --- linux/gpio.h v2 uapi ----------------------------------------------------
_IOC_WRITE, _IOC_READ = 1, 2


def _ioc(d, t, nr, size):
    v = (d << 30) | (size << 16) | (t << 8) | nr
    return v - (1 << 32) if v >= (1 << 31) else v          # fcntl wants signed


GET_CHIPINFO = _ioc(_IOC_READ,              0xB4, 0x01,  68)
GET_LINEINFO = _ioc(_IOC_READ | _IOC_WRITE, 0xB4, 0x05, 256)
GET_LINE     = _ioc(_IOC_READ | _IOC_WRITE, 0xB4, 0x07, 592)
GET_VALUES   = _ioc(_IOC_READ | _IOC_WRITE, 0xB4, 0x0E,  16)
SET_VALUES   = _ioc(_IOC_READ | _IOC_WRITE, 0xB4, 0x0F,  16)

FLAG_INPUT, FLAG_OUTPUT = 4, 8
FLAG_NAMES = [(1, "used"), (2, "active-low"), (4, "input"), (8, "output"),
              (16, "edge-rising"), (32, "edge-falling"), (64, "open-drain"),
              (128, "open-source"), (256, "bias-pull-up"),
              (512, "bias-pull-down"), (1024, "bias-disabled")]


def line_info(fd, offset):
    """Read-only: name, consumer and flags for one line."""
    buf = bytearray(256)
    struct.pack_into("<I", buf, 64, offset)
    fcntl.ioctl(fd, GET_LINEINFO, buf, True)
    name = buf[0:32].split(b"\0")[0].decode() or "(unnamed)"
    cons = buf[32:64].split(b"\0")[0].decode() or "(free)"
    flags = struct.unpack_from("<Q", buf, 72)[0]
    decoded = ",".join(n for b, n in FLAG_NAMES if flags & b) or "none"
    return name, cons, flags, decoded


def request(fd, offsets, flags, consumer=b"gps-probe"):
    """GPIO_V2_GET_LINE_IOCTL -> a line-request fd."""
    req = bytearray(592)
    for i, off in enumerate(offsets):
        struct.pack_into("<I", req, i * 4, off)
    req[256:256 + len(consumer)] = consumer
    struct.pack_into("<Q", req, 288, flags)          # config.flags
    struct.pack_into("<I", req, 560, len(offsets))   # num_lines
    fcntl.ioctl(fd, GET_LINE, req, True)
    return struct.unpack_from("<i", req, 588)[0]


def get_value(lfd, buf):
    struct.pack_into("<QQ", buf, 0, 0, 1)
    fcntl.ioctl(lfd, GET_VALUES, buf, True)
    return buf[0] & 1


def set_value(lfd, bit):
    buf = bytearray(struct.pack("<QQ", bit & 1, 1))
    fcntl.ioctl(lfd, SET_VALUES, buf, True)


def sample(lfd, seconds):
    """Poll the line as fast as Python manages; count lows and transitions."""
    buf = bytearray(16)
    n = lows = trans = 0
    prev = get_value(lfd, buf)
    first_low_at = None
    t0 = time.monotonic()
    end = t0 + seconds
    while time.monotonic() < end:
        for _ in range(2000):                        # amortise the clock call
            struct.pack_into("<QQ", buf, 0, 0, 1)
            fcntl.ioctl(lfd, GET_VALUES, buf, True)
            v = buf[0] & 1
            n += 1
            if not v:
                lows += 1
                if first_low_at is None:
                    first_low_at = time.monotonic() - t0
            if v != prev:
                trans += 1
                prev = v
    return n, lows, trans, first_low_at, time.monotonic() - t0


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sample", type=float, metavar="SECONDS",
                    help="mux pin %d to GPIO input and sample it" % PIN_RXD)
    ap.add_argument("--enable-gps", action="store_true",
                    help="drive pin %d high while sampling, then restore"
                         % PIN_ENABLE)
    args = ap.parse_args()

    fd = os.open(CHIP, os.O_RDWR)
    info = bytearray(68)
    fcntl.ioctl(fd, GET_CHIPINFO, info, True)
    print("chip: %s (%s), %d lines"
          % (info[0:32].split(b"\0")[0].decode(),
             info[32:64].split(b"\0")[0].decode(),
             struct.unpack_from("<I", info, 64)[0]))
    print()
    for off in (PIN_RXD, PIN_RXD + 1, PIN_RXD + 2, PIN_RXD + 3, PIN_ENABLE):
        name, cons, flags, dec = line_info(fd, off)
        print("  line %-2d %-24s consumer=%-12s flags=0x%x [%s]"
              % (off, name, cons, flags, dec))

    if args.sample is None:
        print("\n(report only -- pass --sample SECONDS to look at the line)")
        os.close(fd)
        return 0

    enable_fd = None
    prev_enable = 0
    try:
        if args.enable_gps:
            enable_fd = request(fd, [PIN_ENABLE], FLAG_OUTPUT, b"gps-enable")
            # pin 17 was already an output driving low (CONF0 bit31 clear)
            print("\ndriving pin %d HIGH (GPS0 enable) ..." % PIN_ENABLE)
            set_value(enable_fd, 1)
            time.sleep(1.0)                          # let the module boot

        print("requesting pin %d as GPIO input and sampling for %.1fs ..."
              % (PIN_RXD, args.sample))
        rxd_fd = request(fd, [PIN_RXD], FLAG_INPUT)
        n, lows, trans, first, elapsed = sample(rxd_fd, args.sample)
        os.close(rxd_fd)

        rate = n / elapsed if elapsed else 0
        print("\n  samples      : %d in %.2fs  (%.0f/s, ~%.1f us apart)"
              % (n, elapsed, rate, 1e6 / rate if rate else 0))
        print("  read low     : %d (%.3f%%)" % (lows, 100.0 * lows / n if n else 0))
        print("  transitions  : %d" % trans)
        if first is not None:
            print("  first low at : %.3fs" % first)
        print()
        if trans == 0 and lows == 0:
            print("  VERDICT: line sat high the whole time -- nothing is driving")
            print("           UART0 RXD.  No evidence of a GPS module.")
        elif trans == 0 and lows == n:
            print("  VERDICT: line sat LOW the whole time -- pad is grounded or")
            print("           unpowered, not a UART carrying data.")
        else:
            print("  VERDICT: the line is TOGGLING -- something is transmitting")
            print("           on UART0 RXD.  A GPS module is present and talking.")
    finally:
        if enable_fd is not None:
            try:
                print("\nrestoring pin %d to %d" % (PIN_ENABLE, prev_enable))
                set_value(enable_fd, prev_enable)
            finally:
                os.close(enable_fd)
        os.close(fd)
    return 0


sys.exit(main())
