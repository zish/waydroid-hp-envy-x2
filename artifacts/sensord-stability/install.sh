#!/bin/sh
# Install the waydroid-sensord resource sampler and its timer. Honours
# DESTDIR/PREFIX/UNITDIR so this is both the by-hand install and an RPM's
# %install step -- one description of the layout, per the repo convention.
#
#   sudo sh install.sh
#   sudo sh install.sh --uninstall
#   DESTDIR=%{buildroot} PREFIX=/usr sh install.sh      # packaging
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
UNITDIR=${UNITDIR:-/etc/systemd/system}

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now waydroid-sensord-sample.timer 2>/dev/null || true
    rm -f "$UNITDIR/timers.target.wants/waydroid-sensord-sample.timer" \
          "$UNITDIR/waydroid-sensord-sample.timer" \
          "$UNITDIR/waydroid-sensord-sample.service" \
          "$BINDIR/waydroid-sensord-sample" \
          /var/lib/waydroid-sensord-sample.state
    systemctl daemon-reload
    echo "removed. /var/log/waydroid-sensord-stability.log* kept deliberately --"
    echo "it is the measurement, and nothing else writes it."
    exit 0
fi

install -D -m 0755 "$src/waydroid-sensord-sample" \
    "$DESTDIR$BINDIR/waydroid-sensord-sample"

for u in waydroid-sensord-sample.service waydroid-sensord-sample.timer; do
    sed "s|@BINDIR@|$BINDIR|g" "$src/$u" > "$src/.$u.tmp"
    install -D -m 0644 "$src/.$u.tmp" "$DESTDIR$UNITDIR/$u"
    rm -f "$src/.$u.tmp"
done

# Enabled with a .wants symlink rather than `systemctl enable`: it is the same
# thing enable would create, works identically under $UNITDIR wherever that is,
# and so a package needs no %post scriptlet -- which an ostree host could not
# rely on anyway. Same trick as artifacts/pidguard.
mkdir -p "$DESTDIR$UNITDIR/timers.target.wants"
ln -sf ../waydroid-sensord-sample.timer \
    "$DESTDIR$UNITDIR/timers.target.wants/waydroid-sensord-sample.timer"

# Named files only: restorecon -R on $UNITDIR would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-sensord-sample" \
        "$UNITDIR/waydroid-sensord-sample.service" \
        "$UNITDIR/waydroid-sensord-sample.timer" || true
fi

if [ -z "$DESTDIR" ]; then
    systemctl daemon-reload
    systemctl start waydroid-sensord-sample.timer
    systemctl --no-pager status waydroid-sensord-sample.timer | head -5 || true
fi
