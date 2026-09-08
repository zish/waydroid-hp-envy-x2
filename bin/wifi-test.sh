#!/bin/bash
# Verify the Wi-Fi shim: is waydroid-wifid the wificond Android is talking to,
# did the framework get a client interface out of it, and do the host's real
# access points arrive in Android's scan results?
# Usage: wifi-test.sh
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success. Stage 1 failed with a specific message
# ("Failed to setup iface in wificond"), so this checks positively for the
# inverse -- a live IClientInterface and a ClientModeManager that stayed up --
# rather than for silence. See docs/29-wifi-plan.md.
#
# The scan checks run the host side first, so a failure lands on one side of
# the WifiBackend contract or the other rather than "Wi-Fi is broken". They
# take up to a minute: a real scan has to happen, twice.
#
# Stage 4 adds the supplicant. Its checks are ordered by what breaks first, so
# the first FAIL names the layer at fault rather than the symptom:
#
#   1. is the service DECLARED?   the VINTF fragment, and therefore whether
#                                 Android takes the AIDL path at all
#   2. is it REGISTERED?          waydroid-wifid's binder object
#   3. did the framework USE it?  the toggle staying on, which is the whole
#                                 point of the stage
#
# It does NOT connect to anything. Association needs a password and a decision
# about which network, so it is driven by hand -- see docs/33-wifi-stage4.md.
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
# Reported, not required. Stage 2 assumed the framework needs wlan0 to exist
# before it will finish bringing a client interface up; on 2026-09-08 a
# container that never had wlan0 set one up and scanned anyway, so that is not
# a precondition in scan-only mode. It will be one in Stage 4, when IpClient
# starts running DHCP on it -- hence still worth reporting.
LINK=$(sh_ 'ip -brief link show wlan0' | head -1)
if [ -n "$LINK" ]; then say "OK   $LINK"; else
  say "WARN no wlan0 in the container. Not fatal for scanning; Stage 4 will"
  say "     need it -- it is created by LXC (lxc.net.0.name = wlan0)"
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

echo "### is the supplicant DECLARED? (the VINTF fragment)"
# isDeclared() reads the vendor VINTF manifest and nothing else. It is what
# picks the AIDL path over HIDL, and it is a separate question from whether
# anything has registered the service -- getting this wrong leaves Android
# looking for a HIDL supplicant that does not exist, with no obvious symptom
# beyond the toggle refusing to stay on.
VINTF=$(sh_ 'cat /vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml 2>/dev/null')
if printf '%s' "$VINTF" | grep -q 'ISupplicant/default'; then
  say "OK   the VINTF fragment is in effect inside the container"
else
  say "FAIL no supplicant VINTF fragment inside the container."
  say "     Deploy artifacts/overlay/vendor/etc/vintf/manifest/ and then"
  say "     'systemctl restart waydroid-container.service' -- a plain"
  say "     'waydroid container restart' will NOT pick it up (docs/32)."
  FAIL=1
fi

echo "### is the supplicant REGISTERED? (waydroid-wifid's binder object)"
SUPSVC=$(sh_ 'service check android.hardware.wifi.supplicant.ISupplicant/default')
say "$SUPSVC"
case "$SUPSVC" in *"not found"*)
  say "FAIL the supplicant service is not registered -- is waydroid-wifid the"
  say "     build with Stage 4 in it?"; FAIL=1 ;;
esac

echo "### did the framework take the AIDL path and keep the interface?"
# The positive form matters here for the same reason it did in Stage 2: the
# Stage 3 failure was silent. 'Failed to start supplicant' is the exact line
# that used to appear, so its absence is checked alongside a positive signal.
SUPLOG=$(sh_ 'logcat -d -t 600' | grep -iE 'supplicant|SupplicantStaIfaceHal')
printf '%s\n' "$SUPLOG" | tail -12 | sed 's/^/  /'
BADSUP=$(printf '%s\n' "$SUPLOG" | grep -cE 'Failed to start supplicant|Unable to obtain ISupplicant|Failed to setup iface in supplicant')
chk "supplicant setup failures" 0 "$BADSUP"

if printf '%s' "$D" | grep -q 'Wi-Fi is enabled'; then
  say "OK   the master toggle is on and has stayed on"
else
  say "WARN the master toggle is off. That is not a failure by itself -- it is"
  say "     a setting -- but Stage 4's point is that it CAN now stay on."
  say "     Turn it on with: cmd wifi set-wifi-enabled enabled"
fi

echo "### can wlan0 carry traffic? (Stage 4 needs DHCP on it)"
WLAN=$(sh_ 'ip -brief addr show wlan0' | head -1)
if printf '%s' "$WLAN" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
  say "OK   $WLAN"
elif [ -n "$WLAN" ]; then
  say "WARN wlan0 exists but has no IPv4 address yet: $WLAN"
  say "     Not yet connected, or the association failed. If the SSID is"
  say "     visible in a scan but will not associate: bin/wifi-radio-reset.sh"
else
  say "WARN no wlan0 in the container -- check lxc.net.0.name = wlan0 in"
  say "     /var/lib/waydroid/lxc/waydroid/config, then restart the container"
fi

echo "### does the host backend see access points? (below the contract)"
HOSTSCAN=$(sudo -n waydroid-wifid --scan 2>/dev/null)
HN=$(printf '%s\n' "$HOSTSCAN" | sed -n 's/^\([0-9][0-9]*\) access points$/\1/p')
printf '%s\n' "$HOSTSCAN" | grep -E '^(backend|scan):' | sed 's/^/  /'
if [ "${HN:-0}" -gt 0 ]; then say "OK   the host backend sees $HN access points"; else
  say "FAIL the host backend found nothing -- Android cannot show what NM has not got"; FAIL=1
fi

echo "### do they reach Android? (above the contract)"
# Results must be FRESH, not merely present: Android caches the last set, so
# "there are rows" would pass even with the scan path completely broken. The
# age column is the real check -- and it is also the field this stage had to
# get right, since WificondScannerImpl drops anything older than the scan it
# asked for. The daemon only announces completion once the host has really
# scanned (WifiBackend::onScanComplete), so allow a minute for the round trip.
MAXAGE=60
sh_ 'cmd wifi start-scan' >/dev/null 2>&1
SR=""; N=0; AGE=""
for _ in $(seq 1 30); do
  sleep 2
  SR=$(sh_ 'cmd wifi list-scan-results')
  N=$(printf '%s\n' "$SR" | grep -cE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
  AGE=$(printf '%s\n' "$SR" | awk '/([0-9a-f]{2}:){5}[0-9a-f]{2}/ {print int($4)}' |
        sort -n | head -1)
  [ -n "$AGE" ] && [ "$AGE" -lt "$MAXAGE" ] && break
done
if [ "$N" -gt 0 ] && [ -n "$AGE" ] && [ "$AGE" -lt "$MAXAGE" ]; then
  say "OK   Android has $N scan results, freshest ${AGE}s old"
elif [ "$N" -gt 0 ]; then
  say "FAIL Android has $N results but none newer than ${MAXAGE}s -- the cache"
  say "     is being served and no new scan is completing"; FAIL=1
else
  say "FAIL no scan results reached Android"; FAIL=1
fi
printf '%s\n' "$SR" | head -6 | sed 's/^/  /'

# Flags come only from information elements the daemon synthesises, so a
# secured network showing up as secured proves that half end to end. An
# all-open neighbourhood would make this vacuous, hence the distinct message.
echo "### are the synthesised security flags being parsed?"
SEC=$(printf '%s\n' "$SR" | grep -cE '\[(WPA|RSN|WEP)')
if [ "$SEC" -gt 0 ]; then say "OK   $SEC results carry RSN/WPA/WEP flags"
elif [ "$N" -gt 0 ]; then say "WARN every visible network is open; nothing to check here"
else say "FAIL no results to check"; FAIL=1
fi

echo "### the Stage 1 failure must be absent"
# Only from the most recent attempt onwards. The framework retries whenever the
# daemon restarts, so a logcat buffer that spans a restart legitimately holds
# these lines from before it came back -- counting those would report a failure
# that has already been recovered from.
BAD=$(sh_ 'logcat -d -t 400' |
      awk '/Starting primary ClientModeManager/ {buf=""} {buf = buf $0 "\n"} END {printf "%s", buf}' |
      grep -cE 'Failed to setup iface in wificond|Could not get IClientInterface|No wiphy is found')
chk "failures since the last mode-manager start" 0 "$BAD"

echo "### verdict"
if [ "$FAIL" = 0 ]; then echo "  PASS"; else echo "  FAIL"; fi
exit $FAIL
