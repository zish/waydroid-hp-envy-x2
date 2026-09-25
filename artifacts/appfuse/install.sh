#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Make Android's AppFuse work in the container. Run on the host, as root, or with
# DESTDIR set as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
#
# WHAT THIS FIXES
#
# StorageManager.openProxyFileDescriptor() -- and so every openDocument in a
# DocumentsProvider that synthesises its bytes -- failed on every call with
# `IllegalStateException: Failed to mount`, because vold asks mount(2) for an
# SELinux context Fedora's policy cannot parse. Three identifiers are missing and
# one of them is the SELinux *user* `u`. Full account in docs/55-appfuse.md and in
# the .cil's own header.
#
# THREE FILES, AND WHY THE LOADER IS ONE OF THEM
#
#   waydroid_appfuse.cil             declares the user, the two types, and the one
#                                    allow rule the mount needs
#   waydroid-appfuse-policy          loads it, idempotently by CIL hash, and then
#                                    VERIFIES the kernel will parse the contexts
#   waydroid-appfuse-policy.service  runs the loader at boot
#
# The unit is not belt-and-braces. An RPM %post cannot load this on an rpm-ostree
# host -- scriptlets run against the compose, not the booted system, so the policy
# never reaches the running machine. waydroid_backlight was found failing exactly
# that way on its first real install (2026-09-24): package present, policy absent,
# nothing reporting a problem. See artifacts/backlight/install.sh.
#
# Unlike that module this one needs nothing else at boot -- there are no sysfs
# labels to reapply, because `semodule -i` persists the module to
# /etc/selinux/targeted/active/modules by itself. The unit exists purely to get
# the load to happen on the booted system at least once.
#
# CIL AND NOT .te ON PURPOSE: semodule compiles CIL directly, so this needs no
# selinux-policy-devel. On an rpm-ostree host that package would cost a layered
# install and a reboot, which is exactly what this repo avoids.
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
CILDIR=${CILDIR:-$PREFIX/share/waydroid-appfuse}
# See artifacts/overlay-manager/install.sh for why units default to /etc and not
# to $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels that lib_t,
# and init_t may not start a unit file labelled lib_t.
UNITDIR=${UNITDIR:-/etc/systemd/system}
MODULE=waydroid_appfuse
src=$(dirname "$0")

if [ "${1:-}" = "--uninstall" ]; then
	# Removing the module puts AppFuse back exactly as it was: openDocument starts
	# failing again with `Failed to mount`. Nothing else on this host uses these
	# types or the `u` user, so nothing else notices.
	if [ -x "$PREFIX/bin/waydroid-appfuse-policy" ]; then
		"$PREFIX/bin/waydroid-appfuse-policy" --unload || :
	else
		semodule -r "$MODULE" 2>/dev/null || echo "$MODULE was not loaded"
	fi
	rm -f "$CILDIR/$MODULE.cil" "$PREFIX/bin/waydroid-appfuse-policy"
	rm -f "$UNITDIR/waydroid-appfuse-policy.service" \
	      "$UNITDIR/multi-user.target.wants/waydroid-appfuse-policy.service"
	echo "removed $MODULE"
	exit 0
fi

install -D -m 0644 "$src/$MODULE.cil" "$DESTDIR$CILDIR/$MODULE.cil"
install -D -m 0755 "$src/waydroid-appfuse-policy" \
	"$DESTDIR$PREFIX/bin/waydroid-appfuse-policy"
sed "s|@BINDIR@|$PREFIX/bin|g" "$src/waydroid-appfuse-policy.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" \
	"$DESTDIR$UNITDIR/waydroid-appfuse-policy.service"
rm -f "$src/.unit.tmp"

# Enabled with the symlink `systemctl enable` would create, so the RPM needs no
# scriptlet -- required on an ostree host for the same reason as above.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-appfuse-policy.service \
	"$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-appfuse-policy.service"

# In packaging mode there is no running policy to load into -- just stage.
if [ -n "$DESTDIR" ]; then
	echo "staged into $DESTDIR (not loaded; the unit does that on the target)"
	exit 0
fi

# On a by-hand install, load it now as well as at the next boot. The loader both
# loads and verifies, so its exit status is the answer.
"$DESTDIR$PREFIX/bin/waydroid-appfuse-policy"

# No container restart is needed and none should be done: vold performs the
# AppFuse mount on demand, per openProxyFileDescriptor call, so the next call
# already uses the new policy. Restarting the container would drop a kiosk
# session to the greeter for nothing.
echo "AppFuse is available immediately -- no container restart needed."
echo "Verify with bin/appfuse-test.sh."
