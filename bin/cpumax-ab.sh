#!/bin/bash
# cpumax-ab.sh -- does capping the container's cpu.max keep the HOST responsive while
# Android burns CPU? Run on the host, as root.
#
# WHY THIS EXISTS
#
# docs/43-app-freezer.md closed the battery case against the per-app freezer twice and
# left performance as the live question. Its step 5 asks for an A/B of cpu.max on
# lxc.payload.waydroid, and records that the attempt on 2026-09-12 "lost its load --
# dexopt finished first". That is the flaw this fixes: a dexopt storm is not a load you
# can schedule, and it is now contained anyway, because artifacts/dexopt pins dex2oat to
# `--cpu-set=0,2 -j2`. Waiting for an uncontained storm to recur is not an experiment.
#
# So the load here is synthetic, sustained and deterministic: N spinners inside Android
# at nice 0, which is exactly the shape of the uncontained offender docs/43 caught
# (com.android.vending:background at 86% of a core, nice 0, in 0::/ competing on equal
# terms with SurfaceFlinger). It runs for as long as the arm needs and not a second less.
#
# WHAT IS BEING MEASURED, AND WHY IT IS LATENCY AND NOT THROUGHPUT
#
# "Janky" is a latency claim, so the metric is host scheduling latency: a host-side
# sleep(10ms) loop, reporting how far each wake overshoots. p50 says what the host feels
# normally, p99 says what it feels at its worst, and the worst is what a user calls jank.
# Host CPU pressure (PSI) is sampled alongside as an independent corroborant, and the
# container's own cpu.stat gives the price paid: throttled_usec and nr_throttled say how
# much Android actually gave up to buy the host that latency.
#
# ARMS
#   idle        no load, no cap        -- the floor. What the host feels with Android quiet.
#   uncapped    load, cpu.max = max    -- the complaint. Android competing freely.
#   capped-N    load, cpu.max = N%     -- the proposed fix, at each --caps value.
#
# SAFETY
#
# Two things here can outlive the script, and both get a detached deadman that cleans up
# unconditionally even if this process is SIGKILLed or the ssh session drops:
#   - the spinners, which are 4 uncontained busy loops inside Android;
#   - cpu.max, which if left capped would throttle the container indefinitely.
# cpu.max is restored to its ORIGINAL value, read at startup, not to a hardcoded default.
#
# Usage:  cpumax-ab.sh [options]
#   --caps LIST    comma-separated cap percentages of one core (default 200,100)
#                  200 = two full cores on this 4-cpu box; "max" is the uncapped arm.
#   --burners N    spinners inside Android (default 4, = one per logical cpu)
#   --sample N     seconds of latency sampling per arm (default 30)
#   --settle N     seconds after changing an arm before sampling (default 5)
#   --dry-run      print the arms and change nothing
#   -h, --help     this text
set -uo pipefail

CG=/sys/fs/cgroup/lxc.payload.waydroid
LXC_PATH=/var/lib/waydroid/lxc
LXC_NAME=waydroid
PIDFILE=/data/local/tmp/cpumax-ab-burn.pids     # inside the container

CAPS=200,100
BURNERS=4
SAMPLE=30
SETTLE=5
DRY=0

usage() { sed -n '2,48p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --caps)    CAPS="$2"; shift 2 ;;
        --burners) BURNERS="$2"; shift 2 ;;
        --sample)  SAMPLE="$2"; shift 2 ;;
        --settle)  SETTLE="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (cpu.max and lxc-attach)" >&2; exit 1; }
[ -w "$CG/cpu.max" ] || { echo "$CG/cpu.max not writable -- container running?" >&2; exit 1; }

NCPU=$(nproc)
PERIOD=100000
CPUMAX_ORIG=$(cat "$CG/cpu.max")
OUT=/var/tmp/cpumax-ab-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

attach() { local t="$1"; shift
    timeout "$t" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" --clear-env -- "$@" 2>/dev/null; }

# ------------------------------------------------------------------ load + cleanup

BURNING=0
DEADMAN=""

burners_start() {
    # Each spinner is a backgrounded subshell; when lxc-attach exits they reparent to the
    # container's init and keep running, which is what makes the load outlast the call
    # that started it. Their pids are recorded INSIDE the container because that is the
    # pid namespace the kill has to happen in.
    attach 30 /system/bin/sh -c \
        "rm -f $PIDFILE; i=0; while [ \$i -lt $BURNERS ]; do (while :; do :; done) & echo \$! >> $PIDFILE; i=\$((i+1)); done" \
        >/dev/null
    BURNING=1
    # Confirm they are actually running rather than assuming: the subshells have to
    # survive lxc-attach exiting (they reparent to the container's init), and a silent
    # failure here would make every later arm measure an idle container and look great.
    sleep 1
    local live
    live=$(attach 20 /system/bin/sh -c \
        "n=0; while read p; do [ -d /proc/\$p ] && n=\$((n+1)); done < $PIDFILE; echo \$n")
    echo "  load: ${live:-0}/$BURNERS spinners live inside Android"
    [ "${live:-0}" -gt 0 ] || { echo "  ERROR: no spinners started; the A/B would be meaningless" >&2; return 1; }
}

burners_stop() {
    [ "$BURNING" = 1 ] || return 0
    attach 30 /system/bin/sh -c \
        "[ -f $PIDFILE ] && while read p; do kill -9 \$p 2>/dev/null; done < $PIDFILE; rm -f $PIDFILE" \
        >/dev/null
    BURNING=0
}

deadman_start() {
    # Restores cpu.max AND kills the spinners, with no reference to this script, so it
    # survives this script dying by any means including SIGKILL.
    local secs="$1"
    setsid nohup sh -c "sleep $secs
        printf '%s' '$CPUMAX_ORIG' > $CG/cpu.max 2>/dev/null
        timeout 30 lxc-attach -P $LXC_PATH -n $LXC_NAME --clear-env -- /system/bin/sh -c \
            '[ -f $PIDFILE ] && while read p; do kill -9 \$p 2>/dev/null; done < $PIDFILE; rm -f $PIDFILE' \
            >/dev/null 2>&1" >/dev/null 2>&1 </dev/null &
    DEADMAN=$!
    disown "$DEADMAN" 2>/dev/null || true
}

deadman_cancel() {
    [ -n "$DEADMAN" ] || return 0
    kill -TERM -- "-$DEADMAN" 2>/dev/null || kill -TERM "$DEADMAN" 2>/dev/null || true
    DEADMAN=""
}

restore() {
    local rc=$?
    echo
    echo "--- restoring ---"
    burners_stop && echo "    spinners killed"
    printf '%s' "$CPUMAX_ORIG" > "$CG/cpu.max" 2>/dev/null \
        && echo "    cpu.max -> $CPUMAX_ORIG"
    deadman_cancel
    echo "results in $OUT"
    exit $rc
}
trap restore EXIT INT TERM HUP

# ------------------------------------------------------------------- measurement

# Host scheduling latency: how late a 10 ms sleep actually wakes. Pure stdlib, same
# reason as bin/v4l2-*.py and bin/waydroid-reclaim.py -- nothing to install on an
# immutable host. Reports percentiles in ms, plus PSI and the container's own cpu.stat.
latency_probe() {
    local secs="$1"
    python3 - "$secs" <<'PY'
import sys, time
secs = float(sys.argv[1])
interval = 0.010
end = time.monotonic() + secs
over = []
while time.monotonic() < end:
    t0 = time.monotonic()
    time.sleep(interval)
    over.append((time.monotonic() - t0 - interval) * 1000.0)
over.sort()
def pct(p):
    if not over: return 0.0
    return over[min(len(over) - 1, int(len(over) * p / 100.0))]
print("%d %.3f %.3f %.3f %.3f" % (len(over), pct(50), pct(95), pct(99), over[-1]))
PY
}

psi_cpu()  { awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/cpu; }
usage_usec() { awk '/^usage_usec/{print $2}' "$CG/cpu.stat"; }
throttled()  { awk '/^nr_throttled/{n=$2} /^throttled_usec/{u=$2} END{printf "%s %s", (n==""?0:n), (u==""?0:u)}' "$CG/cpu.stat"; }

arm() {
    local label="$1" cpumax="$2" load="$3"

    printf '%s' "$cpumax" > "$CG/cpu.max" || { echo "  cpu.max write failed" >&2; return 1; }

    if [ "$load" = 1 ] && [ "$BURNING" = 0 ]; then
        # Cover every remaining loaded arm, not a guessed constant: uncapped plus one
        # per --caps value, each costing SETTLE+SAMPLE, plus slack for the attach calls.
        local n_loaded=$(( 1 + $(echo "$CAPS" | tr ',' ' ' | wc -w) ))
        deadman_start $(( n_loaded * (SETTLE + SAMPLE) + 180 ))
        burners_start || return 1
    fi

    sleep "$SETTLE"

    local u0 t0 th0 p
    u0=$(usage_usec); t0=$(date +%s%3N); th0=$(throttled)
    p=$(latency_probe "$SAMPLE")
    local u1 t1 th1 psi
    u1=$(usage_usec); t1=$(date +%s%3N); th1=$(throttled); psi=$(psi_cpu)

    local got
    got=$(awk -v a="$u0" -v b="$u1" -v ms=$((t1 - t0)) 'BEGIN{printf "%.1f", (b-a)/10/ms}')
    local dn du
    dn=$(( $(echo "$th1" | cut -d' ' -f1) - $(echo "$th0" | cut -d' ' -f1) ))
    du=$(( $(echo "$th1" | cut -d' ' -f2) - $(echo "$th0" | cut -d' ' -f2) ))

    # n p50 p95 p99 max
    set -- $p
    printf '  %-12s  p50=%-7s p95=%-7s p99=%-8s max=%-9s  psi_some=%-7s  android=%-7s throttled=%s/%sms\n' \
        "$label" "$2" "$3" "$4" "$5" "$psi" "${got}%" "$dn" "$((du / 1000))"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$label" "$2" "$3" "$4" "$5" "$psi" "$got" "$dn" "$du" >> "$OUT/arms.tsv"
}

# -------------------------------------------------------------------------- run

echo "cpumax-ab.sh -- $(date -Is)"
echo "  cgroup:  $CG"
echo "  cpus:    $NCPU   cpu.max now: $CPUMAX_ORIG   period: ${PERIOD}us"
echo "  burners: $BURNERS spinners inside Android at nice 0"
echo "  arms:    idle, uncapped, $(echo "$CAPS" | tr ',' ' ' | sed 's/[0-9]*/capped-&%/g')"
echo "  sample:  ${SAMPLE}s each after ${SETTLE}s settle"
echo "  out:     $OUT"
echo
echo "  latency = how late a host 10ms sleep wakes, in ms. Lower is less janky."
echo

if [ "$DRY" = 1 ]; then echo "DRY RUN: nothing changed"; trap - EXIT; exit 0; fi

printf 'arm\tp50_ms\tp95_ms\tp99_ms\tmax_ms\tpsi_some\tandroid_pct_core\tnr_throttled\tthrottled_usec\n' \
    > "$OUT/arms.tsv"

arm "idle"     "$CPUMAX_ORIG" 0
arm "uncapped" "max $PERIOD"  1
for c in $(echo "$CAPS" | tr ',' ' '); do
    quota=$(( c * PERIOD / 100 ))
    arm "capped-${c}%" "$quota $PERIOD" 1
done

echo
echo "  (a cap of N% is N% of ONE core; this box has $NCPU logical cpus, so 400% = all of it)"
