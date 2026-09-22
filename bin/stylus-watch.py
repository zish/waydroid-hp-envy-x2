#!/usr/bin/env python3
"""Watch a pen digitizer's evdev stream and report what the pen actually sends.

Written to answer one question about a specific pen and a specific panel: does
the SYNA7500 digitizer in bigtab01 recognise *this* stylus at all?  That is not
a software question.  Active-pen protocols (Wacom AES, Wacom EMR, Microsoft Pen
Protocol / N-trig, and several vendor-proprietary schemes) are negotiated in the
touch controller's firmware, so either the controller speaks the pen's protocol
or it does not, and no driver, quirk or kernel option changes the answer.  The
kernel side here is already done: `hid-multitouch` has created a Stylus evdev
device with ABS_PRESSURE, and this script just listens to it.

Reading it therefore settles the question in seconds:

  * nothing at all           -> the controller does not recognise the pen
  * BTN_TOOL_PEN + X/Y only  -> recognised, but no pressure is being reported
  * pressure varying 0..255  -> fully working, and Linux already has it

It also reports what it does NOT see, because absence is the useful result:
this panel declares no tilt and no azimuth axes, so a pen that has them will
still not deliver them here.

Run as root -- /dev/input/event* is not world readable.  stdlib only; bigtab01
is an immutable host with no pip.

Usage:
    sudo bin/stylus-watch.py                  # auto-pick the Stylus device
    sudo bin/stylus-watch.py --name Stylus    # substring match on device name
    sudo bin/stylus-watch.py --device /dev/input/event4
    sudo bin/stylus-watch.py --secs 30 --raw  # every event, not a summary line
"""

import argparse
import glob
import os
import select
import struct
import sys
import time

# struct input_event { struct timeval time; __u16 type, code; __s32 value; }
# timeval is two longs on this arch, so 16 + 2 + 2 + 4 = 24 bytes.
EVENT_FMT = "llHHi"
EVENT_SIZE = struct.calcsize(EVENT_FMT)

EV_SYN, EV_KEY, EV_ABS, EV_MSC = 0x00, 0x01, 0x03, 0x04

ABS_NAMES = {
    0x00: "X", 0x01: "Y", 0x18: "PRESSURE", 0x19: "DISTANCE",
    0x1A: "TILT_X", 0x1B: "TILT_Y", 0x28: "MISC",
}

# The pen-relevant BTN_ codes. A digitizer reports tool identity as a key.
KEY_NAMES = {
    0x140: "BTN_TOOL_PEN",
    0x141: "BTN_TOOL_RUBBER",     # the eraser end
    0x142: "BTN_TOOL_BRUSH",
    0x145: "BTN_TOOL_FINGER",
    0x146: "BTN_TOOL_MOUSE",
    0x14A: "BTN_TOUCH",           # tip down
    0x14B: "BTN_STYLUS",          # barrel button
    0x14C: "BTN_STYLUS2",         # second barrel button
}


def find_device(name_match):
    """Resolve an evdev node by device name, never by a hardcoded number.

    Event numbers move when devices come and go -- the same lesson
    waydroid-sensord learned about IIO nodes after a driver reprobe
    (docs/19-sensor-hub-suspend-wedge.md).
    """
    hits = []
    for path in sorted(glob.glob("/sys/class/input/event*")):
        try:
            with open(os.path.join(path, "device", "name")) as fh:
                name = fh.read().strip()
        except OSError:
            continue
        if name_match.lower() in name.lower():
            hits.append(("/dev/input/" + os.path.basename(path), name))
    return hits


def read_abs_range(dev, code):
    """EVIOCGABS(code) -> (min, max, res) or None."""
    import ctypes
    import fcntl

    class absinfo(ctypes.Structure):
        _fields_ = [("value", ctypes.c_int32), ("minimum", ctypes.c_int32),
                    ("maximum", ctypes.c_int32), ("fuzz", ctypes.c_int32),
                    ("flat", ctypes.c_int32), ("resolution", ctypes.c_int32)]

    info = absinfo()
    try:
        with open(dev, "rb") as fh:
            fcntl.ioctl(fh, 0x80184540 + code, info)
    except OSError:
        return None
    if info.minimum == 0 and info.maximum == 0:
        return None
    return info.minimum, info.maximum, info.resolution


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--device", help="evdev node; overrides --name")
    ap.add_argument("--name", default="Stylus", help="substring of the device name")
    ap.add_argument("--secs", type=float, default=60.0, help="how long to listen")
    ap.add_argument("--raw", action="store_true", help="print every event")
    args = ap.parse_args()

    if args.device:
        dev, name = args.device, "(as given)"
    else:
        hits = find_device(args.name)
        if not hits:
            print(f"no input device matching {args.name!r}.", file=sys.stderr)
            print("available:", file=sys.stderr)
            for path in sorted(glob.glob("/sys/class/input/event*")):
                try:
                    with open(os.path.join(path, "device", "name")) as fh:
                        print(f"  /dev/input/{os.path.basename(path)}  {fh.read().strip()}",
                              file=sys.stderr)
                except OSError:
                    pass
            return 2
        if len(hits) > 1:
            print("several matches; pass --device to choose:", file=sys.stderr)
            for d, n in hits:
                print(f"  {d}  {n}", file=sys.stderr)
            return 2
        dev, name = hits[0]

    print(f"device : {dev}  ({name})")
    axes = {}
    for code, label in ABS_NAMES.items():
        rng = read_abs_range(dev, code)
        if rng:
            axes[code] = rng
            print(f"  axis {label:<9} min={rng[0]:<6} max={rng[1]:<6} res={rng[2]}")
    missing = [l for c, l in ABS_NAMES.items() if c not in axes
               and l in ("PRESSURE", "TILT_X", "TILT_Y", "DISTANCE")]
    if missing:
        print(f"  no axis for: {', '.join(missing)}")
    print()
    print("Touch the pen tip to the glass, press the barrel button, then try the")
    print("eraser end. Silence below means the digitizer does not see the pen.")
    print(f"Listening for {args.secs:g}s -- Ctrl-C to stop early.")
    print()

    try:
        fh = open(dev, "rb", buffering=0)
    except PermissionError:
        print(f"cannot open {dev} -- run this under sudo.", file=sys.stderr)
        return 1

    state = {}          # ABS code -> latest value
    keys = {}           # key name -> 0/1
    pressures = []
    total = 0
    deadline = time.monotonic() + args.secs
    last_line = 0.0

    try:
        while time.monotonic() < deadline:
            timeout = max(0.0, min(0.2, deadline - time.monotonic()))
            if not select.select([fh], [], [], timeout)[0]:
                continue
            data = fh.read(EVENT_SIZE)
            if not data or len(data) < EVENT_SIZE:
                continue
            _s, _us, etype, code, value = struct.unpack(EVENT_FMT, data)
            total += 1

            if etype == EV_ABS:
                state[code] = value
                if code == 0x18:
                    pressures.append(value)
            elif etype == EV_KEY:
                label = KEY_NAMES.get(code, f"key {code:#x}")
                keys[label] = value
                # Key transitions are always printed: tool-in-range and the
                # barrel button are the events that identify the pen.
                print(f"  KEY  {label:<16} {'down' if value else 'up'}")
                continue
            elif etype == EV_MSC:
                continue

            if args.raw and etype == EV_ABS:
                print(f"  ABS  {ABS_NAMES.get(code, hex(code)):<9} {value}")
                continue

            # One summary line per SYN_REPORT, rate limited so a 100 Hz pen
            # does not scroll the answer off the screen.
            if etype == EV_SYN and not args.raw:
                now = time.monotonic()
                if now - last_line >= 0.1:
                    last_line = now
                    parts = []
                    x = state.get(0x00)
                    y = state.get(0x01)
                    p = state.get(0x18)
                    if x is not None:
                        parts.append(f"x={x:<6}")
                    if y is not None:
                        parts.append(f"y={y:<6}")
                    if p is not None:
                        parts.append(f"pressure={p:<4}")
                    d = state.get(0x19)
                    if d is not None:
                        parts.append(f"dist={d}")
                    held = [k for k, v in keys.items() if v]
                    if held:
                        parts.append("[" + ",".join(held) + "]")
                    if parts:
                        print("  " + "  ".join(parts))
    except KeyboardInterrupt:
        print()
    finally:
        fh.close()

    print()
    print(f"events received : {total}")
    if total == 0:
        print("VERDICT: nothing. The digitizer did not report this pen at all.")
        print("         The controller does not speak this pen's protocol, and")
        print("         that is firmware, not software. Try a Wacom AES pen.")
    elif not pressures:
        print("VERDICT: the pen is seen, but no pressure was reported.")
    else:
        lo, hi = min(pressures), max(pressures)
        print(f"pressure range  : {lo}..{hi} over {len(pressures)} samples")
        if hi > lo:
            print("VERDICT: the pen works, with variable pressure. Linux has it.")
        else:
            print(f"VERDICT: the pen is seen, but pressure never moved off {lo}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
