#!/bin/sh
# Install the graceful-logout hooks. Run on the host, as root.
#
# Everything lands under $PREFIX (default /usr/local, which on this ostree host is
# a symlink to /var/usrlocal) plus one file in /etc. Nothing is written to /usr, so
# no rpm-ostree layering and no reboot.
#
# The PREFIX substitution is here on purpose: an RPM installs the identical files
# with PREFIX=/usr, at which point every path is one an RPM may own. See docs/24.
#
# DESTDIR is honoured so this doubles as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr SWAY_CONFD=/usr/share/sway/config.d sh install.sh
# restorecon is skipped when DESTDIR is set -- a buildroot is never labelled, and
# on rpm-ostree SELinux labels come from the compose, not from a scriptlet.
set -eu

PREFIX=${PREFIX:-/usr/local}
SWAY_CONFD=${SWAY_CONFD:-/etc/sway/config.d}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

subst "$src/waydroid-graceful-exit" >"$src/.exit.tmp"
install -D -m 0755 "$src/.exit.tmp" "$DESTDIR$PREFIX/bin/waydroid-graceful-exit"
rm -f "$src/.exit.tmp"

subst "$src/waydroid-graceful-exit.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" "$DESTDIR$PREFIX/lib/systemd/user/waydroid-graceful-exit.service"
rm -f "$src/.unit.tmp"

# Enable for every user without touching any home directory: systemd merges .wants
# directories across the whole user unit search path.
mkdir -p "$DESTDIR$PREFIX/lib/systemd/user/graphical-session.target.wants"
ln -sf ../waydroid-graceful-exit.service \
    "$DESTDIR$PREFIX/lib/systemd/user/graphical-session.target.wants/waydroid-graceful-exit.service"

subst "$src/95-waydroid-graceful-exit.conf" >"$src/.conf.tmp"
install -D -m 0644 "$src/.conf.tmp" "$DESTDIR$SWAY_CONFD/95-waydroid-graceful-exit.conf"
rm -f "$src/.conf.tmp"

if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$PREFIX/bin/waydroid-graceful-exit" "$PREFIX/lib/systemd/user" \
        "$SWAY_CONFD/95-waydroid-graceful-exit.conf" || true
fi

if [ -n "$DESTDIR" ]; then exit 0; fi
echo "installed. Active for new logins; for the current session:"
echo "  systemctl --user daemon-reload && systemctl --user start waydroid-graceful-exit"
echo "  swaymsg reload"
