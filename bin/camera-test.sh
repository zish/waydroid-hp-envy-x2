#!/bin/bash
# Restart Waydroid and test whether the camera preview produces frames.
# Usage: camera-test.sh <label>
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
set -u
LABEL="${1:-test}"
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1

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

echo "  --- verdict ---"
FAILS=$(sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -c 'coversion failed'" | tr -dc 0-9)
MAPF=$(sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -c 'Failed to map the buffer'" | tr -dc 0-9)
echo "  'format coversion failed'    : ${FAILS:-?}"
echo "  'Failed to map the buffer'   : ${MAPF:-?}"
echo "  --- relevant log ---"
sudo -n waydroid shell -- sh -c "logcat -d 2>/dev/null | grep -iE 'ExtCamUtils|ExtCamDevSsn|GBM-MESA-WRAPPER' | grep -viE 'fpsLimitList|loadFromCfg' | tail -8"
