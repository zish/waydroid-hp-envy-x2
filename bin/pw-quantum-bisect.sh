#!/bin/sh
# pw-quantum-bisect.sh -- how low a graph quantum will this host actually hold?
# (docs/56-pipewire-control.md's last open item; docs/44 has the latency budget.)
#
#     scp bin/pw-quantum-bisect.sh 10.42.0.137:/tmp/
#     ssh -t 10.42.0.137 'sudo sh /tmp/pw-quantum-bisect.sh'
#
# NOT read-only. This is the opposite of pw-audio-diag.sh: it deliberately forces
# the graph quantum down, one step at a time, to find the step where this host
# stops coping. docs/56 records 32 as known bad and 1024 as known good with
# nothing in between measured. This measures the in-between.
#
# WHY IT IS COPIED OVER RATHER THAN PIPED
#
# pipewire-test.sh and pw-audio-diag.sh are piped to `sudo sh -s`, which puts the
# script itself on stdin. This one has to ask a human how the audio SOUNDS, and a
# `read` against that stdin would eat its own source. So it is copied over and run
# with a tty, and it reads verdicts from /dev/tty explicitly. --auto skips the ear
# entirely and judges on xrun counters alone.
#
# WHY ONE STEP AT A TIME
#
# The counters and the ear disagree in both directions: a step can xrun without
# being audible over a HAL buffer that deep, and it can sound wrong while ERR
# stays flat, which is drift rather than deadline misses. So each step gets its
# own verdict before the next one starts. Batching the question -- playing three
# quanta and then asking which sounded worst -- is how you get a confident answer
# about the wrong step.
#
# RECOVERY, IF THIS SCRIPT DIES BADLY
#
# The trap below unforces on any normal exit, interrupt or hangup. If something
# kills it outright, a forced quantum is still not persisted -- it lives in
# PipeWire's settings metadata, so a reboot clears it. By hand:
#
#     XDG_RUNTIME_DIR=/run/user/1000 pw-metadata -n settings 0 clock.force-quantum 0

set -u

SETTLE=${SETTLE:-6}          # seconds to let the graph renegotiate before sampling
SAMPLE=${SAMPLE:-20}         # seconds of xrun accumulation per step
TOLERANCE=${TOLERANCE:-0}    # xruns per step that still count as clean
AUTO=0
for arg in "$@"; do
    case "$arg" in
        --auto) AUTO=1 ;;
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

say()   { printf '%s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()    { printf '  \033[32m  OK\033[0m  %s\n' "$1"; }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
inf()   { printf '        %s\n' "$1"; }

WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p')
[ -n "${WDUSER:-}" ] || WDUSER=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null \
    | head -1 | sed 's|^/home/\([^/]*\)/.*|\1|')
WDUSER=$(echo "${WDUSER:-}" | tr -d '[:space:]')
WDUID=$(id -u "$WDUSER" 2>/dev/null || echo "")
[ -n "${WDUID:-}" ] || { echo "cannot find the Waydroid session user" >&2; exit 1; }

asuser() {
    if [ "$(id -u)" = 0 ]; then
        runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    else
        env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    fi
}
setting() {
    asuser pw-metadata -n settings 0 2>/dev/null \
        | sed -n "s/.*key:'\\($1\\)'.*value:'\\([^']*\\)'.*/\\2/p" | head -1
}
force() { asuser pw-metadata -n settings 0 clock.force-quantum "$1" >/dev/null 2>&1; }

TMP=$(mktemp -d)
ORIGINAL=$(setting clock.force-quantum); ORIGINAL=${ORIGINAL:-0}
RESTORED=0
restore() {
    [ "$RESTORED" = 1 ] && return 0
    RESTORED=1
    force "$ORIGINAL"
    printf '\n\033[1mrestored clock.force-quantum to %s\033[0m\n' "$ORIGINAL"
    rm -rf "$TMP"
}
# A POSIX trap on INT runs the handler and then RESUMES the script, which walked
# an interrupted run straight into the Result block and had it announce a floor
# nobody had measured. These exit; the EXIT trap is the catch-all for normal ends.
trap 'restore; printf "\033[1minterrupted -- nothing concluded\033[0m\n"; exit 130' INT
trap 'restore; printf "\033[1mterminated -- nothing concluded\033[0m\n"; exit 143' TERM HUP
trap restore EXIT

# ---- xrun sampling, shared with pw-audio-diag.sh -----------------------------
xruns() {   # xruns(seconds) -> total ERR delta across all nodes
    asuser pw-top -b -n 1 > "$TMP/a" 2>/dev/null
    sleep "$1"
    asuser pw-top -b -n 1 > "$TMP/b" 2>/dev/null
    python3 - "$TMP/a" "$TMP/b" <<'PY'
import sys
def parse(path):
    err, ei, di = {}, None, None
    try: lines = open(path).read().splitlines()
    except OSError: return err
    for line in lines:
        f = line.split()
        if not f: continue
        if "ERR" in f and "ID" in f:
            ei, di = f.index("ERR"), f.index("ID"); continue
        if ei is None or len(f) <= ei: continue
        try: err[int(f[di])] = int(f[ei])
        except ValueError: pass
    return err
a, b = parse(sys.argv[1]), parse(sys.argv[2])
if not a or not b:
    print("-1")            # could not read the counters: never report this clean
else:
    print(sum(max(0, b[k] - a[k]) for k in b if k in a))
PY
}
playing() {
    asuser pw-dump 2>/dev/null | python3 -c '
import json, sys
try: objs = json.load(sys.stdin)
except Exception: print(0); raise SystemExit
n = 0
for o in objs:
    info = o.get("info") or {}
    p = info.get("props") or {}
    if o.get("type","").endswith("Node") and info.get("state") == "running" \
       and str(p.get("media.class","")).startswith(("Stream/Output/Audio","Audio/Sink")):
        n += 1
print(n)'
}

CFG=$(setting clock.quantum);     CFG=${CFG:-1024}
MIN=$(setting clock.min-quantum); MIN=${MIN:-32}
RATE=$(setting clock.rate);       RATE=${RATE:-48000}

printf '\033[1mQuantum step-down\033[0m  (MUTATES the graph; restores on exit)\n'
inf "session user $WDUSER, configured quantum $CFG, min $MIN, rate $RATE"
inf "force-quantum was $ORIGINAL when this started, and will be put back"
inf "settle ${SETTLE}s, sample ${SAMPLE}s per step, tolerance $TOLERANCE xruns"

if [ "$(playing)" -le 0 ]; then
    bad "no audio node is running. Start audio in Android and keep it playing:"
    inf "an idle graph misses no deadlines, so every step would pass and mean nothing."
    exit 1
fi
ok "audio is playing"

CANDIDATES=""
for v in 512 256 128 64 32; do
    [ "$v" -ge "$MIN" ] && [ "$v" -lt "$CFG" ] && CANDIDATES="$CANDIDATES $v"
done
[ -n "$CANDIDATES" ] || { bad "nothing to test between $MIN and $CFG"; exit 1; }
inf "ladder:$CANDIDATES"

if [ "$AUTO" = 0 ]; then
    if [ ! -r /dev/tty ]; then
        bad "no /dev/tty: run with 'ssh -t', or pass --auto to judge on counters alone"
        exit 1
    fi
    printf '\nEach step asks how it SOUNDS before moving on. Enter to continue, q to quit: '
    read _reply < /dev/tty || true
    case "${_reply:-}" in q|Q) exit 0 ;; esac
fi

LAST_GOOD=$CFG
BOUNDED=0        # 1 only once a step has actually FAILED, or the ladder ran out
ABORT=""         # set when the measurement broke down rather than the host
for q in $CANDIDATES; do
    ms=$(python3 -c "print('%.2f' % ($q * 1000.0 / $RATE))")
    head_ "$q frames  ·  $ms ms"
    force "$q"
    now=$(setting clock.force-quantum)
    if [ "${now:-0}" != "$q" ]; then
        bad "pw-metadata did not take: force-quantum reads '${now:-}'"
        ABORT="pw-metadata would not set the quantum"; break
    fi
    inf "forced; letting the graph settle ${SETTLE}s"
    sleep "$SETTLE"
    if [ "$(playing)" -le 0 ]; then
        bad "audio stopped during this step -- restarting it is part of the test"
        ABORT="audio stopped partway through"; break
    fi
    inf "sampling xruns for ${SAMPLE}s"
    delta=$(xruns "$SAMPLE")
    if [ "$delta" -lt 0 ]; then
        bad "could not read pw-top's ERR column; stopping rather than guessing"
        ABORT="pw-top's ERR column was unreadable"; break
    fi
    if [ "$delta" -gt "$TOLERANCE" ]; then
        bad "$delta xruns in ${SAMPLE}s -- deadline misses. $q is too low."
        BOUNDED=1; break
    fi
    ok "$delta xruns in ${SAMPLE}s"
    if [ "$AUTO" = 1 ]; then
        LAST_GOOD=$q
        continue
    fi
    printf '        does it still sound clean at %s frames? [y/n/q] ' "$q"
    read verdict < /dev/tty || verdict=q
    case "$verdict" in
        y|Y) ok "clean by ear at $q"; LAST_GOOD=$q ;;
        q|Q) ABORT="stopped at the operator's request"; break ;;
        *)   bad "audible at $q frames with ERR flat -- that is drift, not load"
             inf "worth recording separately: the counters said this step was fine."
             BOUNDED=1; break ;;
    esac
done
[ -n "$ABORT" ] || BOUNDED=1

head_ "Result"
if [ -n "$ABORT" ]; then
    bad "no conclusion: $ABORT"
    if [ "$LAST_GOOD" = "$CFG" ]; then
        inf "no step was confirmed, so nothing about this host was measured."
    else
        inf "$LAST_GOOD frames held, but the ladder stopped before anything below it"
        inf "was tried -- that is a lower bound on the answer, not the answer."
    fi
elif [ "$LAST_GOOD" = "$CFG" ]; then
    inf "nothing below $CFG held. $CFG stays the floor for this host."
else
    ms=$(python3 -c "print('%.2f' % ($LAST_GOOD * 1000.0 / $RATE))")
    saved=$(python3 -c "print('%.2f' % (($CFG - $LAST_GOOD) * 1000.0 / $RATE))")
    ok "lowest quantum that held: $LAST_GOOD frames ($ms ms), saving $saved ms vs $CFG"
    inf "docs/44 puts Android's HAL buffer at 85 ms, so that is $saved ms off a ~106 ms"
    inf "path -- worth having for host-side clients, inaudible for Android playback."
    inf "It is NOT persisted. To keep it, set clock.quantum in a pipewire.conf.d"
    inf "drop-in rather than forcing it; force-quantum dies with the next reboot."
fi
