#!/bin/bash
# Verify that Waydroid's battery reporting matches the host's real battery.
# Usage: battery-test.sh
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success: this compares every field positively
# against /sys/class/power_supply and confirms the patched HAL is the one live.
set -u
PATCHED_MD5=4afd21084e721f3bee2dba77c2fbd274
HAL=/var/lib/waydroid/rootfs/vendor/bin/hw/android.hardware.health@2.0-service.waydroid

echo "### is the patched HAL live?"
LIVE=$(sudo -n md5sum "$HAL" 2>/dev/null | cut -d' ' -f1)
if [ "$LIVE" = "$PATCHED_MD5" ]; then
  echo "  md5 $LIVE  OK (patched)"
else
  echo "  md5 ${LIVE:-<unreadable>}  NOT the patched build -- overlay is not live."
  echo "  The overlay is only picked up by 'waydroid session stop/start',"
  echo "  NOT by 'waydroid container restart'. See docs/10-battery-fixed.md."
  exit 1
fi

echo "### host truth"
H_CAP=$(cat /sys/class/power_supply/BAT0/capacity)
H_STAT=$(cat /sys/class/power_supply/BAT0/status)
H_UV=$(cat /sys/class/power_supply/BAT0/voltage_now)
H_AC=$(cat /sys/class/power_supply/AC/online)
H_MV=$((H_UV / 1000))
echo "  BAT0 capacity=$H_CAP status=$H_STAT voltage=${H_MV}mV  AC online=$H_AC"

# Android BatteryManager.BATTERY_STATUS_*: 1 UNKNOWN 2 CHARGING 3 DISCHARGING 4 NOT_CHARGING 5 FULL
case "$H_STAT" in
  Charging)      WANT_STAT=2 ;;
  Discharging)   WANT_STAT=3 ;;
  "Not charging") WANT_STAT=4 ;;
  Full)          WANT_STAT=5 ;;
  *)             WANT_STAT=1 ;;
esac
case "$H_AC" in 1) WANT_AC=true ;; *) WANT_AC=false ;; esac

echo "### what Android reports"
D=$(sudo -n waydroid shell -- sh -c 'dumpsys battery' 2>/dev/null | tr -d '\r')
echo "$D" | sed 's/^/  /'

get() { echo "$D" | grep -E "^ +$1:" | head -1 | sed 's/.*: *//'; }
A_LEVEL=$(get level); A_STAT=$(get status); A_VOLT=$(get voltage); A_AC=$(get "AC powered")

echo "### verdict"
FAIL=0
chk() { # name want got
  if [ "$2" = "$3" ]; then echo "  PASS  $1: $3"; else echo "  FAIL  $1: want $2, got $3"; FAIL=1; fi
}
chk "level"      "$H_CAP"     "$A_LEVEL"
chk "status"     "$WANT_STAT" "$A_STAT"
chk "voltage_mV" "$H_MV"      "$A_VOLT"
chk "AC powered" "$WANT_AC"   "$A_AC"

# Known-absent on this host: the ACPI battery exposes no health or temp node,
# so health=1 (UNKNOWN) and temperature=0 are expected, not regressions.
echo "  note  health/temperature are 0/UNKNOWN by design -- ACPI exposes neither."
exit $FAIL
