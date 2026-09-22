# waydroid-ext-camera -- the camera feature, as one thing a user can ask for.
#
# A group is convenience and nothing else. The hard edges stay on the individual
# packages: waydroid-ext-wifi-hostd requires waydroid-ext-wifid on its own
# account, because installing it alone leaves Android with a Wi-Fi framework and
# no wificond behind it. Nothing should become installable-but-broken just
# because somebody picked the packages by hand instead of taking the group.

VERSION=1.0.0
RELEASE=1
KIND=group
ARCH=noarch

SUMMARY="Everything needed for a working camera in Waydroid"

REQUIRES="waydroid-ext-camera-gbm
waydroid-ext-camera-hal
waydroid-ext-uvc-autosuspend"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/08-camera-fixed.md docs/11-camera-facing.md docs/12-v4l2-frame-errors.md"

DESCRIPTION="Installs the camera fixes as one unit: the rebuilt minigbm wrapper that
makes preview frames arrive at all, the external camera HAL rebuilt to
report LENS_FACING_BACK so that apps needing a rear camera will open it,
and the udev rule that keeps a UVC device out of autosuspend.

This package contains no files of its own."
