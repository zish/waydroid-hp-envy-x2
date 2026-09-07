#!/bin/sh
# power-measure.sh — measure bigtab01's real power draw in each sleep regime.
#
# Run ON THE HOST, on battery. EVERY leg is a charge_now delta across a known
# interval, including the awake ones.
#
# That is forced, not a preference. On bigtab01 `current_now` reads ENODEV the
# whole time the battery is discharging (it works while charging), there is no
# `power_now`, and the hwmon `curr1_input` fails the same way -- the EC does not
# report a present rate on discharge. So there is no instantaneous power source
# on this machine, and nothing can sample during s2idle anyway.
#
#   power-measure.sh sample 300 "screen off, awake"
#   power-measure.sh s2idle-start 30      # arms an RTC wake, then suspends
#   power-measure.sh s2idle-finish        # run after it wakes itself
#
# See docs/17-hybrid-sleep.md for the numbers this produced.
set -eu

BAT=/sys/class/power_supply/BAT0
AC=/sys/class/power_supply/AC/online
STATE=/var/tmp/power-measure.s2idle

r() { cat "$BAT/$1"; }

require_battery() {
    if [ "$(cat $AC 2>/dev/null || echo 1)" != "0" ]; then
        echo "ERROR: still on AC. Unplug first — current_now reads 0 while charging." >&2
        exit 1
    fi
}

case "${1:-}" in
sample)
    secs="${2:-300}"; label="${3:-sample}"
    require_battery
    echo "measuring '$label' over ${secs}s (charge delta) ..."
    t0=$(date +%s); c0=$(r charge_now); v0=$(r voltage_now)
    end=$(( t0 + secs ))
    while [ "$(date +%s)" -lt "$end" ]; do sleep 10; done
    t1=$(date +%s); c1=$(r charge_now); v1=$(r voltage_now)
    dt=$(( t1 - t0 )); dc=$(( c0 - c1 )); vavg=$(( (v0 + v1) / 2 ))
    if [ "$dc" -le 0 ]; then
        echo "$label: INVALID - charge did not fall (dc=${dc}); interval too short"
        exit 1
    fi
    echo "$label: ${dt}s, ${c0} -> ${c1} uAh (delta ${dc}), $(( dc * 3600 / dt * vavg / 1000000000 )) mW"
    ;;

s2idle-start)
    mins="${2:-30}"
    require_battery
    command -v rtcwake >/dev/null || { echo "ERROR: rtcwake not installed" >&2; exit 1; }
    printf '%s %s %s\n' "$(date +%s)" "$(r charge_now)" "$(r voltage_now)" > "$STATE"
    echo "baseline: charge_now=$(r charge_now) uAh at $(date)"
    echo "arming RTC wake in ${mins} min, then suspending. Do not touch the machine."
    # -m no arms the alarm only; systemctl suspend then takes the normal path
    # through the sleep hooks rather than rtcwake's own direct write.
    rtcwake -m no -s $(( mins * 60 )) >/dev/null
    sync
    systemctl --no-block suspend
    ;;

s2idle-finish)
    [ -f "$STATE" ] || { echo "no baseline — run s2idle-start first" >&2; exit 1; }
    read -r t0 c0 v0 < "$STATE"
    t1=$(date +%s); c1=$(r charge_now); v1=$(r voltage_now)
    dt=$(( t1 - t0 )); dc=$(( c0 - c1 ))
    [ "$dt" -gt 0 ] || { echo "zero elapsed time" >&2; exit 1; }
    vavg=$(( (v0 + v1) / 2 ))
    # uAh drained over dt seconds -> milliwatts
    mw=$(( dc * 3600 / dt * vavg / 1000000000 ))
    echo "elapsed ${dt}s, charge ${c0} -> ${c1} uAh (delta ${dc}), Vavg $(( vavg / 1000 )) mV"
    echo "s2idle average: ${mw} mW"
    rm -f "$STATE"
    ;;

*)
    echo "usage: $0 {sample SECS LABEL | s2idle-start MINS | s2idle-finish}" >&2
    exit 2
    ;;
esac
