#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-swtpm (a software TPM 2.0 on a unix socket, for the keystore
# backend of docs/65) and waydroid-tpm-check (the TCTI-agnostic proof that a TPM
# does what that backend needs). Honours DESTDIR/PREFIX/UNITDIR so this same
# script is both the by-hand install and the RPM's %install step -- one
# description of the layout, per the repo convention.
#
#   sudo sh install.sh                                   # needs swtpm installed
#   DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=%{_unitdir} sh install.sh
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
LIBEXECDIR=${LIBEXECDIR:-$PREFIX/libexec}
UNITDIR=${UNITDIR:-/etc/systemd/system}

src=$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)

install -D -m 0755 "$src/waydroid-swtpm"     "$DESTDIR$LIBEXECDIR/waydroid-swtpm"
install -D -m 0755 "$src/waydroid-tpm-check" "$DESTDIR$BINDIR/waydroid-tpm-check"

u=waydroid-swtpm.service
sed "s|@LIBEXECDIR@|$LIBEXECDIR|g" "$src/$u" > "$src/.$u.tmp"
install -D -m 0644 "$src/.$u.tmp" "$DESTDIR$UNITDIR/$u"
rm -f "$src/.$u.tmp"

# Enabled with a .wants symlink rather than `systemctl enable`, so the RPM needs
# no %post -- which an ostree host could not rely on anyway. Same trick as
# artifacts/pidguard and artifacts/mdns.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf "../$u" "$DESTDIR$UNITDIR/multi-user.target.wants/$u"

# Named files only. The wrapper's label is load-bearing: systemd must run it as
# unconfined_service_t, which Fedora's policy does for bin_t and usr_t alike --
# /usr/libexec is bin_t, /usr/local/libexec is usr_t. See the wrapper's header.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$LIBEXECDIR/waydroid-swtpm" "$BINDIR/waydroid-tpm-check" "$UNITDIR/$u" || true
fi

echo "installed:"
echo "  $DESTDIR$LIBEXECDIR/waydroid-swtpm"
echo "  $DESTDIR$BINDIR/waydroid-tpm-check"
echo "  $DESTDIR$UNITDIR/$u"
echo "  $DESTDIR$UNITDIR/multi-user.target.wants/$u"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  systemctl daemon-reload"
    echo "  systemctl start $u         # already enabled by the symlink"
    echo "  journalctl -u $u           # names the SELinux domain on every start"
    echo "  sudo $BINDIR/waydroid-tpm-check"
    command -v swtpm >/dev/null 2>&1 || echo "WARNING: swtpm is not installed; the unit will fail until it is."
fi
