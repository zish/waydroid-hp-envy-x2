#!/bin/bash
# Verify that Waydroid's sensors match the host's real IIO nodes.
# Usage: sensors-test.sh [--stimulate]
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success. This checks, in order:
#   1. the host daemon is the binary we built, and is running
#   2. the guest stub HAL correctly took itself out of the way
#   3. Android registered all five sensors with the right types
#   4. the daemon's own cross-checks pass against live hardware
#   5. the values Android reports match the host's IIO nodes, numerically
#
# Android only streams a sensor while an app is subscribed to it, so step 5
# can only compare sensors that currently have a client. It says which ones it
# actually exercised rather than quietly passing on an empty set.
# --stimulate launches Open Camera first, which subscribes to more of them.
set -u

DAEMON=/usr/local/bin/waydroid-sensord
IIO=/sys/bus/iio/devices
FAIL=0
STIMULATE=0
[ "${1:-}" = "--stimulate" ] && STIMULATE=1

note() { echo "  note  $*"; }
pass() { echo "  PASS  $*"; }
fail() { echo "  FAIL  $*"; FAIL=1; }

# Resolve an IIO node by its `name`. Never hardcode iio:deviceN -- the indices
# are assigned in probe order and change across boots.
iio_path() {
  local want="$1" d
  for d in "$IIO"/iio:device*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "$want" ] && { echo "$d"; return 0; }
  done
  return 1
}

echo "### 1. is the host daemon live?"
# Detecting this daemon is fiddlier than it looks:
#   - "waydroid-sensord" is 16 chars, so /proc/PID/comm is truncated to
#     "waydroid-sensor" and plain pgrep (which matches comm) misses it;
#   - pgrep -f matches any shell whose command line merely mentions the name,
#     including the one running this script;
#   - replaced instances linger as zombies, because Waydroid's background()
#     helper never wait()s on its Popen. A zombie polls nothing, so it must
#     not be counted as running.
# Match the truncated comm and exclude zombies.
live_pids() {
  ps -eo pid,stat,comm --no-headers |
    awk '$3 == "waydroid-sensor" && $2 !~ /Z/ { print $1 }'
}
PID=$(live_pids | head -1)
NLIVE=$(live_pids | wc -l)
if [ -n "$PID" ]; then
  pass "waydroid-sensord running, pid $PID: $(tr '\0' ' ' < /proc/"$PID"/cmdline)"
  if [ "$NLIVE" -eq 1 ]; then
    pass "exactly one live instance"
  else
    fail "$NLIVE live instances -- the single-instance lock did not hold"
  fi
  NZOMBIE=$(ps -eo stat,comm --no-headers | awk '$2=="waydroid-sensor" && $1 ~ /Z/' | wc -l)
  [ "$NZOMBIE" -gt 0 ] && note "$NZOMBIE zombie(s) left unreaped by waydroid's Popen; harmless"
else
  fail "waydroid-sensord is not running."
  echo "        container_manager.py starts it at session start, only if it is"
  echo "        on PATH. Check: command -v waydroid-sensord"
  exit 1
fi

echo "### 2. did the guest stub stand down?"
# images.py adds waydroid.stub_sensors_hal=1 only when waydroid-sensord is
# absent from PATH, and the stub's main() returns immediately when the property
# is false. So both of these are consequences of installing the daemon.
STUB_PROP=$(sudo -n waydroid shell -- sh -c 'getprop waydroid.stub_sensors_hal' 2>/dev/null | tr -d '\r')
STUB_SVC=$(sudo -n waydroid shell -- sh -c 'getprop init.svc.vendor.sensors-hal-1-0' 2>/dev/null | tr -d '\r')
[ -z "$STUB_PROP" ] && pass "waydroid.stub_sensors_hal unset" \
                    || fail "waydroid.stub_sensors_hal=$STUB_PROP (stub would claim the service)"
[ "$STUB_SVC" = "stopped" ] && pass "vendor.sensors-hal-1-0 is $STUB_SVC (it exits at line 1)" \
                            || fail "vendor.sensors-hal-1-0 is '$STUB_SVC', expected stopped"

if [ "$STIMULATE" = 1 ]; then
  echo "### stimulating: launching Open Camera to raise sensor subscriptions"
  sudo -n waydroid shell -- sh -c \
    'am start -n net.sourceforge.opencamera/.MainActivity' >/dev/null 2>&1
  sleep 8
fi

echo "### 3. what Android registered"
DUMP=$(sudo -n waydroid shell -- sh -c 'dumpsys sensorservice' 2>/dev/null | tr -d '\r')
for spec in "0000000000:accelerometer(1)" \
            "0x00000001:gyroscope(4)" \
            "0x00000002:magnetic_field(2)" \
            "0x00000003:orientation(3)" \
            "0x00000004:rotation_vector(11)"; do
  h="${spec%%:*}"; t="${spec##*:}"
  if echo "$DUMP" | grep -q "^$h).*ITE8350.*$t"; then
    pass "handle $h -> $t"
  else
    fail "handle $h ($t) not registered"
  fi
done
EXTRA=$(echo "$DUMP" | grep -cE "^0x5f[0-9a-f]+\) .*\| AOSP")
note "$EXTRA additional sensors synthesised by Android from these"

echo "### 4. daemon self-test against live hardware"
# Runs a second, independent instance: it only reads sysfs and never touches
# binder, so it cannot disturb the one serving Android.
"$DAEMON" --selftest 2>/dev/null | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || FAIL=1

echo "### 5. do Android's values match the host's IIO nodes?"
# Take the newest event Android recorded for each sensor, and bracket it with a
# host reading taken immediately after. Hold the machine still while this runs.
android_last() {  # section-title -> "v1 v2 v3 ..."
  echo "$DUMP" | awk -v s="$1" '
    index($0, s ": last") { inb = 1; next }
    inb && /^[A-Za-z]/   { inb = 0 }
    inb && /ts=/         { sub(/.*\) /, ""); gsub(/,/, ""); last = $0 }
    END                  { print last }'
}

DUMP=$(sudo -n waydroid shell -- sh -c 'dumpsys sensorservice' 2>/dev/null | tr -d '\r')

TESTED=0

# --- accelerometer: raw milli-g x 9.80665e-3 = m/s^2
A=$(android_last "ITE8350 3-axis Accelerometer")
if [ -n "$A" ]; then
  P=$(iio_path accel_3d)
  HX=$(cat "$P/in_accel_x_raw"); HY=$(cat "$P/in_accel_y_raw"); HZ=$(cat "$P/in_accel_z_raw")
  read -r RES < <(awk -v a="$A" -v hx="$HX" -v hy="$HY" -v hz="$HZ" 'BEGIN {
      split(a, v, " "); k = 9.80665e-3
      dx = v[1] - hx*k; dy = v[2] - hy*k; dz = v[3] - hz*k
      d = sqrt(dx*dx + dy*dy + dz*dz)
      printf "%.3f|%.3f %.3f %.3f|%.3f %.3f %.3f", d, v[1], v[2], v[3], hx*k, hy*k, hz*k }')
  D=${RES%%|*}; REST=${RES#*|}; AV=${REST%%|*}; HV=${REST##*|}
  echo "        android [$AV]  host [$HV]  |diff| = $D m/s^2"
  awk -v d="$D" 'BEGIN { exit !(d < 1.0) }' \
    && pass "accelerometer agrees (tolerance 1.0 m/s^2)" \
    || fail "accelerometer differs by $D m/s^2"
  TESTED=$((TESTED+1))
else
  note "accelerometer: no recent events -- no app is subscribed, not compared"
fi

# --- magnetometer: raw x 1e-4 = uT.  in_magn_scale says 1.0 and is wrong.
M=$(android_last "ITE8350 3-axis Magnetometer")
if [ -n "$M" ]; then
  P=$(iio_path magn_3d)
  HX=$(cat "$P/in_magn_x_raw"); HY=$(cat "$P/in_magn_y_raw"); HZ=$(cat "$P/in_magn_z_raw")
  read -r RES < <(awk -v a="$M" -v hx="$HX" -v hy="$HY" -v hz="$HZ" 'BEGIN {
      split(a, v, " "); k = 1e-4
      dx = v[1] - hx*k; dy = v[2] - hy*k; dz = v[3] - hz*k
      printf "%.3f|%.2f %.2f %.2f|%.2f %.2f %.2f",
             sqrt(dx*dx+dy*dy+dz*dz), v[1], v[2], v[3], hx*k, hy*k, hz*k }')
  D=${RES%%|*}; REST=${RES#*|}; AV=${REST%%|*}; HV=${REST##*|}
  echo "        android [$AV]  host [$HV]  |diff| = $D uT"
  awk -v d="$D" 'BEGIN { exit !(d < 5.0) }' \
    && pass "magnetometer agrees (tolerance 5 uT)" \
    || fail "magnetometer differs by $D uT"
  TESTED=$((TESTED+1))
else
  note "magnetometer: no recent events -- no app is subscribed, not compared"
fi

# --- rotation vector: raw x 1e-7, a unit quaternion.  Compare as an angle
#     between orientations, which is what actually matters.
R=$(android_last "ITE8350 Rotation Vector")
if [ -n "$R" ]; then
  P=$(iio_path dev_rotation)
  read -r Q0 Q1 Q2 Q3 < "$P/in_rot_quaternion_raw"
  read -r RES < <(awk -v a="$R" -v q0="$Q0" -v q1="$Q1" -v q2="$Q2" -v q3="$Q3" 'BEGIN {
      split(a, v, " "); k = 1e-7
      hx = q0*k; hy = q1*k; hz = q2*k; hw = q3*k
      dot = v[1]*hx + v[2]*hy + v[3]*hz + v[4]*hw
      if (dot < 0) dot = -dot           # q and -q are the same rotation
      if (dot > 1) dot = 1
      printf "%.2f|%.3f %.3f %.3f %.3f|%.3f %.3f %.3f %.3f",
             2*atan2(sqrt(1-dot*dot), dot)*180/3.14159265358979,
             v[1], v[2], v[3], v[4], hx, hy, hz, hw }')
  D=${RES%%|*}; REST=${RES#*|}; AV=${REST%%|*}; HV=${REST##*|}
  echo "        android [$AV]  host [$HV]  angle = $D deg"
  awk -v d="$D" 'BEGIN { exit !(d < 20.0) }' \
    && pass "rotation vector agrees (tolerance 20 deg)" \
    || fail "rotation vector differs by $D deg"
  TESTED=$((TESTED+1))
else
  note "rotation vector: no recent events -- no app is subscribed, not compared"
fi

# --- gyroscope: only meaningful if the machine is being held still.
G=$(android_last "ITE8350 3-axis Gyroscope")
if [ -n "$G" ]; then
  DPS=$(awk -v a="$G" 'BEGIN { split(a, v, " ")
      printf "%.2f", sqrt(v[1]*v[1]+v[2]*v[2]+v[3]*v[3])*180/3.14159265358979 }')
  echo "        android [$G] rad/s  |w| = $DPS deg/s"
  awk -v d="$DPS" 'BEGIN { exit !(d < 10.0) }' \
    && pass "gyroscope is settled (< 10 deg/s at rest)" \
    || note "gyroscope reads $DPS deg/s -- moving, or still in its warm-up"
  TESTED=$((TESTED+1))
else
  note "gyroscope: no recent events -- no app is subscribed, not compared"
fi

echo "### verdict"
if [ "$TESTED" = 0 ]; then
  echo "  INCONCLUSIVE  no sensor had an active subscriber, so nothing was"
  echo "                compared end to end. Re-run with --stimulate, or open"
  echo "                an app that uses sensors, then try again."
  exit 2
fi
echo "  compared $TESTED sensor(s) end to end against the host"
[ "$FAIL" = 0 ] && echo "  ALL PASS" || echo "  FAILURES -- see above"
exit "$FAIL"
