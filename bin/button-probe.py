#!/usr/bin/env python3
"""Watch every input path at once and report which one carries a button press.

Written to answer one question about bigtab01's capacitive Windows button: the
device vibrates when that button is tapped, and nothing in ACPI, GPIO, PWM, I2C
or the HID Output descriptors explains how.  Whoever *reports* the button is
the best candidate for whoever *drives* the motor, because the two are wired
together in some controller's firmware.

There are three plausible owners and they are distinguishable by who speaks:

  * intel-vbtn (INT33D6)  -> the EC saw it and raised an ACPI notify
  * SYNA7500 touch        -> the digitizer's 0-D capacitive button channel
  * ITE8350 sensor hub    -> the hub's vendor collection

So this listens to all /dev/input/event* devices *and* taps the raw HID streams
of both I2C controllers at the same time, timestamped against one clock.  A
single tap then names its own source.  Silence everywhere is also a result: it
means the button never reaches the OS and the buzz is firmware-local.

Run as root -- /dev/input/event* and /dev/hidraw* are not world readable.
stdlib only; bigtab01 is an immutable host with no pip.

Usage:
    sudo bin/button-probe.py --secs 120 --log /tmp/button-probe.log
"""

import argparse
import glob
import os
import select
import struct
import sys
import time

EV_FMT = "qqHHi"
EV_SIZE = struct.calcsize(EV_FMT)

EV_TYPES = {0: "SYN", 1: "KEY", 2: "REL", 3: "ABS", 4: "MSC", 5: "SW", 17: "LED"}

# Only the codes we actually expect, so an unexpected one stays visible as a number.
KEY_NAMES = {125: "KEY_LEFTMETA", 139: "KEY_MENU", 158: "KEY_BACK", 172: "KEY_HOMEPAGE",
             217: "KEY_SEARCH", 272: "BTN_LEFT", 330: "BTN_TOUCH", 320: "BTN_TOOL_PEN",
             321: "BTN_TOOL_RUBBER", 325: "BTN_TOOL_FINGER", 331: "BTN_STYLUS"}


def evdev_name(path):
    node = os.path.basename(path)
    try:
        with open(f"/sys/class/input/{node}/device/name") as fh:
            return fh.read().strip()
    except OSError:
        return "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secs", type=float, default=120.0)
    ap.add_argument("--log", default="/tmp/button-probe.log")
    args = ap.parse_args()

    watched = {}  # fd -> (kind, label)
    for path in sorted(glob.glob("/dev/input/event*")):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            print(f"skip {path}: {exc}", file=sys.stderr)
            continue
        watched[fd] = ("evdev", f"{os.path.basename(path)} [{evdev_name(path)}]")

    for path in sorted(glob.glob("/dev/hidraw*")):
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        except OSError as exc:
            print(f"skip {path}: {exc}", file=sys.stderr)
            continue
        watched[fd] = ("hidraw", os.path.basename(path))

    log = open(args.log, "w", buffering=1)

    def emit(line):
        log.write(line + "\n")
        print(line, flush=True)

    emit(f"# watching {len(watched)} sources for {args.secs:.0f}s")
    for fd, (kind, label) in sorted(watched.items(), key=lambda kv: kv[1][1]):
        emit(f"#   {kind:6s} {label}")
    emit("# --- tap the button now ---")

    t0 = time.monotonic()
    deadline = t0 + args.secs
    poller = select.poll()
    for fd in watched:
        poller.register(fd, select.POLLIN)

    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        for fd, _ in poller.poll(min(remaining, 1.0) * 1000):
            kind, label = watched[fd]
            try:
                data = os.read(fd, 4096)
            except OSError:
                continue
            dt = time.monotonic() - t0
            if kind == "hidraw":
                emit(f"{dt:8.3f} hidraw {label:9s} {data.hex(' ')}")
                continue
            for off in range(0, len(data) - EV_SIZE + 1, EV_SIZE):
                _s, _us, typ, code, val = struct.unpack_from(EV_FMT, data, off)
                if typ == 0:  # EV_SYN -- pure framing, drop it
                    continue
                tname = EV_TYPES.get(typ, str(typ))
                cname = KEY_NAMES.get(code, str(code)) if typ == 1 else str(code)
                emit(f"{dt:8.3f} evdev  {label:46s} {tname} {cname} {val}")

    emit(f"# done after {time.monotonic() - t0:.1f}s")
    log.close()


if __name__ == "__main__":
    main()
