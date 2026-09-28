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
xruns() {   # xruns(seconds) -> total ERR delta across all nodes, -1 if unreadable
    asuser pw-top -b -n 3 > "$TMP/a" 2>/dev/null
    sleep "$1"
    asuser pw-top -b -n 3 > "$TMP/b" 2>/dev/null
    python3 - "$TMP/a" "$TMP/b" <<'PY'
import sys
def blocks(path):
    """pw-top -b emits one block per iteration, and the FIRST is always
    placeholders -- state C, QUANT 0, RATE 0, no timings -- because nothing has
    been measured yet. So `-n 1` can only ever report ERR 0 for every node, which
    is a sampler that reports a clean host no matter what the host is doing. Ask
    for several iterations and read the LAST complete block."""
    out, cur, ei = [], None, None
    for line in open(path):
        f = line.split()
        if not f: continue
        if "ERR" in f and "ID" in f:
            if cur: out.append(cur)
            cur = {"err": {}, "live": 0}
            ei = dict((k, f.index(k)) for k in ("ID", "ERR", "RATE") if k in f)
            continue
        if cur is None or ei is None or "ERR" not in ei or len(f) <= ei["ERR"]:
            continue
        try: nid = int(f[ei["ID"]])
        except (ValueError, KeyError): continue
        try: cur["err"][nid] = int(f[ei["ERR"]])
        except ValueError: continue
        try:
            if f[0] == "R" and int(f[ei["RATE"]]) > 0: cur["live"] += 1
        except (ValueError, KeyError): pass
    if cur: out.append(cur)
    return out


def sample(path):
    """The last block, or None if no block shows a node actually processing."""
    b = blocks(path)
    if not b: return None
    last = b[-1]
    return last if last["live"] > 0 else None

a, b = sample(sys.argv[1]), sample(sys.argv[2])
if a is None or b is None:
    print("-1")            # could not read the counters: never report this clean
else:
    ae, be = a["err"], b["err"]
    print(sum(max(0, be[k] - ae[k]) for k in be if k in ae))
PY
}
# ---- the real instrument: does every client still get the quantum it asked for?
#
# xruns are NOT the signal for this failure, measured 2026-09-26: forcing 32 on
# bigtab01 made Android's audio plainly bad to a listener while the sink's ERR
# counter moved by single digits over minutes. The sink FOLLOWS a forced quantum;
# a pipewire-pulse client does not. Android's stream negotiates 256 and keeps
# delivering 256-frame buffers into whatever the graph is cycling at, and PipeWire
# resamples across the gap. That is a buffer-size mismatch, and the sink never
# misses a deadline, so ERR stays flat while it sounds wrong.
#
# So the verdict is divergence: any client whose quantum exceeds the graph's is
# being fed in pieces smaller than it asked for. xruns stay in the report as a
# secondary signal, because a step can do both.
diverged() {   # prints "<client-id> <client-quantum> <graph-quantum> <name>" per offender
    asuser pw-top -b -n 3 > "$TMP/q" 2>/dev/null
    asuser pw-dump > "$TMP/qd" 2>/dev/null
    python3 - "$TMP/q" "$TMP/qd" <<'PY'
import json, sys
rows, cur = [], None
for line in open(sys.argv[1]):
    f = line.split()
    if not f: continue
    if "ERR" in f and "ID" in f:
        cur = []; rows.append(cur)
        idx = dict((k, f.index(k)) for k in ("ID", "QUANT", "RATE") if k in f)
        continue
    if cur is None: continue
    try:
        if f[0] != "R": continue
        if int(f[idx["RATE"]]) <= 0: continue
        cur.append((int(f[idx["ID"]]), int(f[idx["QUANT"]])))
    except (ValueError, KeyError, IndexError): continue
live = rows[-1] if rows and rows[-1] else []
if not live:
    sys.exit(0)                      # nothing processing: caller treats as unreadable
cls, name = {}, {}
try:
    for o in json.load(open(sys.argv[2])):
        if not o.get("type", "").endswith("Node"): continue
        p = (o.get("info") or {}).get("props") or {}
        cls[o["id"]] = str(p.get("media.class", ""))
        name[o["id"]] = p.get("node.description") or p.get("node.name") or "?"
except Exception:
    pass
# the graph's quantum is the driver's: the sink, the one that is not a stream
graph = [q for i, q in live if not cls.get(i, "").startswith("Stream/")]
if not graph:
    sys.exit(0)
gq = min(graph)
for i, q in live:
    if cls.get(i, "").startswith("Stream/") and q > gq:
        print("%d %d %d %s" % (i, q, gq, name.get(i, "?")))
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
    # Divergence first: it is the signal that matches what a listener hears.
    off=$(diverged)
    if [ -n "$off" ]; then
        bad "$q starves a client that asked for more:"
        echo "$off" | while read -r cid cq gq cname; do
            inf "client $cid negotiated $cq, graph is at $gq -- $cname"
        done
        inf "PipeWire resamples across that gap. This is what sounds wrong, and it"
        inf "does NOT show up as an xrun. $q is below this host's usable floor."
        BOUNDED=1; break
    fi
    ok "every client is getting the quantum it asked for"
    inf "sampling xruns for ${SAMPLE}s (secondary signal)"
    delta=$(xruns "$SAMPLE")
    if [ "$delta" -lt 0 ]; then
        bad "could not read pw-top's ERR column; stopping rather than guessing"
        ABORT="pw-top's ERR column was unreadable"; break
    fi
    if [ "$delta" -gt "$TOLERANCE" ]; then
        bad "$delta xruns in ${SAMPLE}s -- deadline misses on top of it. $q is too low."
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
    ok "lowest quantum every client still got: $LAST_GOOD frames ($ms ms)"
    inf "That is $saved ms below the configured $CFG -- but read it as a FLOOR, not a"
    inf "saving. The floor is whatever the fussiest client negotiated, not a property"
    inf "of this host: the graph will follow a force well below it and report no"
    inf "xruns doing so, while the client goes on delivering its own buffer size and"
    inf "PipeWire resamples the difference. That is the part a listener hears."
    inf "Forcing a value the graph already negotiates on its own buys nothing."
    inf "It is NOT persisted either. To keep one, set clock.quantum in a"
    inf "pipewire.conf.d drop-in; force-quantum dies with the next reboot."
fi
