# waydroid-ext-wifi-hostd -- docs/34-wifi-second-radio.md, docs/30-wifi-aidl-surface.md
#
# The two Android-side files that hand Wi-Fi to the host daemon: one stands the
# guest's wificond down, the other makes Android take the AIDL path to the
# supplicant instead of a HIDL one that does not exist. Neither is useful
# without waydroid-wifid and both are actively harmful without it, which is why
# the hard dependency is on this package rather than on the group.
#
# wificond.rc -- WHY "disabled" WAS NOT ENOUGH
#
# Stock wificond and waydroid-wifid both register the servicemanager name
# "wifinl80211", and addService() overwrites, so whichever registers last owns
# it. The first attempt added one word, `disabled`, to the stock definition. It
# was verified at the time and it was still wrong: `disabled` means only "do not
# auto-start at class main", and something on this image asks init to start the
# service on demand anyway. getprop init.svc.wificond reported "running", and
# wificond appeared within 1 ms of
#
#   WifiNl80211Manager: Setting up interface for client mode: wlan0
#
# so the on-demand start won every time, wificond took the name, and Android
# then talked to a wificond that answers "No wiphy is found". Stages 2 and 3
# never saw it because only the connectivity path Stage 4 reaches asks for the
# interface that way.
#
# Killing it in a loop is worse, not better: init restarts a dead service on a
# 5 s backoff, and a registered-then-dead binder makes Android report "Failed to
# get reference to wificond", which is a different and more confusing failure.
# Hence /system/bin/true plus `oneshot` plus `disabled`. NET_RAW and NET_ADMIN
# go with the real binary; a service definition should not carry privileges its
# executable cannot use.
#
# THE SUPPLICANT MANIFEST -- WHY THIS FILE SWITCHES THE PATH
#
# service-wifi.jar ships both SupplicantStaIfaceHalAidlImpl and
# SupplicantStaIfaceHalHidlImpl and chooses in initialize(), by asking
# ServiceManager.isDeclared("android.hardware.wifi.supplicant.ISupplicant/default").
# isDeclared() reads the VINTF manifest. It does NOT check whether anything has
# registered the service. So registering the daemon's supplicant object without
# this file leaves Android taking the HIDL path to a HIDL service that does not
# exist, and the master toggle stays off exactly as it did in Stage 3.
#
# Version 1 is not a guess: it is the frozen aidl_api snapshot the shim
# implements (docs/30, finding 1). The instance name "default" has to agree with
# SUPPLICANT_SERVICE_NAME in wifi/Supplicant.h.
#
# A trap met while writing that file, recorded because nothing reports it: an
# XML comment may not contain a double hyphen. libvintf rejects the whole
# manifest if it does, and a rejected manifest declares nothing, which looks
# exactly like the file not being deployed.

VERSION=1.0.1
RELEASE=1
KIND=overlay
ARCH=noarch

SUMMARY="Stands wificond down and points Android's supplicant at the host daemon"

# wificond.rc derives from AOSP's; the supplicant VINTF manifest was written
# for this project.
LICENSE="Apache-2.0 AND GPL-3.0-or-later"

# Hard, and docs/47 names this as the example of why hard edges live on
# individual packages rather than on groups: standing wificond down and putting
# nothing in its place leaves Android with a Wi-Fi framework and no wificond
# behind it, which is worse than stock. Stock at least fails honestly.
#
# waydroid-ext-wifid Recommends this package in the other direction, so the pair
# is not a dependency cycle -- deliberate, because the daemon has to stay
# testable against an image that has never had an overlay file.
REQUIRES="waydroid-ext-overlay-sync >= 1.1.0
waydroid-ext-wifid"

# Without the feature declaration there is no WifiService to take either path.
RECOMMENDS="waydroid-ext-wifi-framework"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/30-wifi-aidl-surface.md docs/34-wifi-second-radio.md docs/35-wifi-stage5.md"

DESCRIPTION="Hands Android's Wi-Fi native layer to the host daemon, by removing the guest
implementation that would otherwise fight it and by declaring the supplicant
interface the daemon actually serves.

Android's wificond and waydroid-wifid register the same servicemanager name,
and the last registration wins. The guest wificond is therefore replaced with
a service definition that exists by name, execs a no-op and exits before it can
claim the name. Marking it disabled is not sufficient on its own: something on
these images asks init to start it on demand regardless, and that start beats
the host daemon every time.

The second file declares android.hardware.wifi.supplicant in the vendor VINTF
manifest. Android ships both an AIDL and a HIDL supplicant client and picks
between them by asking whether the interface is declared -- not by asking
whether anything has registered it. Without the declaration the framework takes
the HIDL path to a service that does not exist, and the Wi-Fi master toggle
will not stay on no matter what the daemon does.

Both files need waydroid-ext-wifid installed to be anything but destructive,
so it is a hard requirement."

# wificond.rc replaces a stock file and records its upstream hash; the
# supplicant manifest adds a path the image does not ship.
FILES="
0644 system/etc/init/wificond.rc artifacts/overlay/system/etc/init/wificond.rc 7ec3ef548e88bcd13577b59239ca88b594454622818e4a9190ad274b1aadee38
0644 vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml artifacts/overlay/vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml
"
