#!/bin/bash
# jank-ab.sh -- measure Android's OWN UI smoothness while something hammers the box.
# Run on the host, as root. Needs a human scrolling the target app for the window.
#
# WHY THIS EXISTS
#
# docs/43-app-freezer.md step 4: "demonstrate the jank before building the v2 rewrite".
# Everything else in that note is now answered. The battery case is closed twice over, and
# the 2026-10-03 cpu.max A/B killed the host-side case outright -- the HOST stays
# responsive (p99 wake 0.1 ms) with Android saturating all four CPUs, so "Waydroid must
# not make the host janky" is not a problem that exists here.
#
# What was never measured is the other direction: Android's own frame timing, from inside,
# while the missing cgroups leave every process at nice 0 in 0::/ with no top-app cpuset,
# no uclamp.min floor and no background throttling. That is the last argument for
# rewriting cgroups.json and task_profiles.json to the v2 layout, and this is the
# instrument that decides it.
#
# WHY gfxinfo AND NOT A STOPWATCH
#
# `dumpsys gfxinfo <pkg>` is Android's own frame accounting: every frame the app rendered,
# how long each took, and which missed the vsync deadline. "Janky frames" is the platform's
# own verdict, not an observer's impression, and the percentiles say whether the badness is
# a steady drag or rare spikes -- which matters, because a 99th percentile of 200 ms with a
# clean 50th is a stutter you SEE, while an evenly raised 50th is one you only measure.
#
# THE ARM IS VOID IF NOBODY SCROLLED
#
# gfxinfo counts rendered frames. A still screen renders none, and zero frames means zero
# janky frames, which reads as a perfect result. The script therefore refuses to report a
# window with implausibly few frames rather than letting it look like a pass.
#
# LOADS
#   none        control arm.
#   bg-dexopt   `cmd package bg-dexopt-job` -- the REAL background dexopt job, the one that
#               took this machine to 91.6% busy on 2026-09-12. Not a synthetic stand-in.
#               It cannot be cleanly aborted; it runs until it is done.
#   compile     forced bg-dexopt-reason recompile of a few large packages. Shorter and
#               bounded, same dex2oat path.
#   spin        four nice-0 busy loops inside Android. Not realistic -- it is the ceiling,
#               for showing what the absent background throttling would be protecting
#               against.
#
# Usage:  jank-ab.sh --label NAME [options]
#   --pkg PKG       package to measure (default com.android.settings)
#   --seconds N     measurement window (default 30)
#   --load WHICH    none|bg-dexopt|compile|spin (default none)
#   --min-frames N  refuse to report fewer than this many frames (default 60)
#   --lead N        seconds to wait before the counters are reset, so a human has time
#                   to start scrolling (default 10). The first attempt on 2026-10-04
#                   rendered 3 frames because measurement began while the operator was
#                   still reading the instruction.
#   --drive         scroll synthetically with `input swipe` instead of asking a human.
#                   STRONGLY PREFERRED for an A/B. A human cannot deliver the same
#                   stimulus twice -- the 2026-10-04 hand-scrolled arms rendered 1122 and
#                   850 frames for nominally identical effort, so part of any difference
#                   between them was just how hard someone was flicking. The driver costs
#                   CPU of its own (each `input` spawns an app_process JVM), but it costs
#                   the SAME in every arm, which is what an A/B needs. Its cost is
#                   reported separately so it is never mistaken for the load under test.
#   -h, --help      this text
set -uo pipefail

CG=/sys/fs/cgroup/lxc.payload.waydroid
LXC_PATH=/var/lib/waydroid/lxc
LXC_NAME=waydroid
PIDFILE=/data/local/tmp/jank-ab-burn.pids
BIGPKGS="com.android.chrome com.google.android.gms com.linkedin.android"

PKG=com.android.settings
SECONDS_WIN=30
LOAD=none
LABEL=""
MINFRAMES=60
LEAD=10
DRIVE=0
DRIVEPID=/data/local/tmp/jank-ab-drive.pid

usage() { sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --pkg)        PKG="$2"; shift 2 ;;
        --seconds)    SECONDS_WIN="$2"; shift 2 ;;
        --load)       LOAD="$2"; shift 2 ;;
        --label)      LABEL="$2"; shift 2 ;;
        --min-frames) MINFRAMES="$2"; shift 2 ;;
        --lead)       LEAD="$2"; shift 2 ;;
        --drive)      DRIVE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done
[ -n "$LABEL" ] || { echo "--label is required" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "must run as root (lxc-attach)" >&2; exit 1; }

OUT=/var/tmp/jank-ab-$(date +%Y%m%d-%H%M%S)-$LABEL
mkdir -p "$OUT"

attach() { local t="$1"; shift
    timeout "$t" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" --clear-env -- "$@" 2>/dev/null; }

usage_usec() { awk '/^usage_usec/{print $2}' "$CG/cpu.stat"; }
psi_cpu()    { awk '/^some/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); print $i}}' /proc/pressure/cpu; }

# ---------------------------------------------------------------- per-process CPU

# utime+stime per container process, so the window can be attributed. Same method as
# docs/43's own tables: ticks are 10 ms, so over W seconds one core is W*100 ticks and the
# percentage is ticks/W. docs/43 records getting this wrong by exactly 10x once.
snap_procs() {
    local p
    for p in $(cat "$CG/cgroup.procs" 2>/dev/null); do
        awk -v pid="$p" '{print pid, $14 + $15}' "/proc/$p/stat" 2>/dev/null
    done
}

# ------------------------------------------------------------------- load control

LOADED=0
DEADMAN=""

load_start() {
    case "$LOAD" in
        none) return 0 ;;
        spin)
            attach 30 /system/bin/sh -c \
              "rm -f $PIDFILE; i=0; while [ \$i -lt 4 ]; do (while :; do :; done) & echo \$! >> $PIDFILE; i=\$((i+1)); done" >/dev/null
            LOADED=1
            setsid nohup sh -c "sleep $((SECONDS_WIN + 180))
                timeout 30 lxc-attach -P $LXC_PATH -n $LXC_NAME --clear-env -- /system/bin/sh -c \
                  '[ -f $PIDFILE ] && while read p; do kill -9 \$p 2>/dev/null; done < $PIDFILE; rm -f $PIDFILE' >/dev/null 2>&1" \
                >/dev/null 2>&1 </dev/null &
            DEADMAN=$!; disown "$DEADMAN" 2>/dev/null || true
            local live
            live=$(attach 20 /system/bin/sh -c "n=0; while read p; do [ -d /proc/\$p ] && n=\$((n+1)); done < $PIDFILE; echo \$n")
            echo "  load: ${live:-0}/4 spinners live"
            ;;
        bg-dexopt)
            # The real job. Fire and forget: it is not cleanly abortable, and waiting for
            # it would defeat the point of measuring DURING it.
            setsid nohup sh -c "timeout 900 lxc-attach -P $LXC_PATH -n $LXC_NAME --clear-env -- \
                /system/bin/cmd package bg-dexopt-job >/dev/null 2>&1" >/dev/null 2>&1 </dev/null &
            LOADED=1
            echo "  load: background dexopt job started (real bg-dexopt-job)"
            ;;
        compile)
            setsid nohup sh -c "for p in $BIGPKGS; do
                timeout 600 lxc-attach -P $LXC_PATH -n $LXC_NAME --clear-env -- \
                  /system/bin/cmd package compile -r bg-dexopt -f \$p >/dev/null 2>&1
              done" >/dev/null 2>&1 </dev/null &
            LOADED=1
            echo "  load: forced bg-dexopt recompile of: $BIGPKGS"
            ;;
        *) echo "unknown --load: $LOAD" >&2; exit 2 ;;
    esac
}

# Long swipes rather than many short ones: `input` is a Java app and each invocation pays
# an app_process start, so a 1200 ms drag renders a whole fling for one spawn instead of
# paying JVM startup per frame.
driver_start() {
    local secs="$1"
    attach 30 /system/bin/sh -c \
      "nohup sh -c 'echo \$\$ > $DRIVEPID; end=\$((\$(date +%s) + $secs));
        while [ \$(date +%s) -lt \$end ]; do
          input swipe 950 850 950 250 1200 >/dev/null 2>&1
          input swipe 950 250 950 850 1200 >/dev/null 2>&1
        done' >/dev/null 2>&1 &" >/dev/null
    echo "  driver: synthetic swipes for ${secs}s"
}

driver_stop() {
    [ "$DRIVE" = 1 ] || return 0
    attach 30 /system/bin/sh -c \
      "[ -f $DRIVEPID ] && kill -9 \$(cat $DRIVEPID) 2>/dev/null; rm -f $DRIVEPID;
       for p in \$(pidof input 2>/dev/null); do kill -9 \$p 2>/dev/null; done" >/dev/null
}

load_stop() {
    [ "$LOADED" = 1 ] || return 0
    case "$LOAD" in
        spin) attach 30 /system/bin/sh -c \
                "[ -f $PIDFILE ] && while read p; do kill -9 \$p 2>/dev/null; done < $PIDFILE; rm -f $PIDFILE" >/dev/null
              echo "    spinners killed" ;;
        *)    echo "    NOTE: dexopt was left to finish on its own; it is not abortable." ;;
    esac
    LOADED=0
}

restore() {
    local rc=$?
    driver_stop
    load_stop
    [ -n "$DEADMAN" ] && { kill -TERM -- "-$DEADMAN" 2>/dev/null || kill -TERM "$DEADMAN" 2>/dev/null; }
    exit $rc
}
trap restore EXIT INT TERM HUP

# -------------------------------------------------------------------------- run

echo "jank-ab.sh [$LABEL] -- $(date -Is)"
echo "  package: $PKG    window: ${SECONDS_WIN}s    load: $LOAD"

if ! attach 20 /system/bin/pidof "$PKG" >/dev/null; then
    echo "  ERROR: $PKG is not running. Open it and put it in the foreground first." >&2
    exit 1
fi

load_start
[ "$LOAD" = none ] || sleep 3          # let the load actually ramp before resetting counters
[ "$DRIVE" = 1 ] && driver_start $((LEAD + SECONDS_WIN + 5))

if [ "$LEAD" -gt 0 ]; then
    echo "  lead-in ${LEAD}s: start scrolling NOW, counters reset at the end of it"
    i=$LEAD
    while [ "$i" -gt 0 ]; do
        printf '\r    measurement starts in %2ss ' "$i"
        sleep 1; i=$((i - 1))
    done
    printf '\r                                  \r'
fi

attach 25 /system/bin/dumpsys gfxinfo "$PKG" reset >/dev/null
snap_procs > "$OUT/proc.before"
u0=$(usage_usec); t0=$(date +%s%3N)

echo "  >>> SCROLL NOW -- sampling ${SECONDS_WIN}s <<<"
sleep "$SECONDS_WIN"

u1=$(usage_usec); t1=$(date +%s%3N)
snap_procs > "$OUT/proc.after"
attach 30 /system/bin/dumpsys gfxinfo "$PKG" > "$OUT/gfxinfo.txt"
psi=$(psi_cpu)
driver_stop
load_stop

# ------------------------------------------------------------------------ report

g="$OUT/gfxinfo.txt"
val() { grep -m1 "$1" "$g" 2>/dev/null | sed "s/.*$1[: ]*//" | tr -d '\r'; }
frames=$(grep -m1 "Total frames rendered:" "$g" | awk '{print $NF}')
frames=${frames:-0}

echo
echo "  ---- $LABEL ----"
if [ "$frames" -lt "$MINFRAMES" ]; then
    echo "  VOID ARM: only $frames frames rendered (need >= $MINFRAMES)."
    echo "  Nothing was scrolling, so 'no jank' here would mean nothing. Re-run it."
    [ "$DRIVE" = 1 ] && echo "  (--drive was on, so this is an instrument fault, not a missed cue.)"
    exit 4
fi

janky=$(grep -m1 "Janky frames:" "$g" | sed 's/.*Janky frames: *//')
echo "  frames rendered   $frames"
echo "  janky frames      ${janky:-?}"
for k in "50th percentile" "90th percentile" "95th percentile" "99th percentile"; do
    printf '  %-17s %s\n' "$k" "$(grep -m1 "$k" "$g" | awk '{print $NF}')"
done
for k in "Number Missed Vsync" "Number High input latency" "Number Slow UI thread" \
         "Number Slow bitmap uploads" "Number Slow issue draw commands" "Number Frame deadline missed"; do
    printf '  %-32s %s\n' "${k#Number }" "$(grep -m1 "$k" "$g" | awk '{print $NF}')"
done

ms=$((t1 - t0))
echo
printf '  container CPU     %s%% of one core      host PSI some avg10 %s\n' \
    "$(awk -v a="$u0" -v b="$u1" -v m="$ms" 'BEGIN{printf "%.1f", (b-a)/10/m}')" "$psi"
echo "  top container processes this window (% of one core):"
join "$OUT/proc.before" "$OUT/proc.after" 2>/dev/null \
  | awk -v w=$((ms / 1000)) '{d=$3-$2; if(d>0 && w>0) printf "%.2f %s\n", d/w, $1}' \
  | sort -rn | head -8 | while read -r pct pid; do
        nm=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-40)
        adj=$(cat "/proc/$pid/oom_score_adj" 2>/dev/null)
        ni=$(awk '{print $19}' "/proc/$pid/stat" 2>/dev/null)
        printf '      %6s%%  adj=%-6s nice=%-4s %s\n' "$pct" "${adj:-?}" "${ni:-?}" "${nm:-<gone>}"
    done
echo
echo "  raw: $OUT/gfxinfo.txt"
