# waydroid-ext-battery -- docs/10-battery-fixed.md, docs/48-battery-frozen-and-netd-stale.md
#
# Five bytes, in three unrelated places, in Waydroid's health HAL. Each one
# undoes something Waydroid did on purpose, and all three are needed: the first
# two produce a battery reading that is correct and then freezes, which is
# harder to diagnose than one that is obviously wrong.
#
#   0x6730  healthd_board_battery_update -> `xor eax,eax; ret`
#           The hook overwrote every field BatteryMonitor had just read from
#           the host's /sys/class/power_supply with hardcoded fakes -- the
#           famous 85%. Only on the path that reaches Android, so the correct
#           values were being read and then discarded.
#
#   0xcbd1  timerfd_create clockid CLOCK_BOOTTIME_ALARM (9) -> CLOCK_BOOTTIME (7)
#           CLOCK_BOOTTIME_ALARM needs CAP_WAKE_ALARM. This service's .rc
#           carries no capabilities line -- upstream AOSP's has one, Waydroid's
#           does not -- so the call returns EPERM and healthd registers no
#           periodic update at all. CLOCK_BOOTTIME needs no capability and
#           still counts across suspend; it does not wake the machine, which is
#           wanted here rather than tolerated. Nothing should wake a laptop to
#           poll its own battery.
#
#   0x6720  healthd_board_init -> `ret`
#           One 64-bit store set periodic_chores_interval_fast and _slow to -1,
#           and WakeAlarmSetInterval maps -1 to a zeroed itimerspec, which
#           DISARMS the timer. So patch 2 alone gives a timer that exists and
#           never fires. Removing the hook leaves the AOSP defaults the caller
#           already wrote: 60 s on charger, 600 s on battery.
#
# WHY A PATCHED BINARY AND NOT AN .rc EDIT
#
# Adding the missing `capabilities WAKE_ALARM` line would not work on this
# host. lxc.cap.keep lists wake_alarm, yet the container's bounding set comes up
# without it (CapBnd bit 35 clear, every other cap in the keep list present), so
# PR_CAP_AMBIENT_RAISE from init would fail anyway. docs/48.
#
# The uevent socket is why this is not an obviously dead reading: a battery is
# not a net device and untagged uevents are broadcast to every network
# namespace, so the container does see the host's power_supply events. Values
# track correctly while they are changing and freeze the moment the pack goes
# quiet. Measured: 101% for nine minutes, which was a real host reading the
# ACPI driver produced at charge termination and never replaced.
#
# Confirm the fix took by reading /proc/<pid>/fdinfo/<timerfd> inside the
# container: clockid must be 7 and it_interval must be (60, 0).

VERSION=2.0.0
RELEASE=1
KIND=overlay

# x86_64 Android ELF. Not noarch, for the reason camera-gbm gives.
ARCH=x86_64

SUMMARY="Health HAL patched so Android sees the real battery, and keeps seeing it"

# android.hardware.health@2.0-service and healthd are AOSP; this is Waydroid's
# build of them, patched in three places.
LICENSE="Apache-2.0"

# Nothing else. The patched HAL reads the host's power supply through the
# container's own sysfs and needs no host daemon, which makes this the one
# overlay component with no companion package at all.
REQUIRES="waydroid-ext-overlay-sync >= 1.1.0"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/10-battery-fixed.md docs/48-battery-frozen-and-netd-stale.md"

DESCRIPTION="Lets Android read the machine's real battery instead of a hardcoded 85 percent,
and keeps the reading current once the battery stops generating events.

Waydroid's health HAL reads the host's power supply correctly and then, on the
one path that reaches Android, overwrites every field -- charge, voltage,
adapter state, temperature -- with fixed values. That hook is patched out, so
what BatteryMonitor read is what Android gets.

Two further patches restore periodic polling, which Waydroid disables twice
over in unrelated ways: the wake alarm asks for a clock that needs a capability
the container does not have, and the board configuration hook disarms the timer
even when the clock succeeds. Without both, the battery reading is correct
while the charge is moving and then freezes on the last kernel event, which
looks like a working battery until you watch it for ten minutes.

Polling uses CLOCK_BOOTTIME rather than CLOCK_BOOTTIME_ALARM. It counts across
suspend but does not wake the machine, so a suspended laptop is not woken every
sixty seconds to poll its own battery."

# A DERIVE row, so this package ships no vendor binary: the five bytes are
# applied to the copy in the user's own vendor.img at reconcile time, between a
# check of the stock hash and a check of the result. Patching somebody else's
# binary does not make it ours to redistribute (docs/54-no-vendored-binaries.md),
# and the input is already on every machine that can run this.
#
# The three patch sites, in the order the header above explains them:
#   6720:48:c3                     healthd_board_init -> ret
#   6730:50:31,6731:66:c0,6732:c7:c3   healthd_board_battery_update -> xor eax,eax; ret
#   cbd1:09:07                     CLOCK_BOOTTIME_ALARM -> CLOCK_BOOTTIME
#
# 0755, not 0644: init execs this one, unlike the libraries the other overlay
# components ship.
FILES="
derive 0755 vendor/bin/hw/android.hardware.health@2.0-service.waydroid vendor /bin/hw/android.hardware.health@2.0-service.waydroid de3cf6bc2565079893dbc3db5c52791c30b168df9c3684e4b4857db4a483a79b a8401c142f4f1f42d854f558fade2207915b2f40ff6df306cb4c02bc3027c40a 6720:48:c3,6730:50:31,6731:66:c0,6732:c7:c3,cbd1:09:07
"
