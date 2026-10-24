#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-keystored, its unit and its configuration (goal 10, docs/75).
# Honours DESTDIR/PREFIX/UNITDIR/SYSCONFDIR, so this one script is both the
# by-hand install and the RPM's %install -- one description of the layout.
#
#   KEYSTORED_BIN=build/keystore-hal/waydroid-keystored sudo sh install.sh
#   DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=%{_unitdir} SYSCONFDIR=/etc \
#       KEYSTORED_BIN=... sh install.sh
#
# The daemon alone declares nothing to Android: keystore2 engages only a
# strongbox the VINTF manifest declares, and that is waydroid-ext-strongbox's
# overlay row, not this. The conf is never overwritten on a live install.
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
# /etc, not $PREFIX: /usr/local is /var/usrlocal on rpm-ostree, labelled lib_t,
# and init_t may not start a lib_t unit file (docs/27). The RPM passes UNITDIR.
UNITDIR=${UNITDIR:-/etc/systemd/system}
SYSCONFDIR=${SYSCONFDIR:-/etc}

src=$(CDPATH="" cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$src/../.." && pwd)
bin=${KEYSTORED_BIN:-$repo/build/keystore-hal/waydroid-keystored}
[ -x "$bin" ] || { echo "no daemon at $bin -- build it with keystore/hal/build.sh" >&2; exit 1; }

install -D -m 0755 "$bin" "$DESTDIR$BINDIR/waydroid-keystored"

u=waydroid-keystored.service
sed "s|@BINDIR@|$BINDIR|g" "$src/$u" >"$src/.$u.tmp"
install -D -m 0644 "$src/.$u.tmp" "$DESTDIR$UNITDIR/$u"
rm -f "$src/.$u.tmp"

# Enabled by a .wants symlink rather than `systemctl enable`, so the RPM needs no
# %post, which an rpm-ostree host could not rely on anyway.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf "../$u" "$DESTDIR$UNITDIR/multi-user.target.wants/$u"

conf="$DESTDIR$SYSCONFDIR/waydroid-keystored.conf"
if [ -z "$DESTDIR" ] && [ -e "$conf" ]; then
	echo "keeping the existing $conf"
else
	install -D -m 0644 "$src/waydroid-keystored.conf" "$conf"
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-keystored"
echo "  $DESTDIR$UNITDIR/$u (enabled)"
echo "  $conf"

[ -z "$DESTDIR" ] || exit 0

if command -v restorecon >/dev/null 2>&1; then
	restorecon -F "$BINDIR/waydroid-keystored" "$UNITDIR/$u" "$conf" || true
fi
echo
echo "next, between sessions (keystore2 meets the StrongBox once a session):"
echo "  systemctl daemon-reload && systemctl start $u"
echo "  journalctl -u $u"
