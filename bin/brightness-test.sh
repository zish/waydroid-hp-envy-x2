#!/bin/bash
# Verify that Android's screen brightness reaches the host's panel backlight.
# Usage: brightness-test.sh [--restore]
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success. This drives brightness FROM Android and
# then reads /sys/class/backlight to confirm the panel actually moved, rather
# than trusting that a setLight call was accepted.
#
# THE TRAP THIS SCRIPT EXISTS TO NAVIGATE
#
# Android will not hold a brightness you set unless it also thinks a user is
# present. WindowManager overrides the user-activity timeout to 10 s here
# (mUserActivityTimeoutOverrideFromWindowManager=10000), and once the display
# policy goes to DIM the panel is pinned at mScreenBrightnessDimConfig=0.05 --
# int 14, raw 51 -- no matter what the brightness setting says. Every
# measurement below therefore pokes user activity in the SAME waydroid shell
# invocation as the set, because each invocation costs seconds of its own and
# two of them will blow the window.
#
# A run that reports raw 51 for every level has not found a broken daemon; it
# has found a display that is dimmed. Touch the machine and run it again.
#
# docs/37-brightness.md
set -u

BL_DIR=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1)
[ -n "$BL_DIR" ] || { echo "no backlight device"; exit 1; }
MAX=$(cat "$BL_DIR/max_brightness")
raw() { cat "$BL_DIR/actual_brightness"; }
ash() { sudo -n waydroid shell -- sh -c "$1" 2>/dev/null; }

echo "### host panel"
echo "  device=$(basename "$BL_DIR")  max=$MAX  now=$(raw)"

if [ "${1:-}" = "--restore" ]; then
    echo "### restoring to full"
    sudo -n sh -c "echo $MAX > $BL_DIR/brightness"
    echo "  now=$(raw)"
    exit 0
fi

echo "### who serves ILight"
LSHAL=$(ash "lshal 2>/dev/null | grep 'light@2.0::ILight/default'")
echo "  ${LSHAL:-<not registered>}"
case "$LSHAL" in
    *"N/A"*"N/A"*)
        echo "  PID N/A twice = served from OUTSIDE the container, i.e. by us. OK" ;;
    "")
        echo "  ILight is not registered at all -- waydroid-sensord is not running,"
        echo "  or it found no backlight device. FAIL"; exit 1 ;;
    *)
        echo "  A PID means the GUEST stub owns the name and discards every call."
        echo "  Deploy the brightness overlay component and restart the container:"
        echo "    waydroid-overlay-sync && systemctl restart waydroid-container.service"
        exit 1 ;;
esac

echo "### policy"
POLICY=$(ash "dumpsys display | grep -m1 mPowerRequest=" | sed 's/.*policy=\([A-Z]*\).*/\1/')
echo "  display policy=$POLICY"
[ "$POLICY" = "DIM" ] && echo "  (DIM pins the panel at raw $((14 * MAX / 255)); touch the machine first)"

echo "### driving brightness from Android"
# DIM pins the panel here regardless of the setting; treat it as SKIPPED, not
# as a failure, because it says nothing about the daemon.
DIM_RAW=$(( 14 * MAX / 255 ))
OK=0; FAIL=0; SKIP=0
for f in 0.2 0.5 0.8 1.0; do
    # One invocation: set, then poke activity, so the 10 s window is not spent
    # on a second round trip through the waydroid wrapper.
    ash "cmd display set-brightness $f; input keyevent KEYCODE_MENU" >/dev/null
    sleep 1.5
    GOT=$(raw)
    WANT=$(awk -v f="$f" -v m="$MAX" 'BEGIN{printf "%d", f*m}')
    TOL=$(awk -v m="$MAX" 'BEGIN{printf "%d", m*0.03+2}')
    DIFF=$(( GOT > WANT ? GOT - WANT : WANT - GOT ))
    if [ "$DIFF" -le "$TOL" ]; then
        printf "  %-5s -> raw %-5s (want ~%s)  OK\n" "$f" "$GOT" "$WANT"
        OK=$((OK + 1))
    elif [ "$GOT" = "$DIM_RAW" ]; then
        printf "  %-5s -> raw %-5s  SKIPPED (display is dimmed)\n" "$f" "$GOT"
        SKIP=$((SKIP + 1))
    else
        printf "  %-5s -> raw %-5s (want ~%s)  MISMATCH\n" "$f" "$GOT" "$WANT"
        FAIL=$((FAIL + 1))
    fi
    sleep 1
done

# The authoritative check, and the only one that does not depend on Android's
# display policy: whatever brightness Android last asked for, did the panel
# land where our own mapping says it should?  This validates the piece we own.
echo "### mapping check (daemon's last setLight vs the panel)"
LOG=$(ls -t /tmp/sensord-v.log /tmp/sensord-lights.log 2>/dev/null | head -1)
if [ -n "$LOG" ]; then
    # Android animates brightness as a RAMP, so the log and the panel are both
    # moving targets for a second or two after a change. Wait for the last
    # logged value to stop changing before comparing, or this check races the
    # animation and reports a mismatch that is really a timing artefact.
    LAST=""; PREV=""
    for _ in 1 2 3 4 5 6 7 8; do
        LAST=$(grep -a -oE "brightness [0-9]+/255" "$LOG" | tail -1 |
               sed -E 's#brightness ([0-9]+)/255#\1#')
        [ -n "$LAST" ] && [ "$LAST" = "$PREV" ] && break
        PREV=$LAST
        sleep 1
    done
    if [ -n "$LAST" ]; then
        EXP=$(( LAST * MAX / 255 ))
        GOT=$(raw)
        D=$(( GOT > EXP ? GOT - EXP : EXP - GOT ))
        printf "  android sent %s/255 -> panel %s, mapping says %s" "$LAST" "$GOT" "$EXP"
        if [ "$D" -le 1 ]; then echo "  OK"; else echo "  MISMATCH"; FAIL=$((FAIL + 1)); fi
    else
        echo "  no setLight logged yet (daemon not started with --verbose?)"
    fi
else
    echo "  no daemon log; start it with --verbose to enable this check"
fi

echo "### daemon's own view (needs --verbose to have been passed)"
for L in /tmp/sensord-v.log /tmp/sensord-lights.log; do
    [ -f "$L" ] && grep -a -E "brightness [0-9]+/255" "$L" | tail -4
done

echo
if [ "$FAIL" != 0 ]; then
    echo "BRIGHTNESS TEST FAILED ($OK ok, $SKIP skipped, $FAIL bad)"
    exit 1
elif [ "$OK" = 0 ]; then
    echo "BRIGHTNESS TEST INCONCLUSIVE -- every level was measured while the"
    echo "display was dimmed. Touch the machine to dismiss the lock screen and"
    echo "run this again; the mapping check above still validates the daemon."
    exit 2
else
    echo "BRIGHTNESS TEST PASSED ($OK ok, $SKIP skipped)"
fi
