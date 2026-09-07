#!/bin/sh
# power-standby.sh — measure standby draw in whichever sleep mode is configured.
#
#   power-standby.sh <minutes> [label]
#
# Works for s2idle and S3 alike: it does NOT assume which one it got, it reads
# the mode back out of the kernel log afterwards and records what actually
# happened. A silent fallback to the wrong mode would otherwise be invisible and
# would quietly invalidate the comparison.
#
# Method, and why (see docs/17-hybrid-sleep.md for the full reasoning):
#   * current_now reads ENODEV on discharge on this machine, so every figure is
#     a charge_now delta.
#   * charge_now moves in 1% steps, recomputed per run because charge_full
#     recalibrates between runs.
#   * the nap STARTS on a step edge, so the baseline is exact; the end reading is
#     mid-step, so results are given as lower bound / best estimate / upper bound
#     rather than a single false-precision number.
#   * the wait is wall-clock (date +%s), because nanosleep runs on
#     CLOCK_MONOTONIC and does not advance while suspended.
#
# When it finishes it SUSPENDS THE MACHINE AGAIN rather than leaving it awake.
# An earlier run left the laptop awake overnight at 2.1 W and flattened it; the
# log is on disk, so there is no reason to stay up waiting to be read.
set -eu

MINS="${1:?usage: power-standby.sh <minutes> [label]}"
LABEL="${2:-standby}"
B=/sys/class/power_supply/BAT0
LOG=/var/tmp/power-measure.log

say() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
edge() { p=$(cat $B/charge_now); while :; do c=$(cat $B/charge_now)
         [ "$c" != "$p" ] && { echo "$c"; return; }; sleep 5; done; }

[ "$(cat /sys/class/power_supply/AC/online)" = "0" ] || { say "ABORT ($LABEL): on AC"; exit 1; }

STEP=$(( $(cat $B/charge_full) / 100 ))
say "=== $LABEL: ${MINS} min, 1% step = ${STEP} uAh, mem_sleep='$(cat /sys/power/mem_sleep)' ==="

say "  waiting for a step edge so the baseline is exact"
c0=$(edge); t0=$(date +%s); v0=$(cat $B/voltage_now)
say "  baseline charge_now=${c0} uAh, V=${v0}"

sudo rtcwake -m no -s $(( MINS * 60 )) >/dev/null 2>&1 || say "  rtcwake FAILED"
sync
sudo systemctl --no-block suspend

target=$(( t0 + MINS * 60 + 90 ))
while [ "$(date +%s)" -lt "$target" ]; do sleep 20; done

t1=$(date +%s); c1=$(cat $B/charge_now); v1=$(cat $B/voltage_now)
dt=$(( t1 - t0 )); dc=$(( c0 - c1 )); vavg=$(( (v0 + v1) / 2 ))

# What mode did we ACTUALLY get, and was the nap the length we asked for?
mode=$(journalctl -k --no-pager -g "PM: suspend entry" 2>/dev/null | tail -1)
entry=$(journalctl -k --no-pager -g "PM: suspend entry" -o short-unix 2>/dev/null | tail -1 | cut -d. -f1)
exit_=$(journalctl -k --no-pager -g "PM: suspend exit"  -o short-unix 2>/dev/null | tail -1 | cut -d. -f1)
say "  kernel says: ${mode##*bigtab01 }"
if [ -n "${entry:-}" ] && [ -n "${exit_:-}" ]; then
    asleep=$(( exit_ - entry ))
    say "  actually asleep ${asleep}s of ${dt}s measured ($(( dt - asleep ))s awake)"
fi

# If the machine was woken early it spent part of the interval AWAKE, drawing
# far more than it does asleep. Subtract that at the measured screen-off awake
# figure (2.142 W, docs/17) and divide by the time genuinely asleep, rather than
# reporting a blended number as though it were standby. This happens in
# practice: tonight's first attempt was cut short by a keypress.
AWAKE_MW=2142
if [ -n "${asleep:-}" ] && [ "$asleep" -gt 0 ] && [ "$asleep" -lt "$dt" ]; then
    awake_s=$(( dt - asleep ))
    awake_uah=$(( AWAKE_MW * 1000000 / (vavg / 1000) * awake_s / 3600 / 1000 ))
    say "  correcting for ${awake_s}s awake (~${awake_uah} uAh at ${AWAKE_MW} mW)"
    dc=$(( dc - awake_uah )); dt="$asleep"
fi

if [ "$dc" -gt 0 ]; then
    lo=$(( dc * 3600 / dt * vavg / 1000000000 ))
    mid=$(( (dc + STEP / 2) * 3600 / dt * vavg / 1000000000 ))
    hi=$(( (dc + STEP) * 3600 / dt * vavg / 1000000000 ))
    say "  RESULT ${LABEL}: ${dt}s asleep, ${dc} uAh -> ${lo} / ${mid} / ${hi} mW (lower/best/upper)"
else
    say "  RESULT ${LABEL}: INVALID (dc=${dc}) — woken early or interval too short"
fi

say "  re-suspending to protect the battery; log is on disk"
sync
sudo systemctl --no-block suspend
