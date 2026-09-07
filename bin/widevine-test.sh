#!/bin/bash
# Verify that the Widevine L3 CDM is installed and that a real client can create a
# Widevine DRM plugin. See docs/21-netflix-widevine.md.
#
# Usage: widevine-test.sh [package]     (default: com.netflix.mediaclient)
# Run ON bigtab01 as jmelanso. Needs sudo for waydroid shell.
#
# Absence of errors is not success. Two traps this script exists to avoid:
#
#   1. The HAL is a *lazy* AIDL service (disabled + oneshot). Before any client asks
#      for it, `service list` does not show it and init.svc.vendor.drm-widevine-hal
#      does not exist. Neither absence means the fix failed -- so this script drives
#      a real client and reads the log, rather than inspecting service state.
#   2. `dumpsys media.drm` is not a valid probe on Android 13 (Can't find service).
set -u
PKG="${1:-com.netflix.mediaclient}"
FAIL=0
wds() { sudo -n waydroid shell -- sh -c "$1" 2>/dev/null; }

echo "### files in place inside the container"
for f in /vendor/bin/hw/android.hardware.drm-service-lazy.widevine \
         /vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc \
         /vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml \
         /vendor/lib64/libwvaidl.so; do
  # NOT `test -e`: waydroid shell always exits non-zero (cosmetic Errno 13), so its
  # exit status carries no information. Judge by whether `ls` produced output.
  if [ -n "$(wds "ls $f")" ]; then
    printf '  OK      %s\n' "$f"
  else
    printf '  MISSING %s\n' "$f"; FAIL=1
  fi
done

echo "### libprotobuf-cpp-lite.so symlink (load-bearing -- see docs/21)"
# libwvaidl.so NEEDs the unversioned soname, which exists only in /system/lib64.
# A vendor process cannot link there, so /vendor/lib64 must carry the name itself.
PB=$(wds 'ls -la /vendor/lib64/libprotobuf-cpp-lite.so' | tr -s ' ')
if [ -n "$PB" ] && [ -n "$(wds 'ls /vendor/lib64/libprotobuf-cpp-lite-3.9.1.so')" ]; then
  echo "  OK      $PB"
  echo "          target libprotobuf-cpp-lite-3.9.1.so present"
else
  echo "  BROKEN  symlink or its target is missing -- the HAL will fail to load"; FAIL=1
fi

if [ "$FAIL" = 1 ]; then
  echo
  echo "Install is incomplete; not driving a client. See docs/21-netflix-widevine.md."
  exit 1
fi

echo "### driving $PKG to force the lazy HAL to start"
ACT=$(wds "cmd package resolve-activity --brief $PKG" | tail -1)
if [ -z "$ACT" ] || [ "${ACT#*/}" = "$ACT" ]; then
  echo "  cannot resolve a launcher activity for $PKG -- is it installed?"; exit 1
fi
echo "  launching $ACT"
wds "logcat -c; am force-stop $PKG; am start -n $ACT >/dev/null 2>&1"
sleep 20

echo "### did a Widevine plugin get created?"
LOG=$(wds 'logcat -d')

check() {  # check <label> <grep-pattern>
  if printf '%s' "$LOG" | grep -qiE "$2"; then
    printf '  OK      %s\n' "$1"
  else
    printf '  NOT SEEN %s\n' "$1"; FAIL=1
  fi
}
check "framework found IDrmFactory/widevine" 'found IDrmFactory.*IDrmFactory/widevine'
check "HAL started for a client"             'IDrmFactory/widevine has clients: 1'
check "$PKG created a Widevine plugin"       "WVCdm-DrmFactory.*$PKG.*createDrmPlugin"

LEVEL=$(printf '%s' "$LOG" | grep -oE 'security_level = L[13]' | head -1)
[ -n "$LEVEL" ] && echo "  ${LEVEL/security_level = /reported }  (L3 is software-only: Netflix caps at SD)"

echo "### the failure this fix removed (must be absent)"
if printf '%s' "$LOG" | grep -qiE 'uuid=\[edef8ba979d64ace.*No supported hal instance found'; then
  echo "  PRESENT -- Widevine UUID still unresolved. The fix is not live."; FAIL=1
else
  echo "  OK      no 'No supported hal instance found' for the Widevine UUID"
fi

echo "### service state (informational -- 'stopped' is correct for a lazy oneshot)"
wds 'getprop | grep -iE "drm-widevine|drm-clearkey"' | grep init.svc | sed 's/^/  /'

echo
if [ "$FAIL" = 0 ]; then
  echo "PASS -- Widevine L3 is live. Playback itself still needs a signed-in account;"
  echo "the CDM provisions against Google's server on first use."
else
  echo "FAIL -- see docs/21-netflix-widevine.md."
fi
exit $FAIL
