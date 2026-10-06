#!/bin/sh
# Install the SELinux module that lets BlueALSA's PCM pipe reach its clients.
#
#   scp -r artifacts/bluealsa HOST:/tmp/ && ssh HOST 'sudo /tmp/bluealsa/install.sh'
#
# or, from a checkout on the host:  sudo artifacts/bluealsa/install.sh
#
# and to take it back off again:    sudo artifacts/bluealsa/install.sh --remove
#
# Without this, A2DP playback fails under systemd with SELinux Enforcing:
#
#   bluealsa-pcm.c: Couldn't open PCM: Remote peer disconnected
#   aplay: set_params:1462: Unable to install hw params
#
# and NOTHING is logged, because the denial is dontaudit'ed. The daemon then
# logs "Lost BlueALSA D-Bus name" and exits(1). See waydroid_bluealsa.cil for
# the full diagnosis and docs/44-audio-alsa-backend.md for how it was found.
#
# The daemon binaries come from bluealsa/build.sh --install; this is only the
# policy. Either alone leaves Bluetooth audio broken.
set -eu

DO_REMOVE=0
case "${1:-}" in
	--remove) DO_REMOVE=1 ;;
	"") ;;
	*) echo "usage: $0 [--remove]" >&2; exit 2 ;;
esac

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
CILDIR=${CILDIR:-$PREFIX/share/waydroid-bluealsa}

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$DO_REMOVE" = 1 ]; then
	command -v semodule >/dev/null 2>&1 || {
		echo "semodule not found -- nothing to remove" >&2
		exit 0
	}
	# -r on a module that is not loaded exits non-zero, which is not a failure
	# here: the goal is "absent afterwards", not "was present before".
	semodule -r waydroid_bluealsa >/dev/null 2>&1 || true
	rm -f "$CILDIR/waydroid_bluealsa.cil"
	rmdir "$CILDIR" 2>/dev/null || true

	# Absence of errors is not success, in this direction either.
	if [ "$(semodule -l | grep -c '^waydroid_bluealsa$')" -ne 0 ]; then
		echo "waydroid_bluealsa is STILL loaded after semodule -r" >&2
		exit 1
	fi
	echo "removed: waydroid_bluealsa is no longer loaded, and the .cil is gone."
	echo "BlueALSA's PCM pipe is denied again -- which is the stock state."
	exit 0
fi

install -d "$DESTDIR$CILDIR"
install -m 0644 "$here/waydroid_bluealsa.cil" "$DESTDIR$CILDIR/waydroid_bluealsa.cil"

if [ -n "$DESTDIR" ]; then exit 0; fi

command -v semodule >/dev/null 2>&1 || {
	echo "semodule not found -- is this an SELinux system?" >&2
	exit 1
}

semodule -i "$CILDIR/waydroid_bluealsa.cil"

# Absence of errors is not success: semodule can exit 0 having loaded nothing if
# the module name is already taken by something else.
if [ "$(semodule -l | grep -c '^waydroid_bluealsa$')" -ne 1 ]; then
	echo "waydroid_bluealsa is NOT loaded after semodule -i" >&2
	exit 1
fi

cat <<EOM
installed:
  $CILDIR/waydroid_bluealsa.cil   (loaded: semodule -l | grep waydroid_bluealsa)

No restart is needed. SELinux checks the access at the moment dbus-broker
relays the PCM pipe, so an already-running bluealsad simply stops being denied.

Verify:
  ssh HOST 'sudo sh -s' -- --status < bluealsa/build.sh
  aplay -D bluealsa, with ALSA_PLUGIN_DIR=$PREFIX/lib/alsa-lib

Remove with: semodule -r waydroid_bluealsa
EOM
