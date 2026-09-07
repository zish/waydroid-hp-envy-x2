#!/bin/sh
# Install the Android sleep/lock unit. Run on the host, as root.
#
# Everything lands under $PREFIX (default /usr/local, an ostree symlink to
# /var/usrlocal). Nothing is written to /usr or /etc, so no rpm-ostree layering and
# no reboot. PREFIX=/usr emits the packaged layout. See docs/27.
#
# DESTDIR is honoured so this doubles as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr sh install.sh
# restorecon and daemon-reload are skipped when DESTDIR is set -- a buildroot is
# never labelled, and on rpm-ostree SELinux labels come from the compose, not from
# a scriptlet.
#
# NOTE: this deliberately does NOT install a /etc/systemd/system-sleep/ hook. On
# this host systemd 259 scans only /usr/lib/systemd/system-sleep, which is empty and
# read-only, so such a hook never runs -- and could not do this job even where it is
# scanned, because user.slice is frozen while hooks execute. docs/27 has the
# measurements; the unit's own comments have the summary.
set -eu

PREFIX=${PREFIX:-/usr/local}
# System units go to /etc by default, NOT under $PREFIX. /usr/local is a symlink to
# /var/usrlocal, which SELinux labels lib_t, and init_t may not start a service whose
# unit file is lib_t -- measured: a unit there fails with "avc: denied { start } ...
# tclass=service" the moment systemd itself tries to start it. /etc/systemd/system is
# systemd_unit_file_t by default. The RPM passes UNITDIR=/usr/lib/systemd/system,
# which is correctly labelled too. See docs/27.
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

subst "$src/waydroid-android-key" >"$src/.key.tmp"
install -D -m 0755 "$src/.key.tmp" "$DESTDIR$PREFIX/bin/waydroid-android-key"
rm -f "$src/.key.tmp"

subst "$src/waydroid-android-lock" >"$src/.lock.tmp"
install -D -m 0755 "$src/.lock.tmp" "$DESTDIR$PREFIX/bin/waydroid-android-lock"
rm -f "$src/.lock.tmp"

subst "$src/waydroid-android-lock.service" >"$src/.unit.tmp"
install -D -m 0644 "$src/.unit.tmp" \
    "$DESTDIR$UNITDIR/waydroid-android-lock.service"
rm -f "$src/.unit.tmp"

# Enabled with a .wants symlink rather than `systemctl enable`, which is the same
# thing enable would create and works identically under $UNITDIR wherever that is --
# so the RPM needs no scriptlet. Same trick as artifacts/graceful-exit.
mkdir -p "$DESTDIR$UNITDIR/sleep.target.wants"
ln -sf ../waydroid-android-lock.service \
    "$DESTDIR$UNITDIR/sleep.target.wants/waydroid-android-lock.service"

# Named files only: `restorecon -R $UNITDIR` would relabel every unit in
# /etc/systemd/system, which is far outside this installer's business.
if [ -z "$DESTDIR" ] && command -v restorecon >/dev/null 2>&1; then
    restorecon -F "$PREFIX/bin/waydroid-android-key" \
        "$PREFIX/bin/waydroid-android-lock" \
        "$UNITDIR/waydroid-android-lock.service" || true
fi

if [ -n "$DESTDIR" ]; then exit 0; fi
systemctl daemon-reload

cat <<EOF
installed:
  $PREFIX/bin/waydroid-android-key
  $PREFIX/bin/waydroid-android-lock
  $UNITDIR/waydroid-android-lock.service   (wanted by sleep.target)

Verify it is wired in:
  systemctl show waydroid-android-lock.service -p WantedBy -p Before
  systemctl list-dependencies sleep.target | grep waydroid

Exercise it without suspending -- drive the script, NOT the unit. StopWhenUnneeded
stops the unit the instant it starts unless sleep.target is active, so a manual
\`systemctl start\` runs both legs a second apart and looks like nothing happened:
  $PREFIX/bin/waydroid-android-lock pre      # Android sleeps and locks
  $PREFIX/bin/waydroid-android-lock post     # Android wakes

For the real path, with an RTC alarm so it returns unattended:
  rtcwake -m no -s 25 && systemctl suspend
  journalctl -u waydroid-android-lock.service -b

The unit arms Android's keyguard, but this image ships with the keyguard turned
off, so nothing will be locked until it is enabled once, inside Android:
  waydroid shell -- locksettings set-disabled false
  waydroid shell -- settings put secure lock_screen_lock_after_timeout 0
then set a PIN or pattern in Settings > Security. If a credential is ever lost, stop
the session and delete ~/.local/share/waydroid/data/system/locksettings.db -- that
path is host-visible and owned by the session user, so it needs no root. See docs/27.
EOF
