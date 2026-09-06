#!/bin/bash
# Log USB runtime-power state across a system suspend/resume, from ON the host,
# because an ssh session does not survive the suspend.
#
# Detects the suspend by the wall-clock gap between samples: the loop sleeps a
# fixed interval, so any jump much larger than that is time the machine spent
# asleep.
#
# Deliberately reads ONLY sysfs power attributes. `lsusb` and `waydroid shell`
# are avoided in the loop: lsusb opens the USB device, which would wake it and
# destroy the very thing being measured.
#
# Usage:  suspend-probe.sh [minutes] [interval_seconds]      (default 30 min / 3 s)
#         start it detached:
#           setsid nohup /tmp/suspend-probe.sh 30 3 >/tmp/suspend-probe.log 2>&1 </dev/null &

MINS=${1:-30}
INT=${2:-3}
D=/sys/bus/usb/devices/1-6/power
END=$(( $(date +%s) + MINS*60 ))
prev_wall=$(date +%s)
prev_status=""

printf '%s  starting: %s min, %ss interval\n' "$(date '+%F %T')" "$MINS" "$INT"
printf '%s  baseline: control=%s status=%s suspended_time=%s\n' \
    "$(date '+%F %T')" "$(cat $D/control)" "$(cat $D/runtime_status)" "$(cat $D/runtime_suspended_time)"

while [ "$(date +%s)" -lt "$END" ]; do
    sleep "$INT"
    now=$(date +%s)
    gap=$(( now - prev_wall ))

    # A gap much larger than the sleep interval means the clock jumped: we were asleep.
    if [ "$gap" -gt $(( INT + 5 )) ]; then
        printf '%s  *** RESUMED after ~%ss asleep ***\n' "$(date '+%F %T')" "$gap"
        printf '%s      on resume: control=%s status=%s node=%s device=%s\n' \
            "$(date '+%F %T')" "$(cat $D/control 2>&1)" "$(cat $D/runtime_status 2>&1)" \
            "$([ -e /dev/video0 ] && echo present || echo GONE)" \
            "$([ -d /sys/bus/usb/devices/1-6 ] && echo present || echo GONE)"
    fi
    prev_wall=$now

    status=$(cat $D/runtime_status 2>/dev/null || echo UNREADABLE)
    if [ "$status" != "$prev_status" ]; then
        printf '%s  status: %s -> %s   (node=%s)\n' "$(date '+%F %T')" \
            "${prev_status:-<start>}" "$status" \
            "$([ -e /dev/video0 ] && echo present || echo GONE)"
        prev_status=$status
    fi
done
printf '%s  done. final: control=%s status=%s suspended_time=%s\n' \
    "$(date '+%F %T')" "$(cat $D/control)" "$(cat $D/runtime_status)" "$(cat $D/runtime_suspended_time)"
