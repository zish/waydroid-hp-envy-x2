#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Let waydroid-sensord write the panel backlight. Run on the host, as root, or
# with DESTDIR set as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
#
# WHAT THIS FIXES
#
# container_manager.py spawns waydroid-sensord as waydroid_t, which may read
# sysfs but not write it, so ILight::setLight returned Status::UNKNOWN and
# Android's brightness slider moved nothing. The denial is dontaudit'ed and
# invisible to ausearch. Full account in docs/42-backlight-selinux.md.
#
# TWO HALVES, ONE FIX
#
#   waydroid_backlight.cil       declares waydroid_backlight_t and allows
#                                waydroid_t to write exactly that type
#   99-waydroid-backlight.rules  puts that label on the brightness attribute,
#                                on every boot, because sysfs labels do not
#                                persist
#
# Either alone does nothing. They install and revert together.
#
# CIL AND NOT .te ON PURPOSE: semodule compiles CIL directly, so this needs no
# selinux-policy-devel. On an rpm-ostree host that package would cost a layered
# install and a reboot, which is exactly what this repo avoids.
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
UDEVRULESDIR=${UDEVRULESDIR:-/etc/udev/rules.d}
CILDIR=${CILDIR:-$PREFIX/share/waydroid-backlight}
src=$(dirname "$0")

install -D -m 0644 "$src/waydroid_backlight.cil" "$DESTDIR$CILDIR/waydroid_backlight.cil"
install -D -m 0644 "$src/99-waydroid-backlight.rules" \
	"$DESTDIR$UDEVRULESDIR/99-waydroid-backlight.rules"

# Staging for a package: the %post scriptlet does the loading, because
# semodule and udevadm must run against the live system, not a buildroot.
if [ -n "$DESTDIR" ]; then exit 0; fi

if ! command -v semodule >/dev/null 2>&1; then
	echo "semodule not found -- is this an SELinux system?" >&2
	exit 1
fi

semodule -i "$CILDIR/waydroid_backlight.cil"

udevadm control --reload
udevadm trigger --subsystem-match=backlight --action=add

# Absence of errors is not success: confirm the label actually landed, because
# the relabel fails silently if the module did not load, and a rule that runs
# but achieves nothing looks identical to one that worked.
ok=0
for d in /sys/class/backlight/*/; do
	[ -e "$d/brightness" ] || continue
	ctx=$(ls -Z "$d/brightness" | awk '{print $1}')
	printf '  %-24s %s\n' "$(basename "$d")" "$ctx"
	case "$ctx" in *waydroid_backlight_t*) ok=1 ;; esac
done

if [ "$ok" != 1 ]; then
	echo "FAILED: no backlight carries waydroid_backlight_t" >&2
	exit 1
fi

cat <<EOM
installed:
  $CILDIR/waydroid_backlight.cil   (loaded: semodule -l | grep waydroid_backlight)
  $UDEVRULESDIR/99-waydroid-backlight.rules

The running daemon does NOT pick this up -- SELinux checks the write, and a
daemon already spawned as waydroid_t simply stops being denied from here on,
so no restart is needed for the fix itself. Verify with bin/brightness-test.sh,
and read its header first: a dimmed display reports SKIPPED, not FAILED.

To revert:
  semodule -r waydroid_backlight
  rm $UDEVRULESDIR/99-waydroid-backlight.rules
  udevadm control --reload
EOM
