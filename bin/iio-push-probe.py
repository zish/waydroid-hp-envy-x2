#!/usr/bin/env python3
"""Measure IIO buffered (push) mode on the ITE8350 sensor hub.

The sensors HAL polls: it reads `in_*_raw` on a timer, and every read is an
i2c round trip to the hub (docs/67).  The alternative is to let the hub push --
enable a channel's `scan_elements`, enable `buffer/enable`, and read scans from
/dev/iio:deviceN as they arrive.  This probe answers whether that would work,
per node, without changing the HAL:

  * What rate does the hub actually push at, and does it match the rate
    `in_*_sampling_frequency` advertises?
  * Does the change-sensitivity threshold (`in_*_hysteresis`) suppress reports
    on a stationary machine?  On this hub it does, and that is the gate.
  * Is there a hardware timestamp channel, and does it advance?
  * What does a sample cost in CPU compared with a polled read?

Parsing the scan buffer correctly is the whole trick, and getting it wrong is
what made an earlier version of this probe report -571350 m/s^2.  The channel
type tells you three different widths and they are not interchangeable:

    accel_3d      in_accel_x_type = le:s16/32>>0      16 real bits in 32
    magn_3d       in_magn_x_type  = le:s32/32>>0      32 in 32
    dev_rotation  in_rot_quaternion_type = le:s32/32X4>>0   four 32s in a row

So: take `storage_bits` from the buffer, shift right by the shift, mask to
`real_bits`, and only then sign-extend.  Reading all 32 bits of an s16/32
channel gives you the 16 bits of whatever the driver left above it.  `X4` is a
repeat count -- one channel, four values -- and an earlier int("32X4") is why
this probe used to crash on dev_rotation.

WRITING `in_*_hysteresis` CAN OOPS THE KERNEL.  On bigtab01, every write to
dev_rotation's `in_rot_hysteresis` -- including writing back the value it
already had -- kills the writing task with a divide error:

    Oops: divide error: 0000 [#1] SMP PTI
    RIP: convert_to_vtf_format+0x78/0xa0 [hid_sensor_iio_common]
      hid_sensor_write_raw_hyst_value+0x4b/0xe0
      iio_write_channel_info+0x148/0x200 [industrialio]
      kernfs_fop_write_iter / vfs_write / ksys_write

convert_to_vtf_format divides by int_pow(10, 6 + exp), where exp is the
channel's HID unit exponent, and int_pow takes its exponent as `unsigned int`.
A unit exponent of -7 or -8 -- two of the sixteen values the HID spec allows --
makes 6 + exp negative, which wraps to ~4.3 billion and drives the u64
accumulator to exactly 0.  No malformed descriptor is involved.  See
docs/68-hid-sensor-hysteresis-oops.md, which includes a userspace reproduction.

Five oopses were taken working this out; the machine survived every one, but
the process died mid-restore each time, which is its own hazard.  So:

  * zeroing hysteresis is opt-in, behind --zero-hysteresis, not the default;
  * the restore only writes attributes this probe actually changed;
  * dev_rotation's in_rot_hysteresis is on a refusal list and is never
    written, whatever the flags say.

PROBE ONE NODE PER RUN.  dev_rotation measured 30.99 Hz on its own and 0.00 Hz
when probed immediately after accel_3d in the same run -- one scan arrived
during calibration and then nothing for six seconds.  Tearing down one node's
buffer appears to stop the hub reporting on another for a while; the mechanism
was not established.  A settle delay between nodes makes it less likely but is
not a fix, so a multi-node run prints a warning and you should trust the first
node only.

Everything else written is restored in a finally block.  If that ever fails
the probe says so and points at bin/sensor-hub-reset.sh.

stdlib only -- bigtab01 is an immutable host with no pip.

Usage:
    sudo iio-push-probe.py --list                  # layouts only, no writes
    sudo iio-push-probe.py                         # probe every node
    sudo iio-push-probe.py --node accel_3d --secs 10
    sudo iio-push-probe.py --node accel_3d --set-hz 20
    sudo iio-push-probe.py --node magn_3d --only in_magn    # one channel only
    sudo iio-push-probe.py --node dev_rotation --dump 256   # work out a layout
    sudo iio-push-probe.py --node incli_3d --zero-hysteresis   # see note above
"""

import os
import re
import resource
import signal
import select
import struct
import sys
import time

IIO = "/sys/bus/iio/devices"

# name -> (channel prefix, raw->SI factor, unit, plausible |v| range)
# Factors come from docs/14-sensors.md (the HID report descriptor), not from
# in_*_scale: the magnetometer's advertised scale is wrong by 1e4.  The range
# is a parse check -- a misparsed s16/32 lands orders of magnitude outside it.
NODES = {
    "accel_3d":     ("in_accel",   9.80665e-3,   "m/s^2", (6.0, 14.0)),
    "gyro_3d":      ("in_anglvel", 1.7453293e-7, "rad/s", (0.0, 10.0)),
    "magn_3d":      ("in_magn",    1e-4,         "uT",    (10.0, 200.0)),
    "incli_3d":     ("in_incli",   0.1,          "deg",   (0.0, 625.0)),
    "dev_rotation": ("in_rot",     1e-7,         "quat",  (0.9, 1.1)),
}

# (node name, attribute) pairs this probe will not write under any flag.
# See the kernel oops described above -- writing these is not a risk, it is a
# reproducible task kill.
HYST_REFUSE = {("dev_rotation", "in_rot_hysteresis")}

# How long to leave the hub alone between nodes.  Not a cure -- see above.
SETTLE_S = 2.0

TYPE_RE = re.compile(r"^(be|le):(s|u)(\d+)/(\d+)(?:X(\d+))?>>(\d+)$")
STRUCT = {1: "B", 2: "H", 4: "I", 8: "Q"}


class Interrupted(Exception):
    """A signal arrived.  Raised from the handler so that the restore in
    probe()'s finally block runs -- bigtab01 is reached over a hotspot, and an
    ssh drop that SIGHUPs this probe mid-phase would otherwise leave the hub
    with a buffer enabled and its change-sensitivity zeroed."""


def _on_signal(signum, _frame):
    raise Interrupted(f"signal {signum}")


def install_handlers():
    for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, _on_signal)


def rd(path):
    with open(path) as f:
        return f.read().strip()


def wr(path, val):
    with open(path, "w") as f:
        f.write(str(val))


def cpu():
    u = resource.getrusage(resource.RUSAGE_SELF)
    return u.ru_utime + u.ru_stime


class Chan:
    """One entry in the scan layout, decoded from scan_elements/<name>_type."""

    def __init__(self, name, index, typestr):
        m = TYPE_RE.match(typestr)
        if not m:
            raise ValueError(f"{name}: cannot parse type {typestr!r}")
        endian, sign, real, storage, repeat, shift = m.groups()
        self.name = name
        self.index = int(index)
        self.little = endian == "le"
        self.signed = sign == "s"
        self.real = int(real)
        self.storage = int(storage)
        self.repeat = int(repeat) if repeat else 1
        self.shift = int(shift)
        self.esize = self.storage // 8
        if self.esize not in STRUCT:
            raise ValueError(f"{name}: odd storage width {self.storage}")
        self.size = self.esize * self.repeat
        self.fmt = ("<" if self.little else ">") + STRUCT[self.esize]
        self.offset = 0          # filled in by layout()

    def decode(self, data):
        """Pull this channel's value(s) out of one scan."""
        out = []
        for i in range(self.repeat):
            v, = struct.unpack_from(self.fmt, data,
                                    self.offset + i * self.esize)
            v >>= self.shift
            v &= (1 << self.real) - 1
            if self.signed and (v >> (self.real - 1)):
                v -= 1 << self.real
            out.append(v)
        return out

    def __str__(self):
        return (f"{self.name}@{self.offset}+{self.size} "
                f"({'s' if self.signed else 'u'}{self.real}/{self.storage}"
                f"{'X%d' % self.repeat if self.repeat > 1 else ''}"
                f">>{self.shift})")


def hyst_str(attrs):
    """Every change-sensitivity attribute on a node, as name=value."""
    if not attrs:
        return "-"
    return ",".join(f"{os.path.basename(a).replace('_hysteresis', '')}"
                    f"={float(rd(a)):g}" for a in attrs)


def hexdump(devn, scan, nbytes):
    """Raw bytes off the chardev, grouped by the scan size we believe in.

    For working out a layout rather than trusting one.  A CLOCK_BOOTTIME
    timestamp is unmistakable in hex -- 8 bytes whose top two are zero -- and
    a quaternion component at 1e-7 is always within +/-0x00989680, so a wrong
    scan size shows up as the recognisable fields walking across the rows.
    """
    fd = os.open("/dev/" + devn, os.O_RDONLY)
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    buf = b""
    sizes = []
    try:
        while len(buf) < nbytes and poller.poll(3000):
            chunk = os.read(fd, nbytes)
            if not chunk:
                break
            sizes.append(len(chunk))
            buf += chunk
    finally:
        os.close(fd)
    print(f"      hexdump: {len(buf)} bytes, read() returned {sizes}")
    print(f"      (assuming scan={scan})")
    for i in range(0, len(buf) - scan + 1, scan):
        row = buf[i:i + scan]
        print("        " + " ".join(f"{row[j:j+4].hex()}"
                                    for j in range(0, len(row), 4)))
    # What size would make every read() a whole number of scans?
    from math import gcd
    g = 0
    for n in sizes:
        g = gcd(g, n)
    if g:
        print(f"      gcd of read() sizes = {g} bytes"
              + (f"  <- scan is probably {g}, not {scan}" if g != scan
                 else "  <- consistent with scan"))


def find_nodes():
    found = {}
    for d in sorted(os.listdir(IIO)):
        if not d.startswith("iio:device"):
            continue
        try:
            found[rd(f"{IIO}/{d}/name")] = f"{IIO}/{d}"
        except OSError:
            pass
    return found


def channels(node, only=None):
    """Every channel the node has, whether or not it is enabled.

    `only` keeps just the channels whose name contains one of the given
    substrings -- which is how you ask whether one particular channel is what
    is holding a report back.
    """
    se = f"{node}/scan_elements"
    out = []
    for f in sorted(os.listdir(se)):
        if not f.endswith("_type"):
            continue
        base = f[:-5]
        if only and not any(o in base for o in only):
            continue
        out.append(Chan(base, rd(f"{se}/{base}_index"), rd(f"{se}/{f}")))
    return out


def divisors(n):
    out = set()
    i = 1
    while i * i <= n:
        if n % i == 0:
            out.add(i)
            out.add(n // i)
        i += 1
    return sorted(out)


def measure_scan(devn, computed, extent, budget=1.2):
    """Ask the device how big a scan is, instead of believing the arithmetic.

    This kernel (7.2.8) exposes no buffer/bytes_per_datum, and the computed
    size is not always right: dev_rotation declares in_timestamp as a channel
    *and* has the core append its own scan timestamp, so its scans are 32
    bytes carrying the timestamp twice, where the IIO alignment rules predict
    24.  Slicing 32-byte scans as 24 is what made this probe report
    dev_rotation at 41.99 Hz -- exactly 4/3 of its real 31.2 Hz -- with a
    quaternion whose norm came out at 170 instead of 1.

    Every read() returns a whole number of scans, so the scan size divides the
    gcd of the sizes seen.  Combined with the extent the channels themselves
    need, that pins it down: take the smallest divisor of the gcd that still
    holds every channel.
    """
    from math import gcd
    fd = os.open("/dev/" + devn, os.O_RDONLY)
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    g, seen = 0, []
    t0 = time.monotonic()
    try:
        while time.monotonic() - t0 < budget and len(seen) < 8:
            if not poller.poll((budget - (time.monotonic() - t0)) * 1000):
                break
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            seen.append(len(chunk))
            g = gcd(g, len(chunk))
    finally:
        os.close(fd)
    if not g:
        return None, seen
    cands = [d for d in divisors(g) if d >= extent]
    return (cands[0] if cands else g), seen


def layout(chans):
    """IIO scan layout: channels in index order, each element aligned to its
    own storage size, the whole scan padded to the largest alignment."""
    chans = sorted(chans, key=lambda c: c.index)
    off, maxa = 0, 1
    for c in chans:
        off += (-off) % c.esize          # align to the element, not the repeat
        c.offset = off
        off += c.size
        maxa = max(maxa, c.esize)
    return chans, off + ((-off) % maxa), off


def raw_read(node, prefix, factor):
    """Read the node's `_raw` attributes -- the path the HAL actually uses."""
    vals = []
    for axis in ("x", "y", "z"):
        p = f"{node}/{prefix}_{axis}_raw"
        if os.path.exists(p):
            vals.append(float(rd(p)) * factor)
    if not vals:
        for cand in ("quaternion_raw", "from_north_magnetic_tilt_comp_raw"):
            p = f"{node}/{prefix}_{cand}"
            if os.path.exists(p):
                vals = [float(v) * factor for v in rd(p).split()]
                break
    return vals


def magnitude(vals):
    return sum(v * v for v in vals) ** 0.5


def run_phase(node, devn, label, chans, scan, prefix, factor, unit, secs):
    fd = os.open("/dev/" + devn, os.O_RDONLY | os.O_NONBLOCK)
    poller = select.poll()
    poller.register(fd, select.POLLIN)
    buf = b""
    n = woke = short = 0
    first = last = None
    ts_first = ts_last = None
    c0, t0 = cpu(), time.monotonic()
    try:
        while True:
            remain = secs - (time.monotonic() - t0)
            if remain <= 0:
                break
            if not poller.poll(remain * 1000):
                continue
            woke += 1
            try:
                data = os.read(fd, scan * 32)
            except BlockingIOError:
                continue
            if not data:
                continue
            # Carry the remainder.  A read that returns a partial scan used to
            # leave this loop permanently misaligned.
            buf += data
            if len(buf) % scan:
                short += 1
            while len(buf) >= scan:
                sc, buf = buf[:scan], buf[scan:]
                vals = {}
                for c in chans:
                    vals[c.name] = c.decode(sc)
                n += 1
                last = vals
                if first is None:
                    first = vals
                ts = vals.get("in_timestamp")
                if ts:
                    ts_last = ts[0]
                    if ts_first is None:
                        ts_first = ts[0]
    finally:
        os.close(fd)

    wall = time.monotonic() - t0
    used = cpu() - c0
    hz = n / wall if wall else 0.0
    print(f"    {label}")
    print(f"      {n} scans in {wall:.2f}s = {hz:.2f} Hz, "
          f"{woke} wakeups, {short} partial reads")
    if not n:
        print("      NO DATA -- the hub pushed nothing")
        return hz, None
    print(f"      CPU {used * 1000:.1f} ms total"
          + (f" = {used / n * 1000:.3f} ms per scan" if n else ""))

    def scaled(v):
        out = []
        for c in chans:
            if c.name == "in_timestamp":
                continue
            out += [x * factor for x in v[c.name]]
        return out

    sv = scaled(last)
    print("      last scan  " +
          " ".join(f"{x:.3f}" for x in sv) + f" {unit}   |v|={magnitude(sv):.3f}")
    if ts_first is not None and ts_last is not None and n > 1:
        span = (ts_last - ts_first) / 1e9
        if span > 0:
            print(f"      hw timestamp advances, {(n - 1) / span:.2f} Hz over "
                  f"{span:.3f}s")
        else:
            print("      hw timestamp present but NOT advancing")
    return hz, sv


def probe(name, node, secs, zero_hyst, set_hz, list_only, only,
          dump):
    devn = os.path.basename(node)
    prefix, factor, unit, (lo, hi) = NODES[name]
    allchans = channels(node, only)
    others = [c.name for c in channels(node)
              if c.name not in {a.name for a in allchans}]
    freq_attr = next((f"{node}/{a}" for a in sorted(os.listdir(node))
                      if a.endswith("_sampling_frequency")), None)
    # A node can carry more than one change-sensitivity attribute -- magn_3d
    # has in_magn_hysteresis (uT) and in_rot_hysteresis (deg, for its
    # tilt-compensated heading channel) -- and the hub appears to gate the
    # whole report on them collectively.  Zeroing only the prefixed one is not
    # enough, so take them all.
    hyst_attrs = [f"{node}/{a}" for a in sorted(os.listdir(node))
                  if a.endswith("_hysteresis")]
    writable_hyst = [a for a in hyst_attrs
                     if (name, os.path.basename(a)) not in HYST_REFUSE]
    refused = [os.path.basename(a) for a in hyst_attrs
               if a not in writable_hyst]

    print(f"\n=== {name} ({devn})")
    print("  channels: " + "; ".join(str(c) for c in layout(allchans)[0]))
    if others:
        print(f"  left disabled: {', '.join(others)}")
    print(f"  freq={rd(freq_attr) if freq_attr else '-'} "
          f"hysteresis={hyst_str(hyst_attrs)} "
          f"trigger={rd(node + '/trigger/current_trigger')} "
          f"buffer/enable={rd(node + '/buffer/enable')}")
    if list_only:
        return None

    if rd(f"{node}/buffer/enable") != "0":
        print("  SKIP: the buffer is already enabled -- something else owns "
              "this node")
        return None

    if refused:
        print(f"  will not write: {', '.join(refused)} (kernel oops -- see the "
              f"module docstring)")

    saved = {
        "en": {c.name: rd(f"{node}/scan_elements/{c.name}_en")
               for c in channels(node)},
        "len": rd(f"{node}/buffer/length"),
        "freq": rd(freq_attr) if freq_attr else None,
    }
    # Only what this probe actually changes goes in here, and only what is in
    # here gets written back.  Restoring a value that was never touched is
    # what kept taking the oops.
    changed = {}
    result = {"name": name}
    try:
        wr(f"{node}/buffer/enable", 0)
        for c in channels(node):
            wr(f"{node}/scan_elements/{c.name}_en",
               1 if any(c.name == a.name for a in allchans) else 0)
        wr(f"{node}/buffer/length", 32)
        if set_hz and freq_attr:
            wr(freq_attr, set_hz)
            print(f"  wrote {set_hz} Hz, reads back {rd(freq_attr)}")
        enabled, scan, extent = layout(allchans)
        wr(f"{node}/buffer/enable", 1)
        measured, reads = measure_scan(devn, scan, extent)
        if measured and measured != scan:
            print(f"  scan={measured} bytes as the device delivers it, NOT the "
                  f"{scan} the layout computes (read sizes {reads})")
            scan = measured
        elif measured:
            print(f"  scan={scan} bytes, confirmed by the device "
                  f"(read sizes {reads})")
        else:
            print(f"  scan={scan} bytes computed; the device pushed nothing to "
                  f"confirm it with")

        if dump:
            hexdump(devn, scan, dump)

        hz, vals = run_phase(node, devn,
                             f"PHASE A, hysteresis as shipped "
                             f"({hyst_str(hyst_attrs)})",
                             enabled, scan, prefix, factor, unit, secs)
        result["hz_shipped"], result["vals"] = hz, vals

        to_zero = [a for a in writable_hyst if float(rd(a)) != 0.0] \
            if zero_hyst else []
        if to_zero:
            wr(f"{node}/buffer/enable", 0)
            for a in to_zero:
                changed[a] = rd(a)
                wr(a, 0)
            wr(f"{node}/buffer/enable", 1)
            m2, reads2 = measure_scan(devn, scan, extent)
            if m2 and m2 != scan:
                print(f"  scan={m2} bytes now the hub is pushing "
                      f"(read sizes {reads2})")
                scan = m2
            hz0, vals0 = run_phase(node, devn,
                                   "PHASE B, hysteresis forced 0 ("
                                   + ", ".join(os.path.basename(a)
                                               for a in to_zero) + ")",
                                   enabled, scan, prefix, factor, unit, secs)
            result["hz_zero"] = hz0
            if vals0:
                result["vals"] = vals0
    finally:
        ok = True
        try:
            wr(f"{node}/buffer/enable", 0)
            for n_, v in saved["en"].items():
                wr(f"{node}/scan_elements/{n_}_en", v)
            wr(f"{node}/buffer/length", saved["len"])
            for a, v in changed.items():
                wr(a, v)
            if saved["freq"] is not None and set_hz:
                wr(freq_attr, saved["freq"])
        except OSError as e:
            ok = False
            print(f"  !! REVERT FAILED: {e}")
            print("  !! run bin/sensor-hub-reset.sh")
        if ok:
            print(f"  reverted: buffer/enable={rd(node + '/buffer/enable')} "
                  f"length={rd(node + '/buffer/length')} "
                  f"hysteresis={hyst_str(hyst_attrs)} "
                  f"freq={rd(freq_attr) if freq_attr else '-'}")

    # Parse check.  The polled path is the reference: compare the buffered
    # values against a fresh _raw read of the same node, and against the
    # magnitude the sensor physically has to report.
    pv = raw_read(node, prefix, factor)
    if pv:
        print("      _raw now   " + " ".join(f"{x:.3f}" for x in pv) +
              f" {unit}   |v|={magnitude(pv):.3f}")
    if result.get("vals"):
        m = magnitude(result["vals"])
        if lo <= m <= hi:
            print(f"      PARSE OK: |v|={m:.3f} {unit} is within "
                  f"[{lo}, {hi}]")
            result["parse"] = True
        else:
            print(f"      PARSE BAD: |v|={m:.3f} {unit} is outside "
                  f"[{lo}, {hi}] -- the scan layout is wrong")
            result["parse"] = False
    return result


def main():
    argv = sys.argv[1:]
    if "--help" in argv or "-h" in argv:
        print(__doc__)
        return 0

    def opt(name, default):
        return type(default)(argv[argv.index(name) + 1]) \
            if name in argv else default

    secs = opt("--secs", 6.0)
    set_hz = opt("--set-hz", 0.0)
    list_only = "--list" in argv
    # Opt-in, not opt-out: writing a hysteresis attribute is what oopses the
    # kernel, so the default run touches no sensitivity value at all.
    zero_hyst = "--zero-hysteresis" in argv
    want = [argv[i + 1] for i, a in enumerate(argv) if a == "--node"]
    only = [argv[i + 1] for i, a in enumerate(argv) if a == "--only"]
    dump = int(opt("--dump", 0))

    found = find_nodes()
    targets = want or [n for n in NODES if n in found]
    missing = [n for n in targets if n not in found]
    if missing:
        print(f"not present: {', '.join(missing)}", file=sys.stderr)
        return 2

    install_handlers()
    print("IIO push-mode probe" + ("  (--list: no writes)" if list_only else
                                   f"  {secs:g}s per phase"))
    if len(targets) > 1 and not list_only:
        print(f"  WARNING: {len(targets)} nodes in one run.  Only the first "
              f"result is trustworthy -- see the module docstring.  Settling "
              f"{SETTLE_S:g}s between nodes.")
    results = []
    try:
        for i, n in enumerate(targets):
            if i and not list_only:
                time.sleep(SETTLE_S)
            r = probe(n, found[n], secs, zero_hyst, set_hz,
                      list_only, only, dump)
            if r:
                results.append(r)
    except Interrupted as e:
        print(f"\ninterrupted ({e}) -- the node above was restored")
    if not results:
        return 0

    print("\n=== verdict")
    print(f"  {'node':<14} {'as-shipped':>11} {'hyst=0':>9}  parse")
    bad = 0
    for r in results:
        z = r.get("hz_zero")
        p = r.get("parse")
        print(f"  {r['name']:<14} {r['hz_shipped']:>8.2f} Hz "
              f"{(f'{z:.2f} Hz' if z is not None else '-'):>9}  "
              f"{'ok' if p else 'BAD' if p is False else '-'}")
        if p is False:
            bad += 1
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
