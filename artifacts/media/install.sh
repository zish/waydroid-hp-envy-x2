#!/bin/sh
# Install waydroid-mediad. Honours DESTDIR/PREFIX/UNITDIR so this same script is
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

install -D -m 0755 "$src/waydroid-mediad" "$DESTDIR$BINDIR/waydroid-mediad"
sed "s|@BINDIR@|$BINDIR|g" "$src/waydroid-mediad.service" \
    > "$src/.waydroid-mediad.service.tmp"
install -D -m 0644 "$src/.waydroid-mediad.service.tmp" \
    "$DESTDIR$UNITDIR/waydroid-mediad.service"
rm -f "$src/.waydroid-mediad.service.tmp"

# Enabled with a .wants symlink rather than `systemctl enable`: it is the same
# thing enable would create, works identically under $UNITDIR wherever that is,
# and so the RPM needs no %post scriptlet -- which an ostree host could not rely
# on anyway. Same trick as artifacts/android-power and artifacts/graceful-exit.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-mediad.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-mediad.service"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-mediad" \
        "$UNITDIR/waydroid-mediad.service" || true
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-mediad"
echo "  $DESTDIR$UNITDIR/waydroid-mediad.service"
echo "  $DESTDIR$UNITDIR/multi-user.target.wants/waydroid-mediad.service"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  systemctl daemon-reload"
    echo "  systemctl start waydroid-mediad.service   # already enabled by the symlink"
    echo "  journalctl -fu waydroid-mediad"
    echo
    echo "The Android half is separate: media-app/build.sh --install"
fi
