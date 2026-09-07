#!/bin/sh
# Install the Waydroid-in-cage session. Run on the host, as root.
#
# Depends on waydroid-graceful-exit (artifacts/graceful-exit, docs/24) being
# installed with the --keep-session flag; the check below warns if it is not.
#
# Everything lands under $PREFIX (default /usr/local, an ostree symlink to
# /var/usrlocal) plus the session entry in $SESSIONDIR. Nothing is written to
# /usr, so no rpm-ostree layering and no reboot. PREFIX=/usr with
# SESSIONDIR=/usr/share/wayland-sessions emits the packaged layout. See docs/25.
#
# DESTDIR is honoured so this doubles as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr SESSIONDIR=/usr/share/wayland-sessions sh install.sh
# restorecon is skipped when DESTDIR is set -- a buildroot is never labelled, and
# on rpm-ostree SELinux labels come from the compose, not from a scriptlet.
set -eu

PREFIX=${PREFIX:-/usr/local}
SESSIONDIR=${SESSIONDIR:-/etc/wayland-sessions}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

subst "$src/waydroid-cage-session" >"$src/.wrapper.tmp"
install -D -m 0755 "$src/.wrapper.tmp" "$DESTDIR$PREFIX/bin/waydroid-cage-session"
rm -f "$src/.wrapper.tmp"

subst "$src/waydroid-cage.desktop" >"$src/.desktop.tmp"
install -D -m 0644 "$src/.desktop.tmp" "$DESTDIR$SESSIONDIR/waydroid-cage.desktop"
rm -f "$src/.desktop.tmp"

if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/waydroid-cage-session" \
        "$SESSIONDIR/waydroid-cage.desktop" || true
fi

if [ -z "$DESTDIR" ] && ! grep -q -- '--keep-session' "$PREFIX/bin/waydroid-graceful-exit" 2>/dev/null; then
    echo "WARNING: $PREFIX/bin/waydroid-graceful-exit is missing or predates" >&2
    echo "         --keep-session. Reinstall it from artifacts/graceful-exit," >&2
    echo "         or the logout path will hard-kill Android." >&2
fi

[ -n "$DESTDIR" ] ||
    echo "installed. SDDM picks the session up with no restart; pick 'Waydroid in Cage'."
