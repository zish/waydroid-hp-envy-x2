#!/usr/bin/env python3
"""Measure the magnetometer's hard-iron offset by rotating the machine.

WHY

|B| is a property of where you are standing, not of how the machine is held,
so a clean magnetometer reads the same magnitude in every orientation. The
keyboard's attachment magnets add a roughly constant vector in the DEVICE
frame -- a hard-iron offset -- and |measured| then swings above and below the
true field as the machine turns. On bigtab01 it has ranged from about 52 uT to
134 uT against a local field near 54, which is a bias comparable to the field
itself.

Geometrically the samples should trace a sphere centred on the origin. A
hard-iron offset moves that sphere's centre; soft-iron (ferrous material
distorting the field) stretches it into an ellipsoid. So: sample while
rotating, fit the surface, and the centre IS the offset.

WHAT THIS ANSWERS

  1. How big is the bias, and along which device axis? The prediction is that
     it is dominated by Z -- perpendicular to the screen, pointing at the
     keyboard -- because that is the only way it can corrupt the heading when
     the machine stands up while leaving it correct when flat.
  2. Does a single fixed offset actually hold? Run it with the keyboard
     attached, then detached, then attached again at a different screen angle.
     If the magnets move relative to the tablet as the hinge opens, the offset
     will differ between the two attached runs and no fixed correction can
     work.

This tool only MEASURES. Nothing is written to the device.

USAGE  (runs on bigtab01; needs no root)

    ssh 10.42.0.137 "python3 - --secs 60 --out /tmp/attached.csv" \
        < bin/magn-calibrate.py

  Rotate the machine slowly through as many orientations as you can while it
  samples -- tumble it about all three axes, not just spin it flat. The
  coverage readout tells you when you have enough.

  Re-fit a saved capture without sampling again:

    python3 bin/magn-calibrate.py --load attached.csv
"""

import argparse
import glob
import math
import os
import sys
import time

IIO = "/sys/bus/iio/devices"


def find_magnetometer():
    """Resolve by name. Never hardcode iio:deviceN -- indices are assigned in
    probe order and move across boots."""
    for d in sorted(glob.glob(os.path.join(IIO, "iio:device*"))):
        try:
            with open(os.path.join(d, "name")) as f:
                if f.read().strip() == "magn_3d":
                    return d
        except OSError:
            continue
    return None


def read_raw(dev):
    out = []
    for axis in ("x", "y", "z"):
        with open(os.path.join(dev, "in_magn_%s_raw" % axis)) as f:
            out.append(float(f.read()))
    return out


def solve(a, b):
    """Gaussian elimination with partial pivoting. Returns None if singular."""
    n = len(a)
    m = [row[:] + [b[i]] for i, row in enumerate(a)]
    for col in range(n):
        piv = max(range(col, n), key=lambda r: abs(m[r][col]))
        if abs(m[piv][col]) < 1e-12:
            return None
        m[col], m[piv] = m[piv], m[col]
        for r in range(n):
            if r == col:
                continue
            f = m[r][col] / m[col][col]
            for c in range(col, n + 1):
                m[r][c] -= f * m[col][c]
    return [m[i][n] / m[i][i] for i in range(n)]


def normal_equations(rows, targets):
    n = len(rows[0])
    ata = [[0.0] * n for _ in range(n)]
    atb = [0.0] * n
    for row, t in zip(rows, targets):
        for i in range(n):
            atb[i] += row[i] * t
            for j in range(n):
                ata[i][j] += row[i] * row[j]
    return solve(ata, atb)


def fit_sphere(samples):
    """x^2+y^2+z^2 = 2ax + 2by + 2cz + d  ->  centre (a,b,c), radius from d."""
    rows, targets = [], []
    for x, y, z in samples:
        rows.append([2 * x, 2 * y, 2 * z, 1.0])
        targets.append(x * x + y * y + z * z)
    p = normal_equations(rows, targets)
    if p is None:
        return None
    a, b, c, d = p
    rsq = d + a * a + b * b + c * c
    if rsq <= 0:
        return None
    return (a, b, c), math.sqrt(rsq)


def fit_ellipsoid(samples):
    """Axis-aligned: x^2 + B y^2 + C z^2 + D x + E y + F z + G = 0.

    Adds diagonal soft-iron on top of the hard-iron offset. Not a full
    ellipsoid fit -- a rotated one needs the cross terms and an eigenvector
    solve, which is more machinery than a first look justifies."""
    rows, targets = [], []
    for x, y, z in samples:
        rows.append([y * y, z * z, x, y, z, 1.0])
        targets.append(-x * x)
    p = normal_equations(rows, targets)
    if p is None:
        return None
    B, C, D, E, F, G = p
    if B <= 1e-6 or C <= 1e-6:
        return None
    cx, cy, cz = -D / 2.0, -E / (2 * B), -F / (2 * C)
    k = cx * cx + B * cy * cy + C * cz * cz - G
    if k <= 0:
        return None
    return (cx, cy, cz), (math.sqrt(k), math.sqrt(k / B), math.sqrt(k / C))


def spread(mags):
    n = len(mags)
    mean = sum(mags) / n
    sd = math.sqrt(sum((m - mean) ** 2 for m in mags) / n)
    return mean, sd, min(mags), max(mags)


def coverage(samples, centre):
    """Which of the 8 sign-octants around the centre were visited. A fit from
    samples clustered in a few octants is unconstrained and will look
    confident while being wrong."""
    seen = {}
    for x, y, z in samples:
        key = ((x > centre[0]) << 2) | ((y > centre[1]) << 1) | (z > centre[2])
        seen[key] = seen.get(key, 0) + 1
    return seen


def report(samples, scale, label):
    n = len(samples)
    print()
    print("=" * 68)
    if label:
        print("  %s" % label)
    print("  %d samples" % n)
    print("=" * 68)
    if n < 100:
        print("  too few samples to fit (want several hundred)")
        return

    raw_mags = [math.sqrt(x * x + y * y + z * z) * scale for x, y, z in samples]
    mean, sd, lo, hi = spread(raw_mags)
    print()
    print("  uncorrected |B|   mean %7.2f  sd %6.2f (%4.1f%%)  range %6.2f - %6.2f uT"
          % (mean, sd, 100 * sd / mean if mean else 0, lo, hi))

    sph = fit_sphere(samples)
    if sph is None:
        print("  sphere fit failed (singular) -- rotate through more orientations")
        return
    centre, radius = sph

    cov = coverage(samples, centre)
    print("  octants visited   %d of 8" % len(cov))
    if len(cov) < 6:
        print("  WARNING: the samples do not surround the centre. The fit below")
        print("           is under-constrained; tumble it about all three axes.")

    corrected = [
        math.sqrt((x - centre[0]) ** 2 + (y - centre[1]) ** 2 + (z - centre[2]) ** 2) * scale
        for x, y, z in samples
    ]
    cmean, csd, clo, chi = spread(corrected)

    print()
    print("  -- sphere fit (hard iron only) --")
    print("  offset            x %+10.1f   y %+10.1f   z %+10.1f   raw"
          % centre)
    print("                    x %+10.2f   y %+10.2f   z %+10.2f   uT"
          % tuple(c * scale for c in centre))
    print("  |offset|          %7.2f uT" % (math.sqrt(sum(c * c for c in centre)) * scale))
    print("  fitted field      %7.2f uT" % (radius * scale))
    print("  corrected |B|     mean %7.2f  sd %6.2f (%4.1f%%)  range %6.2f - %6.2f uT"
          % (cmean, csd, 100 * csd / cmean if cmean else 0, clo, chi))

    ell = fit_ellipsoid(samples)
    if ell is not None:
        ecentre, radii = ell
        ecorr = [
            math.sqrt((x - ecentre[0]) ** 2 + (y - ecentre[1]) ** 2 + (z - ecentre[2]) ** 2) * scale
            for x, y, z in samples
        ]
        emean, esd, _, _ = spread(ecorr)
        rmean = sum(radii) / 3.0
        print()
        print("  -- ellipsoid fit (adds diagonal soft iron) --")
        print("  offset            x %+10.2f   y %+10.2f   z %+10.2f   uT"
              % tuple(c * scale for c in ecentre))
        print("  radii             x %8.2f   y %8.2f   z %8.2f   uT"
              % tuple(r * scale for r in radii))
        print("  axis scale        x %8.4f   y %8.4f   z %8.4f"
              % tuple(rmean / r for r in radii))
        print("  corrected |B|     mean %7.2f  sd %6.2f (%4.1f%%)"
              % (emean, esd, 100 * esd / emean if emean else 0))

    print()
    print("  -- verdict --")
    boff = math.sqrt(sum(c * c for c in centre)) * scale
    if boff < 3.0:
        print("  Offset is small (<3 uT). This magnetometer is essentially clean;")
        print("  a hard-iron correction would buy nothing.")
    else:
        print("  Hard-iron offset of %.1f uT against a %.1f uT field." % (boff, radius * scale))
        big = max(range(3), key=lambda i: abs(centre[i]))
        print("  Dominated by device %s. A bias on Z corrupts the heading only" % "XYZ"[big])
        print("  when the machine stands up, which is the reported symptom.")
    if csd / cmean < 0.05 if cmean else False:
        print("  Correction leaves |B| flat to %.1f%% -- a fixed offset holds for" % (100 * csd / cmean))
        print("  this capture, so a correction is worth applying.")
    else:
        print("  Correction still leaves |B| varying by %.1f%%. Either the sampling"
              % (100 * csd / cmean if cmean else 0))
        print("  missed orientations, or the bias is not constant (check whether")
        print("  the screen angle changed during the capture).")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--secs", type=float, default=60.0, help="capture duration")
    ap.add_argument("--hz", type=float, default=20.0, help="sample rate")
    ap.add_argument("--scale", type=float, default=1e-4,
                    help="raw -> uT; matches the daemon's magn_scale")
    ap.add_argument("--out", help="write raw samples to this CSV")
    ap.add_argument("--load", help="re-fit a saved CSV instead of sampling")
    ap.add_argument("--label", default="", help="annotation for the report")
    args = ap.parse_args()

    if args.load:
        samples = []
        with open(args.load) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                samples.append(tuple(float(v) for v in line.split(",")[:3]))
        report(samples, args.scale, args.label or args.load)
        return 0

    dev = find_magnetometer()
    if dev is None:
        print("no IIO device named magn_3d", file=sys.stderr)
        return 1
    print("magnetometer: %s" % dev)
    print("Rotate the machine slowly through every orientation you can reach --")
    print("tumble it about all three axes, do not just spin it flat.")
    print()

    samples = []
    interval = 1.0 / args.hz
    end = time.time() + args.secs
    nextprint = time.time() + 2.0
    while time.time() < end:
        try:
            samples.append(tuple(read_raw(dev)))
        except OSError as e:
            print("read failed: %s" % e, file=sys.stderr)
            return 1
        now = time.time()
        if now >= nextprint and len(samples) > 20:
            mean = [sum(s[i] for s in samples) / len(samples) for i in range(3)]
            cov = coverage(samples, mean)
            mag = math.sqrt(sum(v * v for v in samples[-1])) * args.scale
            print("  %4.0fs left   %4d samples   octants %d/8   |B| now %6.2f uT"
                  % (end - now, len(samples), len(cov), mag))
            nextprint = now + 2.0
        time.sleep(interval)

    if args.out:
        with open(args.out, "w") as f:
            f.write("# raw in_magn_{x,y,z}_raw, scale %g -> uT\n" % args.scale)
            for s in samples:
                f.write("%.0f,%.0f,%.0f\n" % s)
        print("\nwrote %s" % args.out)

    report(samples, args.scale, args.label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
