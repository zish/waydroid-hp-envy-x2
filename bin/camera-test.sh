#!/bin/bash
# Restart Waydroid and test whether the camera preview produces frames.
# Usage: camera-test.sh <label>
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# THIS SCRIPT STOPS AND RESTARTS THE WAYDROID SESSION, SO IT NEEDS SOMEBODY AT
# THE MACHINE. It is not a read-only check like battery-test.sh or wifi-test.sh,
# and running it over ssh on the kiosk ENDS THE SESSION AND DROPS THE DISPLAY TO
# THE SDDM GREETER, where only a physical login can recover it.
#
# That is not hypothetical. On 2026-09-30 this was run over ssh during a
# post-reboot verification sweep. `waydroid session stop` killed the cage
# compositor; the `waydroid session start` below then failed with
#
#   Wayland socket '/run/user/1000/wayland-1' doesn't exist; are you running a
#   Wayland compositor?
#
# because the compositor it needed was the one just killed. The machine sat at
# the greeter until someone logged in at the console. AGENTS.md warns about
# exactly this and the script carried no guard, so the guard is now here.
set -u
LABEL="${1:-test}"
# THE DISPLAY IS NOT ALWAYS wayland-1. This used to hardcode it, and the number
# is just the order cage got its socket: it was wayland-1 when this was written
# and wayland-0 after the session was restarted on 2026-09-30. So honour an
# inherited WAYLAND_DISPLAY, then look for whatever socket is actually there, and
# only fall back to a literal for the error message.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
if [ -z "${WAYLAND_DISPLAY:-}" ] || [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
	for _s in "$XDG_RUNTIME_DIR"/wayland-[0-9]*; do
		case "$_s" in *'*'*) continue ;; esac
		[ -S "$_s" ] && { WAYLAND_DISPLAY=${_s##*/}; break; }
	done
fi
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

# Refuse rather than warn. The failure is unrecoverable without physical access,
# so a prompt nobody is there to read is worse than an exit.
#
# The test is for the compositor's socket and not for "am I on a tty", because
# the socket is the thing `waydroid session start` actually needs: if it is not
# there now it will not be there after the stop either, and the restart cannot
# succeed. --force is for a host where the session is genuinely headless and
# losing it costs nothing.
if [ "${2:-}" != "--force" ] && [ ! -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]; then
  echo "REFUSING: no Wayland compositor at $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY." >&2
  echo "  This script stops the Waydroid session and starts it again, and the" >&2
  echo "  restart needs that socket. Without it the session ends and the kiosk" >&2
  echo "  drops to the SDDM greeter, which only a physical login recovers." >&2
  echo "  Run it from a terminal inside the Waydroid session, or pass --force" >&2
  echo "  if losing the session really is acceptable here." >&2
  exit 2
fi

echo "### $LABEL: gralloc = $(grep -E '^ro\.hardware\.gralloc' /var/lib/waydroid/waydroid_base.prop)"

waydroid session stop >/dev/null 2>&1
sleep 5
setsid nohup waydroid session start >/tmp/wd-$LABEL.log 2>&1 </dev/null &

for i in $(seq 1 15); do
  sleep 6
  [ "$(sudo -n waydroid shell -- sh -c 'getprop sys.boot_completed' 2>/dev/null | tr -dc 0-9)" = "1" ] && break
done
echo "  booted after ~$((i*6))s"

sudo -n waydroid shell -- sh -c "logcat -c" >/dev/null 2>&1
sudo -n waydroid shell -- sh -c "am start -n net.sourceforge.opencamera/.MainActivity" >/dev/null 2>&1
sleep 18

echo "  --- did the test actually run? ---"
# Absence of errors is not success: a previous test reported zero failures only
# because the app never launched. Confirm positively before reading the counters.
echo "  opencamera pid  : $(sudo -n waydroid shell -- sh -c 'pidof net.sourceforge.opencamera' 2>/dev/null | tr -dc 0-9 || true)"
echo "  camera clients  :"
sudo -n waydroid shell -- sh -c "dumpsys media.camera 2>/dev/null | grep -A3 -i 'active camera clients'" 2>/dev/null | sed 's/^/    /'

echo "  --- verdict ---"
FAILS=$(sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -c 'coversion failed'" | tr -dc 0-9)
MAPF=$(sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -c 'Failed to map the buffer'" | tr -dc 0-9)
echo "  'format coversion failed'    : ${FAILS:-?}"
echo "  'Failed to map the buffer'   : ${MAPF:-?}"
echo "  --- relevant log ---"
sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -iE 'ExtCamUtils|ExtCamDevSsn|GBM-MESA-WRAPPER' | grep -viE 'fpsLimitList|loadFromCfg' | tail -8"
