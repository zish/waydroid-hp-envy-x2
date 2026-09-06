#!/usr/bin/env python3
"""Sample the ITE8350 sensor hub's IIO nodes and report their behaviour.

Answers the questions a polling sensors HAL needs answered before it is
written:

  * Does every `_raw` read return fresh data, or does the hid-sensor driver's
    power-cycle-per-read make the first sample after an idle period garbage?
    (One was observed at 139 deg/s on a stationary machine.)
  * What is the real quantisation step of each channel?
  * How long does a read actually take?  sysfs reads on a HID hub go out over
    i2c, so they are not free.

stdlib only -- bigtab01 is an immutable host with no pip.

Usage:
    iio-probe.py [--hz 50] [--secs 3] [--idle 5] [--warmup 6]
"""

import os
import statistics
import sys
import time

IIO = "/sys/bus/iio/devices"

# name -> (channel attributes, raw->SI factor, SI unit label)
# Factors are derived in docs/14-sensors.md from the HID report descriptor,
# NOT from in_*_scale: the magnetometer's advertised scale is wrong by 1e4.
CHANNELS = {
    "accel_3d":     (["in_accel_x_raw", "in_accel_y_raw", "in_accel_z_raw"],
                     9.80665e-3, "m/s^2"),
    "gyro_3d":      (["in_anglvel_x_raw", "in_anglvel_y_raw",
                      "in_anglvel_z_raw"], 1.7453293e-7, "rad/s"),
    "magn_3d":      (["in_magn_x_raw", "in_magn_y_raw", "in_magn_z_raw"],
                     1e-4, "uT"),
    "incli_3d":     (["in_incli_x_raw", "in_incli_y_raw", "in_incli_z_raw"],
                     0.1, "deg"),
    "dev_rotation": (["in_rot_quaternion_raw"], 1e-7, "quat"),
}


def find_devices():
    """Map sensor name -> sysfs path.  Index is NOT stable across boots."""
    out = {}
    for entry in sorted(os.listdir(IIO)):
        if not entry.startswith("iio:device"):
            continue
        path = os.path.join(IIO, entry)
        try:
            with open(os.path.join(path, "name")) as f:
                out[f.read().strip()] = path
        except OSError:
            pass
    return out


def read_raw(path, attr):
    """Read one IIO attribute; returns a list of ints (quaternion has 4)."""
    with open(os.path.join(path, attr)) as f:
        return [int(v) for v in f.read().split()]


def main():
    argv = sys.argv[1:]

    def opt(name, default):
        return type(default)(argv[argv.index(name) + 1]) if name in argv else default

    hz = opt("--hz", 50.0)
    secs = opt("--secs", 3.0)
    idle = opt("--idle", 5.0)
    warmup = opt("--warmup", 0.0)

    devs = find_devices()
    if warmup:
        print(f"# warm-up: {warmup:.0f}s of discarded polling per sensor\n")
    print(f"# found {len(devs)} IIO devices: "
          + ", ".join(f"{n}={os.path.basename(p)}" for n, p in devs.items()))
    print("# NOTE: iio:deviceN indices are not stable across boots; "
          "match on name.\n")

    for name, (attrs, factor, unit) in CHANNELS.items():
        path = devs.get(name)
        if path is None:
            print(f"{name}: ABSENT")
            continue

        # 1. Cold read: the sensor has been idle, so this exercises the
        #    power-up path that produced the 139 deg/s outlier.
        print(f"=== {name}  ({os.path.basename(path)})")
        print(f"    idling {idle:.0f}s to let runtime PM suspend the sensor...")
        time.sleep(idle)
        t0 = time.perf_counter()
        cold = [read_raw(path, a) for a in attrs]
        cold_ms = (time.perf_counter() - t0) * 1000

        # 2. Warm-up.  The gyro needs ~5 s after a runtime-PM resume before it
        #    settles (first read can be 1000 deg/s), and the hub fuses it into
        #    incli_3d and dev_rotation, so those need the same wait.
        period = 1.0 / hz
        if warmup:
            end = time.perf_counter() + warmup
            while time.perf_counter() < end:
                for a in attrs:
                    read_raw(path, a)
                time.sleep(period)

        samples, durations = [], []
        deadline = time.perf_counter() + secs
        while time.perf_counter() < deadline:
            t = time.perf_counter()
            try:
                s = [read_raw(path, a) for a in attrs]
            except OSError as e:
                print(f"    read failed: {e}")
                break
            durations.append((time.perf_counter() - t) * 1000)
            samples.append(s)
            time.sleep(max(0, period - (time.perf_counter() - t)))

        if not samples:
            continue

        flat_cold = [v for ch in cold for v in ch]
        print(f"    cold read : {flat_cold}  ({cold_ms:.1f} ms)")
        print(f"    warm reads: n={len(samples)}  "
              f"read time min/med/max = "
              f"{min(durations):.1f}/{statistics.median(durations):.1f}/"
              f"{max(durations):.1f} ms")

        # Per-channel statistics, and the quantisation step: the GCD of the
        # differences between distinct observed values.
        for ci, attr in enumerate(attrs):
            width = len(samples[0][ci])
            for comp in range(width):
                vals = [s[ci][comp] for s in samples]
                uniq = sorted(set(vals))
                step = 0
                for a, b in zip(uniq, uniq[1:]):
                    d = b - a
                    while d:
                        step, d = d, step % d
                    step = abs(step)
                label = attr if width == 1 else f"{attr}[{comp}]"
                spread = max(vals) - min(vals)
                mean = statistics.fmean(vals)
                cold_v = flat_cold[ci * width + comp] if width > 1 else flat_cold[ci]
                outlier = ""
                if spread and abs(cold_v - mean) > 5 * spread:
                    outlier = "   <-- COLD READ IS AN OUTLIER"
                print(f"      {label:<28} mean={mean:>14.1f} "
                      f"({mean * factor:>+11.4f} {unit})  "
                      f"spread={spread:<10} step={step:<8}{outlier}")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
