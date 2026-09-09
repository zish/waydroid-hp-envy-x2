#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install the waydroid-container.service drop-ins. Run on the host, as root.
#
# Right now that is one file, nice-limit.conf, which raises RLIMIT_NICE for the
# container and everything Waydroid starts alongside it. See docs/40-binder-nice.md.
#
# WHY THIS IS A DROP-IN ON WAYDROID'S UNIT, AND NOT PART OF THE DAEMON IT FIXES
#
# The process that needs the limit is waydroid-sensord, which has no unit of its
# own on purpose -- container_manager.py starts it because it is on PATH, so it
# is a child of waydroid-container.service and inherits that unit's limits.
# Setting the limit here also means systemd applies it as PID 1, before the
# SELinux transition, so the install cannot be defeated by the very capability
# restriction it exists to work around. The container's own Android processes
# get it too, which matches what stock Android's init does.
#
# UNITDIR and DESTDIR as everywhere else in artifacts/, so this doubles as the
# RPM's %install step:
#     DESTDIR=%{buildroot} UNITDIR=/usr/lib/systemd/system sh install.sh
# PREFIX is accepted and ignored: nothing here lands outside UNITDIR.
set -eu

# System units go to /etc by default, NOT under $PREFIX. /usr/local is a symlink to
# /var/usrlocal, which SELinux labels lib_t, and init_t may not start a service whose
# unit file is lib_t. /etc/systemd/system is systemd_unit_file_t by default. The RPM
# passes UNITDIR=/usr/lib/systemd/system, which is correctly labelled too. docs/27.
UNITDIR=${UNITDIR:-/etc/systemd/system}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")

dropin=$UNITDIR/waydroid-container.service.d/nice-limit.conf

install -D -m 0644 "$src/nice-limit.conf" "$DESTDIR$dropin"

if [ -n "$DESTDIR" ]; then exit 0; fi

# Named file only: restorecon -R on $UNITDIR would relabel every unit in
# /etc/systemd/system, far outside this installer's business.
if command -v restorecon >/dev/null 2>&1; then
	restorecon -F "$dropin" || true
fi
systemctl daemon-reload

cat <<EOM
installed:
  $dropin

DELIBERATELY NOT RESTARTED. A drop-in only reaches the container at the next
start of waydroid-container.service, and restarting that unit drops a kiosk
session back to the SDDM greeter, so it needs someone at the machine. Let it
land on the next natural restart or reboot.

Until then the running daemon can be fixed in place, with no restart at all.
(pidof, not pgrep: the daemon's comm is truncated to "waydroid-sensor" at 15
characters, and pgrep -f would match the shell running this command.)
  prlimit --pid \$(pidof waydroid-sensord) --nice=40:40

Verify, after the next container start:
  grep -i nice /proc/\$(pidof waydroid-sensord)/limits     # expect 40  40
  journalctl --since -5min | grep -c 'RLIMIT_NICE not set'    # expect 0
EOM
