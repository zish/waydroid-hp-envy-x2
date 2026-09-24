# waydroid-ext-camera -- the camera feature, as one thing a user can ask for.
#
# A group is convenience and nothing else. The hard edges stay on the individual
# packages: waydroid-ext-wifi-hostd requires waydroid-ext-wifid on its own
# account, because installing it alone leaves Android with a Wi-Fi framework and
# no wificond behind it. Nothing should become installable-but-broken just
# because somebody picked the packages by hand instead of taking the group.

VERSION=1.0.1
RELEASE=1
KIND=group
ARCH=noarch

SUMMARY="Everything needed for a working camera in Waydroid"

# waydroid-ext-uvc-autosuspend was here and is deliberately gone (2026-09-24).
# The rule it would have shipped pins this project's reference webcam out of USB
# runtime suspend, and docs/12 closes by measuring that suspend and resume cost
# nothing and corrupt nothing: 150 frames off a suspended device, zero errors,
# zero sequence gaps. It was installed and withdrawn the same session, it fixed
# nothing it was suspected of fixing, and it is keyed to one vendor:product
# pair. A group that required it would make every camera user install a
# machine-specific rule that solves no problem.
REQUIRES="waydroid-ext-camera-gbm
waydroid-ext-camera-hal"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/08-camera-fixed.md docs/11-camera-facing.md docs/12-v4l2-frame-errors.md"

DESCRIPTION="Installs the camera fixes as one unit: the rebuilt minigbm wrapper that
makes preview frames arrive at all, the external camera HAL patched to
report LENS_FACING_BACK so that apps needing a rear camera will open it,
together with the resolution cap that keeps the HAL out of the frame
conversion it fails.

This package contains no files of its own."
