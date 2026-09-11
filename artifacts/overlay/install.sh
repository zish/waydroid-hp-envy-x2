#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stage Waydroid overlay components for waydroid-overlay-sync. Run on the host,
# as root, or with DESTDIR set as the RPM's %install step.
#
# This installs payload, NOT the live overlay. Files land in
# $PREFIX/share/waydroid-overlay/<component>/ with a manifest beside them, and
# waydroid-overlay-sync copies them into /var/lib/waydroid/overlay -- see the
# header of artifacts/overlay-manager/waydroid-overlay-sync for why the two
# steps are separate.
#
# THE TABLE BELOW IS THE ONLY PLACE THE OVERLAY LAYOUT IS WRITTEN DOWN.
#
# Each row is "<mode> <path inside the overlay> <file in this repository>". The
# repository copies are the same bytes that are running on bigtab01 today: every
# one of the twelve was compared by sha256 against /var/lib/waydroid/overlay on
# 2026-09-09 and matched. Where a source file has variants (.orig/.front/.back)
# the row names the one that is deployed, which is the point of the exercise --
# artifacts/camera holds three builds and only one of them is the fix.
#
# Usage:
#   sh artifacts/overlay/install.sh                    # stage every component
#   sh artifacts/overlay/install.sh camera wifi        # stage some
#   sh artifacts/overlay/install.sh --list             # show the table
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
src=$(dirname "$0")
repo=$(cd "$src/../.." && pwd)

ALL_COMPONENTS="camera battery wifi widevine brightness"

# --------------------------------------------------------------------- table

component_files() {
	case "$1" in
	camera)
		# docs/08-camera-fixed.md -- the minigbm wrapper rebuilt with the NDK, both
		# ABIs, plus docs/11's LENS_FACING_BACK build of the external camera HAL.
		cat <<-TABLE
		0644 vendor/lib64/libgbm_mesa_wrapper.so artifacts/phase2/libgbm_mesa_wrapper-fixed-64.so
		0644 vendor/lib/libgbm_mesa_wrapper.so artifacts/phase2/libgbm_mesa_wrapper-fixed-32.so
		0644 vendor/lib/camera.device@3.4-external-impl.so artifacts/camera/camera.device@3.4-external-impl.so.back
		0644 vendor/etc/external_camera_config.xml artifacts/overlay/vendor/etc/external_camera_config.xml
		TABLE
		;;
	battery)
		# docs/10-battery-fixed.md -- three bytes patched out of
		# healthd_board_battery_update(), which otherwise overwrites every field
		# the host reported with hardcoded fakes.
		cat <<-TABLE
		0755 vendor/bin/hw/android.hardware.health@2.0-service.waydroid artifacts/health/android.hardware.health@2.0-service.waydroid
		TABLE
		;;
	wifi)
		# docs/31, docs/34 -- the feature XML that wakes the dormant framework, the
		# .rc that stops the guest wificond racing the host daemon for the service
		# name, and the supplicant HAL manifest entry.
		cat <<-TABLE
		0644 system/etc/permissions/android.hardware.wifi.xml artifacts/overlay/system/etc/permissions/android.hardware.wifi.xml
		0644 system/etc/init/wificond.rc artifacts/overlay/system/etc/init/wificond.rc
		0644 vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml artifacts/overlay/vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml
		TABLE
		;;
	brightness)
		# docs/37-brightness.md -- the guest light HAL is a stub that discards
		# every call, and it would take ILight/default back from waydroid-sensord
		# because it registers after us. This neuters it.
		cat <<-TABLE
		0644 vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc artifacts/overlay/vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc
		TABLE
		;;
	widevine)
		# docs/21-netflix-widevine.md -- the L3 CDM and its lazy HAL service.
		cat <<-TABLE
		0644 vendor/lib64/libwvaidl.so artifacts/widevine/vendor/lib64/libwvaidl.so
		0755 vendor/bin/hw/android.hardware.drm-service-lazy.widevine artifacts/widevine/vendor/bin/hw/android.hardware.drm-service-lazy.widevine
		0644 vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc artifacts/widevine/vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc
		0644 vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml artifacts/widevine/vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml
		TABLE
		;;
	*)
		echo "unknown component: $1 (known: $ALL_COMPONENTS)" >&2
		exit 2
		;;
	esac
}

# ---------------------------------------------------------------------- stage

if [ "${1:-}" = "--list" ]; then
	for c in $ALL_COMPONENTS; do
		echo "== $c"
		component_files "$c" | while read -r mode rel from; do
			printf '   %s  %-70s <- %s\n' "$mode" "$rel" "$from"
		done
	done
	exit 0
fi

components=${*:-$ALL_COMPONENTS}
stage="$DESTDIR$PREFIX/share/waydroid-overlay"
commit=$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo unknown)

mkdir -p "$stage/manifests"

for comp in $components; do
	manifest="$stage/manifests/$comp.manifest"
	{
		echo "# waydroid overlay component: $comp"
		echo "# staged from bigtab01-waydroid $commit by artifacts/overlay/install.sh"
		echo "# <mode> <sha256> <path relative to /var/lib/waydroid/overlay>"
	} >"$manifest.new"

	component_files "$comp" | while read -r mode rel from; do
		[ -n "$mode" ] || continue
		if [ ! -f "$repo/$from" ]; then
			echo "missing payload: $repo/$from" >&2
			exit 1
		fi
		install -D -m "$mode" "$repo/$from" "$stage/$comp/$rel"
		sha=$(sha256sum "$repo/$from" | cut -d' ' -f1)
		printf '%s %s %s\n' "$mode" "$sha" "$rel" >>"$manifest.new"
	done

	mv -f "$manifest.new" "$manifest"
	echo "staged $comp ($(grep -vc '^#' "$manifest") files)"
done

if [ -n "$DESTDIR" ]; then exit 0; fi

if command -v restorecon >/dev/null 2>&1; then
	restorecon -R "$PREFIX/share/waydroid-overlay" 2>/dev/null || true
fi

cat <<EOM

Staged, but NOT yet in the overlay. Reconcile with:
  waydroid-overlay-sync --verify     # what would change
  waydroid-overlay-sync              # change it
EOM
