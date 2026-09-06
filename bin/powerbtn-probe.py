#!/usr/bin/env python3
"""Watch the power-button input devices and report press/hold/release timing.

Answers the one question that decides whether a three-stage power button is
possible on this machine: does *any* input device report the button being
*held* (a key-down followed later by a key-up), or only an instantaneous
press+release pair?

The ACPI button driver (PNP0C0C / LNXPWRBN) emits down+up back-to-back, so it
carries no hold duration. intel-vbtn (INT33D6) *may* report a real hold, if the
firmware sends its press/release event pair. Only a physical press tells us.

Run it under a logind inhibitor so the press does not act on the machine:

    sudo systemd-inhibit --what=handle-power-key --who=powerbtn-probe \
         --why="measuring button timing" ./powerbtn-probe.py

Needs root: /dev/input/event* is root:input 0660 and the session user is not in
the `input` group.

Every event is appended to the log file and fsync'd immediately, so the record
survives the firmware's hold-to-cut-power override killing the machine.
"""

import os
import select
import struct
import sys
import time

# struct input_event on 64-bit: struct timeval {long,long}, __u16, __u16, __s32
EV_FMT = "llHHi"
EV_SIZE = struct.calcsize(EV_FMT)
assert EV_SIZE == 24

EV_SYN, EV_KEY = 0x00, 0x01
KEY_POWER = 116

DEFAULT_LOG = "/var/tmp/powerbtn-probe.log"


def candidates():
    """Every input device whose name or phys looks like a power button."""
    found = []
    with open("/proc/bus/input/devices") as fh:
        blocks = fh.read().split("\n\n")
    for blk in blocks:
        name = phys = handlers = ""
        for line in blk.splitlines():
            if line.startswith("N: Name="):
                name = line.split("=", 1)[1].strip('"')
            elif line.startswith("P: Phys="):
                phys = line.split("=", 1)[1]
            elif line.startswith("H: Handlers="):
                handlers = line.split("=", 1)[1]
        if not handlers:
            continue
        hay = (name + " " + phys).lower()
        if "power" not in hay and "virtual button" not in hay:
            continue
        for tok in handlers.split():
            if tok.startswith("event"):
                found.append(("/dev/input/" + tok, name))
    return found


def main():
    log_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LOG
    devs = candidates()
    if not devs:
        sys.exit("no power-button input devices found")

    fds = {}
    for path, name in devs:
        try:
            fds[os.open(path, os.O_RDONLY)] = (path, name)
        except OSError as exc:
            print(f"  !! {path} ({name}): {exc}", file=sys.stderr)
    if not fds:
        sys.exit("could not open any device (are you root?)")

    log = open(log_path, "a", buffering=1)

    def emit(msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        log.write(line + "\n")
        log.flush()
        os.fsync(log.fileno())

    emit("--- probe start ---")
    for fd, (path, name) in fds.items():
        emit(f"watching {path}  [{name}]")
    emit("press the power button; Ctrl-C to stop")

    down_at = {}
    try:
        while True:
            ready, _, _ = select.select(list(fds), [], [], 1.0)
            for fd in ready:
                path, name = fds[fd]
                data = os.read(fd, EV_SIZE * 64)
                for off in range(0, len(data) - EV_SIZE + 1, EV_SIZE):
                    sec, usec, etype, code, value = struct.unpack_from(
                        EV_FMT, data, off)
                    if etype == EV_SYN:
                        continue
                    stamp = sec + usec / 1e6
                    if etype == EV_KEY:
                        what = {0: "RELEASE", 1: "PRESS", 2: "REPEAT"}.get(
                            value, str(value))
                        tag = " KEY_POWER" if code == KEY_POWER else f" code={code}"
                        extra = ""
                        if value == 1:
                            down_at[(fd, code)] = stamp
                        elif value == 0:
                            t0 = down_at.pop((fd, code), None)
                            if t0 is not None:
                                held = stamp - t0
                                extra = f"  held {held * 1000:.0f} ms"
                                if held < 0.05:
                                    extra += "  <- instantaneous, no hold reported"
                                else:
                                    extra += "  <- REAL HOLD"
                        emit(f"{name}: {what}{tag}{extra}")
                    else:
                        emit(f"{name}: type={etype} code={code} value={value}")
    except KeyboardInterrupt:
        emit("--- probe stop ---")


if __name__ == "__main__":
    main()
