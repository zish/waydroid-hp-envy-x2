#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-overlay-sync and the boot unit that runs it. Run on the host,
# as root, or with DESTDIR set as the RPM's %install step.
#
# This installs the mechanism, not the payload: the overlay components are
# staged by artifacts/overlay/install.sh, and either installer is useful without
# the other -- the manager with no components staged does nothing and says so.
#
# Everything lands under $PREFIX (default /usr/local, an ostree symlink to
# /var/usrlocal). PREFIX=/usr emits the packaged layout. DESTDIR is honoured:
#     DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=/usr/lib/systemd/system sh install.sh
set -eu

PREFIX=${PREFIX:-/usr/local}
# See artifacts/sensor-hub/install.sh for why units default to /etc and not to
# $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels that lib_t,
# and init_t may not start a unit file labelled lib_t. docs/27 has the measurement.
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
# Where components stage their payload. /usr/lib and not /usr/share because most
# of them carry Android ELF; the reconciler still searches the old /usr/share
# location after this one, so nothing staged the old way stops working.
STAGEDIR=${STAGEDIR:-$PREFIX/lib/waydroid-overlay}
src=$(dirname "$0")

install -D -m 0755 "$src/waydroid-overlay-sync" \
    "$DESTDIR$PREFIX/bin/waydroid-overlay-sync"

sed "s|@BINDIR@|$PREFIX/bin|g" "$src/waydroid-overlay-sync.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" "$DESTDIR$UNITDIR/waydroid-overlay-sync.service"
rm -f "$src/.unit.tmp"

# Enabled with the symlink `systemctl enable` would create, so the RPM needs no
# scriptlet -- a requirement on an ostree host, where scriptlets run against the
# compose and not against the booted system.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-overlay-sync.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-overlay-sync.service"

# The directory the components stage into. Owned here so that the manager alone
# is a complete, working install.
mkdir -p "$DESTDIR$STAGEDIR/manifests"

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/waydroid-overlay-sync" \
        "$UNITDIR/waydroid-overlay-sync.service" || true
fi
systemctl daemon-reload

cat <<EOM
installed:
  $PREFIX/bin/waydroid-overlay-sync
  $UNITDIR/waydroid-overlay-sync.service   (wanted by multi-user.target)
  $STAGEDIR/          (stage components here)

Stage the components, then reconcile:
  sh artifacts/overlay/install.sh camera battery wifi widevine
  waydroid-overlay-sync --verify
  waydroid-overlay-sync

Anything it installs while the container is running is invisible to Android
until: systemctl restart waydroid-container.service
EOM
