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
# See artifacts/overlay-manager/install.sh for why units default to /etc and
# not to $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels that
# lib_t, and init_t may not start a unit file labelled lib_t.
UNITDIR=${UNITDIR:-/etc/systemd/system}
src=$(dirname "$0")

install -D -m 0644 "$src/waydroid_backlight.cil" "$DESTDIR$CILDIR/waydroid_backlight.cil"
install -D -m 0644 "$src/99-waydroid-backlight.rules" \
	"$DESTDIR$UDEVRULESDIR/99-waydroid-backlight.rules"

# The loader and its boot unit. The module is loaded from here and NOT from the
# package's %post, because on an rpm-ostree host a scriptlet runs against the
# compose and the policy never reaches the booted system -- found the hard way
# on 2026-09-24. See the script's own header.
install -D -m 0755 "$src/waydroid-backlight-policy" \
	"$DESTDIR$PREFIX/bin/waydroid-backlight-policy"
sed "s|@BINDIR@|$PREFIX/bin|g" "$src/waydroid-backlight-policy.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" \
	"$DESTDIR$UNITDIR/waydroid-backlight-policy.service"
rm -f "$src/.unit.tmp"

# Enabled with the symlink `systemctl enable` would create, so the RPM needs no
# scriptlet -- required on an ostree host for the same reason as above.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-backlight-policy.service \
	"$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-backlight-policy.service"

# Staging for a package: loading happens at boot, from the unit above.
if [ -n "$DESTDIR" ]; then exit 0; fi

if ! command -v semodule >/dev/null 2>&1; then
	echo "semodule not found -- is this an SELinux system?" >&2
	exit 1
fi

systemctl daemon-reload

# One call does the module, the udev reload and the label check, and reports a
# label that did not land -- absence of errors is not success, because a relabel
# fails silently when the module is missing and a rule that runs and achieves
# nothing looks identical to one that worked.
CIL="$CILDIR/waydroid_backlight.cil" "$PREFIX/bin/waydroid-backlight-policy"

cat <<EOM
installed:
  $CILDIR/waydroid_backlight.cil   (loaded: semodule -l | grep waydroid_backlight)
  $UDEVRULESDIR/99-waydroid-backlight.rules
  $PREFIX/bin/waydroid-backlight-policy
  $UNITDIR/waydroid-backlight-policy.service   (wanted by multi-user.target)

The running daemon does NOT pick this up -- SELinux checks the write, and a
daemon already spawned as waydroid_t simply stops being denied from here on,
so no restart is needed for the fix itself. Verify with bin/brightness-test.sh,
and read its header first: a dimmed display reports SKIPPED, not FAILED.

To revert:
  waydroid-backlight-policy --unload
  rm $UDEVRULESDIR/99-waydroid-backlight.rules
  udevadm control --reload
EOM
