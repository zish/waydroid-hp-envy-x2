#!/usr/bin/env bash
#
# power-ab.sh — measure real system draw on battery, arm by arm.
#
# WHY THIS EXISTS
#
# docs/39-power-management.md measured the SoC package at 0.47-0.55 W and then had to
# stop, because the machine was on AC at Full: `current_now` reads 0 while charging, and
# RAPL covers the package only -- not the panel, the backlight inverter, the SSD or the
# radios. So every claim in that note about the panel's share is an estimate, and the
# denominator for "is X worth fixing" was never obtained.
#
# docs/41-battery-cutoff.md supplies the only real figure we have: UPower's history
# recorded 12.5-25 W during the 2026-09-09 discharge. That is the number this script is
# meant to reproduce and then decompose.
#
# Run it on the host, as root, with the CHARGER UNPLUGGED. It walks a set of arms,
# changing one thing at a time, and restores every change on exit -- including on Ctrl-C
# or a crash, via a trap.
#
# READING THE OUTPUT
#
# `sys_W` is the whole machine: current_now x voltage_now, straight off the pack's own
# gauge. `pkg_W` is RAPL, the SoC package alone. The difference between them is
# everything RAPL cannot see, which is the part docs/39 could only guess at.
#
# TWO CONFOUNDS THIS SCRIPT MAKES VISIBLE RATHER THAN HIDING
#
# 1. Android owns the backlight now (docs/37, docs/42), and its dim policy drives the
#    *physical* panel 10 s after the last touch of Android -- even when someone is using
#    the host. So the panel can move under us mid-arm. Every sample records `bl`, the
#    raw backlight value, so a drifting arm is obvious instead of silent.
# 2. The gauge on this pack is uncalibrated and reads high (docs/41: charge_full equals
#    charge_full_design exactly, cycle_count 0, a 2014 pack). That affects *capacity*
#    estimates, not the instantaneous current reading, so the watts are usable even
#    though the percentage is not -- BUT the current reading is itself heavily filtered.
#    Measured 2026-09-10: it held one identical value for 20 minutes across three
#    different machine configurations. Do not ask it to resolve anything under ~1 W;
#    for on-package terms use pkg_W (RAPL), which resolved an 80 mW effect cleanly in
#    the same run.
#
# SAFETY
#
# This machine hard-cut at roughly 18% on 2026-09-09 with no shutdown and no warning,
# and the host has no working notification path at all (docs/41). The script therefore
# aborts below --floor (default 45%) and refuses to start on AC.

set -uo pipefail

BAT=/sys/class/power_supply/BAT0
RAPL=/sys/class/powercap/intel-rapl:0/energy_uj
BL=/sys/class/backlight/intel_backlight
CG=/sys/fs/cgroup/lxc.payload.waydroid

SETTLE=120      # discarded, to clear the previous arm from a heavily filtered gauge
SAMPLE=300      # the pack can hold one value this long; see measure() for why
INTERVAL=10     # poll rate; far faster than the gauge, deduped into distinct values
FLOOR=45        # abort below this battery percentage
DO_FREEZE=0     # --freeze opts in to the whole-container freeze arm
CURVE=0         # --curve prints every raw sample, to expose gauge lag
ONLY=""

usage() {
    sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
    cat <<'EOF'

Usage: power-ab.sh [options]

  --floor N      abort below N% battery (default 45)
  --sample N     seconds of sampling per arm (default 300 = 5 gauge updates)
  --settle N     seconds to settle after changing an arm (default 120)
  --freeze       include the whole-container cgroup.freeze arm (see docs/38).
                 UNTESTED on this host: 1780 tasks all observe the same
                 CLOCK_MONOTONIC jump on thaw. Watchdogs, ANRs and a herd of
                 expired alarms are the expected failure mode.
  --curve        print every raw sample live (elapsed, watts, backlight, dpms)
                 instead of a progress dot. Use it to see whether the pack's
                 reading is actually tracking the arm, or just sitting still.
  --only LIST    comma-separated arm names to run (default: all but freeze)
  -h, --help     this text

Arms: baseline backlight-10 backlight-50 sensord-stopped wifi-powersave container-frozen
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --floor)  FLOOR="$2"; shift 2 ;;
        --sample) SAMPLE="$2"; shift 2 ;;
        --settle) SETTLE="$2"; shift 2 ;;
        --freeze) DO_FREEZE=1; shift ;;
        --curve)  CURVE=1; shift ;;
        --only)   ONLY="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (RAPL, backlight and SIGSTOP all need it)" >&2; exit 1; }

# ---------------------------------------------------------------- preconditions

on_ac() { cat /sys/class/power_supply/A*/online 2>/dev/null | grep -q 1; }

if on_ac; then
    echo "ERROR: still on AC. current_now reads 0 while charging, so every arm would" >&2
    echo "       measure nothing. Unplug the charger and run again." >&2
    exit 1
fi

capacity() { cat "$BAT/capacity"; }

if [ "$(capacity)" -lt "$FLOOR" ]; then
    echo "ERROR: battery at $(capacity)%, floor is ${FLOOR}%. Charge first." >&2
    exit 1
fi

# ------------------------------------------------------------------- restore

BL_SAVED=""
SENSORD_PID=""
SENSORD_STOPPED=0
WIFI_DEV=""
WIFI_PS_SAVED=""
FROZE=0

restore() {
    local rc=$?
    echo
    echo "--- restoring ---"
    if [ -n "$BL_SAVED" ]; then
        echo "$BL_SAVED" > "$BL/brightness" 2>/dev/null && echo "backlight -> $BL_SAVED"
    fi
    if [ "$SENSORD_STOPPED" = 1 ] && [ -n "$SENSORD_PID" ]; then
        kill -CONT "$SENSORD_PID" 2>/dev/null && echo "waydroid-sensord -> SIGCONT (pid $SENSORD_PID)"
        # docs/39: check /proc, not `kill -0` -- EPERM is indistinguishable from "gone".
        sleep 1
        awk '{print "  state: " $3}' "/proc/$SENSORD_PID/stat" 2>/dev/null
    fi
    if [ -n "$WIFI_DEV" ] && [ -n "$WIFI_PS_SAVED" ]; then
        iw dev "$WIFI_DEV" set power_save "$WIFI_PS_SAVED" 2>/dev/null \
            && echo "$WIFI_DEV power_save -> $WIFI_PS_SAVED"
    fi
    if [ "$FROZE" = 1 ]; then
        echo 0 > "$CG/cgroup.freeze" 2>/dev/null && echo "container -> thawed"
        thaw_wait
    fi
    echo "--- restored ---"
    exit $rc
}
trap restore EXIT INT TERM

# ------------------------------------------------------------------ sampling

# Power is not published directly on this pack -- it is a charge-based gauge
# (charge_now/charge_full in uAh), so there is no power_now node. Compute it.
read_w() {
    local i v
    i=$(cat "$BAT/current_now" 2>/dev/null) || return 1
    v=$(cat "$BAT/voltage_now" 2>/dev/null) || return 1
    awk -v i="$i" -v v="$v" 'BEGIN{ printf "%.3f", (i/1e6)*(v/1e6) }'
}

read_bl() { cat "$BL/brightness" 2>/dev/null || echo "-"; }

# Panel power state, independent of the backlight value. These are NOT the same thing:
# the panel can be blanked by DPMS while /sys/class/backlight still reports its old
# brightness, which is one of the two explanations for the self-contradictory first run
# on 2026-09-10 (backlight 50% appearing to draw less than backlight 10%). Sampling both
# at every point is what tells them apart.
read_dpms() {
    local c
    for c in /sys/class/drm/card*-*/; do
        [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
        cat "$c/dpms" 2>/dev/null && return 0
    done
    echo "-"
}

# median of column N of stdin
median() {
    local col="${1:-1}"
    sort -n -k"$col","$col" | awk -v c="$col" '{a[NR]=$c} END{ if(NR==0){print "-"; exit}
        if(NR%2) printf "%.3f", a[(NR+1)/2]; else printf "%.3f", (a[NR/2]+a[NR/2+1])/2 }'
}

measure() {
    local label="$1"
    local n=$((SAMPLE / INTERVAL))
    local tmp; tmp=$(mktemp)
    local e0 e1 t0 t1 pkg="-" bl_first bl_last
    local raw="${RESULTS%.txt}-${label}.raw"

    printf '  settling %ss ... ' "$SETTLE"; sleep "$SETTLE"; echo "done"

    bl_first=$(read_bl)
    e0=$(cat "$RAPL" 2>/dev/null || echo "")
    t0=$(date +%s.%N)

    # Per-sample raw series: elapsed_s  watts  backlight  dpms. Written for every arm so
    # a drifting or lagging reading is reconstructable after the fact instead of being
    # collapsed into a single median that hides it.
    echo "# elapsed_s watts backlight dpms   ($label)" > "$raw"

    printf '  sampling %ss ' "$SAMPLE"
    local i w el
    for i in $(seq 1 "$n"); do
        w=$(read_w 2>/dev/null) || w=""
        el=$(awk -v a="$t0" 'BEGIN{ printf "%.1f", systime()-int(a) }')
        if [ -n "$w" ]; then
            printf '%s %s %s %s\n' "$el" "$w" "$(read_bl)" "$(read_dpms)" >> "$raw"
            echo "$w" >> "$tmp"
        fi
        if [ "$CURVE" = 1 ]; then
            printf '\n    t=%-7s W=%-8s bl=%-5s dpms=%s' "$el" "$w" "$(read_bl)" "$(read_dpms)"
        else
            printf '.'
        fi
        sleep "$INTERVAL"
        if [ "$(capacity)" -lt "$FLOOR" ]; then
            echo; echo "ABORT: battery hit floor (${FLOOR}%) mid-arm." >&2
            rm -f "$tmp"; exit 3
        fi
        if on_ac; then
            echo; echo "ABORT: AC was reconnected mid-arm; readings are void." >&2
            rm -f "$tmp"; exit 3
        fi
    done
    echo

    t1=$(date +%s.%N)
    e1=$(cat "$RAPL" 2>/dev/null || echo "")
    bl_last=$(read_bl)

    # THE INSTRUMENT SAMPLES AT 1/60 Hz. Measured on this host 2026-09-10: BAT0's
    # current_now changes exactly once every 60 s, and battery.cache_time is 1000 ms, so
    # the limit is the EC's own _BST refresh and there is no knob for it. Polling faster
    # just returns the same number again -- which is exactly what made the first run's
    # medians meaningless: a 120 s arm saw TWO gauge updates, so a "median of 18 samples"
    # was really a median of two, weighted by whichever was held longer. Collapse
    # consecutive identical readings into gauge UPDATES and do all statistics on those.
    local updates; updates=$(awk '$1!=p{print $1; p=$1}' "$tmp")
    local n_upd; n_upd=$(printf '%s\n' "$updates" | grep -c .)

    # Discard the first update: it straddles the instant the arm changed, so it is part
    # this arm and part the previous one.
    local steady
    if [ "$n_upd" -gt 1 ]; then
        steady=$(printf '%s\n' "$updates" | tail -n +2 | median 1)
    else
        steady=$(printf '%s\n' "$updates" | median 1)
    fi

    # Distinguish "not enough data" from "the effect is below the instrument's
    # resolution" -- an earlier version of this script conflated them and flagged a
    # perfectly stable reading as insufficient sampling.
    #
    # Measured on this host 2026-09-10: the pack's reported current is heavily filtered.
    # It held ONE identical value across 20 minutes spanning three different machine
    # configurations (sensord running vs SIGSTOPped, wifi CAM vs power-save). It is not
    # a clean 60 s refresh, and it cannot resolve sub-watt terms at all. Anything smaller
    # than roughly 1 W has to be measured with pkg_W (RAPL), which is precise and fast --
    # but only sees the SoC package, so it is blind to the panel, the radios and the SSD.
    local slew=""
    if [ "$SAMPLE" -lt 300 ]; then
        slew="  SAMPLE TOO SHORT (${SAMPLE}s; this pack can hold one value for 300s+)"
    elif [ "$n_upd" -le 1 ]; then
        slew="  GAUGE NEVER MOVED (one value all arm: this effect is below the pack's"
        slew="$slew resolution -- read pkg_W instead, if the term is on-package)"
    elif [ "$n_upd" -lt 3 ]; then
        slew="  ONLY ${n_upd} DISTINCT VALUES (treat this delta as indicative, not measured)"
    else
        # Slew check in update space: first half of the kept updates against the last half.
        local h; h=$(( (n_upd - 1) / 2 )); [ "$h" -lt 1 ] && h=1
        local ea la
        ea=$(printf '%s\n' "$updates" | tail -n +2 | head -n "$h" | median 1)
        la=$(printf '%s\n' "$updates" | tail -n "$h" | median 1)
        slew=$(awk -v a="$ea" -v b="$la" 'BEGIN{ d=b-a; if(d<0)d=-d;
              if(a>0 && d/a > 0.05) printf "  NOT SETTLED (early=%.2f late=%.2f)", a, b }')
    fi

    # Did the panel move under us mid-arm? min/max over every sample, not just endpoints.
    local bl_lo bl_hi dpms_states
    bl_lo=$(awk 'NR>1{print $3}' "$raw" | sort -n | head -1)
    bl_hi=$(awk 'NR>1{print $3}' "$raw" | sort -n | tail -1)
    dpms_states=$(awk 'NR>1{print $4}' "$raw" | sort -u | tr '\n' '/' | sed 's|/$||')

    # RAPL is a wrapping uJ counter; a negative delta means it wrapped, so drop it
    # rather than report a nonsense figure.
    if [ -n "$e0" ] && [ -n "$e1" ]; then
        pkg=$(awk -v a="$e0" -v b="$e1" -v t0="$t0" -v t1="$t1" \
              'BEGIN{ d=b-a; dt=t1-t0; if(d<0||dt<=0){print "-"} else printf "%.3f", (d/1e6)/dt }')
    fi

    local sys cap flags blrange
    sys="$steady"
    cap=$(capacity)

    blrange="$bl_lo"
    [ "$bl_lo" != "$bl_hi" ] && blrange="${bl_lo}-${bl_hi}"

    flags="$slew"
    [ "$bl_lo" != "$bl_hi" ] && flags="$flags  BACKLIGHT MOVED ${bl_lo}->${bl_hi}"
    case "$dpms_states" in
        *On*Off*|*Off*On*) flags="$flags  PANEL BLANKED MID-ARM ($dpms_states)" ;;
        *Off*)             flags="$flags  PANEL OFF ($dpms_states)" ;;
    esac

    printf '%-18s sys_W=%-8s pkg_W=%-8s off_pkg_W=%-8s bl=%-9s dpms=%-4s upd=%-3s cap=%s%%%s\n' \
        "$label" "$sys" "$pkg" \
        "$(awk -v s="$sys" -v p="$pkg" 'BEGIN{ if(p=="-"||s=="-"){print "-"} else printf "%.3f", s-p }')" \
        "$blrange" "$dpms_states" "$n_upd" "$cap" "$flags" | tee -a "$RESULTS"

    rm -f "$tmp"
}

# ---------------------------------------------------------------------- arms

thaw_wait() {
    local i
    for i in $(seq 1 60); do
        grep -q 'frozen 0' "$CG/cgroup.events" 2>/dev/null && return 0
        sleep 0.5
    done
    echo "  WARNING: container did not report thawed within 30s" >&2
}

arm_baseline() { :; }

arm_backlight_10() {
    local max; max=$(cat "$BL/max_brightness")
    : "${BL_SAVED:=$(cat "$BL/brightness")}"
    echo $((max / 10)) > "$BL/brightness"
}

arm_backlight_50() {
    local max; max=$(cat "$BL/max_brightness")
    : "${BL_SAVED:=$(cat "$BL/brightness")}"
    echo $((max / 2)) > "$BL/brightness"
}

arm_sensord_stopped() {
    # docs/39: waydroid-sensord is NOT a systemd unit -- it is a child of
    # `waydroid container start`, spawned by container_manager.py because its literal
    # binary name is on PATH, and it runs as waydroid_t. Killing it would leave it dead
    # until the next container restart, which drops the kiosk to the SDDM greeter.
    # SIGSTOP is the reversible equivalent and is already proven safe on this host.
    # NOTE the name: /proc/PID/comm truncates at 15 characters, so the daemon appears as
    # "waydroid-sensor" and `pgrep -x waydroid-sensord` matches nothing at all. `pgrep -f`
    # is worse -- it happily matches any shell whose command line mentions the daemon,
    # including the ssh session running this script. Match the truncated comm, then
    # confirm against the real cmdline before signalling anything.
    SENSORD_PID=$(pgrep -x waydroid-sensor | head -1)
    if [ -z "$SENSORD_PID" ]; then
        echo "  SKIP: waydroid-sensord not running" >&2
        return 1
    fi
    if ! tr '\0' ' ' < "/proc/$SENSORD_PID/cmdline" 2>/dev/null | grep -q 'waydroid-sensord'; then
        echo "  SKIP: pid $SENSORD_PID is not waydroid-sensord" >&2
        SENSORD_PID=""
        return 1
    fi
    kill -STOP "$SENSORD_PID" && SENSORD_STOPPED=1
}

arm_wifi_powersave() {
    # /etc/modprobe.d sets power_save=0 and power_scheme=1 (CAM). docs/39 flags this as
    # possibly load-bearing for association stability, so this arm is runtime-only and
    # reverts on exit -- it does not touch modprobe.d.
    command -v iw >/dev/null || { echo "  SKIP: iw not installed" >&2; return 1; }
    WIFI_DEV=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
    [ -n "$WIFI_DEV" ] || { echo "  SKIP: no wifi interface" >&2; WIFI_DEV=""; return 1; }
    WIFI_PS_SAVED=$(iw dev "$WIFI_DEV" get power_save 2>/dev/null | awk '{print $NF}')
    iw dev "$WIFI_DEV" set power_save on || { WIFI_DEV=""; return 1; }
}

arm_container_frozen() {
    [ -w "$CG/cgroup.freeze" ] || { echo "  SKIP: $CG/cgroup.freeze not writable" >&2; return 1; }
    echo 1 > "$CG/cgroup.freeze" || return 1
    FROZE=1
    # docs/38: the write is one atomic request but not instantaneous -- tasks freeze at
    # their next safe stopping point. Poll cgroup.events rather than sleeping blind.
    local i
    for i in $(seq 1 60); do
        grep -q 'frozen 1' "$CG/cgroup.events" 2>/dev/null && return 0
        sleep 0.5
    done
    echo "  WARNING: container did not report frozen within 30s" >&2
}

undo_backlight()  { [ -n "$BL_SAVED" ] && echo "$BL_SAVED" > "$BL/brightness"; }
undo_sensord()    { [ "$SENSORD_STOPPED" = 1 ] && kill -CONT "$SENSORD_PID" && SENSORD_STOPPED=0; }
undo_wifi()       { [ -n "$WIFI_DEV" ] && iw dev "$WIFI_DEV" set power_save "$WIFI_PS_SAVED"; WIFI_DEV=""; }
undo_frozen()     { [ "$FROZE" = 1 ] && { echo 0 > "$CG/cgroup.freeze"; thaw_wait; FROZE=0; }; }

# ------------------------------------------------------------------------ run

RESULTS="/var/tmp/power-ab-$(date +%Y%m%d-%H%M%S).txt"

echo "power-ab.sh  --  $(date -Is)"
echo "host: $(uname -n)  kernel: $(uname -r)"
echo "battery: $(capacity)%  ${SETTLE}s settle + ${SAMPLE}s sample per arm  floor ${FLOOR}%"
echo "results: $RESULTS"
echo

ARMS="baseline backlight-10 backlight-50 sensord-stopped wifi-powersave"
[ "$DO_FREEZE" = 1 ] && ARMS="$ARMS container-frozen"
[ -n "$ONLY" ] && ARMS=$(echo "$ONLY" | tr ',' ' ')

for arm in $ARMS; do
    echo "=== $arm ==="
    case "$arm" in
        baseline)         arm_baseline ;;
        backlight-10)     arm_backlight_10 ;;
        backlight-50)     arm_backlight_50 ;;
        sensord-stopped)  arm_sensord_stopped ;;
        wifi-powersave)   arm_wifi_powersave ;;
        container-frozen) arm_container_frozen ;;
        *) echo "unknown arm: $arm" >&2; continue ;;
    esac
    # An arm whose setup failed is skipped rather than measured as if it applied.
    if [ $? -ne 0 ]; then echo "  (arm skipped)"; continue; fi

    measure "$arm"

    case "$arm" in
        backlight-10|backlight-50) undo_backlight ;;
        sensord-stopped)           undo_sensord ;;
        wifi-powersave)            undo_wifi ;;
        container-frozen)          undo_frozen ;;
    esac
done

echo
echo "=== summary ==="
cat "$RESULTS"
echo
echo "Deltas are against the baseline arm. off_pkg_W is everything RAPL cannot see:"
echo "panel, backlight inverter, SSD, radios -- the term docs/39 could only estimate."
