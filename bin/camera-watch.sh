#!/bin/bash
# Watch for the two intermittent camera faults on bigtab01 that could not be
# reproduced on demand (see docs/12-v4l2-frame-errors.md):
#
#   1. ERROR-flagged V4L2 buffers reaching the external camera HAL
#        ExtCamDevSsn@3.4: dequeueV4l2FrameLocked: v4l2 buf error! buf flag 0x12040
#        ExtCamDevSsn@3.4: threadLoop: Convert V4L2 frame to YU12 failed! res 1
#
#   2. spurious device removal, which disconnects whatever app is streaming
#        REMOVE device 100, reason: (Device status changed from -2 to 0)
#
# Both are intermittent. Leave this running while using the camera normally;
# it prints a line only when something happens, and records host-side context
# at that moment so the trigger can be identified after the fact.
#
# Usage:  camera-watch.sh [interval_seconds]     (default 20; Ctrl-C to stop)
#         run it ON the host: scp bin/camera-watch.sh 10.42.0.137:/tmp/
#
# Needs sudo for `waydroid shell` and `dmesg`.

INTERVAL=${1:-20}
LOG=${LOG:-/tmp/camera-watch.log}
W() { sudo waydroid shell -- sh -c "$1" 2>/dev/null; }

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }

say "watching every ${INTERVAL}s -> $LOG   (Ctrl-C to stop)"
W 'logcat -c'
prev_events=$(W 'dumpsys media.camera' | grep -E '^ *[0-9-]+ [0-9:]+ :' | head -20)

while true; do
    sleep "$INTERVAL"

    # --- 1. V4L2 frame errors -------------------------------------------
    log=$(W 'logcat -d')
    n_err=$(grep -c 'v4l2 buf error' <<<"$log")
    n_cvt=$(grep -c 'Convert V4L2 frame to YU12 failed' <<<"$log")
    if [ "$n_err" -gt 0 ] || [ "$n_cvt" -gt 0 ]; then
        say "FRAME ERRORS: ${n_err} buf-error, ${n_cvt} convert-fail in the last ${INTERVAL}s"
        grep -o 'buf flag 0x[0-9a-f]*' <<<"$log" | sort | uniq -c | sed 's/^/    /' | tee -a "$LOG"
        {
            echo "    loadavg : $(cat /proc/loadavg)"
            echo "    usb pwr : control=$(cat /sys/bus/usb/devices/1-6/power/control) status=$(cat /sys/bus/usb/devices/1-6/power/runtime_status)"
            echo "    cpu MHz : $(awk '/cpu MHz/{printf "%s ", $4}' /proc/cpuinfo)"
            echo "    dmesg   : $(sudo dmesg | tail -3 | tr '\n' '|')"
        } | tee -a "$LOG"
    fi
    W 'logcat -c'

    # --- 2. device flap --------------------------------------------------
    events=$(W 'dumpsys media.camera' | grep -E '^ *[0-9-]+ [0-9:]+ :' | head -20)
    new=$(comm -23 <(sort <<<"$events") <(sort <<<"$prev_events"))
    if grep -qE 'REMOVE|DISCONNECT' <<<"$new"; then
        say "DEVICE FLAP:"
        grep -E 'REMOVE|ADD|CONNECT|DISCONNECT' <<<"$new" | sed 's/^/    /' | tee -a "$LOG"
        {
            echo "    lsusb   : $(lsusb | grep -c 064e:c353) TrueVision device(s) on the bus"
            echo "    node    : $(stat -c 'inode=%i' /dev/video0)"
            echo "    loadavg : $(cat /proc/loadavg)"
        } | tee -a "$LOG"
    fi
    prev_events=$events
done
