#!/bin/sh
# bluetooth-test.sh -- verify BlueZ reaches Android (docs/50-bluetooth.md).
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/bluetooth-test.sh
#
# Walks the whole chain -- controller, daemon, protocol, profile delivery, app
# -- and names the link that is broken rather than just failing. Needs root:
# the token is 0600 and the app's private directory is mode 0700.
#
# The one thing it CANNOT test is pairing. An agent prompt only exists when a
# real device is in pairing mode and somebody is looking at the screen to answer
# it, so that leg reports SKIPPED. bin/brightness-test.sh has the same shape for
# the same reason: a test that needs a human is better named than faked.

set -u

PKG=lan.syshlt.bluetooth
PORT=7712
pass=0; fail=0; skip=0

ok()    { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()    { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
na()    { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ash() { waydroid shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1'; }

DATA=$(ls -d /home/*/.local/share/waydroid/data 2>/dev/null | head -1)

head_ "1. The controller"
if systemctl is-active --quiet bluetooth; then
    ok "bluetooth.service is active"
else
    no "bluetooth.service is not active"
fi
if rfkill list bluetooth 2>/dev/null | grep -q 'Soft blocked: no'; then
    ok "the radio is not soft-blocked"
else
    no "the radio is rfkill'd (rfkill unblock bluetooth)"
fi

head_ "2. The host daemon"
if systemctl is-active --quiet waydroid-btd; then
    ok "waydroid-btd.service is active"
else
    no "waydroid-btd.service is not active (systemctl status waydroid-btd)"
fi
if busctl --system list 2>/dev/null | grep -q '^org.bluez '; then
    ok "org.bluez is on the system bus"
else
    no "org.bluez is not on the system bus"
fi
# The agent is what makes pairing possible at all. BlueZ exports no way to list
# agents, so ask the daemon's own log -- it says so once per registration.
if journalctl -u waydroid-btd --no-pager -n 200 2>/dev/null \
        | grep -q 'agent registered'; then
    ok "the pairing agent registered with BlueZ"
else
    no "no 'agent registered' line -- pairing prompts will never appear"
fi
if journalctl -u waydroid-btd --no-pager -n 200 2>/dev/null \
        | grep -q 'RequestDefaultAgent failed'; then
    no "another agent holds the default slot (a stray bluetoothctl?)"
else
    ok "the daemon holds the default agent slot"
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

head_ "4. The protocol"
TOKEN=$(cat /var/lib/waydroid-btd/token 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
    ok "a token exists in /var/lib/waydroid-btd"
else
    na "no token -- daemon running with --no-auth?"
fi
if [ -n "$ADDR" ]; then
    RESULT=$(ADDR="$ADDR" PORT="$PORT" TOKEN="$TOKEN" python3 - <<'PY' 2>&1
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
            chunk = sock.recv(65536)
        except OSError:
            return None
        if not chunk:
            return None
        buf += chunk
    line, buf = buf.split(b"\n", 1)
    return json.loads(line)

def send(obj):
    sock.sendall((json.dumps(obj) + "\n").encode())

send({"id": 1, "cmd": "state"})
first = read(time.time() + 5)
print("GATED" if first and not first.get("ok") else "UNGATED")

send({"id": 2, "cmd": "auth", "token": token})
auth = read(time.time() + 5)
if not (auth and auth.get("ok")):
    print("AUTH-FAIL")
    sys.exit(0)
print("AUTH-OK")

ready = read(time.time() + 5)
if not ready or ready.get("ev") != "ready":
    print("NO-READY")
    sys.exit(0)
adapter = ready.get("adapter") or {}
print("ADAPTER %s %s" % (adapter.get("addr"), adapter.get("powered")))
print("PAIRED %d" % sum(1 for d in ready.get("devices", []) if d.get("paired")))

send({"id": 3, "cmd": "scan", "on": True})
seen, deadline = set(), time.time() + 10
while time.time() < deadline:
    msg = read(deadline)
    if msg is None:
        break
    if msg.get("ev") == "device":
        seen.add(msg["device"].get("addr"))
print("SCANNED %d" % len(seen))
send({"id": 4, "cmd": "scan", "on": False})
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
    ADAPTER_LINE=$(echo "$RESULT" | sed -n 's/^ADAPTER //p')
    case "$ADAPTER_LINE" in
    *True)  ok "adapter $ADAPTER_LINE reported and powered" ;;
    *False) no "the adapter is reported but powered off" ;;
    *)      no "no adapter in the ready snapshot" ;;
    esac
    # A low count here is not a fault if the app is open. The daemon sets
    # DuplicateData:false on the discovery filter, so a device already reported
    # to the app's scan is not re-emitted to this one -- run with the app closed
    # to see the full set.
    SCANNED=$(echo "$RESULT" | sed -n 's/^SCANNED //p')
    if [ "${SCANNED:-0}" -gt 0 ] 2>/dev/null; then
        ok "discovery returned $SCANNED device(s) in 10 s"
    else
        na "discovery found nothing -- no devices in range, or the app is open
        and already has them (DuplicateData is off)"
    fi
    echo "$RESULT" | sed -n 's/^PAIRED /        paired devices: /p'
else
    no "skipping the protocol: no bridge address"
fi

head_ "5. The app"
if [ -z "$DATA" ]; then
    no "no Waydroid data directory found"
elif ash "pm list packages" | grep -q "$PKG"; then
    ok "$PKG is installed"
    PROFILE="$DATA/data/$PKG/files/btd.json"
    if [ -f "$PROFILE" ]; then
        ok "the connection profile is published"
        OWNER=$(stat -c %u "$PROFILE")
        APPUID=$(stat -c %u "$DATA/data/$PKG")
        if [ "$OWNER" = "$APPUID" ]; then
            ok "the profile is owned by the app (uid $OWNER), so it can read it"
        else
            no "the profile is uid $OWNER but the app is uid $APPUID -- unreadable"
        fi
    else
        no "no profile at $PROFILE (the daemon publishes it within 30 s)"
    fi
    # The app holds its socket open while it is in the foreground, so a client
    # in the daemon's log is the only proof the two halves ever met. It has to
    # be a client from INSIDE the container: a test client run on the host
    # connects from the bridge address itself and would pass this for free.
    if journalctl -u waydroid-btd --no-pager -n 500 2>/dev/null \
            | grep 'client .* connected' | grep -qv "client $ADDR:"; then
        ok "the app has connected to the daemon from inside the container"
    else
        na "no client from inside the container yet -- open the app once"
    fi
else
    na "$PKG is not installed (bt-app/build.sh --install)"
fi

head_ "6. Pairing"
na "needs a real device in pairing mode and somebody to answer the prompt"
printf '        open the app, put a device in pairing mode, tap it under\n'
printf '        Available devices, and answer the dialog.\n'
# Not a check, context: a SKIP that can never become a PASS is more useful with
# the current bond list next to it.
BONDS=$(timeout 6 bluetoothctl devices Paired 2>/dev/null)
if [ -n "$BONDS" ]; then
    printf '\n        currently bonded:\n'
    echo "$BONDS" | sed 's/^Device /          /'
else
    printf '\n        nothing is bonded yet\n'
fi
# Whether any of those came through the app is only answerable from the log,
# and only for pairings since the daemon started logging agent requests.
if journalctl -u waydroid-btd --no-pager 2>/dev/null \
        | grep -q 'agent request .* accepted by'; then
    printf '        at least one was accepted through the app\n'
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
