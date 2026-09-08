#!/usr/bin/env bash
#
# wifi-radio-reset.sh -- reprobe the USB Wi-Fi driver when the radio wedges.
#
# THE FAULT THIS EXISTS FOR
#
# The TP-Link Archer T3U (rtw88_8822bu) can reach a state where it scans
# perfectly well and cannot associate at all.  Every layer lies about it in a
# different way:
#
#   nmcli connection up ...   Error: The Wi-Fi network could not be found
#   NetworkManager            state change: config -> failed ('ssid-not-found')
#   waydroid-wifid            host failed to associate with "vidiot"
#   Android                   Wifi is not connected
#
# and all four are wrong, because `nmcli device wifi list` shows the SSID at
# full signal the whole time.  "ssid-not-found" is NetworkManager's label for
# its 25 s activation timeout, not an observation about the SSID.
#
# HOW TO TELL IT IS THIS AND NOT THE SOFTWARE
#
# Activate the profile with nmcli directly, bypassing Android and
# waydroid-wifid entirely:
#
#     sudo nmcli connection up "vidiot (Waydroid)"
#
# If that fails while the SSID is visible in a scan, nothing above the driver is
# implicated and this script is the answer.  If it succeeds, the fault is higher
# up and reprobing will only hide it.  Do that test first -- an afternoon was
# spent debugging a shim that was working correctly.
#
# This is the same shape of fault as the ITE8350 sensor hub wedge in
# 19-sensor-hub-suspend-wedge.md: a device that answers some requests and
# silently refuses others until its driver is reloaded.  Unlike that one, no
# automatic trigger is wired up, because the conditions that provoke it are not
# yet understood -- it has been seen after repeated container restarts and heavy
# scan activity, which is a description, not a cause.
#
# The host's own radio (wlp1s0, phy0) is a different device on a different
# driver and is not touched.  This is safe to run over ssh.

set -euo pipefail

MODULE="${MODULE:-rtw88_8822bu}"
IFNAME="${IFNAME:-wlp0s20u1}"
SETTLE="${SETTLE:-10}"

die() { echo "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (sudo $0)"

echo "== before"
if ip -br link show "$IFNAME" 2>/dev/null; then
	:
else
	echo "   $IFNAME is not present"
fi

# Refuse to touch the host's own uplink.  The whole point of the second adapter
# is that Android cannot strand this machine; a reset script that could unplug
# the management link would give that back.
HOSTDEV="$(ip -o route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2}' || true)"
if [ "$HOSTDEV" = "$IFNAME" ]; then
	die "refusing: $IFNAME currently carries the host's default route"
fi

echo "== reprobing $MODULE"
modprobe -r "$MODULE"
sleep 3
modprobe "$MODULE"

echo "== waiting up to ${SETTLE}s for $IFNAME to come back"
for _ in $(seq 1 "$SETTLE"); do
	ip link show "$IFNAME" >/dev/null 2>&1 && break
	sleep 1
done

ip link show "$IFNAME" >/dev/null 2>&1 \
	|| die "$IFNAME did not return -- check 'dmesg | tail' and the USB port"

echo "== after"
ip -br link show "$IFNAME"
nmcli -t -f DEVICE,STATE,CONNECTION device 2>/dev/null | grep "^$IFNAME:" || true

cat <<EOF

The interface is back and NetworkManager is managing it again.  waydroid-wifid
re-resolves its device by NAME on every use, so it does not need restarting --
but Android will have seen the association drop, so re-connect from Android (or
'nmcli connection up "<ssid> (Waydroid)"' to confirm the radio first).
EOF
