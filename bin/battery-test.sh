#!/bin/bash
# Verify that Waydroid's battery reporting matches the host's real battery.
# Usage: battery-test.sh
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success: this compares every field positively
# against /sys/class/power_supply and confirms the patched HAL is the one live.
set -u
HAL=/var/lib/waydroid/rootfs/vendor/bin/hw/android.hardware.health@2.0-service.waydroid

# THE EXPECTED HASH IS READ FROM THE PACKAGE, NOT PINNED HERE.
#
# It used to be pinned, as PATCHED_MD5=4afd2108..., and that md5 is the
# THREE-byte patch from docs/10. docs/48 added two more bytes on 2026-09-18 --
# five now differ from shipped -- and nobody updated this constant. So from that
# day until 2026-09-30 this script opened by declaring a correctly patched
# machine broken and exiting 1, which means every check below it stopped running
# and the failure read as "the overlay is not live". Proved by reconstructing
# both: all five patches against the stock image give the md5 the machine
# actually has, and the pinned one is reproduced by applying only the three at
# 0x6730, 0x6731 and 0x6732.
#
# A hash of a patched binary cannot be maintained by hand -- it changes whenever
# the patch set does, and the thing that knows the patch set is
# waydroid-ext-battery's manifest, which records the expected result hash as the
# authoritative value the reconciler itself verifies against. So read it from
# there and only fall back to a pinned value on a host with no package.
MANIFEST=/usr/lib/waydroid-overlay/manifests/battery.manifest
REL=vendor/bin/hw/android.hardware.health@2.0-service.waydroid

# derive <mode> <image> <path-in-image> <stock sha256> <result sha256> <patches> <path>
WANT_SHA=$(awk -v rel="$REL" '$1 == "derive" && $8 == rel { print $6 }' \
           "$MANIFEST" 2>/dev/null)

echo "### is the patched HAL live?"
if [ -n "$WANT_SHA" ]; then
  LIVE=$(sudo -n sha256sum "$HAL" 2>/dev/null | cut -d' ' -f1)
  WHERE="waydroid-ext-battery's manifest"
else
  # No package: the 5-patch build of docs/10 plus docs/48, recorded 2026-09-30.
  WANT_SHA=a8401c142f4f1f42d854f558fade2207915b2f40ff6df306cb4c02bc3027c40a
  LIVE=$(sudo -n sha256sum "$HAL" 2>/dev/null | cut -d' ' -f1)
  WHERE="this script (no battery.manifest -- package not installed)"
fi

if [ "$LIVE" = "$WANT_SHA" ]; then
  echo "  sha256 ${LIVE:0:16}  OK (patched; expected per $WHERE)"
else
  echo "  sha256 ${LIVE:-<unreadable>}"
  echo "  does not match $WANT_SHA"
  echo "  expected per $WHERE"
  echo "  NOT the patched build -- overlay is not live, or the patch set moved."
  echo "  The overlay is only picked up by 'waydroid session stop/start',"
  echo "  NOT by 'waydroid container restart'. See docs/10-battery-fixed.md"
  echo "  and docs/48-battery-frozen-and-netd-stale.md."
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
