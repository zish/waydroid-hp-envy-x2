#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# hand-deploy.sh -- put a waydroid-keystored build in front of keystore2 for
# exactly one Waydroid session, then take it away (goal 10, docs/73, docs/74).
# Run as root on bigtab01, detached:
#
#   setsid sh hand-deploy.sh DAEMON [DAEMON_ARGS...] </dev/null >/dev/null 2>&1 &
#
# keystore2 looks for a StrongBox once, when a session starts, and only for one
# the VINTF manifest declares; and an overlay file is read only at session start
# (AGENTS.md). So a build reaches Android at a logout and login, and this does
# the four things around that by itself:
#
#   1. now: derive the strongbox manifest from this machine's vendor.img
#      (strongbox-manifest.sh refuses if the image moved), install DAEMON as
#      /usr/local/bin/waydroid-keystored, and enable a boot-time guard;
#   2. at the logout: install the manifest into the vendor overlay and start the
#      daemon, which waits for the next session's hwservicemanager and registers
#      the moment it appears -- ahead of keystore2's probe;
#   3. through that session: nothing;
#   4. at the next logout: stop the daemon and remove the manifest, the binary
#      and the guard, so the session after boots stock.
#
# The manifest and the daemon come and go together because a strongbox that is
# declared with nothing serving it is the one combination never booted (docs/65
# open question 4). A reboot would kill this script between 2 and 4 and leave
# exactly that, which is what the guard is for: a oneshot unit, ordered before
# waydroid-container.service, that removes the manifest and the binary at boot
# if they are still there, and then disables itself.
#
# Everything is logged to /var/tmp/waydroid-keystored.log, the daemon's own log.
set -u

LOG=/var/tmp/waydroid-keystored.log
OVL=/var/lib/waydroid/overlay/vendor/etc/vintf/manifest.xml
BIN=/usr/local/bin/waydroid-keystored
GUARD=waydroid-keystore-hand-deploy-guard.service
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

log() { echo "[hand-deploy] $(date '+%F %T') $*" >>"$LOG"; }
session_running() {
	waydroid status </dev/null 2>/dev/null | grep -q '^Session:[[:space:]]*RUNNING'
}

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 2; }
[ $# -ge 1 ] && [ -x "$1" ] || { echo "usage: $0 DAEMON [ARGS...]" >&2; exit 2; }
daemon=$1; shift

# This is for a host WITHOUT the packages (docs/75). With them, the packaged
# daemon would register the same name alongside this one and the manifest is
# already overlay-sync's; test a build there with a drop-in that points
# waydroid-keystored.service's ExecStart at it instead, between sessions.
if systemctl cat waydroid-keystored.service >/dev/null 2>&1; then
	log "refusing: waydroid-keystored.service is installed; use a drop-in, not this (docs/75)"
	echo "refusing: waydroid-keystored.service is installed; use a drop-in instead (docs/75)" >&2
	exit 3
fi
if [ -e "$OVL" ]; then
	log "refusing: $OVL already exists (another deployment, or a stale one)"
	exit 3
fi
if ! sh "$here/strongbox-manifest.sh" --out "$here/manifest.xml" </dev/null 2>>"$LOG"; then
	log "refusing: the manifest derivation refused (see above)"
	exit 3
fi
install -m 0755 -o root -g root "$daemon" "$BIN"
cat >"/etc/systemd/system/$GUARD" <<EOF
# Written by artifacts/keystore/hand-deploy.sh; removes itself. docs/74.
[Unit]
Description=Remove a hand-deployed waydroid-keystored strongbox left by a reboot
Before=waydroid-container.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/bin/rm -f $OVL $BIN
ExecStart=/usr/bin/systemctl disable $GUARD
ExecStart=/usr/bin/rm -f /etc/systemd/system/$GUARD

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload </dev/null
systemctl enable "$GUARD" </dev/null 2>/dev/null
log "armed: $BIN $*; waiting for the session to stop"

while session_running; do sleep 0.5; done
install -D -m 0644 "$here/manifest.xml" "$OVL"
"$BIN" "$@" </dev/null >>"$LOG" 2>&1 &
pid=$!
log "session stopped: manifest installed, daemon started (pid $pid)"

while ! session_running; do sleep 1; done
log "session started"
while session_running; do sleep 1; done

# The daemon exits by itself once the session it served is gone; make sure.
kill "$pid" 2>/dev/null
wait "$pid" 2>/dev/null
rm -f "$OVL" "$BIN" "$here/manifest.xml"
systemctl disable "$GUARD" </dev/null 2>/dev/null
rm -f "/etc/systemd/system/$GUARD"
systemctl daemon-reload </dev/null
log "session stopped: removed the strongbox manifest, the daemon and the boot guard"
