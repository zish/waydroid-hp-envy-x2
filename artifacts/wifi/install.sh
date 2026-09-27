#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Install waydroid-wifid, waydroid-wifi-sync and their units. Run on the host,
# as root, or with DESTDIR set as the RPM's %install step:
#     DESTDIR=%{buildroot} PREFIX=/usr UNITDIR=/usr/lib/systemd/system \
#         WIFID_BIN=path/to/waydroid-wifid sh install.sh wifid
#
# wifi/build.sh --install --unit remains the way to deploy to a running host
# over ssh; this script is the layout, and both use it. The daemon binary is not
# built here -- it comes from wifi/build.sh or from the RPM's %build.
#
# WHY THERE IS A COMPONENT ARGUMENT
#
# These files are two modifications and not one (docs/47-package-split.md): the
# daemon is waydroid-ext-wifid, the credential reconciler is
# waydroid-ext-wifi-sync, and a fix to one must not reissue the other. While this
# script installed both unconditionally it could not be the %install of either
# one alone -- rpmbuild -ba fails on whichever half the spec does not list -- so
# waydroid-ext-wifid could only ever be built as an SRPM. The treatment is the
# one artifacts/overlay/install.sh already has, for the same reason.
#
# The default is `all`, and that is load-bearing: the superseded
# packaging/waydroid-wifid.spec builds one package holding both halves and calls
# this script with no argument, so a no-argument run has to keep laying down
# everything it laid down before. That was checked and not assumed -- the
# pre-change script and this one were each run into their own DESTDIR and the two
# trees diffed, symlink targets included, and they are identical.
#
# wifi/build.sh is NOT a caller, despite installing the same files: its --unit
# mode substitutes @BINDIR@ itself and scps the result to the host. That is a
# second copy of this layout and a cost worth naming, but it is not something the
# component argument changes either way.
#
# Usage:
#   sh artifacts/wifi/install.sh              # both halves (the default)
#   sh artifacts/wifi/install.sh wifid        # daemon, nudge, unit, conf
#   sh artifacts/wifi/install.sh wifi-sync    # reconciler, its units, share conf
#
# The two conf files are never overwritten on a live install. /etc/waydroid-wifid.conf
# names the radio to hand Android, and clobbering somebody's --device with the
# adapter this repository happens to know about is exactly the failure the
# daemon's fatal-on-missing-device rule exists to prevent (docs/33 trap 5).
# /etc/waydroid-wifi-share.conf lists the networks whose passphrases get copied
# into the container, so it is an opt-in record and 0600 for that reason.
set -eu

PREFIX=${PREFIX:-/usr/local}
# /etc, not $PREFIX: /usr/local is a symlink to /var/usrlocal, SELinux labels
# that lib_t, and init_t may not start a lib_t unit file. See docs/27 and the
# same note in artifacts/sensor-hub/install.sh. The RPM passes UNITDIR.
UNITDIR=${UNITDIR:-/etc/systemd/system}
SYSCONFDIR=${SYSCONFDIR:-/etc}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")
repo=$(cd "$src/../.." && pwd)
WIFID_BIN=${WIFID_BIN:-$repo/build/wifi/daemon/waydroid-wifid}

# ------------------------------------------------------------------ components

ALL_COMPONENTS="wifid wifi-sync"

components=""
for c in ${*:-all}; do
	case "$c" in
	all)             components="$components $ALL_COMPONENTS" ;;
	wifid|wifi-sync) components="$components $c" ;;
	*) echo "unknown component: $c (known: $ALL_COMPONENTS all)" >&2; exit 2 ;;
	esac
done

# Asked as a question per file group rather than by splitting the script in two:
# the two halves share the @BINDIR@ substitution, the .wants symlink idiom and
# the never-clobber rule for conf files, and two copies of those three would
# drift apart exactly the way twenty-five hand-written specs did.
want() {
	case " $components " in *" $1 "*) return 0 ;; esac
	return 1
}

subst() { sed "s|@BINDIR@|$PREFIX/bin|g" "$1"; }

# Accumulated as files are installed rather than re-listed at the bottom: a path
# added above and forgotten below is an unlabelled file on an SELinux host, and
# that failure stays silent until the unit refuses to start.
relabel=""
report=""
note() { relabel="$relabel $1"; report="$report $1"; }

# ------------------------------------------------------------------- binaries

install_bin() {
	subst "$src/$1" >"$src/.bin.tmp"
	install -D -m 0755 "$src/.bin.tmp" "$DESTDIR$PREFIX/bin/$1"
	rm -f "$src/.bin.tmp"
	note "$PREFIX/bin/$1"
}

if want wifid; then
	if [ -f "$WIFID_BIN" ]; then
		install -D -m 0755 "$WIFID_BIN" "$DESTDIR$PREFIX/bin/waydroid-wifid"
		note "$PREFIX/bin/waydroid-wifid"
	else
		echo "no daemon at $WIFID_BIN -- build it with wifi/build.sh, or set WIFID_BIN" >&2
		exit 1
	fi
	# waydroid-wifi-nudge ships with the daemon and not with the reconciler: it
	# pokes Android's Wi-Fi framework into noticing the daemon, which is the
	# daemon's own business. The superseded waydroid-wifid.spec drew the line in
	# the same place.
	install_bin waydroid-wifi-nudge
fi

if want wifi-sync; then
	install_bin waydroid-wifi-sync
fi

# ---------------------------------------------------------------------- units

install_unit() {
	subst "$src/$1" >"$src/.unit.tmp"
	install -D -m 0644 "$src/.unit.tmp" "$DESTDIR$UNITDIR/$1"
	rm -f "$src/.unit.tmp"
	note "$UNITDIR/$1"
}

# The symlinks `systemctl enable` would create, so the RPM needs no scriptlet --
# a requirement on an ostree host, where scriptlets run against the compose.
# Only the .wants directory this component's own symlink needs gets created:
# each half declares one as %dir in its %files, and creating both would leave an
# empty directory in the buildroot that neither package owns.
if want wifid; then
	install_unit waydroid-wifid.service
	mkdir -p "$DESTDIR$UNITDIR/multi-user.target.wants"
	ln -sf ../waydroid-wifid.service \
	    "$DESTDIR$UNITDIR/multi-user.target.wants/waydroid-wifid.service"
	report="$report $UNITDIR/multi-user.target.wants/waydroid-wifid.service"
fi

if want wifi-sync; then
	install_unit waydroid-wifi-sync.service
	install_unit waydroid-wifi-sync.timer
	# The timer, not the service: the reconciler runs on a schedule, and enabling
	# the service would fire one sync at boot before anyone has opted a network in.
	mkdir -p "$DESTDIR$UNITDIR/timers.target.wants"
	ln -sf ../waydroid-wifi-sync.timer \
	    "$DESTDIR$UNITDIR/timers.target.wants/waydroid-wifi-sync.timer"
	report="$report $UNITDIR/timers.target.wants/waydroid-wifi-sync.timer"
fi

# ------------------------------------------------------------------- config

install_conf() {
	mode=$1; file=$2; dest="$DESTDIR$SYSCONFDIR/$2"
	report="$report $SYSCONFDIR/$2"
	if [ -z "$DESTDIR" ] && [ -e "$dest" ]; then
		echo "keeping the existing $dest"
		return
	fi
	install -D -m "$mode" "$src/$file" "$dest"
}
if want wifid;     then install_conf 0644 waydroid-wifid.conf; fi
if want wifi-sync; then install_conf 0600 waydroid-wifi-share.conf; fi

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
	# shellcheck disable=SC2086
	restorecon -F $relabel || true
fi
systemctl daemon-reload

echo "installed:"
for p in $report; do echo "  $p"; done
echo
echo "Nothing was started. Start what was installed with:"
if want wifid;     then echo "  systemctl start waydroid-wifid"; fi
if want wifi-sync; then echo "  systemctl start waydroid-wifi-sync.timer"; fi
