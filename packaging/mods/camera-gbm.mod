# waydroid-ext-camera-gbm -- docs/08-camera-fixed.md
#
# Waydroid's minigbm gbm_mesa wrapper imported the external camera's fallback
# buffer with a width of 0, so the map returned NULL and the HAL got an all-zero
# plane layout: every preview frame was black. Rebuilt with the NDK, no AOSP
# tree. Nothing about this is HP Envy x2 specific -- it is a bug in Waydroid's
# own wrapper and it reaches any host with a UVC camera.

VERSION=1.0.0
RELEASE=1
KIND=overlay

# x86_64 and x86 Android ELF. NOT noarch: a noarch package would install
# happily on an aarch64 host and break Android there instead of on the shelf.
ARCH=x86_64

SUMMARY="Waydroid minigbm wrapper rebuilt so camera buffer imports get a real width"

# minigbm is Apache-2.0 (AOSP external/minigbm, via waydroid/android_external_minigbm);
# Mesa's gbm, statically linked into the rebuilt wrapper, is MIT.
LICENSE="Apache-2.0 AND MIT"

REQUIRES="waydroid-ext-overlay-sync"

DOCS="docs/user/overlay.md docs/user/lxc-config.md docs/08-camera-fixed.md docs/09-upstream-report.md"

DESCRIPTION="The gbm_mesa wrapper that Waydroid's minigbm loads, rebuilt so that importing
a buffer whose size minigbm has not filled in yet no longer produces a
zero-width mapping.

minigbm fills meta.total_size in only after calling the backend's bo_import
hook, so the wrapper saw 0 and mapped nothing; the camera HAL then reported an
all-zero plane layout and every preview frame was black. Reported upstream as
waydroid/android_external_minigbm#3.

Both ABIs are shipped: the 64-bit wrapper for the camera HAL and the 32-bit one
for apps that open the camera through the 32-bit path."

# <mode> <path in the overlay> <payload in this repo> [stock file it replaces]
#
# The fourth column is what makes `waydroid-overlay-sync --check-upstream`
# possible: it is the copy of the file Waydroid's own image ships at that path,
# so an image upgrade that changes it can be noticed instead of silently
# reverted. Both rows here REPLACE a stock file. See docs/47-package-split.md.
FILES="
0644 vendor/lib64/libgbm_mesa_wrapper.so artifacts/phase2/libgbm_mesa_wrapper-fixed-64.so artifacts/lib/libgbm_mesa_wrapper.so
0644 vendor/lib/libgbm_mesa_wrapper.so   artifacts/phase2/libgbm_mesa_wrapper-fixed-32.so artifacts/lib/libgbm_mesa_wrapper-32.so
"
