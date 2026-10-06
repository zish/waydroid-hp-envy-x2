#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the mDNS reflector reconciler. Run on the host, as root, or with
# DESTDIR set as the RPM's %install step.
#
# This installs the mechanism and the values; the reconcile is what applies them,
# and with no DESTDIR this script runs it, because an installed reconciler that
# has not run leaves the host exactly as it was.
#
# Everything lands under $PREFIX (default /usr/local, which on this ostree host
# is a symlink to /var/usrlocal) plus one file in $SYSCONFDIR. PREFIX=/usr emits
# the packaged layout:
#     DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=/usr/lib/systemd/system \
#         SYSCONFDIR=/etc sh install.sh
# restorecon is skipped when DESTDIR is set -- a buildroot is never labelled, and
# on rpm-ostree SELinux labels come from the compose, not from a scriptlet.
set -eu

PREFIX=${PREFIX:-/usr/local}
# See artifacts/sensor-hub/install.sh for why units default to /etc and not to
# $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels that lib_t,
# and init_t may not start a unit file labelled lib_t. docs/27 has the measurement.
UNITDIR=${UNITDIR:-/etc/systemd/system}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g; s|@SYSCONFDIR@|$SYSCONFDIR|g" "$1"; }

subst "$src/waydroid-mdns-reflector" >"$src/.tool.tmp"
install -D -m 0755 "$src/.tool.tmp" "$DESTDIR$PREFIX/bin/waydroid-mdns-reflector"
rm -f "$src/.tool.tmp"

subst "$src/waydroid-mdns-reflector.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" "$DESTDIR$UNITDIR/waydroid-mdns-reflector.service"
rm -f "$src/.unit.tmp"

# Enabled with the symlink `systemctl enable` would create, so the RPM needs no
# scriptlet for it -- a requirement on an ostree host, where scriptlets run
# against the compose and not against the booted system.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-mdns-reflector.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-mdns-reflector.service"

# Never clobber an administrator's edited values on a manual re-install. The RPM
# gets the same guarantee from %config(noreplace); this is the hand-installed
# half of it, and the filter list is the one thing here somebody legitimately
# tunes.
conf=$DESTDIR$SYSCONFDIR/waydroid-mdns.conf
if [ -z "$DESTDIR" ] && [ -e "$conf" ]; then
    echo "kept existing: $SYSCONFDIR/waydroid-mdns.conf"
else
    install -D -m 0644 "$src/waydroid-mdns.conf" "$conf"
fi

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/waydroid-mdns-reflector" \
        "$UNITDIR/waydroid-mdns-reflector.service" \
        "$SYSCONFDIR/waydroid-mdns.conf" || true
fi
systemctl daemon-reload

echo "installed:"
echo "  $PREFIX/bin/waydroid-mdns-reflector"
echo "  $UNITDIR/waydroid-mdns-reflector.service   (wanted by multi-user.target)"
echo "  $SYSCONFDIR/waydroid-mdns.conf"
echo
# Not piped into sed for indentation: a pipeline's exit status would be sed's, and
# the reconciler's non-zero exits are the ones that matter -- an avahi too old for
# a key it was asked to set, or a daemon that would not restart. Reported, and not
# fatal: the files really are installed, and the boot unit will try again.
echo "reconciling now:"
if "$PREFIX/bin/waydroid-mdns-reflector"; then
    :
else
    echo "reconcile declined or failed (exit $?) -- see above. The files are"
    echo "installed and waydroid-mdns-reflector.service will try again at boot."
fi
echo
echo "Nothing here restarts the container, and nothing needed to: mDNS is"
echo "discovery over a live socket. Check it from the container's netns with"
echo "bin/mdns-listen.py -- docs/45-mdns-reflection.md has the command."
