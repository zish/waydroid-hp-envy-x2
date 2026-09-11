#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-sensord. Run on the host, as root, or with DESTDIR set as the
# RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr SENSORD_BIN=path/to/waydroid-sensord sh install.sh
#
# There is no unit and no config to install, and that is the design: Waydroid's
# own container_manager.py starts a host daemon called waydroid-sensord if one
# is on PATH, and images.py sets waydroid.stub_sensors_hal=1 only when it is
# NOT -- so the guest's stub HAL stands down by itself. Putting the binary on
# PATH is the entire installation. See sensors/build.sh and docs/14-sensors.md.
#
# waydroid-sensors.conf is deliberately NOT installed into /etc. Every key in it
# is shown at its built-in default, so shipping it would give the defaults a
# second home that can silently drift from the code. It goes in %doc; copy it to
# /etc/waydroid-sensors.conf only when something actually needs changing.
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")
repo=$(cd "$src/../.." && pwd)
SENSORD_BIN=${SENSORD_BIN:-$repo/build/sensors/waydroid-sensord}

if [ ! -f "$SENSORD_BIN" ]; then
	echo "no daemon at $SENSORD_BIN -- build it with sensors/build.sh, or set SENSORD_BIN" >&2
	exit 1
fi

install -D -m 0755 "$SENSORD_BIN" "$DESTDIR$PREFIX/bin/waydroid-sensord"

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
	restorecon -F "$PREFIX/bin/waydroid-sensord" || true
fi

cat <<EOM
installed:
  $PREFIX/bin/waydroid-sensord

It is picked up by the NEXT session start, because waydroid.prop is regenerated
then and only then:
  waydroid session stop && waydroid session start
Verify with bin/sensors-test.sh.
EOM
