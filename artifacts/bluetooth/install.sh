#!/bin/sh
# Install waydroid-btd. Honours DESTDIR/PREFIX/UNITDIR so this same script is
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

install -D -m 0755 "$src/waydroid-btd" "$DESTDIR$BINDIR/waydroid-btd"
sed "s|@BINDIR@|$BINDIR|g" "$src/waydroid-btd.service" \
    > "$src/.waydroid-btd.service.tmp"
install -D -m 0644 "$src/.waydroid-btd.service.tmp" \
    "$DESTDIR$UNITDIR/waydroid-btd.service"
rm -f "$src/.waydroid-btd.service.tmp"

# Enabled with a .wants symlink rather than `systemctl enable`: same thing
# enable would create, works under any $UNITDIR, and so the RPM needs no %post
# scriptlet -- which an ostree host could not rely on anyway. Same trick as
# artifacts/media and artifacts/android-power.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-btd.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-btd.service"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-btd" \
        "$UNITDIR/waydroid-btd.service" || true
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-btd"
echo "  $DESTDIR$UNITDIR/waydroid-btd.service"
echo "  $DESTDIR$UNITDIR/multi-user.target.wants/waydroid-btd.service"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  systemctl daemon-reload"
    echo "  systemctl start waydroid-btd.service   # already enabled by the symlink"
    echo "  journalctl -fu waydroid-btd"
    echo
    echo "The Android half is separate: bt-app/build.sh --install"
fi
