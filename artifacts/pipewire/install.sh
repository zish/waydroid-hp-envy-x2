#!/bin/sh
# Install waydroid-pwd. Honours DESTDIR/PREFIX/UNITDIR/USERUNITDIR so this same
# script is both the by-hand install and the RPM's %install step -- one
# description of the layout, per the repo convention.
#
#   sudo sh install.sh
#   DESTDIR=%{buildroot} PREFIX=/usr sh install.sh      # packaging
set -eu

DESTDIR=${DESTDIR:-}
PREFIX=${PREFIX:-/usr/local}
BINDIR=${BINDIR:-$PREFIX/bin}
UNITDIR=${UNITDIR:-/etc/systemd/system}
# The user unit goes where a --user manager looks. Unlike UNITDIR there is no
# /etc/systemd/user default worth using for a package: systemctl --user reads
# /etc/systemd/user before /usr/lib/systemd/user, so an RPM passing
# %{_userunitdir} lands in the right place and a by-hand install stays out of it.
USERUNITDIR=${USERUNITDIR:-/etc/systemd/user}

src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

install -D -m 0755 "$src/waydroid-pwd" "$DESTDIR$BINDIR/waydroid-pwd"
install -D -m 0755 "$src/waydroid-pwd-publish" \
    "$DESTDIR$BINDIR/waydroid-pwd-publish"

for unit in waydroid-pwd.service waydroid-pwd-publish.service; do
    sed "s|@BINDIR@|$BINDIR|g" "$src/$unit" > "$src/.$unit.tmp"
    case $unit in
        waydroid-pwd.service) dir=$USERUNITDIR ;;
        *)                    dir=$UNITDIR ;;
    esac
    install -D -m 0644 "$src/.$unit.tmp" "$DESTDIR$dir/$unit"
    rm -f "$src/.$unit.tmp"
done

# Enabled with .wants symlinks rather than `systemctl enable`: same thing enable
# would create, works under any unit dir, and so the RPM needs no %post
# scriptlet -- which an ostree host could not rely on anyway. Same trick as
# artifacts/bluetooth, artifacts/media and artifacts/android-power.
mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
ln -sf ../waydroid-pwd-publish.service \
    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-pwd-publish.service"
mkdir -p "$DESTDIR$USERUNITDIR/default.target.wants"
ln -sf ../waydroid-pwd.service \
    "$DESTDIR$USERUNITDIR/default.target.wants/waydroid-pwd.service"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$BINDIR/waydroid-pwd" "$BINDIR/waydroid-pwd-publish" \
        "$UNITDIR/waydroid-pwd-publish.service" \
        "$USERUNITDIR/waydroid-pwd.service" || true
fi

echo "installed:"
echo "  $DESTDIR$BINDIR/waydroid-pwd"
echo "  $DESTDIR$BINDIR/waydroid-pwd-publish"
echo "  $DESTDIR$USERUNITDIR/waydroid-pwd.service"
echo "  $DESTDIR$UNITDIR/waydroid-pwd-publish.service"

if [ -z "$DESTDIR" ]; then
    echo
    echo "next:"
    echo "  systemctl daemon-reload && systemctl --user daemon-reload"
    echo "  systemctl --user start waydroid-pwd.service   # already enabled"
    echo "  systemctl start waydroid-pwd-publish.service  # already enabled"
    echo "  journalctl --user -fu waydroid-pwd"
    echo
    echo "The daemon needs no privilege: it is a --user unit, because PipeWire"
    echo "is a user service. Only the publisher is root, and only because the"
    echo "app's private directory is mode 0700."
    echo
    echo "The Android half is separate: pw-app/build.sh --install"
    echo
    echo "No policy file is installed: the daemon's built-in defaults are what"
    echo "policy.conf.example documents. To change them, copy that file to"
    echo "/etc/waydroid-pwd/policy.conf. It is shipped as documentation rather"
    echo "than into /etc because a policy the package owned would silently"
    echo "change what an already-running deployment permits on upgrade."
fi
