#!/usr/bin/env bash
#
# OBSOLETE AS OF THE STAGE 4 CUTOVER.  DO NOT RUN THIS.
#
# The container's uplink is now NAMED wlan0 by LXC itself -- the one-line change
# this script's own header argued against, lxc.net.0.name = wlan0, turned out to
# be the thing that made Android register a NetworkAgent and get a routable
# network at all.  See docs/34-wifi-second-radio.md.
#
# So wlan0 already exists at container start, there is no eth0 to conflict with,
# and running this would add a SECOND interface of the same name's making into a
# namespace that already has the real one.  Kept only as the record of the
# development-time approach and as a way back if the rename is ever reverted
# (the LXC config backup is /var/lib/waydroid/lxc/waydroid/config.pre-wlan0).
#
# Everything below describes the superseded arrangement.
#
# Put a wlan0 netdev inside the Waydroid container's network namespace.
#
# Android's WifiNative registers a netd observer on the interface and calls
# isInterfaceUp() on it, and from Stage 4 onwards IpClient runs DHCP on it, so
# wlan0 has to exist AND carry traffic.  It does not have to be a real 802.11
# device, because waydroid-wifid replaces wificond and nothing in this design
# talks to nl80211 (docs/29-wifi-plan.md, "Path U").
#
# WHAT THIS CREATES, AND WHY NOT WHAT THE PLAN SAID
#
# docs/29 proposed renaming the container's own uplink -- lxc.net.0.name =
# wlan0 -- which would also have disposed of the EthernetService conflict for
# free.  That is still the tidy end state, but it is a bad way to GET there:
# it needs a container restart, it drops the kiosk session to the greeter, and
# it leaves Android with no network at all in the window where the Wi-Fi path
# is not yet working.  A bug in the supplicant shim would then look identical
# to a bug in the cutover.
#
# So this makes wlan0 a second veth onto the same bridge instead.  eth0 keeps
# working throughout, wlan0 is independently a real routable interface that
# DHCP succeeds on, and the two can be compared against each other.  Nothing
# needs restarting and `down` removes every trace.  Both interfaces sit on
# waydroid0 with distinct MACs, so dnsmasq gives each its own lease.
#
# Android ends up with both an Ethernet and a Wi-Fi network, and prefers the
# Ethernet one -- which is honest, because at this stage both are the same
# bridge.  What it proves is the part that was in doubt: that the supplicant
# shim drives a real association and that L3 comes up on wlan0 behind it.
#
# Deliberately NOT virt_wifi.  virt_wifi does create a netdev in the container,
# but it pins its wiphy to init_net -- stock virt_wifi never sets
# WIPHY_FLAG_NETNS_OK -- so `iw phy set netns` is refused with -EOPNOTSUPP.
# That was Stage 1's blocker; a veth avoids the whole question.
#
# NOT PERSISTENT.  The veth lives in the container's network namespace, which
# is destroyed and recreated with the container, so this has to be re-run after
# every container restart.  Making it survive is the LXC-config change docs/29
# described (a second lxc.net.N stanza, or renaming the uplink); that is a
# Stage 5 job, because it costs a container restart to install and this does
# not.
#
# Usage:  bin/wifi-wlan0.sh [up|down|status]     (run on bigtab01, needs root)
#         IFNAME=wlan0 BRIDGE=waydroid0 are overridable
set -euo pipefail

ACTION="${1:-status}"
IFNAME="${IFNAME:-wlan0}"
BRIDGE="${BRIDGE:-waydroid0}"
HOSTIF="${HOSTIF:-wdwlan0}"

# Stable and locally unique: dnsmasq keys its lease on this, so a fixed value
# means wlan0 keeps its address across an up/down cycle.  Same 00:16:3e Xen OUI
# Waydroid itself uses for eth0, next address along.
MACADDR="${MACADDR:-00:16:3e:f9:d3:04}"

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

# "dummy" or "veth" or "" -- what wlan0 currently is inside the container.
# Stages 2 and 3 left a dummy behind, and a dummy silently blackholes DHCP,
# which is a genuinely confusing way for Stage 4 to fail.
current_kind() {
	# The trailing "|| true" is load-bearing under `set -eo pipefail`: when
	# wlan0 does not exist -- which is the normal state after a container
	# restart, since the netns and everything in it is new -- `ip link show`
	# exits non-zero, pipefail propagates that, and the assignment
	# `kind="$(current_kind)"` then kills the script before it can create
	# anything.  It fails silently and looks like the script doing nothing.
	"${NS[@]}" ip -details link show "$IFNAME" 2>/dev/null |
		sed -n 's/.*\(dummy\|veth\).*/\1/p' | head -1 || true
}

case "$ACTION" in
up)
	kind="$(current_kind)"
	if [ "$kind" = "veth" ]; then
		echo "$IFNAME is already a veth in the container (pid $PID)"
	else
		if [ -n "$kind" ]; then
			echo "removing the existing $kind $IFNAME -- a dummy cannot carry DHCP"
			"${NS[@]}" ip link del "$IFNAME"
		fi
		ip link show "$HOSTIF" >/dev/null 2>&1 && ip link del "$HOSTIF"

		ip link add "$HOSTIF" type veth peer name "$IFNAME-tmp"
		ip link set "$IFNAME-tmp" address "$MACADDR"
		# One command: move into the netns and rename on the way in.  The
		# rename has to happen while it is down, which it is at creation.
		ip link set "$IFNAME-tmp" netns "$PID" name "$IFNAME"
		ip link set "$HOSTIF" master "$BRIDGE" up
		echo "created $IFNAME (veth onto $BRIDGE) in the container (pid $PID)"
	fi
	"${NS[@]}" ip link set "$IFNAME" up
	ip link set "$HOSTIF" up 2>/dev/null || true
	"${NS[@]}" ip -brief addr show "$IFNAME"
	echo "host side: $(ip -brief link show "$HOSTIF" 2>/dev/null || echo missing)"
	;;
down)
	if "${NS[@]}" ip link show "$IFNAME" >/dev/null 2>&1; then
		# Deleting either end of a veth pair removes both.
		"${NS[@]}" ip link del "$IFNAME"
		echo "removed $IFNAME from the container (pid $PID)"
	else
		echo "$IFNAME is not present in the container (pid $PID)"
	fi
	ip link show "$HOSTIF" >/dev/null 2>&1 && ip link del "$HOSTIF" && \
		echo "removed the host-side $HOSTIF"
	exit 0
	;;
status)
	echo "container pid: $PID"
	kind="$(current_kind)"
	echo "kind of $IFNAME: ${kind:-absent}"
	"${NS[@]}" ip -brief addr show
	echo "--- host side ---"
	ip -brief link show "$HOSTIF" 2>/dev/null || echo "$HOSTIF: absent"
	bridge link show 2>/dev/null | grep -E "$BRIDGE" || true
	;;
*)
	echo "usage: $0 [up|down|status]" >&2
	exit 2
	;;
esac
