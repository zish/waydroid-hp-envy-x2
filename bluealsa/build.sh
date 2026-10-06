#!/usr/bin/env bash
#
# Build and deploy BlueALSA (bluez-alsa) for bigtab01, so the host can send
# A2DP audio to Bluetooth headphones with NO PipeWire anywhere in the path.
# Goal 5, docs/44-audio-alsa-backend.md.
#
#   bluealsa/build.sh --deps        # apt the build dependencies (dev box)
#   bluealsa/build.sh               # fetch + build + stage
#   bluealsa/build.sh --install     # also push and install onto the host
#   bluealsa/build.sh --status      # what is installed and running over there
#   bluealsa/build.sh --uninstall   # take it all back off
#
# Env: HOST=<ip>
#
# WHY THIS EXISTS
#
# Masking PipeWire (bin/pipewire-off.sh) gave up exactly one thing that was
# ever working: host Bluetooth audio, because WirePlumber's bluez5 monitor is
# what claims BlueZ's media endpoint. BlueALSA claims it instead, and exposes
# each connected device as an ordinary ALSA PCM. Nothing in the chain is a sound
# server.
#
# Giving the Bluetooth ADAPTER to Android instead -- so Android's own Fluoride
# stack does A2DP -- was the obvious alternative and is wrong here: the host's
# HP Bluetooth keyboard is paired to that adapter, so handing it over costs the
# keyboard. BlueALSA keeps the adapter host-side and lets Android send PCM to
# it, which is why the owner's instinct to go this way was right.
#
# WHY IT CROSS-BUILDS FROM DEBIAN ONTO FEDORA
#
# Per AGENTS.md all builds happen on the dev box, never on bigtab01: the laptop
# has 8 GB against 32 GB, and it is an immutable host where every toolchain
# package costs a layered install AND A REBOOT -- and a reboot there needs
# someone at the console for the LUKS passphrase and to start sshd by hand.
#
# So: built on Debian 13 (glibc 2.41), run on Fedora 44 (glibc 2.43). That
# direction is forward-compatible, and MEASURED to work -- `bluealsad --version`
# prints v5.0.0 on the host with all 16 shared-library dependencies resolved and
# none missing, for the daemon and for the ALSA plugin. Every library it needs
# was already there: libasound, libdbus-1, libglib-2.0, libsbc, libbluetooth,
# and libfdk-aac, which is why AAC is enabled rather than SBC alone.
#
# WHERE THINGS GO, AND WHY, ON AN IMMUTABLE HOST
#
# /usr is read-only, so the usual prefixes are unavailable. Everything lands
# somewhere writable, and nothing needs a reboot:
#
#   /usr/local/bin             -> really /var/usrlocal/bin, writable
#   /usr/local/lib/alsa-lib    -> the ALSA plugin
#   /etc/alsa/conf.d           -> the snippet defining pcm.bluealsa. The host's
#                                 /usr/share/alsa/alsa.conf includes this
#                                 directory (line 13), which is what makes a
#                                 config drop-in possible at all.
#   /etc/dbus-1/system.d       -> the policy letting bluealsad own org.bluealsa
#   /etc/systemd/system        -> the unit
#
# Upstream also installs /usr/share/dbus-1/interfaces/org.bluealsa.xml. That
# path IS read-only here and the file is only D-Bus introspection metadata, so
# it is deliberately skipped; nothing depends on it at runtime.
#
# alsa-lib will not look in /usr/local/lib/alsa-lib on its own -- its compiled-in
# plugin directory is /usr/lib64/alsa-lib. Both the host's libasound.so.2 and,
# usefully, the Android image's libasound.so honour ALSA_PLUGIN_DIR, so the
# snippet does not have to fight that: anything using pcm.bluealsa runs with
# ALSA_PLUGIN_DIR pointed at the local directory. `--status` checks it.
#
# SELINUX
#
# Executing from /var/usrlocal under systemd with SELinux Enforcing depends on
# the label, so `--install` runs restorecon and `--status` prints the context.
# If it comes back as something init_t may not exec, that is the first thing to
# look at -- not a mystery.

set -euo pipefail

HOST="${HOST:-10.42.0.137}"
# BA_VERSION overrides the release built. v5.0.0 is the default; v4.3.1 is the
# previous stable and is worth reaching for when a v5-specific regression is
# suspected -- see docs/44 on the Open()/fd-passing failure.
VERSION="${BA_VERSION:-v5.0.0}"
REPO=https://github.com/arkq/bluez-alsa.git

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
OUT="${OUT:-$repo/build/bluez-alsa-src}"
SRC="$OUT/src"
STAGE="$OUT/stage"
TARBALL="$OUT/bluealsa-$VERSION.tar"

# v5 renamed the daemon bluealsad and the CLI bluealsactl; v4 calls them bluealsa
# and bluealsa-cli, and ships a bluealsa.conf rather than org.bluealsa.conf.
# Everything below branches on that rather than hard-coding v5 names.
case "$VERSION" in
	v5.*) BA_BIN=bluealsad; BA_CLI=bluealsactl; BA_EXTRA_CONF=""      ;;
	*)    BA_BIN=bluealsa;  BA_CLI=bluealsa-cli; BA_EXTRA_CONF="--enable-cli" ;;
esac

# The host sends TO headphones, so the host is the A2DP *source*.
# --keep-alive: with the default 0.0 the transport is torn down the instant the
# last PCM client closes, and that teardown path (transport_a2dp_suspend ->
# a2dp_unregister_sep -> media_endpoint_remove -> queue_remove) SEGFAULTS
# bluetoothd 5.87. Delaying it avoids the crash. See docs/44.
BLUEALSAD_ARGS="-p a2dp-source --keep-alive=5"

# Who is allowed to talk to org.bluealsa besides root.
#
# Upstream's policy grants own_prefix to root and send_destination to group
# "audio". That group is unusable here: it exists at gid 63 but is defined in
# the BASE IMAGE's /usr/lib/group, which is read-only, so `usermod -aG audio
# jmelanso` exits 0 and changes nothing -- `id` still shows only jmelanso and
# wheel. Editing /etc/group to shadow the base entry would work and is the
# conventional ostree answer, but it is system-database surgery for one D-Bus
# ACL, and it would be invisible to anyone reading this directory.
#
# A drop-in naming the user is declarative, lives in a file this script owns,
# and is removed by --uninstall. It matters because the Android side connects as
# this uid: the container has no idmap, so Android's AID_SYSTEM (1000) IS host
# uid 1000.
BT_CLIENT_USER="${BT_CLIENT_USER:-jmelanso}"

DO_DEPS=0; DO_INSTALL=0; DO_STATUS=0; DO_UNINSTALL=0; DO_BUILD=1
while [ $# -gt 0 ]; do
	case "$1" in
	--deps) DO_DEPS=1; shift ;;
	--install) DO_INSTALL=1; shift ;;
	--status) DO_STATUS=1; DO_BUILD=0; shift ;;
	--uninstall) DO_UNINSTALL=1; DO_BUILD=0; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

if [ "$DO_DEPS" = 1 ]; then
	echo "== apt: build dependencies"
	sudo apt-get install -y -q autoconf automake libtool pkg-config \
		libasound2-dev libdbus-1-dev libglib2.0-dev libsbc-dev \
		libbluetooth-dev libfdk-aac-dev
fi

status() {
	ssh "$HOST" 'sudo sh -s' <<'REMOTE'
set -u
kv() { printf '  %-36s %s\n' "$1" "$2"; }
hd() { printf '\n\033[1m%s\033[0m\n' "$1"; }

hd "Installed"
for f in /usr/local/bin/bluealsad /usr/local/bin/bluealsa \
         /usr/local/bin/bluealsactl /usr/local/bin/bluealsa-cli \
         /usr/local/lib/alsa-lib/libasound_module_pcm_bluealsa.so \
         /etc/alsa/conf.d/20-bluealsa.conf \
         /etc/dbus-1/system.d/org.bluealsa.conf \
         /etc/systemd/system/bluealsad.service; do
	kv "$(basename "$f")" "$([ -e "$f" ] && echo present || echo ABSENT)"
done
BIN=$(ls /usr/local/bin/bluealsad /usr/local/bin/bluealsa 2>/dev/null | head -1)
kv "version" "$("${BIN:-/bin/false}" --version 2>/dev/null || echo 'n/a')"
kv "SELinux label" "$(ls -Z "${BIN:-/dev/null}" 2>/dev/null | awk '{print $1}')"

hd "Daemon"
kv "bluealsad.service" "$(systemctl is-enabled bluealsad.service 2>/dev/null || echo 'not-enabled')/$(systemctl is-active bluealsad.service 2>/dev/null || echo inactive)"
kv "owns org.bluealsa" "$(busctl --system list 2>/dev/null | grep -c org.bluealsa | tr -d ' ') name(s)"
kv "PipeWire processes" "$(pgrep -x 'pipewire|wireplumber' 2>/dev/null | wc -l | tr -d ' ')"

hd "Bluetooth"
kv "adapter" "$(bluetoothctl show 2>/dev/null | sed -n 's/^Controller //p' | head -1)"
kv "powered" "$(bluetoothctl show 2>/dev/null | sed -n 's/^[[:space:]]*Powered: //p' | head -1)"
echo "  paired devices:"
bluetoothctl devices Paired 2>/dev/null | sed 's/^/      /' || true
echo "  connected devices:"
bluetoothctl devices Connected 2>/dev/null | sed 's/^/      /' || echo "      (none)"

hd "BlueALSA PCMs"
CLI=$(ls /usr/local/bin/bluealsactl /usr/local/bin/bluealsa-cli 2>/dev/null | head -1)
if [ -n "$CLI" ]; then
	"$CLI" list-pcms 2>&1 | sed 's/^/      /' | head -20
else
	echo "      no CLI tool installed"
fi

hd "Client access"
kv "org.bluealsa-local.conf" "$([ -e /etc/dbus-1/system.d/org.bluealsa-local.conf ] && echo present || echo ABSENT)"
kv "user granted by drop-in" "$(sed -n 's/.*<policy user="\([^"]*\)".*/\1/p' /etc/dbus-1/system.d/org.bluealsa-local.conf 2>/dev/null | head -1)"
echo "  (group audio is NOT usable here: gid 63 is defined in the read-only base"
echo "   image, so usermod -aG audio succeeds and changes nothing)"
kv "ALSA_PLUGIN_DIR needed" "/usr/local/lib/alsa-lib"
echo
REMOTE
}

if [ "$DO_UNINSTALL" = 1 ]; then
	echo "== uninstalling from $HOST"
	ssh "$HOST" 'sudo sh -s' <<'REMOTE'
systemctl disable --now bluealsad.service >/dev/null 2>&1
rm -f /etc/systemd/system/bluealsad.service
rm -f /etc/alsa/conf.d/20-bluealsa.conf
rm -f /etc/dbus-1/system.d/org.bluealsa.conf /etc/dbus-1/system.d/bluealsa.conf /etc/dbus-1/system.d/org.bluealsa-local.conf
rm -rf /etc/systemd/system/bluealsad.service.d
rm -f /usr/local/bin/bluealsad /usr/local/bin/bluealsactl \
      /usr/local/bin/bluealsa /usr/local/bin/bluealsa-cli \
      /usr/local/bin/bluealsa-aplay /usr/local/bin/a2dpconf
rm -rf /usr/local/lib/alsa-lib /usr/local/share/alsa
# Only bluealsad's own state dirs. /usr/local is shared -- /usr/local/bin
# holds this project's `waydroid` wrapper -- so nothing broader is removed.
# The second path is where an earlier --localstatedir bug put the state.
rm -rf /var/lib/bluealsa /usr/local/var/lib/bluealsa
rmdir -p --ignore-fail-on-non-empty /usr/local/var/lib 2>/dev/null || true
systemctl daemon-reload
# RELOAD ONLY -- the same rule as the install path, and this copy was missed
# when that one was fixed. `systemctl restart dbus-broker` severs every D-Bus
# connection on the machine: the desktop session, SDDM and Waydroid included.
# A stale policy for a daemon that is already gone is harmless; a restarted
# broker is not.
if ! systemctl reload dbus 2>/dev/null; then
    echo "  WARNING: could not reload dbus; the removed policy is still cached." >&2
    echo "  It references a daemon that no longer exists, so this is harmless." >&2
fi
echo "  removed. Nothing was modified in place; /usr was never written."
REMOTE
	exit 0
fi

if [ "$DO_STATUS" = 1 ]; then status; exit 0; fi

if [ "$DO_BUILD" = 1 ]; then
	# libtoolize, not libtool: autoreconf --install needs the former, and Debian
	# ships the macros and libtoolize without necessarily providing a `libtool`
	# wrapper on PATH. Checking the wrong one failed a build that worked.
	for t in autoconf automake libtoolize pkg-config; do
		command -v "$t" >/dev/null || { echo "missing $t -- run with --deps" >&2; exit 1; }
	done

	if [ ! -d "$SRC/.git" ]; then
		echo "== cloning bluez-alsa"
		mkdir -p "$OUT"
		git clone -q "$REPO" "$SRC"
	fi
	echo "== checking out $VERSION"
	git -C "$SRC" fetch -q --tags
	git -C "$SRC" checkout -q "$VERSION"

	echo "== autoreconf"
	( cd "$SRC" && autoreconf --install >/dev/null 2>&1 )

	echo "== configure"
	# --sysconfdir=/etc matters. Upstream installs the real alsa snippet under
	# $prefix/share/alsa/alsa.conf.d and SYMLINKS it from $sysconfdir/alsa/conf.d.
	# Left at the default, that symlink lands in /usr/local/etc, which alsa-lib
	# never reads. Pointing sysconfdir at /etc puts the link where the host's
	# alsa.conf actually includes it, with the target in writable /usr/local.
	# The first version of this script instead moved the file and deleted
	# share/, which left a dangling symlink in the tarball.
	# BA_DEBUG=1 adds --enable-debug, which is what defines DEBUG and so compiles
	# in snd_debug() -- stubbed out of a release build by src/asound/log.h. Without
	# it BLUEALSA_LOG_LEVEL=debug produces nothing from the ALSA plugin, which is
	# what stalled the A2DP investigation: the plugin could not say which hw
	# constraint it was rejecting.
	( cd "$SRC" && ./configure \
		${BA_DEBUG:+--enable-debug} \
		--prefix=/usr/local \
		--sysconfdir=/etc \
		--localstatedir=/var \
		--with-alsaplugindir=/usr/local/lib/alsa-lib \
		--with-dbusconfdir=/etc/dbus-1/system.d \
		--enable-a2dpconf $BA_EXTRA_CONF \
		--enable-aac >/dev/null )

	echo "== make"
	( cd "$SRC" && make -j"$(nproc)" >/dev/null )

	echo "== stage"
	rm -rf "$STAGE"
	( cd "$SRC" && make install DESTDIR="$STAGE" >/dev/null )
	# Drop the static/la cruft and the one path that is read-only over there.
	# The parentheses are load-bearing: without them -delete binds only to the
	# last -name and would delete rather more than intended.
	find "$STAGE" \( -name '*.a' -o -name '*.la' \) -delete
	rm -rf "$STAGE/usr/share"

	# /usr/local on this host is a SYMLINK to ../var/usrlocal, and tar will not
	# extract directories through a symlink onto a read-only /usr -- it fails
	# with "Invalid cross-device link" on every entry, which is how the first
	# install attempt died. Rewrite the staged paths to the real location. The
	# binaries keep their --prefix=/usr/local, which is correct at RUNTIME
	# because the symlink resolves; only extraction needs the real path.
	if [ -d "$STAGE/usr/local" ]; then
		mkdir -p "$STAGE/var"
		mv "$STAGE/usr/local" "$STAGE/var/usrlocal"
		rmdir "$STAGE/usr" 2>/dev/null || true
	fi

	cat > "$STAGE/etc/dbus-1/system.d/org.bluealsa-local.conf" <<DBUSPOLICY
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<!-- Deployed by bluealsa/build.sh. See docs/44-audio-alsa-backend.md.
     Upstream's org.bluealsa.conf grants send_destination to group "audio",
     which cannot be joined on this host: the group is defined in the read-only
     base image, so usermod succeeds and does nothing. This names the user
     instead. The Android side needs it too, because with no idmap Android's
     AID_SYSTEM (uid 1000) is host uid 1000.
     NOTE: no double hyphen may appear inside an XML comment. A stray one here
     made dbus-broker unable to parse the policy, and bluealsad then lost its
     bus name and exited(1) the instant a client opened a PCM. -->
<busconfig>
  <policy user="$BT_CLIENT_USER">
    <allow send_destination="org.bluealsa"/>
  </policy>
</busconfig>
DBUSPOLICY

	# Validate it. A malformed policy does not fail loudly at install time: the
	# broker simply cannot parse it, and the symptom surfaces much later as
	# bluealsad losing its bus name under load.
	python3 -c "import sys,xml.dom.minidom; xml.dom.minidom.parse(sys.argv[1])" \
		"$STAGE/etc/dbus-1/system.d/org.bluealsa-local.conf" \
		|| { echo "generated D-Bus policy is not well-formed XML" >&2; exit 1; }

	mkdir -p "$STAGE/etc/systemd/system"
	# No `|| true` here. The first version had one, the directory did not exist,
	# and the tarball shipped without a unit while the build reported success.
	cat > "$STAGE/etc/systemd/system/bluealsad.service" <<UNIT
# BlueALSA, deployed by bluealsa/build.sh. See docs/44-audio-alsa-backend.md.
#
# Deliberately NOT upstream's heavily sandboxed unit. That one sets
# ProtectSystem=strict and User=, and this binary lives in /var/usrlocal on an
# ostree host with SELinux Enforcing -- so the sandbox and the label interact in
# ways worth eliminating from a first bring-up rather than debugging blind.
# Tighten it once A2DP is proven end to end; upstream's version is in
# misc/systemd/bluealsa.service.in and is the right target.
#
# Runs as root because the shipped D-Bus policy grants own_prefix=org.bluealsa
# to root only.
[Unit]
Description=BlueALSA service
Documentation=man:bluealsad(8)
Requisite=dbus.service
After=bluetooth.service
Wants=bluetooth.service

[Service]
# Type=simple, NOT Type=dbus, and this is load-bearing. Under Type=dbus (with
# BusName=org.bluealsa) the daemon died with "Lost BlueALSA D-Bus name" the
# instant a client called PCM1.Open() -- the call whose reply carries two Unix
# FDs -- and took bluetoothd down with it. Run manually, or as Type=simple, it
# survives the identical sequence. See docs/44.
Type=simple
ExecStart=/usr/local/bin/$BA_BIN $BLUEALSAD_ARGS
Restart=on-failure
RestartSec=2

[Install]
WantedBy=bluetooth.target
UNIT

	[ -s "$STAGE/etc/systemd/system/bluealsad.service" ] || { echo "unit not staged" >&2; exit 1; }
	# A symlink whose target will not exist after extraction means the conf.d
	# link and its target disagree -- exactly the bug --sysconfdir fixed. Check
	# for it, but check it CORRECTLY: upstream's link is absolute
	# (/usr/local/share/alsa/...), which is right once extracted at / and looks
	# dangling inside a DESTDIR. Resolve absolute targets against $STAGE.
	while IFS= read -r l; do
		t=$(readlink "$l")
		case "$t" in
			# /usr/local/X lives at var/usrlocal/X in the stage, per the path
			# rewrite above, so an absolute target has to be mapped the same way.
			/usr/local/*) [ -e "$STAGE/var/usrlocal/${t#/usr/local/}" ] || { echo "staged symlink ${l#$STAGE} -> $t has no target in the stage" >&2; exit 1; } ;;
			/*) [ -e "$STAGE$t" ] || { echo "staged symlink ${l#$STAGE} -> $t has no target in the stage" >&2; exit 1; } ;;
			*)  [ -e "$(dirname "$l")/$t" ] || { echo "staged symlink ${l#$STAGE} -> $t is dangling" >&2; exit 1; } ;;
		esac
	done < <(find "$STAGE" -type l)
	mkdir -p "$(dirname "$TARBALL")"
	# Archive the top-level directories by name, NOT ".". A "./" member makes tar
	# try to set ownership and mtime on / itself, which is read-only here, so the
	# extraction exits non-zero after having written every file correctly -- and
	# the installer's `set -e` then skipped chmod, restorecon and enable.
	( cd "$STAGE" && tar cf "$TARBALL" -- * )
	echo
	echo "== staged $VERSION"
	find "$STAGE" -type f | sed "s|$STAGE||" | sort | sed 's/^/   /'
	ls -l "$TARBALL"
fi

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing onto $HOST"
	scp -q "$TARBALL" "$HOST:/tmp/bluealsa.tar"
	ssh "$HOST" 'sudo sh -s' <<'REMOTE'
set -eu
# --no-same-owner: the stage is owned by the build user, and these belong to root.
# Remove the other release's binaries and any ad-hoc drop-in, so switching
# between v4 and v5 cannot leave a unit pointing at a binary that is gone.
rm -rf /etc/systemd/system/bluealsad.service.d
rm -f /usr/local/bin/bluealsad /usr/local/bin/bluealsactl \
      /usr/local/bin/bluealsa /usr/local/bin/bluealsa-cli
tar xf /tmp/bluealsa.tar -C / --no-same-owner
rm -f /tmp/bluealsa.tar
chmod 0755 /usr/local/bin/bluealsad /usr/local/bin/bluealsactl \
           /usr/local/bin/bluealsa-aplay /usr/local/bin/a2dpconf 2>/dev/null || true
# Labels matter here: the binaries really live under /var/usrlocal, and systemd
# has to be allowed to exec them.
restorecon -R /var/usrlocal /etc/alsa /etc/dbus-1 /etc/systemd/system 2>/dev/null || true
# D-Bus must re-read system.d before anything can own org.bluealsa.
#
# RELOAD ONLY. The first version fell back to `systemctl restart dbus-broker`,
# which severs every D-Bus connection on the machine -- a far worse outcome than
# the problem it was papering over. If the reload fails, say so and stop.
if ! systemctl reload dbus 2>/dev/null; then
    echo "  WARNING: could not reload dbus; the policy may not be active yet." >&2
    echo "  NOT restarting the system bus. Check /etc/dbus-1/system.d XML validity." >&2
fi
systemctl daemon-reload
# `enable --now` does NOT restart an already-running unit, so a reinstall left
# the OLD binary running while reporting success -- which is how a stale build
# without --localstatedir stayed live through two installs.
systemctl enable bluealsad.service >/dev/null 2>&1
systemctl restart bluealsad.service
sleep 2
echo "  bluealsad: $(systemctl is-active bluealsad.service)"
systemctl is-active --quiet bluealsad.service || systemctl status bluealsad.service --no-pager -l | tail -20
REMOTE
	status
fi
