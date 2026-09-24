# waydroid-ext-wifi-framework -- docs/29-wifi-plan.md Stage 0
#
# One 557-byte XML file, and the cheapest thing in this repository by a wide
# margin. The Waydroid LineageOS 20 image ships no Wi-Fi feature declaration at
# all, so PackageManager reports no android.hardware.wifi feature, WifiService
# never starts, and Settings shows no Wi-Fi panel. Declaring the feature wakes
# the whole dormant stack.
#
# It over-delivered when it was first deployed, and that result is what retired
# the largest risk in the Wi-Fi plan a stage early: with this file alone,
# WifiService starts and completes every boot phase, wificond starts by itself
# and registers wifinl80211, wifiscanner registers, and Settings actively tries
# to switch Wi-Fi on. `dumpsys wifi` reports `HalDeviceManager: mWifi: null` --
# the vendor HAL really is absent -- and the framework proceeds past it anyway
# and goes straight to wificond. The absence of a vendor Wi-Fi HAL was the
# thing that could have sunk the design, and it does not.
#
# It then fails at exactly one place: "Can't get wlan0 index: No such device",
# CMD_STA_START_FAILURE, DisabledState. That is what the other three Wi-Fi
# packages exist to fix.
#
# WHY THE DAEMON IS RECOMMENDED AND NOT REQUIRED
#
# Installed alone this produces a Wi-Fi panel that fails honestly -- it shows
# up, tries to turn on, and reports failure -- rather than one that lies. That
# is a legitimate configuration and it is exactly how Stage 0 was verified,
# before any of the rest existed. A hard dependency would forbid it. The
# corresponding hard edge lives on waydroid-ext-wifi-hostd instead, where
# standing wificond down with no replacement really is worse than stock.
#
# The file is verbatim in form from AOSP frameworks/native/data/etc.

VERSION=1.0.0
RELEASE=1
KIND=overlay
ARCH=noarch

SUMMARY="Declares 802.11 hardware to Android, which starts its dormant Wi-Fi stack"

LICENSE="Apache-2.0"

REQUIRES="waydroid-ext-overlay-sync"

# The daemon that makes the panel work. Weak on purpose: see above.
RECOMMENDS="waydroid-ext-wifid"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/29-wifi-plan.md docs/31-wifi-stage2.md"

DESCRIPTION="Tells Android that this device has Wi-Fi hardware.

Waydroid's images ship no android.hardware.wifi feature declaration, and
without it PackageManager reports no Wi-Fi feature, WifiService never starts,
and the Wi-Fi panel is absent from Settings entirely. This adds the standard
AOSP feature permission file, at which point the framework brings its whole
Wi-Fi stack up on its own.

On its own that produces a Wi-Fi panel that appears, tries to enable itself,
and fails because there is no wlan0 in the container -- which is honest and is
how this file was first verified. Install waydroid-ext-wifid alongside it for a
panel that scans and connects; it is recommended rather than required so that
this one file can still be used alone, as a probe of whether a given
image's framework reacts to the declaration at all."

# Adds a file rather than replacing one: the image ships nothing at this path,
# so there is no upstream hash to record and no upstream to drift from.
FILES="
0644 system/etc/permissions/android.hardware.wifi.xml artifacts/overlay/system/etc/permissions/android.hardware.wifi.xml
"
