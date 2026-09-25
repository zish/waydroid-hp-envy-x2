#!/bin/sh
# pipewire-test.sh -- verify the host's PipeWire graph reaches Android
# (docs/56-pipewire-control.md).
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/pipewire-test.sh
#
# Walks the whole chain -- PipeWire, the daemon, the protocol, the policy, the
# profile delivery, the app -- and names the link that is broken rather than just
# failing. Root is not needed for most of it, but is for two legs: the token is
# 0600 in the session user's state directory, and the app's private directory is
# mode 0700 owned by the app's uid.
#
# WHY IT RUNS THE PIPEWIRE TOOLS AS THE SESSION USER
#
# PipeWire is a user service. Root CAN reach the socket (measured: `sudo
# XDG_RUNTIME_DIR=/run/user/1000 pw-cli info 0` works, because root bypasses the
# 0700 on /run/user/1000), but the daemon under test is a --user unit and `pw-dump`
# run as root against a guessed XDG_RUNTIME_DIR is a different client from the one
# the daemon is, so every comparison would be against the wrong graph. So the
# tools are run through runuser as the session user, and only the two file checks
# use root directly.
#
# THE ONE MUTATION THIS MAKES, AND WHY IT IS SAFE
#
# Leg 5 creates and then destroys one link, between the two "Midi Through" ports
# of the ALSA sequencer bridge. No audio device is touched, no sink moves, nothing
# becomes audible, and the ports exist on any host with snd-seq loaded. If they
# are absent the leg reports SKIPPED rather than picking an audio port instead.

set -u

PKG=com.systemhalted.patchbay
PORT=7713
pass=0; fail=0; skip=0

ok()    { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()    { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
na()    { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ash() { waydroid shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1'; }

# Who owns the session, and therefore the PipeWire graph under test.
WDUSER=$(waydroid status 2>/dev/null | sed -n 's/^Session user:[[:space:]]*\([^(]*\)(.*/\1/p')
[ -n "${WDUSER:-}" ] || WDUSER=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null \
    | head -1 | sed 's|^/home/\([^/]*\)/.*|\1|')
WDUID=$(id -u "$WDUSER" 2>/dev/null || echo "")
DATA=$(ls -d "/home/$WDUSER/.local/share/waydroid/data" 2>/dev/null \
    || ls -d /home/*/.local/share/waydroid/data 2>/dev/null | head -1)
STATE="/home/$WDUSER/.local/state/waydroid-pwd"

# Run a command as the session user with its runtime dir, whether we are root or
# already that user.
asuser() {
    if [ "$(id -u)" = 0 ]; then
        runuser -u "$WDUSER" -- env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    else
        env "XDG_RUNTIME_DIR=/run/user/$WDUID" "$@"
    fi
}
userctl() {
    if [ "$(id -u)" = 0 ]; then
        systemctl --user "--machine=$WDUSER@" "$@"
    else
        systemctl --user "$@"
    fi
}

printf '\033[1mwaydroid-pwd end-to-end\033[0m  (session user: %s, uid %s)\n' \
    "${WDUSER:-?}" "${WDUID:-?}"

head_ "1. PipeWire on the host"
if [ -z "${WDUID:-}" ]; then
    no "cannot identify the session user -- is the container running?"
else
    ok "session user is $WDUSER (uid $WDUID)"
fi
for unit in pipewire pipewire-pulse wireplumber; do
    if userctl is-active --quiet "$unit" 2>/dev/null; then
        ok "$unit.service is active"
    else
        no "$unit.service is not active"
    fi
done
missing=""
for tool in pw-dump pw-link pw-metadata wpctl; do
    command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -z "$missing" ]; then
    ok "pw-dump, pw-link, pw-metadata and wpctl are installed"
else
    no "missing:$missing (dnf install pipewire-utils wireplumber)"
fi
RAW=$(asuser pw-dump 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin)))
except Exception: print(0)')
if [ "${RAW:-0}" -gt 0 ] 2>/dev/null; then
    ok "pw-dump sees $RAW objects"
else
    no "pw-dump returned nothing -- wrong XDG_RUNTIME_DIR, or PipeWire is down"
fi

head_ "2. The daemon and the publisher"
if userctl is-active --quiet waydroid-pwd 2>/dev/null; then
    ok "waydroid-pwd.service (user) is active"
else
    no "waydroid-pwd.service is not active (systemctl --user status waydroid-pwd)"
fi
if systemctl is-active --quiet waydroid-pwd-publish 2>/dev/null; then
    ok "waydroid-pwd-publish.service (system) is active"
else
    no "waydroid-pwd-publish.service is not active"
fi
# The daemon must NOT be root. That is the whole point of the split, and a unit
# accidentally moved to /etc/systemd/system would still work -- silently, with
# privilege nothing here needs.
DPID=$(pgrep -f '[w]aydroid-pwd([[:space:]]|$)' | head -1)
if [ -n "${DPID:-}" ]; then
    DOWNER=$(ps -o user= -p "$DPID" | tr -d ' ')
    if [ "$DOWNER" = "root" ]; then
        no "the daemon is running as root -- it is meant to be a --user unit"
    else
        ok "the daemon runs as $DOWNER, not root"
    fi
else
    na "could not find the daemon process to check its user"
fi

head_ "3. The listener"
ADDR=$(ip -4 -o addr show waydroid0 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p')
if [ -n "$ADDR" ]; then
    ok "waydroid0 is up at $ADDR"
else
    no "waydroid0 has no address -- is the container running?"
fi
if ss -ltn 2>/dev/null | grep -q ":$PORT "; then
    ok "something is listening on port $PORT"
else
    no "nothing is listening on port $PORT"
fi

head_ "4. The protocol, the graph and the policy"
TOKEN=$(cat "$STATE/token" 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
    ok "a token exists in $STATE"
else
    na "no token at $STATE/token -- daemon running with --no-auth?"
fi
PWDUMP=$(asuser pw-dump 2>/dev/null)
RESULT=""
if [ -n "$ADDR" ]; then
    RESULT=$(ADDR="$ADDR" PORT="$PORT" TOKEN="$TOKEN" PWDUMP="$PWDUMP" python3 - <<'PY' 2>&1
import json, os, socket, sys, time

addr, port = os.environ["ADDR"], int(os.environ["PORT"])
token = os.environ.get("TOKEN", "")
try:
    sock = socket.create_connection((addr, port), timeout=8)
except OSError as exc:
    print("CONNECT-FAIL %s" % exc)
    sys.exit(0)

buf = b""


def read(deadline):
    global buf
    while b"\n" not in buf:
        sock.settimeout(max(0.2, deadline - time.time()))
        try:
            chunk = sock.recv(1 << 20)
        except OSError:
            return None
        if not chunk:
            return None
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)


def send(obj):
    sock.sendall((json.dumps(obj) + "\n").encode())


def await_reply(want, limit=8):
    """Replies and events interleave; pick out the reply to one request."""
    deadline = time.time() + limit
    while time.time() < deadline:
        msg = read(deadline)
        if msg is None:
            return None
        if msg.get("id") == want and "ok" in msg:
            return msg
    return None


send({"id": 1, "cmd": "graph"})
first = read(time.time() + 5)
print("GATED" if first and not first.get("ok") else "UNGATED")

send({"id": 2, "cmd": "auth", "token": token})
auth = await_reply(2)
if not (auth and auth.get("ok")):
    print("AUTH-FAIL")
    sys.exit(0)
print("AUTH-OK")
policy = auth.get("policy") or {}
print("POLICY %s" % json.dumps(policy, sort_keys=True))

ready = None
deadline = time.time() + 8
while time.time() < deadline:
    msg = read(deadline)
    if msg is None:
        break
    if msg.get("ev") == "ready":
        ready = msg
        break
if not ready:
    print("NO-READY")
    sys.exit(0)

objects = ready.get("objects") or []
print("MIRROR %d" % len(objects))

# Graph fidelity: the daemon projects six types and drops the rest, so compare
# against pw-dump's count of those same six rather than its total.
KINDS = {
    "PipeWire:Interface:Node": "node",
    "PipeWire:Interface:Port": "port",
    "PipeWire:Interface:Link": "link",
    "PipeWire:Interface:Client": "client",
    "PipeWire:Interface:Device": "device",
    "PipeWire:Interface:Metadata": "metadata",
}
try:
    raw = json.loads(os.environ.get("PWDUMP") or "[]")
except ValueError:
    raw = []
expected = {o["id"] for o in raw if KINDS.get(o.get("type"))}
got = {o["id"] for o in objects}
# A transient client (this script's own pw-dump) may exist in one view and not
# the other, so report the symmetric difference rather than requiring equality.
print("FIDELITY %d %d %d" % (len(expected), len(got),
                             len(expected ^ got)))

ports = [o for o in objects if o.get("kind") == "port"]
nodes = {o["id"]: o for o in objects if o.get("kind") == "node"}


def midi(direction):
    for p in ports:
        node = nodes.get(p.get("node"))
        if not node:
            continue
        if node.get("name") == "Midi-Bridge" and "Midi Through" in (p.get("name") or "") \
                and p.get("direction") == direction:
            return p["id"]
    return None


out_port, in_port = midi("out"), midi("in")
if out_port is None or in_port is None:
    print("MIDI-MISSING")
else:
    print("MIDI %d %d" % (out_port, in_port))

# The capture gate. Pick a real monitor or capture port and check it is refused
# on its own merits rather than because the ids are nonsense.
tap = None
for p in ports:
    if p.get("monitor"):
        tap = p["id"]
        break
if tap is None:
    for p in ports:
        node = nodes.get(p.get("node"))
        if node and (node.get("media_class") or "").startswith("Audio/Source") \
                and p.get("direction") == "out":
            tap = p["id"]
            break
sink_in = None
for p in ports:
    node = nodes.get(p.get("node"))
    if node and node.get("media_class") == "Audio/Sink" and p.get("direction") == "in":
        sink_in = p["id"]
        break
if tap is not None and sink_in is not None:
    send({"id": 10, "cmd": "link-create", "output": tap, "input": sink_in})
    reply = await_reply(10)
    refused = bool(reply and not reply.get("ok"))
    why = (reply or {}).get("error", "")
    print("CAPTURE %s %s" % ("REFUSED" if refused else "ALLOWED", why))
else:
    print("CAPTURE NOPORTS")

# node-create and module hosting are default-deny; check they say so.
send({"id": 11, "cmd": "node-create", "kind": "loopback", "name": "pwtest-probe"})
reply = await_reply(11)
print("NODES %s" % ("REFUSED" if reply and not reply.get("ok") else "ALLOWED"))

# The one mutation: a MIDI link, created and destroyed.
if out_port is not None and in_port is not None:
    send({"id": 20, "cmd": "link-create", "output": out_port, "input": in_port})
    reply = await_reply(20, 12)
    if not (reply and reply.get("ok")):
        print("LINK-CREATE-FAIL %s" % (reply or {}).get("error", "no reply"))
    else:
        print("LINK-CREATE-OK")
        made = None
        deadline = time.time() + 8
        while time.time() < deadline and made is None:
            msg = read(deadline)
            if msg is None:
                break
            if msg.get("ev") != "update":
                continue
            for obj in msg.get("changed") or []:
                if obj.get("kind") == "link" \
                        and obj.get("output_port") == out_port \
                        and obj.get("input_port") == in_port:
                    made = obj["id"]
        if made is None:
            print("LINK-EVENT-MISSING")
        else:
            print("LINK-EVENT-OK %d" % made)
            send({"id": 21, "cmd": "link-destroy", "link": made})
            reply = await_reply(21, 12)
            if not (reply and reply.get("ok")):
                print("LINK-DESTROY-FAIL %s" % (reply or {}).get("error", "no reply"))
            else:
                gone = False
                deadline = time.time() + 8
                while time.time() < deadline and not gone:
                    msg = read(deadline)
                    if msg is None:
                        break
                    if msg.get("ev") == "update" and made in (msg.get("removed") or []):
                        gone = True
                print("LINK-DESTROY-OK" if gone else "LINK-STILL-THERE %d" % made)
sock.close()
PY
)
    case "$RESULT" in
    *GATED*)   ok "an unauthenticated command is refused" ;;
    *UNGATED*) na "auth is not enforced (--no-auth)" ;;
    *)         no "no reply to the first command" ;;
    esac
    case "$RESULT" in
    *AUTH-OK*)   ok "the token is accepted" ;;
    *AUTH-FAIL*) no "the token was rejected -- stale profile?" ;;
    *)           no "could not connect to $ADDR:$PORT" ;;
    esac
    echo "$RESULT" | sed -n 's/^POLICY /        policy: /p'

    set -- $(echo "$RESULT" | sed -n 's/^FIDELITY //p')
    if [ $# -eq 3 ]; then
        if [ "$3" -eq 0 ]; then
            ok "the mirror matches pw-dump exactly ($2 objects)"
        elif [ "$3" -le 2 ]; then
            ok "the mirror matches pw-dump to within $3 transient object(s) ($2 vs $1)"
        else
            no "the mirror and pw-dump disagree on $3 objects ($2 vs $1)"
        fi
    else
        no "no graph in the ready snapshot"
    fi

    case "$RESULT" in
    *"CAPTURE REFUSED"*)
        ok "a link from a monitor or capture port is refused by the policy" ;;
    *"CAPTURE ALLOWED"*)
        na "links.capture is enabled on this host, so the tap was allowed" ;;
    *"CAPTURE NOPORTS"*)
        na "no monitor or capture port to test the capture gate with" ;;
    *)  no "the capture gate did not answer" ;;
    esac
    case "$RESULT" in
    *"NODES REFUSED"*) ok "node creation is refused by the policy" ;;
    *"NODES ALLOWED"*) na "the nodes capability is enabled on this host" ;;
    *)                 no "node-create did not answer" ;;
    esac
else
    no "skipping the protocol: no bridge address"
fi

head_ "5. The link round-trip (MIDI Through, no audio device touched)"
case "$RESULT" in
*MIDI-MISSING*)
    na "no Midi Through port pair -- is snd-seq loaded? (modprobe snd-seq)" ;;
"")
    na "no protocol result, so nothing to round-trip" ;;
*)
    case "$RESULT" in
    *LINK-CREATE-OK*)      ok "link-create succeeded" ;;
    *LINK-CREATE-FAIL*)    no "link-create failed: $(echo "$RESULT" | sed -n 's/^LINK-CREATE-FAIL //p')" ;;
    *)                     no "link-create did not answer" ;;
    esac
    case "$RESULT" in
    *LINK-EVENT-OK*)       ok "the new link arrived as an update event" ;;
    *LINK-EVENT-MISSING*)  no "the link was made but never reported -- is pw-dump -m alive?" ;;
    esac
    case "$RESULT" in
    *LINK-DESTROY-OK*)     ok "link-destroy removed it, and the removal was reported" ;;
    *LINK-STILL-THERE*)    no "link-destroy returned ok but the link is still there" ;;
    *LINK-DESTROY-FAIL*)   no "link-destroy failed: $(echo "$RESULT" | sed -n 's/^LINK-DESTROY-FAIL //p')" ;;
    esac
    # Belt and braces: ask pw-link directly, so a daemon that lied about the
    # removal cannot pass this leg.
    if asuser pw-link -l 2>/dev/null | grep -q 'Midi Through'; then
        no "pw-link still lists a Midi Through link -- the test left one behind"
    else
        ok "pw-link confirms no Midi Through link remains"
    fi
    ;;
esac

head_ "6. Profile delivery and the app"
if [ ! -f "$STATE/profile.json" ]; then
    no "the daemon has not written $STATE/profile.json"
else
    ok "the daemon wrote its profile to $STATE"
fi
if [ -z "$DATA" ]; then
    no "no Waydroid data directory found"
elif ash "pm list packages" | grep -q "$PKG"; then
    ok "$PKG is installed"
    PROFILE="$DATA/data/$PKG/files/profile.json"
    if [ -f "$PROFILE" ]; then
        ok "the connection profile is published into the app"
        OWNER=$(stat -c %u "$PROFILE")
        APPUID=$(stat -c %u "$DATA/data/$PKG")
        if [ "$OWNER" = "$APPUID" ]; then
            ok "the profile is owned by the app (uid $OWNER), so it can read it"
        else
            no "the profile is uid $OWNER but the app is uid $APPUID -- unreadable"
        fi
        MODE=$(stat -c %a "$PROFILE")
        if [ "$MODE" = "600" ]; then
            ok "the profile is mode 600, so no other app in the container can read the token"
        else
            no "the profile is mode $MODE -- the token is readable by other apps"
        fi
    else
        no "no profile at $PROFILE (the publisher retries every 30 s)"
    fi
else
    na "$PKG is not installed (pw-app/build.sh --install)"
fi

printf '\n----------------------------------------------------------------\n'
printf 'pipewire-test: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
