#!/usr/bin/env bash
#
# Put a wlan0 netdev inside the Waydroid container's network namespace.
#
# Android's WifiNative registers a netd observer on the interface and calls
# isInterfaceUp() on it, so wlan0 has to EXIST as a netdev before the Wi-Fi
# framework will finish bringing a client interface up.  It does not have to
# carry traffic yet, and it does not have to be a real 802.11 device at all,
# because waydroid-wifid replaces wificond and nothing in this design talks to
# nl80211 (docs/29-wifi-plan.md, "Path U").
#
# So a dummy is enough for Stages 2 and 3.  Stage 4 -- when IpClient starts
# running DHCP on wlan0 -- replaces this by renaming the container's real
# uplink (lxc.net.0.name = wlan0), which also disposes of the EthernetService
# conflict for free.  Until then this is scaffolding: it creates nothing that
# survives a reboot and `down` removes every trace of it.
#
# Deliberately NOT virt_wifi.  virt_wifi does create a netdev in the container,
# but it pins its wiphy to init_net -- stock virt_wifi never sets
# WIPHY_FLAG_NETNS_OK -- so `iw phy set netns` is refused with -EOPNOTSUPP.
# That was Stage 1's blocker; a dummy avoids the whole question.
#
# Usage:  bin/wifi-wlan0.sh [up|down|status]     (run on bigtab01, needs root)
set -euo pipefail

ACTION="${1:-status}"
IFNAME="${IFNAME:-wlan0}"

container_pid() {
	local pid
	pid="$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH 2>/dev/null || true)"
	if [ -z "$pid" ] || [ "$pid" = "-1" ]; then
		# lxc-info needs root; fall back to the child of the lxc-start monitor,
		# which is the container's /init.
		local monitor
		monitor="$(pgrep -f 'lxc-start .* -n waydroid' | head -1 || true)"
		[ -n "$monitor" ] && pid="$(pgrep -P "$monitor" | head -1 || true)"
	fi
	[ -n "$pid" ] || { echo "cannot find the waydroid container pid" >&2; exit 1; }
	echo "$pid"
}

PID="$(container_pid)"
NS=(nsenter -t "$PID" -n --)

case "$ACTION" in
up)
	if "${NS[@]}" ip link show "$IFNAME" >/dev/null 2>&1; then
		echo "$IFNAME already exists in the container (pid $PID)"
	else
		"${NS[@]}" ip link add "$IFNAME" type dummy
		echo "created $IFNAME (dummy) in the container (pid $PID)"
	fi
	"${NS[@]}" ip link set "$IFNAME" up
	"${NS[@]}" ip -brief link show "$IFNAME"
	;;
down)
	if "${NS[@]}" ip link show "$IFNAME" >/dev/null 2>&1; then
		"${NS[@]}" ip link del "$IFNAME"
		echo "removed $IFNAME from the container (pid $PID)"
	else
		echo "$IFNAME is not present in the container (pid $PID)"
	fi
	;;
status)
	echo "container pid: $PID"
	"${NS[@]}" ip -brief link show
	;;
*)
	echo "usage: $0 [up|down|status]" >&2
	exit 2
	;;
esac
