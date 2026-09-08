#!/bin/bash
# Verify the Wi-Fi shim: is waydroid-wifid the wificond Android is talking to,
# and did the framework get a client interface out of it?
# Usage: wifi-test.sh
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success. Stage 1 failed with a specific message
# ("Failed to setup iface in wificond"), so this checks positively for the
# inverse -- a live IClientInterface and a ClientModeManager that stayed up --
# rather than for silence. See docs/29-wifi-plan.md.
set -u

FAIL=0
say() { printf '  %s\n' "$*"; }
chk() { # label want got
  if [ "$2" = "$3" ]; then say "OK   $1: $3"; else say "FAIL $1: got '$3', want '$2'"; FAIL=1; fi
}

sh_() { sudo -n waydroid shell -- sh -c "$1" 2>/dev/null | tr -d '\r'; }

echo "### host side"
if pgrep -x waydroid-wifid >/dev/null; then
  say "OK   waydroid-wifid is running (pid $(pgrep -x waydroid-wifid | tr '\n' ' '))"
else
  say "FAIL waydroid-wifid is not running"; FAIL=1
fi
if pgrep -x wificond >/dev/null; then
  say "WARN stock wificond is also running -- it registers wifinl80211 too,"
  say "     and whichever registered last owns the name. Stop it with:"
  say "       sudo waydroid shell -- setprop ctl.stop wificond"
else
  say "OK   stock wificond is not running"
fi

echo "### is wlan0 present in the container?"
LINK=$(sh_ 'ip -brief link show wlan0' | head -1)
if [ -n "$LINK" ]; then say "OK   $LINK"; else
  say "FAIL no wlan0 in the container -- run bin/wifi-wlan0.sh up"; FAIL=1
fi

echo "### does the container see the service?"
SVC=$(sh_ 'service check wifinl80211')
say "$SVC"
case "$SVC" in *"not found"*) say "FAIL wifinl80211 is not registered"; FAIL=1 ;; esac

echo "### what the framework did with it"
D=$(sh_ 'dumpsys wifi')
ENABLED=$(printf '%s' "$D" | grep -m1 -oE 'Wi-Fi is (enabled|disabled)')
IFACE=$(printf '%s' "$D" | grep -m1 'mClientInterfaceName' | sed 's/.*: *//')
say "${ENABLED:-<no Wi-Fi state reported>}"
say "mClientInterfaceName: ${IFACE:-<none>}"
[ -n "$IFACE" ] || { say "FAIL the framework never got a client interface"; FAIL=1; }

echo "### recent wificond/WifiNative log"
sh_ 'logcat -d -t 400' |
  grep -iE 'wificond|WifiNl80211|WifiNative|ClientModeManager|ActiveModeWarden' |
  tail -25 | sed 's/^/  /'

echo "### the Stage 1 failure must be absent"
BAD=$(sh_ 'logcat -d -t 400' | grep -cE 'Failed to setup iface in wificond|Could not get IClientInterface|No wiphy is found')
chk "old failure lines" 0 "$BAD"

echo "### verdict"
if [ "$FAIL" = 0 ]; then echo "  PASS"; else echo "  FAIL"; fi
exit $FAIL
