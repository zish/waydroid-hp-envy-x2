#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-wifid and its units. Run on the host, as root, or with
# DESTDIR set as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=/usr/lib/systemd/system \
#         WIFID_BIN=path/to/waydroid-wifid sh install.sh
#
# wifi/build.sh --install --unit remains the way to deploy to a running host
# over ssh; this script is the layout, and both use it. The daemon binary is not
# built here -- it comes from wifi/build.sh or from the RPM's %build.
#
# The two conf files are never overwritten on a live install. /etc/waydroid-wifid.conf
# names the radio to hand Android, and clobbering somebody's --device with the
# adapter this repository happens to know about is exactly the failure the
# daemon's fatal-on-missing-device rule exists to prevent (docs/33 trap 5).
# /etc/waydroid-wifi-share.conf lists the networks whose passphrases get copied
# into the container, so it is an opt-in record and 0600 for that reason.
set -eu

PREFIX=${PREFIX:-/usr/local}
# /etc, not $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels
# that lib_t, and init_t may not start a lib_t unit file. See docs/27 and the
# same note in artifacts/sensor-hub/install.sh. The RPM passes UNITDIR.
UNITDIR=${UNITDIR:-/etc/systemd/system}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")
repo=$(cd "$src/../.." && pwd)
WIFID_BIN=${WIFID_BIN:-$repo/build/wifi/daemon/waydroid-wifid}

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

# ------------------------------------------------------------------- binaries

if [ -f "$WIFID_BIN" ]; then
	install -D -m 0755 "$WIFID_BIN" "$DESTDIR$PREFIX/bin/waydroid-wifid"
else
	echo "no daemon at $WIFID_BIN -- build it with wifi/build.sh, or set WIFID_BIN" >&2
	exit 1
fi

for s in waydroid-wifi-nudge waydroid-wifi-sync; do
	subst "$src/$s" >"$src/.bin.tmp"
	install -D -m 0755 "$src/.bin.tmp" "$DESTDIR$PREFIX/bin/$s"
	rm -f "$src/.bin.tmp"
done

# ---------------------------------------------------------------------- units

for unit in waydroid-wifid.service waydroid-wifi-sync.service waydroid-wifi-sync.timer; do
	subst "$src/$unit" >"$src/.unit.tmp"
	install -D -m 0644 "$src/.unit.tmp" "$DESTDIR$UNITDIR/$unit"
	rm -f "$src/.unit.tmp"
done

# The symlinks `systemctl enable` would create, so the RPM needs no scriptlet --
# a requirement on an ostree host, where scriptlets run against the compose.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants" "$DESTDIR$UNITDIR/timers.target.wants"
ln -sf ../waydroid-wifid.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-wifid.service"
# The timer, not the service: the reconciler runs on a schedule, and enabling
# the service would fire one sync at boot before anyone has opted a network in.
ln -sf ../waydroid-wifi-sync.timer \
    "$DESTDIR$UNITDIR/timers.target.wants/waydroid-wifi-sync.timer"

# ------------------------------------------------------------------- config

install_conf() {
	mode=$1; file=$2; dest="$DESTDIR$SYSCONFDIR/$2"
	if [ -z "$DESTDIR" ] && [ -e "$dest" ]; then
		echo "keeping the existing $dest"
		return
	fi
	install -D -m "$mode" "$src/$file" "$dest"
}
install_conf 0644 waydroid-wifid.conf
install_conf 0600 waydroid-wifi-share.conf

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
	restorecon -F "$PREFIX/bin/waydroid-wifid" "$PREFIX/bin/waydroid-wifi-nudge" \
	    "$PREFIX/bin/waydroid-wifi-sync" \
	    "$UNITDIR/waydroid-wifid.service" "$UNITDIR/waydroid-wifi-sync.service" \
	    "$UNITDIR/waydroid-wifi-sync.timer" || true
fi
systemctl daemon-reload

cat <<EOM
installed:
  $PREFIX/bin/waydroid-wifid
  $PREFIX/bin/waydroid-wifi-nudge
  $PREFIX/bin/waydroid-wifi-sync
  $UNITDIR/waydroid-wifid.service        (wanted by multi-user.target)
  $UNITDIR/waydroid-wifi-sync.{service,timer}  (timer wanted by timers.target)
  $SYSCONFDIR/waydroid-wifid.conf
  $SYSCONFDIR/waydroid-wifi-share.conf

Nothing was started. Start the daemon with:
  systemctl start waydroid-wifid && systemctl start waydroid-wifi-sync.timer
EOM
