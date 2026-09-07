#!/bin/sh
# power-legs.sh — the remaining power legs, logged HOST-SIDE so progress is
# readable at any time with `cat /var/tmp/power-measure.log`, and so the run
# survives ssh dropping (which it must: one leg suspends the machine).
#
# Every figure is a charge_now delta. current_now reads ENODEV on discharge on
# this machine, so there is no instantaneous source -- see power-measure.sh.
#
# The EC reports charge in 1% steps (~31 mAh). Two things follow:
#   * awake legs are measured EDGE TO EDGE, between step transitions, which
#     removes the quantisation error entirely rather than averaging it down.
#   * the s2idle leg cannot do that, because nothing can observe a step while
#     the CPU is frozen. It starts on an edge (so c0 is exact) and ends on a
#     mid-step read, leaving a one-sided 0..1 step undercount. The best
#     estimate therefore adds half a step back; both raw and corrected figures
#     are logged.
set -eu

B=/sys/class/power_supply/BAT0
AC=/sys/class/power_supply/AC/online
LOG=/var/tmp/power-measure.log
S2IDLE_MIN="${S2IDLE_MIN:-90}"
AWAKE_MIN_SEC="${AWAKE_MIN_SEC:-600}"

export XDG_RUNTIME_DIR=/run/user/1000
SWAYSOCK=$(ls /run/user/1000/sway-ipc.*.sock 2>/dev/null | head -1)
export SWAYSOCK

say() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
disp() { swaymsg "output * dpms $1" >/dev/null 2>&1 || true; }
edge() { p=$(cat $B/charge_now); while :; do c=$(cat $B/charge_now)
         [ "$c" != "$p" ] && { echo "$c"; return; }; sleep 5; done; }
mw() { # uAh, seconds, uV -> mW
    [ "$2" -gt 0 ] || { echo 0; return; }
    echo $(( $1 * 3600 / $2 * $3 / 1000000000 )); }

STEP=$(( $(cat $B/charge_full) / 100 ))
say "=== remaining legs; 1% step = ${STEP} uAh ==="

[ "$(cat $AC)" = "0" ] || { say "ABORT: on AC"; exit 1; }

# ---- leg: screen off, awake ------------------------------------------------
say "leg: screen off, awake (edge to edge, >= ${AWAKE_MIN_SEC}s)"
disp off
sleep 15
c0=$(edge); t0=$(date +%s); v0=$(cat $B/voltage_now)
say "  first edge at charge_now=${c0}"
while :; do
    c1=$(edge); t1=$(date +%s)
    [ $(( t1 - t0 )) -ge "$AWAKE_MIN_SEC" ] && break
done
v1=$(cat $B/voltage_now); dt=$(( t1 - t0 )); dc=$(( c0 - c1 ))
vavg=$(( (v0 + v1) / 2 ))
say "  RESULT screen-off awake: ${dt}s, ${dc} uAh, $(mw $dc $dt $vavg) mW"

# ---- leg: s2idle -----------------------------------------------------------
say "leg: s2idle for ${S2IDLE_MIN} min - starting on a step edge"
c0=$(edge); t0=$(date +%s); v0=$(cat $B/voltage_now)
say "  baseline charge_now=${c0} (exact, on edge)"
sudo rtcwake -m no -s $(( S2IDLE_MIN * 60 )) >/dev/null 2>&1 || say "  rtcwake FAILED"
sync
sudo systemctl --no-block suspend

# Wall clock, not sleep(1): nanosleep uses CLOCK_MONOTONIC, which does not
# advance while suspended.
target=$(( t0 + S2IDLE_MIN * 60 + 90 ))
while [ "$(date +%s)" -lt "$target" ]; do sleep 20; done

t1=$(date +%s); c1=$(cat $B/charge_now); v1=$(cat $B/voltage_now)
dt=$(( t1 - t0 )); dc=$(( c0 - c1 )); vavg=$(( (v0 + v1) / 2 ))
if [ "$dc" -gt 0 ]; then
    say "  RESULT s2idle raw:       ${dt}s, ${dc} uAh, $(mw $dc $dt $vavg) mW (lower bound)"
    say "  RESULT s2idle corrected: $(mw $(( dc + STEP / 2 )) $dt $vavg) mW (+half step)"
    say "  RESULT s2idle upper:     $(mw $(( dc + STEP )) $dt $vavg) mW"
else
    say "  s2idle INVALID (dc=${dc}) - woken early or interval too short"
fi

disp on
say "=== all legs done ==="
