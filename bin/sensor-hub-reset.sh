#!/bin/bash
# Recover the ITE8350 HID sensor hub when it fails to come back from suspend.
# Run ON bigtab01 as jmelanso. Needs sudo for the driver unbind/bind.
#
# Usage: sensor-hub-reset.sh [--check] [--restart]
#   --check    report staleness and exit; change nothing
#   --restart  after a reprobe that renumbers the IIO nodes, also restart the
#              waydroid container and session so waydroid-sensord re-resolves
#              its cached paths. This closes any running Android apps.
#
# WHY THIS EXISTS
#
# s2idle suspend can leave the hub half-alive: accel_3d, dev_rotation and
# incli_3d stop updating while gyro_3d and magn_3d keep going, and the kernel
# logs "i2c_hid_acpi i2c-ITE8350:00: failed to set a report to device: -121"
# (EREMOTEIO). Observed after two suspends four seconds apart; single suspends
# have always recovered on their own, so do not reprobe reflexively.
#
# A frozen accelerometer is not silent -- it pins Android to whatever rotation
# the stale sample implies, which looks exactly like the sign-convention bug
# fixed in docs/18. Check staleness before re-opening that.
#
# Rewriting in_*_sampling_frequency revives dev_rotation but NOT the
# accelerometer, including when a genuinely different value is written, so the
# gentle path is not sufficient. Only a driver reprobe brings the accelerometer
# back. See docs/19-sensor-hub-suspend-wedge.md.
set -u

I2C_DEV=i2c-ITE8350:00
I2C_DRV=/sys/bus/i2c/drivers/i2c_hid_acpi
CHECK_ONLY=0
DO_RESTART=0
for a in "$@"; do
	case "$a" in
	--check) CHECK_ONLY=1 ;;
	--restart) DO_RESTART=1 ;;
	*) echo "unknown argument: $a" >&2; exit 2 ;;
	esac
done

# Resolve by name, never by index: the indices are assigned in probe order and
# a reprobe reshuffles them, which is the whole reason this script has to think
# about restarting the daemon.
find_dev() {
	local d
	for d in /sys/bus/iio/devices/iio:device*; do
		[ "$(cat "$d/name" 2>/dev/null)" = "$1" ] && { echo "$d"; return; }
	done
}

attrs_for() {
	case "$1" in
	accel_3d)     echo "in_accel_x_raw in_accel_y_raw in_accel_z_raw" ;;
	gyro_3d)      echo "in_anglvel_x_raw in_anglvel_y_raw in_anglvel_z_raw" ;;
	magn_3d)      echo "in_magn_x_raw in_magn_y_raw in_magn_z_raw" ;;
	dev_rotation) echo "in_rot_quaternion_raw" ;;
	incli_3d)     echo "in_incli_x_raw in_incli_y_raw in_incli_z_raw" ;;
	esac
}

# A live sensor always jitters by an LSB or two. Identical readings across a
# 3 s window mean the hub has stopped publishing, not that the machine is
# still. incli_3d updates slowly enough to trip this, so it is reported but
# never used to decide -- the daemon does not read it anyway.
is_stale() {
	local dev="$1" d a first cur i
	d=$(find_dev "$dev") || return 2
	[ -z "$d" ] && return 2
	first=""
	for a in $(attrs_for "$dev"); do first="$first $(cat "$d/$a" 2>/dev/null)"; done
	for i in $(seq 1 15); do
		sleep 0.2
		cur=""
		for a in $(attrs_for "$dev"); do cur="$cur $(cat "$d/$a" 2>/dev/null)"; done
		[ "$cur" != "$first" ] && return 1      # moved: live
	done
	return 0                                        # never moved: stale
}

report() {
	local n s
	for n in accel_3d dev_rotation gyro_3d magn_3d incli_3d; do
		if [ -z "$(find_dev "$n")" ]; then s="ABSENT"
		elif is_stale "$n"; then s="STALE"
		else s="live"; fi
		printf "  %-13s %-7s %s\n" "$n" "$s" "$(find_dev "$n")"
	done
}

echo "### sensor state"
report

if is_stale accel_3d; then
	echo "  -> accelerometer is stale"
else
	echo "  -> accelerometer is live; nothing to do"
	[ "$CHECK_ONLY" = 1 ] && exit 0
	exit 0
fi
[ "$CHECK_ONLY" = 1 ] && exit 1

before=$(for d in /sys/bus/iio/devices/iio:device*; do echo "$d=$(cat "$d/name" 2>/dev/null)"; done)

echo "### reprobing $I2C_DEV"
# Safe: only HID-SENSOR-* function nodes sit behind this device -- no input
# devices, so the touchscreen and keyboard are unaffected. Verified with
# `ls -d /sys/devices/.../i2c-ITE8350:00/0018:*/*/`.
echo "$I2C_DEV" | sudo tee "$I2C_DRV/unbind" >/dev/null 2>&1 || {
	echo "  unbind failed" >&2; exit 1; }
sleep 2
echo "$I2C_DEV" | sudo tee "$I2C_DRV/bind" >/dev/null 2>&1 || {
	echo "  bind failed" >&2; exit 1; }
sleep 4

echo "### sensor state after reprobe"
report

if is_stale accel_3d; then
	echo "  -> STILL STALE. A reboot is the next step." >&2
	exit 1
fi
echo "  -> accelerometer recovered"

after=$(for d in /sys/bus/iio/devices/iio:device*; do echo "$d=$(cat "$d/name" 2>/dev/null)"; done)
if [ "$before" = "$after" ]; then
	echo "### IIO indices unchanged -- waydroid-sensord's cached paths still valid"
	exit 0
fi

echo "### IIO indices CHANGED -- waydroid-sensord is now reading the wrong nodes"
diff <(echo "$before") <(echo "$after") | sed 's/^/    /'
if [ "$DO_RESTART" != 1 ]; then
	echo "    Re-run with --restart, or restart by hand. Until then Android's"
	echo "    sensors are wrong even though the hardware is fine."
	exit 1
fi

echo "### restarting container and session"
sudo systemctl restart waydroid-container >/dev/null 2>&1
sleep 6
# The container restart stops the session and does NOT bring it back.
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
nohup waydroid session start >/tmp/waydroid-session.log 2>&1 &
disown
for i in $(seq 1 25); do
	sleep 2
	c=$(waydroid status 2>&1 | awk -F'\t' '/Container/{print $2}')
	[ "$c" = "RUNNING" ] && { echo "  container RUNNING after $((i*2))s"; break; }
done
pgrep -af waydroid-sensord | grep -v pgrep | sed 's/^/  daemon: /'
