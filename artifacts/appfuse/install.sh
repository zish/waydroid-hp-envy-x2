#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Make Android's AppFuse work in the container. Run on the host, as root, or with
# DESTDIR set as an RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
#
# WHAT THIS FIXES
#
# StorageManager.openProxyFileDescriptor() -- and so every openDocument in a
# DocumentsProvider that synthesises its bytes -- failed on every call with
# `IllegalStateException: Failed to mount`, because vold asks mount(2) for an
# SELinux context Fedora's policy cannot parse. Full account, and the three
# missing identifiers, in docs/55-appfuse.md and in the .cil's own header.
#
# ONE FILE, NO UDEV RULES, NO UNIT
#
# Unlike waydroid_backlight (docs/42) this needs nothing at boot. That module has
# a loader service because sysfs labels do not survive a reboot; this one only
# declares policy, and `semodule -i` writes it into
# /etc/selinux/targeted/active/modules/ where it persists by itself. Verified:
# the module is in the store on disk, not just in the running policy.
#
# PACKAGERS, READ THIS: do NOT load the module from an RPM %post. On an
# rpm-ostree host a scriptlet runs against the compose and the policy never
# reaches the booted system -- found the hard way on 2026-09-24, see
# artifacts/backlight/install.sh. Either ship a boot-time loader the way that
# package does, or require the administrator to run this script once.
#
# CIL AND NOT .te ON PURPOSE: semodule compiles CIL directly, so this needs no
# selinux-policy-devel. On an rpm-ostree host that package would cost a layered
# install and a reboot, which is exactly what this repo avoids.
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
CILDIR=${CILDIR:-$PREFIX/share/waydroid-appfuse}
MODULE=waydroid_appfuse
src=$(dirname "$0")

if [ "${1:-}" = "--uninstall" ]; then
	# Removing the module puts AppFuse back exactly as it was: openDocument
	# starts failing again with `Failed to mount`. Nothing else on the host uses
	# these types or the `u` user, so nothing else notices.
	semodule -r "$MODULE" 2>/dev/null || echo "$MODULE was not loaded"
	rm -f "$CILDIR/$MODULE.cil"
	echo "removed $MODULE"
	exit 0
fi

install -D -m 0644 "$src/$MODULE.cil" "$DESTDIR$CILDIR/$MODULE.cil"

# In packaging mode there is no running policy to load into -- just stage the file.
if [ -n "$DESTDIR" ]; then
	echo "staged $DESTDIR$CILDIR/$MODULE.cil (not loaded; see the note above)"
	exit 0
fi

semodule -i "$CILDIR/$MODULE.cil"
echo "loaded $MODULE"

# Say so rather than assuming it. A module that failed to take is the one thing
# that would make every other symptom in docs/55 come back looking like a new bug.
if semodule -l | grep -q "^$MODULE"; then
	echo "verified: $MODULE is in the policy store"
else
	echo "WARNING: $MODULE is not listed by semodule -l" >&2
	exit 1
fi

# No container restart is needed and none should be done: vold performs the
# AppFuse mount on demand, per openProxyFileDescriptor call, so the next call
# already uses the new policy. Restarting the container would drop a kiosk
# session to the greeter for nothing.
echo "AppFuse is available immediately -- no container restart needed."
echo "Verify with bin/appfuse-test.sh."
