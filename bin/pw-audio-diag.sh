#!/bin/sh
# pw-audio-diag.sh -- why does Android's audio sound scratchy/robotic?
# (companion to bin/pipewire-test.sh, docs/56-pipewire-control.md).
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/pw-audio-diag.sh
#
# READ-ONLY. Unlike pipewire-test.sh, which creates and destroys one MIDI link,
# this makes NO change of any kind: no link, no volume, no metadata, no profile.
# Every PipeWire tool it runs is an enumerator.
#
# It is looking for an ACCUMULATING fault, because the reported symptom is not
# "wrong" but "getting worse" -- and a wrong gain or a wrong profile is static.
# So the decisive leg is leg 6, which samples each node's xrun counter twice and
# reports the DELTA. A single snapshot of a cumulative counter cannot tell a host
# that xruns constantly from one that xrun'd once at boot and has been clean since.
#
# WHY IT INSISTS ON AUDIO PLAYING
#
# An idle graph misses no deadlines, so leg 6 against a silent host reports zero
# and means nothing. docs/56 already recorded one vacuous probe (it tested Python
# None and so was blind to the JSON null it existed to catch); this one refuses to
# produce a clean number it has not earned. Start audio in Android first.

set -u

GAP=${GAP:-45}
pass=0; warn=0; skip=0

ok()    { printf '  \033[32m  OK\033[0m  %s\n' "$1"; pass=$((pass+1)); }
hm()    { printf '  \033[31mLOOK\033[0m  %s\n' "$1"; warn=$((warn+1)); }
na()    { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
inf()   { printf '        %s\n' "$1"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p')
[ -n "${WDUSER:-}" ] || WDUSER=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null \
    | head -1 | sed 's|^/home/\([^/]*\)/.*|\1|')
WDUSER=$(echo "${WDUSER:-}" | tr -d '[:space:]')
WDUID=$(id -u "$WDUSER" 2>/dev/null || echo "")

# pgrep -f can match this script's own command line, depending on how it was
# invoked. Count PIDs and drop our own and our parent's, so a leg that reports
# "1 leftover" is reporting a leftover and not itself.
countproc() {
    pgrep -f "$1" 2>/dev/null | grep -vx -e "$$" -e "${PPID:-0}" | wc -l
}

asuser() {
    if [ "$(id -u)" = 0 ]; then
        runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    else
        env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    fi
}

printf '\033[1mPipeWire audio-quality diagnostic\033[0m  (read-only)\n'
if [ -z "${WDUID:-}" ]; then
    printf '  \033[31mcannot find the Waydroid session user; aborting\033[0m\n'; exit 1
fi
inf "session user $WDUSER (uid $WDUID), sampling gap ${GAP}s"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
asuser pw-dump > "$TMP/dump.json" 2>/dev/null || true
if [ ! -s "$TMP/dump.json" ]; then
    printf '  \033[31mpw-dump produced nothing -- is PipeWire up for %s?\033[0m\n' "$WDUSER"; exit 1
fi

head_ "1. Host and units"
inf "uptime:$(uptime | sed 's/.*up/ up/')"
for unit in pipewire pipewire-pulse wireplumber; do
    if [ "$(id -u)" = 0 ]; then
        state=$(systemctl --user "--machine=$WDUSER@" is-active "$unit" 2>/dev/null || echo unknown)
    else
        state=$(systemctl --user is-active "$unit" 2>/dev/null || echo unknown)
    fi
    [ "$state" = active ] && ok "$unit is active" || hm "$unit is $state"
done

head_ "2. Leftover daemons from the dev process"
# waydroid-pwd has no pidfile and no single-instance guard, sets SO_REUSEADDR and
# binds a SPECIFIC address, so an instance on 127.0.0.1 and one on 192.168.240.1
# never collide on 7713. Every dev iteration could have left another one live, and
# each holds a permanent `pw-dump -m` client that PipeWire wakes on every event.
n_pwd=$(countproc 'waydroid-pwd')
n_mon=$(countproc 'pw-dump -m')
if [ "$n_pwd" -le 1 ]; then ok "waydroid-pwd instances: $n_pwd"
else hm "waydroid-pwd instances: $n_pwd -- expected at most 1"; fi
if [ "$n_mon" -le 1 ]; then ok "pw-dump -m monitors: $n_mon"
else hm "pw-dump -m monitors: $n_mon -- each is a live client on the graph"; fi
[ "$n_pwd" -gt 0 ] && pgrep -af 'waydroid-pwd' 2>/dev/null | while read -r line; do
    pid=${line%% *}
    inf "pid $pid started $(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//') :: ${line#* }"
done
for stray in pw-loopback 'pipewire -c' pw-cat pacat; do
    c=$(countproc "$stray")
    [ "$c" -gt 0 ] && hm "$c process(es) matching '$stray' still running" || true
done

head_ "3. Graph clock settings"
asuser pw-metadata -n settings 0 2>/dev/null | sed -n 's/.*key:.\([^'"'"']*\).*value:.\([^'"'"']*\).*/\1 = \2/p' \
    | grep -i 'quantum\|rate' > "$TMP/settings" || true
[ -s "$TMP/settings" ] && sed 's/^/        /' "$TMP/settings"
fq=$(sed -n 's/^clock\.force-quantum = //p' "$TMP/settings" | head -1)
fr=$(sed -n 's/^clock\.force-rate = //p' "$TMP/settings" | head -1)
case "${fq:-0}" in
    0|"") ok "clock.force-quantum is unset" ;;
    *)    hm "clock.force-quantum is ${fq} -- forced graph-wide, including Android's pulse path" ;;
esac
case "${fr:-0}" in
    0|"") ok "clock.force-rate is unset" ;;
    *)    hm "clock.force-rate is ${fr} -- a forced rate resamples every client that disagrees" ;;
esac

head_ "4. Gains above unity, links, and feedback paths"
asuser pw-dump 2>/dev/null > "$TMP/d2.json" || cp "$TMP/dump.json" "$TMP/d2.json"
python3 - "$TMP/d2.json" <<'PY'
import json, sys, collections
objs = json.load(open(sys.argv[1]))
def props(o): return ((o.get("info") or {}).get("props") or {})
name = {}
mon  = set()
portnode = {}
for o in objs:
    p = props(o)
    t = o.get("type", "")
    if t.endswith("Node"):
        name[o["id"]] = p.get("node.description") or p.get("node.name") or "?"
    if t.endswith("Port"):
        portnode[o["id"]] = p.get("node.id")
        if p.get("port.monitor") in (True, "true") or str(p.get("port.name","")).startswith("monitor_"):
            mon.add(o["id"])
# gains: cubic, matching what wpctl prints
hot = []
for o in objs:
    for pr in (o.get("info") or {}).get("params", {}).get("Props", []) or []:
        if isinstance(pr, dict) and "channelVolumes" in pr:
            for v in pr["channelVolumes"] or []:
                c = v ** (1/3)
                if c > 1.001: hot.append((o["id"], name.get(o["id"], "?"), round(c, 3)))
if hot:
    for i, n, c in sorted(set(hot)):
        print("  \033[31mLOOK\033[0m  node %d volume %.3f is above unity (%s)" % (i, c, n))
else:
    print("  \033[32m  OK\033[0m  no node is above unity gain")
pairs = collections.Counter(); feedback = []
for o in objs:
    p = props(o)
    if "link.output.port" in p:
        op, ip = p["link.output.port"], p["link.input.port"]
        pairs[(op, ip)] += 1
        if int(op) in mon: feedback.append((o["id"], op, ip))
dups = [k for k, v in pairs.items() if v > 1]
print("        %d links total" % sum(pairs.values()))
if dups:
    print("  \033[31mLOOK\033[0m  duplicate link(s) on the same port pair: %s" % dups)
    print("        two links into one port SUM -- +6 dB and a comb filter per extra copy")
else:
    print("  \033[32m  OK\033[0m  no duplicated port pair")
if feedback:
    print("  \033[31mLOOK\033[0m  link(s) out of a MONITOR port: %s" % feedback)
    print("        a monitor feeding a sink is a loop: metallic, and it builds")
else:
    print("  \033[32m  OK\033[0m  nothing is linked out of a monitor port")
PY

head_ "5. Is the graph actually carrying audio right now?"
# Leg 6 is meaningless on a silent host, so this gates it rather than reporting a
# zero it has not earned.
running=$(python3 - "$TMP/d2.json" <<'PY'
import json, sys
n = 0
for o in json.load(open(sys.argv[1])):
    info = o.get("info") or {}
    p = (info.get("props") or {})
    if o.get("type","").endswith("Node") and info.get("state") == "running" \
       and str(p.get("media.class","")).startswith(("Stream/Output/Audio","Audio/Sink")):
        n += 1
print(n)
PY
)
if [ "${running:-0}" -gt 0 ]; then
    ok "$running audio node(s) in state 'running' -- leg 6 will mean something"
else
    na "no audio node is running: START AUDIO IN ANDROID, then re-run. Leg 6 is skipped."
fi

head_ "6. XRUN TREND over ${GAP}s  <-- the decisive leg"
if [ "${running:-0}" -le 0 ]; then
    na "skipped: nothing is playing, so a zero here would be vacuous"
else
    asuser pw-top -b -n 3 > "$TMP/top1" 2>/dev/null || true
    inf "sampling ... keep the audio playing for ${GAP}s"
    sleep "$GAP"
    asuser pw-top -b -n 3 > "$TMP/top2" 2>/dev/null || true
    if [ ! -s "$TMP/top1" ] || [ ! -s "$TMP/top2" ]; then
        na "pw-top produced no batch output (is pipewire-utils' pw-top present?)"
    else
        python3 - "$TMP/top1" "$TMP/top2" "$TMP/d2.json" "$GAP" <<'PY'
import json, sys
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

_a, _b = sample(sys.argv[1]), sample(sys.argv[2])
a = _a["err"] if _a else {}
b = _b["err"] if _b else {}
gap = float(sys.argv[4])
# A parser that found no ERR column would report "nothing moved" for every host
# on earth, which is the false clean this whole script exists to avoid. Say so
# instead.
if not a or not b:
    print("  \033[33mSKIP\033[0m  pw-top showed no node actually processing in either sample")
    print("        (%d/%d nodes read) -- run `pw-top -b -n 3` by hand and send it" % (len(a), len(b)))
    raise SystemExit(0)
name = {}
for o in json.load(open(sys.argv[3])):
    if o.get("type","").endswith("Node"):
        p = (o.get("info") or {}).get("props") or {}
        name[o["id"]] = p.get("node.description") or p.get("node.name") or "?"
grew = sorted(((b[k]-a[k], k) for k in b if k in a and b[k] > a[k]), reverse=True)
if not grew:
    print("  \033[32m  OK\033[0m  no node's xrun counter moved in %ds of playback" % gap)
    print("        so this is NOT deadline misses. Robotic audio with a flat ERR")
    print("        counter is clock drift or resampling, not load -- different fix.")
else:
    print("  \033[31mLOOK\033[0m  xruns accumulating during playback:")
    for d, k in grew[:12]:
        print("        node %-5d +%-6d (%.2f/s)  %s" % (k, d, d/gap, name.get(k, "?")))
    print("        this IS deadline misses. Suspect the daemon count (leg 2) or")
    print("        clock.force-quantum (leg 3), in that order.")
PY
    fi
fi

head_ "7. Android's own path"
python3 - "$TMP/d2.json" <<'PY'
import json, sys
objs = json.load(open(sys.argv[1]))
wd = {o["id"] for o in objs
      if o.get("type","").endswith("Client")
      and "waydroid" in json.dumps((o.get("info") or {}).get("props") or {}).lower()}
found = False
for o in objs:
    info = o.get("info") or {}
    p = info.get("props") or {}
    if o.get("type","").endswith("Node") and p.get("client.id") in wd:
        found = True
        print("        node %-5d %-28s state=%s rate=%s quantum=%s" % (
            o["id"], str(p.get("node.name"))[:28], info.get("state"),
            p.get("audio.rate") or p.get("node.rate") or "-",
            p.get("node.latency") or "-"))
if not found:
    print("        no stream node is attributed to a Waydroid client right now")
    print("        (Android plays nothing, or the stream is between tracks)")
PY

printf '\n\033[1m%d ok, %d to look at, %d skipped\033[0m\n' "$pass" "$warn" "$skip"
printf 'Nothing was changed. Paste this whole output back.\n'
