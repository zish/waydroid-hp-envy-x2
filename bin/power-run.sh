#!/bin/sh
# power-run.sh — drive the whole power measurement unattended.
#
# Waits for the machine to be unplugged, then runs every leg in order and
# writes results to $LOG. Launch it with nohup and walk away: it survives the
# ssh session dying, which it must, because one leg suspends the machine.
#
# The s2idle leg deliberately waits on wall-clock time (date +%s, CLOCK_REALTIME)
# rather than sleep(1), because nanosleep uses CLOCK_MONOTONIC, which does not
# advance while the machine is suspended.
set -eu

LOG=/var/tmp/power-measure.log
M=/var/tmp/power-measure.sh
AC=/sys/class/power_supply/AC/online
BAT=/sys/class/power_supply/BAT0
S2IDLE_MIN="${S2IDLE_MIN:-30}"
XDG_RUNTIME_DIR=/run/user/1000; export XDG_RUNTIME_DIR

say() { echo "[$(date +%H:%M:%S)] $*" >> "$LOG"; }
sway() { S=$(ls /run/user/1000/sway-ipc.*.sock 2>/dev/null | head -1) || return 0
         [ -n "$S" ] && SWAYSOCK="$S" swaymsg "$@" >/dev/null 2>&1 || true; }

: > "$LOG"
say "waiting for AC to be unplugged (up to 45 min)"
i=0
while [ "$(cat $AC)" != "0" ]; do
    i=$(( i + 1 )); [ "$i" -gt 2700 ] && { say "ABORT: never unplugged"; exit 1; }
    sleep 1
done
say "on battery: charge_now=$(cat $BAT/charge_now) uAh, full=$(cat $BAT/charge_full) uAh"

say "settling for 120s"
sleep 120

say "--- leg 1: screen on, idle ---"
"$M" sample 180 "screen on, idle" >> "$LOG" 2>&1 || say "leg 1 FAILED"

say "--- leg 2: screen off, awake ---"
sway 'output * dpms off'
sleep 5
"$M" sample 300 "screen off, awake" >> "$LOG" 2>&1 || say "leg 2 FAILED"
sway 'output * dpms on'

say "--- leg 3: s2idle for ${S2IDLE_MIN} min ---"
t0=$(date +%s); c0=$(cat $BAT/charge_now); v0=$(cat $BAT/voltage_now)
say "baseline charge_now=${c0} uAh"
sudo rtcwake -m no -s $(( S2IDLE_MIN * 60 )) >/dev/null 2>&1 || say "rtcwake FAILED"
sync
sudo systemctl --no-block suspend

# Wall-clock wait: survives the suspend, unlike sleep(1).
target=$(( t0 + S2IDLE_MIN * 60 + 60 ))
while [ "$(date +%s)" -lt "$target" ]; do sleep 20; done

t1=$(date +%s); c1=$(cat $BAT/charge_now); v1=$(cat $BAT/voltage_now)
dt=$(( t1 - t0 )); dc=$(( c0 - c1 )); vavg=$(( (v0 + v1) / 2 ))
if [ "$dc" -gt 0 ] && [ "$dt" -gt 0 ]; then
    mw=$(( dc * 3600 / dt * vavg / 1000000000 ))
    say "s2idle: ${dt}s elapsed, ${c0} -> ${c1} uAh (delta ${dc}), Vavg $(( vavg / 1000 )) mV"
    say "s2idle average: ${mw} mW"
else
    say "s2idle: INVALID (dt=${dt} dc=${dc}) — machine was probably woken early"
fi

say "--- done ---"
