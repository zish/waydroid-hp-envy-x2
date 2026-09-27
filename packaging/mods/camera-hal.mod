# waydroid-ext-camera-hal -- docs/11-camera-facing.md, docs/12-v4l2-frame-errors.md
#
# Two files that together make the external camera usable by apps, once
# waydroid-ext-camera-gbm has made its frames arrive at all.
#
# THE ONE BYTE
#
# Waydroid's external camera HAL reports ANDROID_LENS_FACING = EXTERNAL (2).
# That is truthful and it is also useless: an app that declares
# android.hardware.camera (rear) in its manifest, or calls
# CameraCharacteristics and requires LENS_FACING_BACK, will not open an
# EXTERNAL camera. On a tablet with exactly one camera, BACK and FRONT are
# mutually exclusive and EXTERNAL satisfies neither, so the choice is which
# lie to tell, not whether to tell one. BACK is the one more apps require.
#
# The change is a single byte at file offset 0x2c061, the immediate of a movb
# in ExternalCameraDevice::initDefaultCharsKeys. Everything else in the 407,412
# bytes is the vendor image's own build. Locate it in an unfamiliar build by
# the 17-byte signature c644242d028d44242d6a01506805000800 rather than by
# offset; artifacts/camera/README.md carries the disassembly and a two-line
# reproduction from the original.
#
# There is NO 64-bit counterpart. The camera provider is a 32-bit process, and
# vendor/lib64 has no camera.device@3.4-external-impl.so to replace.
#
# THE RESOLUTION CAP
#
# external_camera_config.xml is stock with every Limit above 1280x720 removed.
# The HAL picks the largest advertised mode, started 1920x1080@30 MJPG, and
# then failed in conversion -- "threadLoop: format coversion failed!" -- so the
# LED lit and the preview stayed black. That failure is in the HAL's conversion
# path, not in any particular camera, which is why this ships in the generic
# package rather than an hw- one. The stock file additionally advertises
# 2592x1944 and 1600x1200, which the reference camera does not have at all.
#
# The cost is real and worth stating plainly: a camera that can do 1080p is
# capped at 720p by this file. That is the trade for a preview that is not
# black, and it is why the cap is named in the package description and not
# only in a comment.

VERSION=2.0.0
RELEASE=1
KIND=overlay

# The HAL is ELF32 i386 -- the camera provider is a 32-bit process -- but it is
# loaded inside an x86_64 Android container and is meaningless anywhere else.
# ExclusiveArch, for the reason camera-gbm gives: a noarch package would
# install happily on an aarch64 host and break Android there instead of failing
# on the shelf.
ARCH=x86_64

SUMMARY="External camera seen as a rear camera, capped where the HAL can convert"

# Both files derive from AOSP: hardware/interfaces/camera/device/3.4/default
# for the HAL and frameworks' external camera config for the XML, as built into
# the LineageOS 20 vendor image. A one-byte patch and a list of deleted Limit
# entries do not change that.
LICENSE="Apache-2.0"

# Hard, and not only for tidiness. Without the rebuilt minigbm wrapper every
# frame this camera produces is black (docs/08), and this package's entire
# effect is to make MORE apps willing to open it -- so installing it alone
# widens the surface of a bug it does not fix. That is the "worse than stock"
# test docs/47 puts on individual packages, and it fails it.
REQUIRES="waydroid-ext-overlay-sync >= 1.1.0
waydroid-ext-camera-gbm"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/11-camera-facing.md docs/12-v4l2-frame-errors.md"

DESCRIPTION="Makes Waydroid's external camera openable by apps that require a rear camera,
and caps it at a resolution the HAL can actually convert.

Waydroid's external camera HAL reports the lens as EXTERNAL. Apps that require
android.hardware.camera, or that check for LENS_FACING_BACK, will not open an
EXTERNAL camera -- so on a tablet whose only camera is a webcam, a large part
of the camera-using software simply does not see it. This ships that HAL with
the lens constant changed to BACK. A device with both a front and a rear camera
does not want this package; a device with one camera has to pick, because
EXTERNAL satisfies neither requirement.

The second file removes every advertised mode above 1280x720 from the external
camera configuration. The HAL selects the largest mode offered, and above 720p
its frame conversion fails outright: the camera LED lights and the preview
stays black. Capping the advertised list is what makes a preview appear. Note
the consequence -- a camera capable of 1080p will be limited to 720p while this
package is installed.

Neither file is useful without waydroid-ext-camera-gbm, which is what makes
camera frames arrive at all, so that package is required rather than suggested."

# <mode> <path in the overlay> <payload in this repo> [stock sha256 it replaces]
# derive <mode> <path> <image> <path in image> <stock sha256> <result sha256> <patches>
#
# The HAL is a DERIVE row, so this package ships no vendor binary at all: the
# bytes are taken out of the user's own vendor.img at reconcile time, checked
# against the stock hash, patched, checked again. A one-byte patch of Waydroid's
# own binary is still a redistribution of that binary and it is not ours to make
# (docs/54-no-vendored-binaries.md) -- and every user who can run this package
# already has the input in their images directory.
#
# The XML is different and stays a plain row: it is text produced by deleting
# lines from the stock file, which is ours to ship. It records the stock hash as
# a bare sha256 rather than naming a copy of the file, so the tripwire costs the
# repository nothing to keep.
#
# 0644 for the HAL: it is a library loaded by the camera provider, not a service
# binary that init execs.
FILES="
derive 0644 vendor/lib/camera.device@3.4-external-impl.so vendor /lib/camera.device@3.4-external-impl.so 95b1b3e4ff6d17ce7cd56086626b6cbc0db7c70fd49760b57414f8128c91dd69 7028e057f21fb7b7cbb3e4cfce88a29f7ff35a3304107f4c1d1849193343a017 2c061:02:01
0644 vendor/etc/external_camera_config.xml artifacts/overlay/vendor/etc/external_camera_config.xml dd6d27649154f485cdc7294f99dd9c97132c4d378900d5ac349ad11693ddea1d
"
