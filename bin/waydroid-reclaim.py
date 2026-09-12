#!/usr/bin/env python3
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reclaim anonymous memory from cached Waydroid processes, from the host.

WHY THIS EXISTS

Android's own answer is CachedAppOptimizer's compaction half, and on bigtab01 it
does work -- but only after a container restart, and only while
`device_config put activity_manager use_compaction true` is in effect, which does
NOT survive a restart. It is also deliberately conservative: it throttles on time,
on RSS delta and on oom_adj, which is right for a phone on battery and leaves a
lot on the table on a machine with 8 GB and a 7.7 GB zram device.

This does the same thing from the host, on demand, with no dependency on AMS
plumbing, no cgroups, no device_config flag and no image change -- the same
"host-side tool doing what the guest path cannot" shape as waydroid-sensord and
waydroid-wifid.

The mechanism is process_madvise(2) with MADV_PAGEOUT, merged upstream in Linux
5.10 as the supported replacement for Android's out-of-tree /proc/<pid>/reclaim
(which this kernel does not have and never will). See docs/43-app-freezer.md.

WHAT IT COSTS

Nothing is freed outright -- anonymous pages move to swap, which here is zram, so
they end up compressed in RAM. Measured on this machine the ratio is around 4:1,
so reclaiming 155 MB of RSS cost 33 MB of zram: a real saving, but report both
numbers rather than just the RSS drop, which is why --verbose prints the pair.

SAFETY

Only processes at or above --min-adj are touched, defaulting to 900, which is
Android's own CACHED_APP floor and the same threshold CachedAppOptimizer uses
(compact_throttle_min_oom_adj=900). The framework -- system_server, SurfaceFlinger,
SystemUI, anything persistent -- sits far below that and is never a candidate.
MADV_PAGEOUT is non-destructive: pages come back from swap on next touch, at the
cost of a fault. Nothing is killed and no process is stopped.

Stdlib only, for the same reason as bin/v4l2-*.py and bin/mdns-listen.py: Fedora
Atomic makes layering a package cost a reboot.

    sudo bin/waydroid-reclaim.py --dry-run       # what it would touch
    sudo bin/waydroid-reclaim.py                 # reclaim, one line per process
    sudo bin/waydroid-reclaim.py --min-adj 800 -v
"""

import argparse
import ctypes
import errno
import os
import sys
import time

# x86_64 syscall numbers. This host is the only target; check before reusing.
NR_PIDFD_OPEN = 434
NR_PROCESS_MADVISE = 440

MADV_COLD = 20      # deactivate: cheap, reclaimed only under pressure
MADV_PAGEOUT = 21   # reclaim now: pages go to swap immediately

UIO_MAXIOV = 1024   # kernel cap on iovec count per call

CGROUP_PROCS = "/sys/fs/cgroup/lxc.payload.waydroid/cgroup.procs"
ZRAM_MM_STAT = "/sys/block/zram0/mm_stat"


class IOVec(ctypes.Structure):
    _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]


def read_int_file(path, default=None):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (OSError, ValueError):
        return default


def zram_used_mb():
    """mem_used_total from zram's mm_stat, in MB. None if there is no zram."""
    try:
        with open(ZRAM_MM_STAT) as f:
            return int(f.read().split()[2]) // 1048576
    except (OSError, IndexError, ValueError):
        return None


def proc_status(pid):
    """RSS and swap in MB, plus the process name, from /proc/<pid>/status."""
    rss = swap = 0
    name = "?"
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("Name:"):
                    name = line.split(None, 1)[1].strip()
                elif line.startswith("VmRSS:"):
                    rss = int(line.split()[1]) // 1024
                elif line.startswith("VmSwap:"):
                    swap = int(line.split()[1]) // 1024
    except OSError:
        return None
    return rss, swap, name


def cmdline(pid):
    try:
        with open("/proc/%d/cmdline" % pid, "rb") as f:
            return f.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        return ""


def anon_regions(pid):
    """Private writable anonymous mappings -- the only ones PAGEOUT can reclaim.

    File-backed pages are already evictable without help, and read-only or shared
    mappings are not this tool's business.
    """
    out = []
    try:
        with open("/proc/%d/maps" % pid) as f:
            for line in f:
                parts = line.split()
                if len(parts) < 5:
                    continue
                addrs, perms = parts[0], parts[1]
                path = parts[5] if len(parts) > 5 else ""
                if path and not path.startswith("[anon"):
                    continue
                if path in ("[vvar]", "[vdso]", "[vsyscall]"):
                    continue
                if "w" not in perms or "p" not in perms:
                    continue
                lo, hi = (int(x, 16) for x in addrs.split("-"))
                if hi > lo:
                    out.append((lo, hi - lo))
    except OSError:
        return []
    return out


def container_pids():
    try:
        with open(CGROUP_PROCS) as f:
            return [int(x) for x in f.read().split()]
    except OSError:
        sys.exit("cannot read %s -- is the Waydroid container running?" % CGROUP_PROCS)


def reclaim(libc, pid, behavior):
    """process_madvise every anon region of pid. Returns (bytes_advised, error)."""
    regions = anon_regions(pid)
    if not regions:
        return 0, None

    pidfd = libc.syscall(NR_PIDFD_OPEN, pid, 0)
    if pidfd < 0:
        return 0, errno.errorcode.get(ctypes.get_errno(), "pidfd_open failed")

    total = 0
    try:
        for i in range(0, len(regions), UIO_MAXIOV):
            chunk = regions[i:i + UIO_MAXIOV]
            arr = (IOVec * len(chunk))()
            for j, (base, length) in enumerate(chunk):
                arr[j].base, arr[j].len = base, length
            ctypes.set_errno(0)
            n = libc.syscall(NR_PROCESS_MADVISE, pidfd, arr, len(chunk), behavior, 0)
            if n < 0:
                e = ctypes.get_errno()
                # ESRCH just means the process exited under us; not an error worth
                # reporting, and common when sweeping cached apps.
                if e == errno.ESRCH:
                    return total, None
                return total, errno.errorcode.get(e, "errno %d" % e)
            total += n
    finally:
        os.close(pidfd)
    return total, None


def main():
    ap = argparse.ArgumentParser(
        description="Reclaim anonymous memory from cached Waydroid processes.")
    ap.add_argument("--min-adj", type=int, default=900, metavar="N",
                    help="only touch processes with oom_score_adj >= N "
                         "(default 900, Android's CACHED_APP floor)")
    ap.add_argument("--min-rss", type=int, default=32, metavar="MB",
                    help="skip processes smaller than this (default 32 MB)")
    ap.add_argument("--cold", action="store_true",
                    help="MADV_COLD instead of MADV_PAGEOUT: deactivate rather "
                         "than swap out, reclaimed later only under pressure")
    ap.add_argument("--dry-run", action="store_true",
                    help="list candidates and do nothing")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="show per-process swap growth as well as RSS drop")
    args = ap.parse_args()

    if not args.dry_run and os.geteuid() != 0:
        sys.exit("needs root: process_madvise on another process requires CAP_SYS_NICE")

    if args.min_adj < 900:
        print("warning: --min-adj %d reaches below Android's cached floor (900); "
              "perceptible and foreground apps may be paged out"
              % args.min_adj, file=sys.stderr)

    behavior = MADV_COLD if args.cold else MADV_PAGEOUT
    libc = ctypes.CDLL("libc.so.6", use_errno=True)

    candidates = []
    for pid in container_pids():
        adj = read_int_file("/proc/%d/oom_score_adj" % pid)
        if adj is None or adj < args.min_adj:
            continue
        st = proc_status(pid)
        if st is None or st[0] < args.min_rss:
            continue
        candidates.append((pid, adj, st[0], cmdline(pid) or st[2]))

    if not candidates:
        print("no candidates at adj >= %d with RSS >= %d MB"
              % (args.min_adj, args.min_rss))
        return 0

    candidates.sort(key=lambda c: -c[2])
    zram_before = zram_used_mb()

    if args.dry_run:
        print("would reclaim from %d process(es), %d MB resident:"
              % (len(candidates), sum(c[2] for c in candidates)))
    else:
        print("reclaiming from %d process(es) with %s:"
              % (len(candidates), "MADV_COLD" if args.cold else "MADV_PAGEOUT"))

    freed = 0
    for pid, adj, rss_before, name in candidates:
        if args.dry_run:
            print("  pid=%-7d adj=%-4d RSS=%5d MB  %s" % (pid, adj, rss_before, name[:46]))
            continue

        _, err = reclaim(libc, pid, behavior)
        if err:
            print("  pid=%-7d adj=%-4d FAILED: %s  %s" % (pid, adj, err, name[:38]))
            continue

        st = proc_status(pid)
        if st is None:
            print("  pid=%-7d adj=%-4d exited during reclaim" % (pid, adj))
            continue
        rss_after, swap_after, _ = st
        delta = rss_before - rss_after
        freed += delta
        if args.verbose:
            print("  pid=%-7d adj=%-4d RSS %5d -> %5d MB (%+d)  swap=%d MB  %s"
                  % (pid, adj, rss_before, rss_after, -delta, swap_after, name[:34]))
        else:
            print("  pid=%-7d adj=%-4d RSS %5d -> %5d MB (%+d MB)  %s"
                  % (pid, adj, rss_before, rss_after, -delta, name[:40]))

    if args.dry_run:
        return 0

    # zram compresses what we paged out, so the honest figure is the pair, not
    # the RSS drop alone.
    time.sleep(1)
    zram_after = zram_used_mb()
    print()
    if zram_before is not None and zram_after is not None:
        cost = zram_after - zram_before
        ratio = (" (%.1f:1)" % (freed / cost)) if cost > 0 else ""
        print("reclaimed %d MB of RSS for %d MB of zram%s -- net ~%d MB of RAM"
              % (freed, cost, ratio, freed - cost))
    else:
        print("reclaimed %d MB of RSS (no zram device found to account against)" % freed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
