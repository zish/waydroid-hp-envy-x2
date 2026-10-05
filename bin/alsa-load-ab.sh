#!/bin/bash
# alsa-load-ab.sh -- does Waydroid's audio survive a busy machine? Run on the
# host, as root. Goal 5, docs/44-audio-alsa-backend.md.
#
#     ssh 10.42.0.137 'sudo bash -s' < bin/alsa-load-ab.sh
#     ssh 10.42.0.137 'sudo bash -s' -- --burners 4 --hold 60 < bin/alsa-load-ab.sh
#
# THE QUESTION
#
# The 2026-10-04 A/B measured both audio arms at IDLE and found direct ALSA
# clean: zero xruns, zero delayed writes, and a listener calling it a clean
# sine. It also found the thing that should make that result fragile. In the
# ALSA arm the card buffer is 1024 frames -- 21.3 ms, against PipeWire's 682.7
# ms -- and the thread feeding it, the audio HAL service's `writer`, runs
# SCHED_OTHER at nice -19, NOT SCHED_FIFO. A short buffer behind a
# non-realtime writer is the classic recipe for dropouts under load, and
# nothing had loaded it. That is what this measures.
#
# It is deliberately the same load docs/43 used to close goal 7: N spinners
# inside Android at nice 0, the shape of the real uncontained offender that
# document caught. The spinner and deadman mechanics are lifted from
# bin/cpumax-ab.sh for the same reason they exist there -- the subshells
# reparent to the container's init and outlive the lxc-attach that started
# them, so they need a cleanup that survives this script being SIGKILLed.
#
# WHAT IT READS, AND WHY NOT xruns
#
# PipeWire's xrun counters are the wrong instrument here: in the ALSA arm
# PipeWire is not in the path at all, so they stay at zero no matter how badly
# the audio breaks. The honest signals are Android-side:
#
#   Delayed writes      AudioFlinger's own count of HAL writes that blocked
#                       longer than the buffer should allow. The direct
#                       underrun proxy, and the one that matters.
#   Hal write jitter    std and extremes of how regularly snd_pcm_writei()
#                       returns, i.e. how steady the clock below the HAL is.
#                       This is what degraded 2.4x when PipeWire was removed,
#                       so it is the number most likely to move again.
#   Process time        AudioFlinger's own mixing cost; its max catches stalls
#                       that the average hides.
#
# HOW TO READ THE JITTER COLUMNS -- they do not all behave the same way, and
# two of them cannot fall. Measured across three runs: jit_std rose under load
# and came back down afterwards (0.354 -> 0.416 -> 0.362 in one run,
# 0.362 -> 0.418 in another), so it is responsive and usable per arm. But
# jit_min/max and pt_max were IDENTICAL in the loaded and recovered arms, which
# a genuinely recovering statistic would not be. They are absolute extremes
# that only ratchet upward for the life of the stream; the mean and std look to
# be exponentially weighted, which is why they decay and the extremes do not.
# So: compare jit_std ACROSS arms, read jit_min/max and pt_max as "the worst
# this stream has ever seen", and never read a sticky extreme as evidence that
# an arm is still degraded. All of them reset when the output thread enters
# standby, which happens whenever playback stops -- so values are comparable
# within a run and not between runs.
#   Timestamp disc      timestamp discontinuities. `err` is useless on this
#                       image (it is 100% of writes in both arms, a HAL
#                       omission) but `disc` is not, and it correlates with
#                       audible dropouts.
#   signal power        proof the arm was actually playing. docs/44 records a
#                       listening test that reported silence for an arm whose
#                       tone had run out, so no arm here is trusted without it.
#
# Every one is sampled per arm over --hold seconds and reported as a DELTA.
#
# IT INSISTS ON AUDIO PLAYING. Start it first:
#     ssh HOST 'sudo sh -s' -- play < bin/audio-tone.sh

set -uo pipefail

BURNERS=4
HOLD=60
CARD=1
DEV=0

while [ $# -gt 0 ]; do
    case "$1" in
        --burners) BURNERS=$2; shift 2 ;;
        --hold)    HOLD=$2;    shift 2 ;;
        --card)    CARD=$2;    shift 2 ;;
        --dev)     DEV=$2;     shift 2 ;;
        *) echo "usage: $0 [--burners N] [--hold SECS] [--card N] [--dev N]" >&2; exit 2 ;;
    esac
done

LXC_PATH=/var/lib/waydroid/lxc
LXC_NAME=waydroid
PIDFILE=/data/local/tmp/.alsa-load-ab.pids
PCM=/proc/asound/card$CARD/pcm${DEV}p/sub0

head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
kv()    { printf '  %-30s %s\n' "$1" "$2"; }
no()    { printf '  \033[31m%-30s\033[0m %s\n' "$1" "$2"; }

attach() { local t="$1"; shift
    timeout "$t" lxc-attach -P "$LXC_PATH" -n "$LXC_NAME" --clear-env -- "$@" 2>/dev/null; }

ash() { attach 30 /system/bin/sh -c "$1"; }

# ------------------------------------------------------------------ load + cleanup

BURNING=0
DEADMAN=""

burners_start() {
    attach 30 /system/bin/sh -c \
        "rm -f $PIDFILE; i=0; while [ \$i -lt $BURNERS ]; do (while :; do :; done) & echo \$! >> $PIDFILE; i=\$((i+1)); done" \
        >/dev/null
    BURNING=1
    sleep 1
    local live
    live=$(attach 20 /system/bin/sh -c \
        "n=0; while read p; do [ -d /proc/\$p ] && n=\$((n+1)); done < $PIDFILE; echo \$n")
    kv "spinners live inside Android" "${live:-0}/$BURNERS"
    [ "${live:-0}" -gt 0 ] || { no "no spinners started" "the A/B would be meaningless"; return 1; }
}

burners_stop() {
    [ "$BURNING" = 1 ] || return 0
    attach 30 /system/bin/sh -c \
        "[ -f $PIDFILE ] && while read p; do kill -9 \$p 2>/dev/null; done < $PIDFILE; rm -f $PIDFILE" \
        >/dev/null
    BURNING=0
}

deadman_start() {
    # Kills the spinners with no reference to this script, so it survives this
    # process dying by any means including SIGKILL or the ssh session dropping.
    local secs="$1"
    setsid nohup sh -c "sleep $secs
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
    printf '\n--- restoring ---\n'
    burners_stop && echo "    spinners killed"
    deadman_cancel
    exit $rc
}
trap restore EXIT INT TERM

# ------------------------------------------------------------------ sampling

af_out() { ash 'dumpsys media.audio_flinger' | sed -n '/^Output thread/,/^Input thread/p'; }

# Signal power proves the arm was playing. Three shapes are required to find a
# history line, because the section also carries a setParameters log whose
# lines start with a date ("... UID 10181, 1 KVP received") and a
# "Master balance: 0.000000" line, each of which matches a looser test and each
# of which yields a plausible wrong number. See docs/44.
sig_power() {
    awk '/Signal power history/ { f = 1; next }
         f && $1 ~ /^[0-9][0-9]-[0-9][0-9]$/ && $2 ~ /:$/ &&
              $3 ~ /^-?[0-9]+\.[0-9]+$/ { v = $3 }
         END { print (v == "" ? "unavailable" : v) }'
}

sample() {  # $1: file to write
    local af; af=$(af_out)
    {
        echo "DELAYED $(echo "$af"  | sed -n 's/^ *Delayed writes: *\([0-9]*\).*/\1/p' | head -1)"
        echo "WRITES  $(echo "$af"  | sed -n 's/^ *Total writes: *\([0-9]*\).*/\1/p'   | head -1)"
        echo "DISC    $(echo "$af"  | grep -oE 'disc=[0-9]+' | head -1 | cut -d= -f2)"
        echo "JSTD    $(echo "$af"  | sed -n 's/.*Hal write jitter.*std=\([0-9.e-]*\).*/\1/p' | head -1)"
        echo "JMIN    $(echo "$af"  | sed -n 's/.*Hal write jitter.*min=\([0-9.e-]*\).*/\1/p' | head -1)"
        echo "JMAX    $(echo "$af"  | sed -n 's/.*Hal write jitter.*max=\([0-9.e-]*\).*/\1/p' | head -1)"
        echo "PTMAX   $(echo "$af"  | sed -n 's/.*Process time ms stats.*max=\([0-9.e-]*\).*/\1/p' | head -1)"
        echo "PTAVE   $(echo "$af"  | sed -n 's/.*Process time ms stats: *ave=\([0-9.e-]*\).*/\1/p' | head -1)"
        echo "SIG     $(echo "$af"  | sig_power)"
        echo "AVAILMX $(sed -n 's/^avail_max *: *//p' "$PCM/status" 2>/dev/null | head -1)"
        echo "STATE   $(head -1 "$PCM/status" 2>/dev/null)"
        # Proof the arm was what it claims to be. "0 delayed writes under load"
        # is worthless unless the machine was actually busy, and the spinner
        # liveness check only proves four processes exist -- not that they are
        # getting CPU or that anything else is being starved. These two make the
        # load itself a measured quantity: BUSY is host-wide non-idle jiffies,
        # PSI is cumulative microseconds of stall from /proc/pressure/cpu.
        echo "CPUBUSY $(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t-$5-$6}' /proc/stat)"
        echo "CPUTOT  $(awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; print t}' /proc/stat)"
        echo "PSI     $(sed -n 's/^some .*total=\([0-9]*\).*/\1/p' /proc/pressure/cpu 2>/dev/null | head -1)"
    } > "$1"
}

g() { sed -n "s/^$2  *//p" "$1" | head -1; }

# AudioFlinger's jitter and process-time figures are RUNNING statistics over the
# life of the stream, not windowed, so a delta on them is meaningless -- the
# arm's own value is what gets reported, and the drift between the two reads is
# what shows whether the arm was stable while it was held.
arm() {  # $1: label
    local label="$1" a=/tmp/.alb.a b=/tmp/.alb.b
    sample "$a"
    sleep "$HOLD"
    sample "$b"

    local st; st=$(g "$b" STATE)
    if [ "$st" != "state: RUNNING" ]; then
        no "$label" "card is '$st' -- nothing was playing, arm discarded"
        return 1
    fi
    local sig; sig=$(g "$b" SIG)

    local dw dd tw
    dw=$(( $(g "$b" DELAYED) - $(g "$a" DELAYED) ))
    dd=$(( $(g "$b" DISC)    - $(g "$a" DISC) ))
    tw=$(( $(g "$b" WRITES)  - $(g "$a" WRITES) ))

    # Host busy% over the window, and PSI stall accumulated during it.
    local busy psi
    busy=$(awk "BEGIN{d=$(g "$b" CPUTOT)-$(g "$a" CPUTOT);
                      if(d>0) printf \"%.0f%%\", 100*($(g "$b" CPUBUSY)-$(g "$a" CPUBUSY))/d;
                      else printf \"?\"}")
    psi=$(awk "BEGIN{printf \"%.1f\", ($(g "$b" PSI)-$(g "$a" PSI))/1000000}")

    printf '  %-11s %-6s %-7s %-8s %-7s %-8s %-9s %-9s %s\n' \
        "$label" "$busy" "${psi}s" "$dw" "$dd" "$tw" \
        "$(g "$b" JSTD)" "$(g "$b" JMIN)/$(g "$b" JMAX)" "$sig"
    printf '%s\n' "$label $dw $dd $tw $busy" >> /tmp/.alb.summary
}

# ------------------------------------------------------------------ run

head_ "Audio under load -- $BURNERS spinners at nice 0, ${HOLD}s per arm"

# Which arm of the audio A/B is live, by who holds the PCM -- not by config.
T=$(sed -n 's/^owner_pid *: *//p' "$PCM/status" 2>/dev/null)
if [ -z "${T:-}" ]; then
    no "nothing holds hw:$CARD,$DEV" "start audio first: bin/audio-tone.sh play"
    exit 1
fi
P=$(grep -a '^Tgid:' "/proc/$T/status" 2>/dev/null | awk '{print $2}')
OWNER=$(tr -d '\0' < "/proc/${P:-$T}/cmdline" 2>/dev/null)
case "$OWNER" in
    *android.hardware.audio*) AUDIO_ARM=alsa  ;;
    *pipewire*)               AUDIO_ARM=pulse ;;
    *)                        AUDIO_ARM="other:$OWNER" ;;
esac
kv "audio arm" "$AUDIO_ARM"
kv "hw:$CARD,$DEV held by" "$OWNER"
kv "card buffer" "$(sed -n 's/^buffer_size: *//p' "$PCM/hw_params" 2>/dev/null) frames"
kv "cpus" "$(nproc)"

# The writer thread's scheduling policy is the whole premise of this test, so it
# is reported rather than assumed.
kv "writer thread policy" "$(chrt -p "$T" 2>/dev/null | sed -n 's/.*policy: //p') \
nice $(awk '{print $19}' "/proc/$T/stat" 2>/dev/null)"

rm -f /tmp/.alb.summary
deadman_start $(( HOLD * 3 + 120 ))

printf '\n  %-11s %-6s %-7s %-8s %-7s %-8s %-9s %-9s %s\n' \
    arm busy psi delayed disc writes jit_std jit_min/max dBFS
printf '  %s\n' "---------------------------------------------------------------------------------------------"

arm idle || true
burners_start || { no "aborting" "no load to measure"; exit 1; }
arm loaded || true
burners_stop
echo "    spinners killed"
sleep 3
arm recovered || true

head_ "Verdict"
D_IDLE=$(awk '$1=="idle"    {print $2}' /tmp/.alb.summary)
D_LOAD=$(awk '$1=="loaded"  {print $2}' /tmp/.alb.summary)
W_IDLE=$(awk '$1=="idle"    {print $4}' /tmp/.alb.summary)
W_LOAD=$(awk '$1=="loaded"  {print $4}' /tmp/.alb.summary)
B_IDLE=$(awk '$1=="idle"   {print $5}' /tmp/.alb.summary)
B_LOAD=$(awk '$1=="loaded" {print $5}' /tmp/.alb.summary)
kv "host busy idle -> load" "${B_IDLE:-?} -> ${B_LOAD:-?}"
# A loaded arm that did not actually load the box proves nothing, so say so
# rather than letting a clean result stand on an unloaded machine.
case "${B_LOAD:-0%}" in
    100%|9[0-9]%|8[0-9]%) : ;;
    *) no "load not established" "the 'loaded' arm only reached ${B_LOAD:-?} busy -- a clean result here is not evidence" ;;
esac
if [ -n "${D_LOAD:-}" ]; then
    if [ "${D_LOAD:-0}" -gt 0 ]; then
        no "delayed writes under load" "$D_LOAD in ${HOLD}s (idle: ${D_IDLE:-?})"
        echo "        The short-buffer/non-realtime-writer prediction holds: this arm"
        echo "        drops audio under load. Fix the HAL's scheduling before using it."
    else
        kv "delayed writes under load" "0 in ${HOLD}s -- the arm held"
    fi
    # A write rate that falls is a stall the delayed-write counter can miss:
    # 48000/1024 = ~46.9 writes/s is the rate a healthy 48 kHz stream must sustain.
    if [ -n "${W_LOAD:-}" ] && [ -n "${W_IDLE:-}" ] && [ "$W_IDLE" -gt 0 ]; then
        kv "HAL write rate idle -> load" \
           "$(awk "BEGIN{printf \"%.2f/s -> %.2f/s\", $W_IDLE/$HOLD, $W_LOAD/$HOLD}")"
    fi
fi
rm -f /tmp/.alb.a /tmp/.alb.b /tmp/.alb.summary
