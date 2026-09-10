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
# int 14, raw 51 -- no matter what the brightness setting says.
#
# THIS SCRIPT CANNOT LIFT THAT ITSELF. A HUMAN MUST TOUCH THE MACHINE.
#
# An earlier version claimed it beat the trap by poking user activity in the
# same waydroid shell invocation as each set. That claim was false and cost a
# session's worth of misread FAILEDs. Measured on this image (42-backlight-selinux.md):
#
#   before:         mLastUserActivityTime(excludingAttention)=70768
#   after keyevent: mLastUserActivityTime(excludingAttention)=70768
#   after tap:      mLastUserActivityTime(excludingAttention)=70768
#
# Injected input from `waydroid shell` does not count as user activity for
# PowerManagerService, so neither `input keyevent` nor `input touchscreen tap`
# does anything at all. `svc power stayon true` does not rescue it either: the
# setting takes (stay_on_while_plugged_in goes 0 -> 7, and the machine really
# is on AC) but the WindowManager override still wins and the policy stays DIM.
#
# So a full-range run needs someone physically interacting with Android for the
# WHOLE ~40 s duration -- not one tap, because the display re-dims 10 s after
# the last REAL touch and the remaining levels then measure the dim pin.
#
# Rather than mislead, this script now detects the condition: it reads
# mLastUserActivityTime alongside each set, and if that value never moves while
# the panel refuses to follow, it reports HUMAN REQUIRED instead of MISMATCH.
# Reading it is free -- it rides in the same invocation as the set, which is
# what the old keyevent slot was spent on.
#
# The mapping check near the end is the one measurement that does NOT depend on
# display policy, so prefer it when nobody is at the machine. It needs the
# daemon to have been started with --verbose.
#
# docs/37-brightness.md, docs/42-backlight-selinux.md
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

# One round trip: current policy and the user-activity clock, before we start.
echo "### policy"
BASE=$(ash "dumpsys display | grep -m1 mPowerRequest=
            dumpsys power | grep -o 'mLastUserActivityTime(excludingAttention)=[0-9]*'")
POLICY=$(printf '%s\n' "$BASE" | sed -n 's/.*policy=\([A-Z]*\).*/\1/p' | head -1)
UA0=$(printf '%s\n' "$BASE" | sed -n 's/.*excludingAttention)=\([0-9]*\).*/\1/p' | head -1)
echo "  display policy=${POLICY:-unknown}   mLastUserActivityTime=${UA0:-unknown}"
if [ "$POLICY" != "BRIGHT" ]; then
    echo "  The display is not BRIGHT, so the panel is pinned at raw $((14 * MAX / 255))."
    echo "  TOUCH THE MACHINE NOW and keep interacting for the whole run (~40 s)."
    echo "  One tap is not enough: it re-dims 10 s after your last REAL touch."
fi

echo "### driving brightness from Android"
DIM_RAW=$(( 14 * MAX / 255 ))
OK=0; FAIL=0; SKIP=0; HUMAN=0
for f in 0.2 0.5 0.8 1.0; do
    # Set the level and read back BOTH the user-activity clock and the policy in
    # the same invocation, because each round trip through the waydroid wrapper
    # costs seconds. No `input keyevent` here: it provably does nothing (see the
    # header) and it has side effects on the focused window.
    PROBE=$(ash "cmd display set-brightness $f >/dev/null 2>&1
                 dumpsys power | grep -o 'mLastUserActivityTime(excludingAttention)=[0-9]*'
                 dumpsys display | grep -m1 mPowerRequest=")
    UA=$(printf '%s\n' "$PROBE" | sed -n 's/.*excludingAttention)=\([0-9]*\).*/\1/p' | head -1)
    POL=$(printf '%s\n' "$PROBE" | sed -n 's/.*policy=\([A-Z]*\).*/\1/p' | head -1)

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
    elif [ "$POL" != "BRIGHT" ] && [ -n "$UA" ] && [ "$UA" = "$UA0" ]; then
        # The panel did not follow, the display is not BRIGHT, and the
        # user-activity clock has not advanced since this script started --
        # nobody is touching the machine, so Android is overriding every value
        # we set. This says nothing about the daemon. Do not call it a failure.
        printf "  %-5s -> raw %-5s  HUMAN REQUIRED (no user activity; UA stuck at %s)\n" \
            "$f" "$GOT" "$UA"
        HUMAN=$((HUMAN + 1))
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
    # animation and reports a mismatch that is really a timing artefact. A
    # reading of raw 375 against a request of 0.35 was exactly this, and briefly
    # looked like a non-linear brightness curve -- see docs/42.
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
    echo "BRIGHTNESS TEST FAILED ($OK ok, $SKIP skipped, $HUMAN human-required, $FAIL bad)"
    exit 1
elif [ "$HUMAN" != 0 ] && [ "$OK" = 0 ]; then
    echo "BRIGHTNESS TEST INCONCLUSIVE -- nobody was touching the machine, so Android"
    echo "overrode every level we set and the panel never followed. This is NOT a"
    echo "daemon fault. mLastUserActivityTime never moved from $UA0."
    echo "Re-run while interacting with Android continuously for the whole ~40 s,"
    echo "or read the mapping check above, which is independent of display policy."
    exit 2
elif [ "$OK" = 0 ]; then
    echo "BRIGHTNESS TEST INCONCLUSIVE -- every level was measured while the"
    echo "display was dimmed. Touch the machine to dismiss the lock screen and"
    echo "run this again; the mapping check above still validates the daemon."
    exit 2
else
    echo "BRIGHTNESS TEST PASSED ($OK ok, $SKIP skipped, $HUMAN human-required)"
fi
