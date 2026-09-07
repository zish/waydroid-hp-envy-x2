#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the ITE8350 sensor-hub resume check. Run on the host, as root.
#
# This is docs/19's safety net for the suspend wedge: after s2idle the hub can
# keep answering reads with a frozen value, which is indistinguishable from the
# sign bug docs/18 fixed, and only a driver reprobe clears it.
#
# It ships as two units rather than the /etc/systemd/system-sleep/ite8350 hook it
# used to be, because that hook never ran -- systemd 259 scans only
# /usr/lib/systemd/system-sleep, empty and read-only here. docs/27 has the
# measurements. This installer REMOVES the dead hook if it finds one.
#
# Everything lands under $PREFIX (default /usr/local, an ostree symlink to
# /var/usrlocal). PREFIX=/usr emits the packaged layout. DESTDIR is honoured so
# this doubles as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
set -eu

PREFIX=${PREFIX:-/usr/local}
# System units go to /etc by default, NOT under $PREFIX. /usr/local is a symlink to
# /var/usrlocal, which SELinux labels lib_t, and init_t may not start a service whose
# unit file is lib_t -- measured: a unit there fails with "avc: denied { start } ...
# tclass=service" the moment systemd itself tries to start it. /etc/systemd/system is
# systemd_unit_file_t by default. The RPM passes UNITDIR=/usr/lib/systemd/system,
# which is correctly labelled too. See docs/27.
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

subst "$src/ite8350-resume-check" >"$src/.check.tmp"
install -D -m 0755 "$src/.check.tmp" "$DESTDIR$PREFIX/bin/ite8350-resume-check"
rm -f "$src/.check.tmp"

for unit in ite8350-resume-check.service ite8350-sleep.service; do
    subst "$src/$unit" >"$src/.unit.tmp"
    install -D -m 0644 "$src/.unit.tmp" \
        "$DESTDIR$UNITDIR/$unit"
    rm -f "$src/.unit.tmp"
done

# Enabled with a .wants symlink rather than `systemctl enable` -- the same thing
# enable would create, so the RPM needs no scriptlet.
mkdir -p "$DESTDIR$UNITDIR/sleep.target.wants"
ln -sf ../ite8350-sleep.service \
    "$DESTDIR$UNITDIR/sleep.target.wants/ite8350-sleep.service"

if [ -n "$DESTDIR" ]; then exit 0; fi

# Only for the live install: the hook this replaces would otherwise sit there
# looking like a working safety net.
if [ -e /etc/systemd/system-sleep/ite8350 ]; then
    rm -f /etc/systemd/system-sleep/ite8350
    echo "removed the dead hook /etc/systemd/system-sleep/ite8350"
fi

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, which is far outside this installer's business.
if command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/ite8350-resume-check" \
        "$UNITDIR/ite8350-resume-check.service" \
        "$UNITDIR/ite8350-sleep.service" || true
fi
systemctl daemon-reload

cat <<EOF
installed:
  $PREFIX/bin/ite8350-resume-check
  $UNITDIR/ite8350-resume-check.service
  $UNITDIR/ite8350-sleep.service   (wanted by sleep.target)

Check the wiring, and run the check on demand:
  systemctl list-dependencies sleep.target | grep ite8350
  systemctl start ite8350-resume-check && journalctl -t ite8350-resume -n 20
EOF
