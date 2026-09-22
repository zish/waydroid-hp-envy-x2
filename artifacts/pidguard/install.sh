#!/bin/sh
# Install waydroid-pidguard (the per-namespace pid_max cap, timer-driven) and
# waydroid-pid-reset (manual recovery for a container already past the cliff).
# Honours DESTDIR/PREFIX/UNITDIR so this same script is both the by-hand install
# and the RPM's %install step -- one description of the layout, per the repo
# convention.
#
#   sudo sh install.sh
#   DESTDIR=%{buildroot} PREFIX=/usr sh install.sh      # packaging
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
UNITDIR=${UNITDIR:-/etc/systemd/system}

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

install -D -m 0755 "$src/waydroid-pidguard"   "$DESTDIR$BINDIR/waydroid-pidguard"
install -D -m 0755 "$src/waydroid-pid-reset"  "$DESTDIR$BINDIR/waydroid-pid-reset"

for u in waydroid-pidguard.service waydroid-pidguard.timer; do
    sed "s|@BINDIR@|$BINDIR|g" "$src/$u" > "$src/.$u.tmp"
    install -D -m 0644 "$src/.$u.tmp" "$DESTDIR$UNITDIR/$u"
    rm -f "$src/.$u.tmp"
done

# Enabled with a .wants symlink rather than `systemctl enable`: it is the same
# thing enable would create, works identically under $UNITDIR wherever that is,
# and so the RPM needs no %post scriptlet -- which an ostree host could not rely
# on anyway. Same trick as artifacts/restartd and artifacts/media.
mkdir -p "$DESTDIR$UNITDIR/timers.target.wants"
ln -sf ../waydroid-pidguard.timer "$DESTDIR$UNITDIR/timers.target.wants/waydroid-pidguard.timer"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-pidguard" "$BINDIR/waydroid-pid-reset" \
        "$UNITDIR/waydroid-pidguard.service" "$UNITDIR/waydroid-pidguard.timer" || true
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-pidguard"
echo "  $DESTDIR$BINDIR/waydroid-pid-reset"
echo "  $DESTDIR$UNITDIR/waydroid-pidguard.service"
echo "  $DESTDIR$UNITDIR/waydroid-pidguard.timer"
echo "  $DESTDIR$UNITDIR/timers.target.wants/waydroid-pidguard.timer"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  $BINDIR/waydroid-pidguard --status        # see what it sees"
    echo "  $BINDIR/waydroid-pidguard --dry-run       # what it would change"
    echo "  systemctl daemon-reload"
    echo "  systemctl start waydroid-pidguard.timer   # already enabled by the symlink"
    echo "  journalctl -u waydroid-pidguard"
    echo
    echo "REQUIRES Linux >= 6.14 for per-namespace pid_max. On an older kernel the"
    echo "guard detects that the host's pid_max moved, restores it, and refuses to"
    echo "run -- use the host-wide cap from waydroid#2071 instead."
    echo "Tunables go in /etc/waydroid-pidguard.conf as WAYDROID_PIDGUARD_*=..."
fi
