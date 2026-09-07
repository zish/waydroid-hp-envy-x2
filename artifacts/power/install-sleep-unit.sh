#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the periodic-sync sleep/resume unit. Run on the host, as root.
#
# SCOPE: this installs only the sleep/resume legs of the sync feature -- the
# replacement for /etc/systemd/system-sleep/50-waydroid-sync, which never ran
# (systemd 259 scans only /usr/lib/systemd/system-sleep, empty and read-only
# here; docs/27). It does NOT install waydroid-sync, waydroid-bt-restore or the
# timer: those are already deployed and unchanged, and the timer is deliberately
# left DISABLED per docs/06. The other files in this directory -- the two logind
# and sleep drop-ins -- are installed by hand; see README.md.
#
# Everything lands under $PREFIX (default /usr/local, an ostree symlink to
# /var/usrlocal). PREFIX=/usr emits the packaged layout. DESTDIR is honoured so
# this doubles as part of the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install-sleep-unit.sh
set -eu

PREFIX=${PREFIX:-/usr/local}
# System units go to /etc by default, NOT under $PREFIX. /usr/local is a symlink to
# /var/usrlocal, which SELinux labels lib_t, and init_t may not start a service whose
# unit file is lib_t. /etc/systemd/system is systemd_unit_file_t by default. The RPM
# passes UNITDIR=/usr/lib/systemd/system, correctly labelled too. See docs/27.
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

subst "$src/waydroid-sync-sleep" >"$src/.sleep.tmp"
install -D -m 0755 "$src/.sleep.tmp" "$DESTDIR$PREFIX/bin/waydroid-sync-sleep"
rm -f "$src/.sleep.tmp"

subst "$src/waydroid-sync-sleep.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" \
    "$DESTDIR$UNITDIR/waydroid-sync-sleep.service"
rm -f "$src/.unit.tmp"

mkdir -p "$DESTDIR$UNITDIR/sleep.target.wants"
ln -sf ../waydroid-sync-sleep.service \
    "$DESTDIR$UNITDIR/sleep.target.wants/waydroid-sync-sleep.service"

if [ -n "$DESTDIR" ]; then exit 0; fi

if [ -e /etc/systemd/system-sleep/50-waydroid-sync ]; then
    rm -f /etc/systemd/system-sleep/50-waydroid-sync
    echo "removed the dead hook /etc/systemd/system-sleep/50-waydroid-sync"
fi

# Named files only: a recursive restorecon on $UNITDIR would relabel every unit in
# /etc/systemd/system, which is far outside this installer's business.
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/waydroid-sync-sleep" \
        "$UNITDIR/waydroid-sync-sleep.service" || true
fi
systemctl daemon-reload

cat <<EOF
installed:
  $PREFIX/bin/waydroid-sync-sleep
  $UNITDIR/waydroid-sync-sleep.service   (wanted by sleep.target)

Note the feature as a whole stays dormant until waydroid-sync.timer is enabled:
with no sync windows, waydroid-sync never blocks bluetooth, so the deferred
restore this arms finds no state to restore and only clears the cycle marker.
EOF
