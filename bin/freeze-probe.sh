#!/bin/bash
# freeze-probe.sh -- characterise the whole-container cgroup freeze and, above all,
# the THAW. Run on the host, as root.
#
# WHY THIS EXISTS, AND WHY IT IS NOT power-ab.sh --freeze
#
# docs/43-app-freezer.md step 5 asks for the host-side whole-container freeze to be
# tested "short then long" with the thaw characterised. `power-ab.sh --freeze` cannot
# answer that: it refuses to run on AC, it measures watts -- a question docs/43 closed
# twice, at a known ceiling of ~40 mW -- and it records nothing whatever about what
# happens on thaw. The open question is not what freezing saves. It is what it breaks.
#
# The predicted failure mode is specific. ~1300 tasks are suspended at their next safe
# stopping point while CLOCK_MONOTONIC keeps advancing, so on thaw every one of them
# observes the same apparent time jump at once: watchdogs that think they hung, ANRs,
# and a thundering herd of alarms that all came due while nothing could run. docs/43's
# own words: "Seconds should be clean; minutes need evidence." This produces the
# evidence, by escalating rungs, and stops at the first rung that does damage.
#
# WHAT IT MEASURES, PER RUNG
#
#   freeze latency   write to `frozen 1` -- NOT instantaneous; a task in uninterruptible
#                    sleep delays the whole cgroup, so this is polled, never slept.
#   thaw latency     write back to `frozen 0`.
#   lxc-info state   does LXC report FROZEN? This is a SAFETY hypothesis, not trivia.
#                    waydroid-restartd polls `lxc-info -sH` and stands down on anything
#                    that is not RUNNING. If LXC reports FROZEN it never attaches, which
#                    is the clean path. If it still says RUNNING, restartd falls back to
#                    lxc-attach, whose child is born inside the frozen cgroup and hangs
#                    until its own 10 s timeout -- read_props() returns None and it still
#                    signals nothing. Safe either way; worth knowing which.
#   daemon D-state   the six waydroid-* host daemons live OUTSIDE this cgroup and talk to
#                    Android over binder. A synchronous call into a frozen peer blocks.
#                    Any of them landing in D is the interesting negative result.
#   the herd         container CPU over the recovery window against the same-length
#                    baseline window, from cpu.stat usage_usec. A thaw that costs more
#                    than it saved is the thing to catch.
#   casualties       cgroup.procs before vs after, by pid, so a kill is named rather than
#                    inferred from a count that moved.
#   logcat           ANRs, FATAL EXCEPTION, Watchdog, lmkd kills and binder failures in
#                    the window, counted as a delta and dumped in full.
#   liveness         how long Android takes to answer a getprop after the thaw.
#
# SAFETY: THE DEADMAN THAW
#
# A trap covers Ctrl-C and a crash. It does NOT cover SIGKILL, the ssh session dropping,
# or this script's own host going away mid-rung -- and a container left frozen with
# nobody at the machine is the one genuinely bad outcome, because the screen is frozen
# too and the recovery is a power cycle. So before every freeze a DETACHED child is
# started that unconditionally writes 0 to cgroup.freeze after the hold plus a slack, and
# it is killed only once the thaw has already happened. It is setsid'd and holds no
# reference to this script, so it survives this script being killed by anything at all.
#
# Usage:  freeze-probe.sh [options]
#   --rungs LIST     comma-separated hold seconds (default 5,30,120)
#   --window N       baseline window and recovery slice, seconds (default 60)
#   --recovery N     total recovery seconds, sliced by --window (default 60)
#   --slack N        deadman fires at hold+N seconds (default 30)
#   --dry-run        do everything except write cgroup.freeze
#   -h, --help       this text
#
# Exit: 0 all rungs clean / 3 a rung did damage and the escalation stopped / 1 error.
set -uo pipefail

CG=/sys/fs/cgroup/lxc.payload.waydroid
LXC_PATH=/var/lib/waydroid/lxc
LXC_NAME=waydroid
# Units, not comms. An earlier version matched truncated /proc/PID/comm by hand and
# silently checked only four of six: /proc/PID/comm cuts at 15 characters, so
# waydroid-restartd is "waydroid-restar" and waydroid-pwd-publish is "waydroid-pwd-pu",
# and both hand-written names overshot. Asking systemd for MainPID cannot drift.
DAEMON_UNITS="waydroid-container waydroid-restartd waydroid-wifid waydroid-btd \
waydroid-mediad waydroid-pwd-publish waydroid-shutdown-inhibitor"

RUNGS=5,30,120
WINDOW=60
RECOVERY=60
SLACK=30
DRY=0

usage() { sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --rungs)  RUNGS="$2"; shift 2 ;;
        --window) WINDOW="$2"; shift 2 ;;
        --recovery) RECOVERY="$2"; shift 2 ;;
        --slack)  SLACK="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[ "$(id -u)" -eq 0 ] || { echo "must run as root (cgroup.freeze and lxc-attach)" >&2; exit 1; }
[ -w "$CG/cgroup.freeze" ] || { echo "$CG/cgroup.freeze not writable -- container running?" >&2; exit 1; }

OUT=/var/tmp/freeze-probe-$(date +%Y%m%d-%H%M%S)
mkdir -p "$OUT"

# ------------------------------------------------------------------ primitives

now_ms()  { date +%s%3N; }
frozen_field() { awk '/^frozen /{print $2}' "$CG/cgroup.events" 2>/dev/null; }
usage_usec()   { awk '/^usage_usec/{print $2}' "$CG/cpu.stat" 2>/dev/null; }
procs()        { sort -n "$CG/cgroup.procs" 2>/dev/null; }

# pid + name. The host can read the container's /proc, and a pid-only diff is unreadable
# -- the 600s rung on 2026-10-03 needed a separate logcat dig just to learn that its six
# "lost" processes were AMS reaping empty ones on schedule.
procs_named() {
    local p
    for p in $(procs); do
        printf '%s\t%s\n' "$p" "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-60)"
    done
}
name_of() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | cut -c1-48; }
lxc_state()    { lxc-info -P "$LXC_PATH" -n "$LXC_NAME" -sH 2>/dev/null || echo "?"; }

# Run argv inside the container. Same mechanism waydroid-restartd uses, deliberately:
# `waydroid shell` is a python wrapper that prints a cosmetic errno 13 on every call.
attach() {
    local t="$1"; shift
    timeout "$t" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" --clear-env -- "$@" 2>/dev/null
}

# State letter per daemon. D is the one that matters: these six live OUTSIDE the frozen
# cgroup and talk to Android over binder, so a synchronous call into a frozen peer is
# where one would wedge. waydroid-sensord is covered as a child of waydroid-container.
daemon_states() {
    local u p st out=""
    for u in $DAEMON_UNITS; do
        p=$(systemctl show -p MainPID --value "$u" 2>/dev/null)
        [ -n "$p" ] && [ "$p" != 0 ] || continue
        st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
        out="$out ${u#waydroid-}/$p=${st:-gone}"
    done
    # waydroid-sensord has no unit of its own -- container_manager.py spawns it because
    # it is on PATH, so it is a child of waydroid-container.service. docs/40.
    for p in $(pgrep -x waydroid-sensor 2>/dev/null); do
        st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
        out="$out sensord/$p=${st:-gone}"
    done
    echo "${out# }"
}

# Hung lxc-attach children accumulate INSIDE the frozen cgroup: lxc-attach places the
# process it spawns into the container's cgroup, so every poller that retries during a
# freeze parks one more task there, and they all run at once on thaw. waydroid-restartd
# is the known poller -- see the lxc-info note at the top. This counts both ends.
attach_backlog() {
    local la
    la=$(pgrep -xc lxc-attach 2>/dev/null); la=${la:-0}   # prints 0 AND exits 1, as grep -c does
    printf 'pids.current=%s host_lxc_attach=%s' "$(cat "$CG/pids.current" 2>/dev/null)" "$la"
}

# DAMAGE is what the freeze broke. Deliberately narrow: an earlier, looser pattern
# matched "AnrHeartbeatWatchdog: Starting ANR heartbeat watchdog" -- an app starting its
# own watchdog -- and reported a clean 600s rung as damaged.
DAMAGE_PATTERNS='ANR in |am_anr|FATAL EXCEPTION|Watchdog: \*\*\*|WATCHDOG KILLING|has died|Force finishing|lowmemorykiller|failed to (freeze|thaw)'
# EXPECTED is Android catching up on work that came due while it could not run. These
# are the thaw herd, and they are the measurement, not a fault.
EXPECTED_PATTERNS='Killing [0-9]+:.*empty for|Start proc |Slow operation|Slow Looper'

# ------------------------------------------------------------ deadman + restore

DEADMAN=""
FROZE=0

deadman_start() {
    local secs="$1"
    # Detached, setsid'd, no fd kept to this script: survives us being SIGKILLed and
    # survives the ssh session dropping. It thaws unconditionally and then exits.
    setsid nohup sh -c "sleep $secs; echo 0 > $CG/cgroup.freeze 2>/dev/null" \
        >/dev/null 2>&1 </dev/null &
    DEADMAN=$!
    disown "$DEADMAN" 2>/dev/null || true
}

deadman_cancel() {
    [ -n "$DEADMAN" ] || return 0
    # setsid detaches into a new session; kill the process group to get the sleep too.
    kill -TERM -- "-$DEADMAN" 2>/dev/null || kill -TERM "$DEADMAN" 2>/dev/null || true
    DEADMAN=""
}

restore() {
    local rc=$?
    echo
    if [ "$FROZE" = 1 ]; then
        echo "--- restoring: thawing container ---"
        echo 0 > "$CG/cgroup.freeze" 2>/dev/null
        local i
        for i in $(seq 1 120); do
            [ "$(frozen_field)" = 0 ] && break
            sleep 0.5
        done
        echo "    frozen=$(frozen_field)  lxc=$(lxc_state)"
    fi
    deadman_cancel
    echo "results in $OUT"
    exit $rc
}
trap restore EXIT INT TERM HUP

# ----------------------------------------------------------------------- a rung

# Returns 0 clean, 1 damaged.
rung() {
    local hold="$1"
    local base_cpu
    local tag="rung-${hold}s"
    local d="$OUT/$tag"
    mkdir -p "$d"

    echo
    echo "=============================================================="
    echo "RUNG: hold ${hold}s   (baseline/recovery window ${WINDOW}s)"
    echo "=============================================================="

    # ---- baseline
    local android_ts
    android_ts=$(attach 15 /system/bin/date +'%m-%d %H:%M:%S.000')
    echo "  android clock: ${android_ts:-<no answer>}"
    procs > "$d/procs.before"
    procs_named > "$d/procs.before.named"
    local u0 t0
    u0=$(usage_usec); t0=$(now_ms)
    printf '  baseline %ss ... ' "$WINDOW"; sleep "$WINDOW"
    local u1 t1
    u1=$(usage_usec); t1=$(now_ms)
    base_cpu=$(awk -v a="$u0" -v b="$u1" -v ms=$((t1 - t0)) \
        'BEGIN{ if(ms<=0){print "-"; exit} printf "%.3f", (b-a)/10/ms }')
    echo "done  (container ${base_cpu}% of one core)"

    # ---- freeze
    local fz_start fz_done freeze_ms state_frozen dstates backlog_early backlog_late
    if [ "$DRY" = 1 ]; then
        echo "  DRY RUN: not writing cgroup.freeze"
        freeze_ms="-"; state_frozen="-"; dstates="-"
        backlog_early="-"; backlog_late="-"
        sleep "$hold"
    else
        deadman_start $((hold + SLACK))
        fz_start=$(now_ms)
        echo 1 > "$CG/cgroup.freeze" || { echo "  write failed" >&2; deadman_cancel; return 1; }
        FROZE=1
        # Poll. docs/43: the write is one atomic request but tasks stop at their next
        # safe point, and one in uninterruptible sleep delays the lot.
        local i
        for i in $(seq 1 240); do
            [ "$(frozen_field)" = 1 ] && break
            sleep 0.25
        done
        fz_done=$(now_ms)
        freeze_ms=$((fz_done - fz_start))
        if [ "$(frozen_field)" != 1 ]; then
            echo "  WARNING: never reported frozen within 60s (frozen=$(frozen_field))"
        fi
        state_frozen=$(lxc_state)
        echo "  frozen in ${freeze_ms}ms   lxc-info says: $state_frozen"

        # Mid-hold observations: the host daemons are outside this cgroup and talk to
        # Android over binder, so this is where a D-state would show up.
        sleep 2
        dstates=$(daemon_states)
        echo "  host daemons: $dstates"
        echo "$dstates" > "$d/daemons.during"

        backlog_early=$(attach_backlog)
        echo "  at freeze+2s:   $backlog_early"

        local remain=$((hold - 2))
        [ "$remain" -gt 0 ] && { printf '  holding %ss ... ' "$remain"; sleep "$remain"; echo "done"; }
        backlog_late=$(attach_backlog)
        echo "  at thaw-0s:     $backlog_late"
    fi

    # ---- thaw
    local th_start th_done thaw_ms
    if [ "$DRY" = 1 ]; then
        thaw_ms="-"
    else
        th_start=$(now_ms)
        echo 0 > "$CG/cgroup.freeze"
        local i
        for i in $(seq 1 240); do
            [ "$(frozen_field)" = 0 ] && break
            sleep 0.25
        done
        th_done=$(now_ms)
        thaw_ms=$((th_done - th_start))
        FROZE=0
        deadman_cancel
        echo "  thawed in ${thaw_ms}ms"
    fi

    # ---- recovery, in slices. A single average over the whole window says the herd
    # happened but not whether it ENDED, and "does it settle" is the question that
    # decides whether a long freeze is usable. Slice 1 is compared against baseline.
    local slices=$(( RECOVERY / WINDOW )); [ "$slices" -lt 1 ] && slices=1
    local r0 rt0 r1 rt1 rec_cpu="" sl i
    printf '  recovery %ss in %s slice(s) of %ss:\n' "$((slices * WINDOW))" "$slices" "$WINDOW"
    for i in $(seq 1 "$slices"); do
        r0=$(usage_usec); rt0=$(now_ms)
        sleep "$WINDOW"
        r1=$(usage_usec); rt1=$(now_ms)
        sl=$(awk -v a="$r0" -v b="$r1" -v ms=$((rt1 - rt0)) \
            'BEGIN{ if(ms<=0){print "-"; exit} printf "%.3f", (b-a)/10/ms }')
        printf '      slice %s: %s%% of one core   (x%s baseline)\n' "$i" "$sl" \
            "$(awk -v s="$sl" -v b="$base_cpu" 'BEGIN{ if(b+0>0) printf "%.1f", s/b; else print "-" }')"
        [ "$i" = 1 ] && rec_cpu=$sl
    done

    # ---- liveness: how fast does Android answer at all
    local l0 l1 boot
    l0=$(now_ms)
    boot=$(attach 30 /system/bin/getprop sys.boot_completed)
    l1=$(now_ms)
    echo "  liveness: getprop sys.boot_completed = '${boot:-<no answer>}' in $((l1 - l0))ms"

    # ---- casualties, by pid rather than by a count that moved
    procs > "$d/procs.after"
    procs_named > "$d/procs.after.named"
    local gone born p
    gone=$(comm -23 "$d/procs.before" "$d/procs.after" | tr '\n' ' ')
    born=$(comm -13 "$d/procs.before" "$d/procs.after" | tr '\n' ' ')
    echo "  procs: $(wc -l < "$d/procs.before") -> $(wc -l < "$d/procs.after")"
    for p in $gone; do
        # Already exited, so the name has to come from the pre-freeze snapshot.
        echo "    gone: $p  $(awk -F'\t' -v k="$p" '$1==k{print $2}' "$d/procs.before.named")"
    done
    for p in $born; do echo "    new:  $p  $(name_of "$p")"; done

    # ---- logcat over exactly this window
    local lc="$d/logcat.txt"
    if [ -n "$android_ts" ]; then
        attach 45 /system/bin/logcat -d -v threadtime -T "$android_ts" > "$lc" 2>/dev/null
    fi
    # -T is not universally accepted; fall back to a tail if it produced nothing.
    if [ ! -s "$lc" ]; then
        attach 45 /system/bin/logcat -d -v threadtime -t 600 > "$lc" 2>/dev/null
        echo "  (logcat -T empty; fell back to last 600 lines)"
    fi
    # grep -c PRINTS 0 and EXITS 1 when it matches nothing, so `|| echo 0` would append
    # a second zero and every later [ -gt ] would die on "0\n0". Default the empty case
    # instead -- that is the only one grep leaves unprinted.
    local hits lines
    hits=$(grep -Ec "$DAMAGE_PATTERNS" "$lc" 2>/dev/null); hits=${hits:-0}
    local expected
    expected=$(grep -Ec "$EXPECTED_PATTERNS" "$lc" 2>/dev/null); expected=${expected:-0}
    lines=$(wc -l < "$lc" 2>/dev/null); lines=${lines:-0}
    echo "  logcat: $lines lines, $hits DAMAGE, $expected expected-catch-up"
    if [ "$hits" -gt 0 ]; then
        echo "    --- damage ---"
        grep -E "$DAMAGE_PATTERNS" "$lc" | head -25 | sed 's/^/      /'
    fi
    if [ "$expected" -gt 0 ]; then
        echo "    --- catch-up (expected; this is the herd) ---"
        grep -E "$EXPECTED_PATTERNS" "$lc" | head -12 | sed 's/^/      /'
    fi

    # ---- restartd's own view
    journalctl -u waydroid-restartd --since "-$((WINDOW + RECOVERY + hold + 30))s" --no-pager -q \
        > "$d/restartd.txt" 2>/dev/null
    local rd
    rd=$(grep -c . "$d/restartd.txt" 2>/dev/null); rd=${rd:-0}
    echo "  restartd: $rd journal lines in window"
    [ "$rd" -gt 0 ] && sed 's/^/      /' "$d/restartd.txt" | head -10

    # ---- verdict
    {
        echo "hold_s=$hold freeze_ms=$freeze_ms thaw_ms=$thaw_ms"
        echo "lxc_state_while_frozen=$state_frozen"
        echo "baseline_pct_core=$base_cpu recovery_pct_core=$rec_cpu"
        echo "liveness_ms=$((l1 - l0)) boot_completed=${boot:-none}"
        echo "procs_before=$(wc -l < "$d/procs.before") procs_after=$(wc -l < "$d/procs.after")"
        echo "gone=$gone"
        echo "logcat_hits=$hits"
        echo "daemons_during=$dstates"
        echo "backlog_early=$backlog_early"
        echo "backlog_late=$backlog_late"
    } > "$d/summary.txt"

    # A lost process is only damage if Android did not say why it went. AMS reaps a
    # cached process once it has been empty past mMaxEmptyTime (30 min), and a freeze
    # pushes several over that line at once, so they all go in one burst at thaw --
    # measured twice on 2026-10-03, and every single casualty was one of these. Those
    # were due to die anyway; counting them as damage made a clean rung look broken.
    # The logcat pid is a CONTAINER pid and cgroup.procs gives HOST pids, so the match
    # has to be by process name, not by number.
    local damaged=0 unexplained="" p nm
    for p in $gone; do
        nm=$(awk -F'\t' -v k="$p" '$1==k{print $2}' "$d/procs.before.named" | awk '{print $1}')
        if [ -n "$nm" ] && grep -qE "Killing [0-9]+:${nm}[/ ]" "$lc" 2>/dev/null; then
            continue                      # AMS said why; expected
        fi
        unexplained="$unexplained $p(${nm:-?})"
    done
    if [ -n "${unexplained// }" ]; then
        echo "  UNEXPLAINED process loss:$unexplained"
        damaged=1
    elif [ -n "${gone// }" ]; then
        echo "  (all $(echo "$gone" | wc -w) lost processes accounted for by AMS empty-process reaping)"
    fi
    [ "$hits" -gt 0 ] && damaged=1
    [ -z "$boot" ] && damaged=1
    case "$dstates" in *=D*) damaged=1 ;; esac
    return $damaged
}

# -------------------------------------------------------------------------- run

echo "freeze-probe.sh -- $(date -Is)"
echo "  cgroup:   $CG"
echo "  tasks:    $(cat "$CG/pids.current" 2>/dev/null)   procs: $(wc -l < "$CG/cgroup.procs")"
echo "  lxc:      $(lxc_state)"
echo "  rungs:    $RUNGS   window: ${WINDOW}s   deadman slack: ${SLACK}s"
echo "  out:      $OUT"
[ "$DRY" = 1 ] && echo "  DRY RUN"

rc=0
for h in $(echo "$RUNGS" | tr ',' ' '); do
    if ! rung "$h"; then
        echo
        echo "*** RUNG ${h}s SHOWED DAMAGE -- stopping the escalation here. ***"
        echo "    See $OUT/rung-${h}s/ for the logcat and the process diff."
        rc=3
        break
    fi
    echo "  rung ${h}s: clean"
done

echo
echo "=============================================================="
for f in "$OUT"/rung-*/summary.txt; do
    [ -e "$f" ] || continue
    echo "--- $(basename "$(dirname "$f")")"
    sed 's/^/    /' "$f"
done
exit $rc
