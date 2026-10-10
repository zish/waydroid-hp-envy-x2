#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Let Android's APEX-packaged HALs talk to the rest of the container over
# binder. Run on the host, as root, or with DESTDIR set as the RPM's %install
# step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
#
# WHAT THIS FIXES
#
# On a Fedora host, Waydroid's container runs its APEX-packaged HALs in the
# spc_t domain while the rest of the container is container_runtime_t, and
# Fedora's policy allows binder between neither. Android does not boot: every
# transaction is refused, the kernel logs `binder: N:N transaction credentials
# failed`, and the whole boot stalls in bootanim. Verified by an A/B boot pair
# on 2026-10-08 with the host Enforcing throughout -- no boot in 240 s and 657
# denials without the module, boot in 18 seconds and zero denials with it.
# Full account in docs/64-vidiot01-atv-host.md and in the .cil's own header.
#
# THIS IS A GAP IN FEDORA'S POLICY, NOT A WAYDROID BUG. Fedora's own
# waydroid-selinux ships a `waydroid` module at priority 200 that grants exactly
# these binder permissions to waydroid_t, unconfined_t and unconfined_service_t
# -- and not to spc_t. This module is the stopgap; the real fix is upstream, and
# when it lands this package becomes redundant rather than wrong.
#
# THREE FILES, AND WHY THE LOADER IS ONE OF THEM
#
#   waydroid_binder.cil            the two allow rules, both directions
#   waydroid-binder-policy         loads it, idempotently by CIL hash, and then
#                                  ASKS THE KERNEL whether the rules are in force
#   waydroid-binder-policy.service runs the loader at boot
#
# The unit is not belt-and-braces. An RPM %post cannot load this on an
# rpm-ostree host -- scriptlets run against the compose, not the booted system,
# so the module never reaches the running machine. waydroid_backlight was found
# failing exactly that way on its first real install (2026-09-24): package
# present, policy absent, nothing reporting a problem. See
# artifacts/backlight/install.sh.
#
# CIL AND NOT .te ON PURPOSE: semodule compiles CIL directly, so this needs no
# selinux-policy-devel. On an rpm-ostree host that package would cost a layered
# install and a reboot, which is exactly what this repo avoids.
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
CILDIR=${CILDIR:-$PREFIX/share/waydroid-binder}
# See artifacts/overlay-manager/install.sh for why units default to /etc and not
# to $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels that
# lib_t, and init_t may not start a unit file labelled lib_t.
UNITDIR=${UNITDIR:-/etc/systemd/system}
MODULE=waydroid_binder
src=$(dirname "$0")

if [ "${1:-}" = "--uninstall" ]; then
	# Removing the module puts the host back exactly as it was, which on a host
	# running an APEX-HAL image means Android stops booting again. Nothing else
	# here uses these rules: both types belong to container-selinux and the base
	# policy's own decisions about them are untouched.
	if [ -x "$PREFIX/bin/waydroid-binder-policy" ]; then
		"$PREFIX/bin/waydroid-binder-policy" --unload || :
	else
		semodule -r "$MODULE" 2>/dev/null || echo "$MODULE was not loaded"
	fi
	rm -f "$CILDIR/$MODULE.cil" "$PREFIX/bin/waydroid-binder-policy"
	rm -f "$UNITDIR/waydroid-binder-policy.service" \
	      "$UNITDIR/multi-user.target.wants/waydroid-binder-policy.service"
	echo "removed $MODULE"
	exit 0
fi

install -D -m 0644 "$src/$MODULE.cil" "$DESTDIR$CILDIR/$MODULE.cil"
install -D -m 0755 "$src/waydroid-binder-policy" \
	"$DESTDIR$PREFIX/bin/waydroid-binder-policy"
sed "s|@BINDIR@|$PREFIX/bin|g" "$src/waydroid-binder-policy.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" \
	"$DESTDIR$UNITDIR/waydroid-binder-policy.service"
rm -f "$src/.unit.tmp"

# Enabled with the symlink `systemctl enable` would create, so the RPM needs no
# scriptlet -- required on an ostree host for the same reason as above.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-binder-policy.service \
	"$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-binder-policy.service"

# In packaging mode there is no running policy to load into -- just stage.
if [ -n "$DESTDIR" ]; then
	echo "staged into $DESTDIR (not loaded; the unit does that on the target)"
	exit 0
fi

# On a by-hand install, load it now as well as at the next boot. The loader both
# loads and verifies against the kernel, so its exit status is the answer.
"$DESTDIR$PREFIX/bin/waydroid-binder-policy"

# THE RESTART IS NAMED, NOT PERFORMED -- the same choice waydroid-ext-mdns and
# waydroid-ext-overlay-sync make. SELinux checks each binder transaction as it
# happens, so the new policy is in force immediately and a container that has
# not started yet will simply boot. But a container that ALREADY failed to boot
# for want of this policy does not recover on its own: its init gave up on the
# crash-looping HALs long ago, and only a fresh start re-runs them.
#
# On a kiosk host that restart drops the session to the greeter, which is not a
# thing an installer should decide. So it is printed.
echo
echo "Policy is in force now. If Waydroid is already running and Android did"
echo "not boot, it needs a fresh start to pick this up:"
echo "    waydroid session stop   # then start a new session"
echo "Restarting waydroid-container alone is NOT enough, and on a kiosk host it"
echo "drops the session to the greeter."
