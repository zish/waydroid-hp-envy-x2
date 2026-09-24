# waydroid-ext-brightness-overlay -- docs/37-brightness.md
#
# The Android half of the brightness fix: one .rc file that stands the guest's
# stub light HAL down so waydroid-sensord can own ILight/default.
#
# WHY THERE IS A RACE TO LOSE
#
# Waydroid ships a 15 KB binary that registers
# android.hardware.light@2.0::ILight/default and discards every call -- it
# contains no file path strings at all, so it writes nowhere, and Android's
# brightness slider has never moved anything on any Waydroid host.
# waydroid-sensord serves that same interface for real, mapping Android's 0..255
# onto the host's /sys/class/backlight. Both register the same name and
# addService() overwrites, so the last to register owns it -- and
# container_manager.py starts waydroid-sensord BEFORE lxc-start, so the guest
# stub is guaranteed to register second. Without this file the host daemon
# always loses.
#
# WHY THE `interface` LINE IS DROPPED RATHER THAN THE SERVICE DISABLED
#
# This is the lesson wificond charged for in docs/34. `disabled` alone means
# only "do not auto-start at class main"; something can still ask init to start
# the service on demand, and an `interface` line in the service block is exactly
# how init knows which service to start when a client waits for a HIDL name.
# Removing the line removes the trigger. Three guards then work together:
# /system/bin/true execs and exits before it can reach addService(), `oneshot`
# stops init respawning it forever on a 5 s backoff, and `disabled` keeps it out
# of class hal.
#
# `shutdown critical` goes with the real binary -- it exists so a lights HAL can
# turn LEDs off during power-down, which /system/bin/true has no use for.
#
# WHAT HAPPENS IF THE DAEMON IS NOT THERE
#
# Nothing serves ILight at all, which is not a regression: the stub it replaces
# did nothing either. The vendor VINTF manifest still declares the HAL, and a
# declared-but-absent HAL is a VTS complaint rather than a runtime failure. So
# this file cannot break a system -- but it also cannot do anything alone, which
# is why waydroid-ext-sensord is a hard dependency here and only a Recommends in
# waydroid-ext-backlight. The SELinux label that package ships is correct on its
# own and can be staged before the daemon exists; this .rc is correct only in
# the daemon's presence.

VERSION=1.0.0
RELEASE=1
KIND=overlay

# A text .rc file with no architecture in it, and the daemon that gives it
# meaning is packaged separately and is arch-specific on its own account.
ARCH=noarch

SUMMARY="Stands the do-nothing light HAL down so the host daemon can drive the panel"

# Derived from Waydroid's stock vendor .rc, which is AOSP-descended.
LICENSE="Apache-2.0"

# Hard: the whole purpose of this file is to lose a name to waydroid-sensord,
# and with no sensord installed there is nothing to lose it to. Contrast
# waydroid-ext-backlight, which Recommends the daemon because its SELinux
# policy is correct whether or not anything is using it yet.
REQUIRES="waydroid-ext-overlay-sync
waydroid-ext-sensord"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/37-brightness.md"

DESCRIPTION="Lets Android's brightness slider reach the real panel, by getting Waydroid's
own light HAL out of the way.

The image ships a light HAL that registers the ILight interface and then
discards every call it receives -- it contains no file paths at all, so it
cannot write a backlight even in principle. waydroid-sensord implements the
same interface against the host's /sys/class/backlight, but both register the
same name and the guest stub always registers second, so it always wins.

This replaces the stub's init service definition with one that runs
/system/bin/true: the service still exists by name, so nothing that looks for
it is surprised, but it exits before it can claim the interface. The line that
lets init start it on demand is removed as well, which is the part that a
simple 'disabled' misses and the reason an earlier attempt at the same trick
on wificond did not hold.

Reverting is deleting the file, which restores the stub and with it a
brightness slider that moves nothing."

# Replaces a stock file, so the manifest records the upstream hash.
FILES="
0644 vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc artifacts/overlay/vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc artifacts/overlay/vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc.orig
"
