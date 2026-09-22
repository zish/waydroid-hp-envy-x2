#!/bin/sh
# Install waydroid-restartd. Honours DESTDIR/PREFIX/UNITDIR so this same script is
# both the by-hand install and the RPM's %install step -- one description of the
# layout, per the repo convention.
#
#   sudo sh install.sh
#   DESTDIR=%{buildroot} PREFIX=/usr sh install.sh      # packaging
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
UNITDIR=${UNITDIR:-/etc/systemd/system}

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

install -D -m 0755 "$src/waydroid-restartd" "$DESTDIR$BINDIR/waydroid-restartd"
sed "s|@BINDIR@|$BINDIR|g" "$src/waydroid-restartd.service" \
    > "$src/.waydroid-restartd.service.tmp"
install -D -m 0644 "$src/.waydroid-restartd.service.tmp" \
    "$DESTDIR$UNITDIR/waydroid-restartd.service"
rm -f "$src/.waydroid-restartd.service.tmp"

# Enabled with a .wants symlink rather than `systemctl enable`: it is the same
# thing enable would create, works identically under $UNITDIR wherever that is,
# and so the RPM needs no %post scriptlet -- which an ostree host could not rely
# on anyway. Same trick as artifacts/media and artifacts/graceful-exit.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-restartd.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-restartd.service"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-restartd" \
        "$UNITDIR/waydroid-restartd.service" || true
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-restartd"
echo "  $DESTDIR$UNITDIR/waydroid-restartd.service"
echo "  $DESTDIR$UNITDIR/multi-user.target.wants/waydroid-restartd.service"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  $BINDIR/waydroid-restartd --once --dry-run --verbose   # see what it sees"
    echo "  systemctl daemon-reload"
    echo "  systemctl start waydroid-restartd.service   # already enabled by the symlink"
    echo "  journalctl -fu waydroid-restartd"
    echo
    echo "Tunables go in /etc/waydroid-restartd.conf as WAYDROID_RESTARTD_*=..."
    echo "Read the daemon's header before changing the intervals: the fast cascade"
    echo "poll is what stops the netd<->zygote onrestart pair from ping-ponging."
fi
