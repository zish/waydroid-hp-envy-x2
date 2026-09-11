#!/usr/bin/env bash
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build this repository's RPMs. Runs on the dev box, like every other build here.
#
# Usage:
#   packaging/build-rpms.sh                      # all four packages, source build
#   packaging/build-rpms.sh --prebuilt           # ... daemons from build/ binaries
#   packaging/build-rpms.sh --srpm               # source RPMs only
#   packaging/build-rpms.sh waydroid-overlay     # just one
#
# WHICH OF THESE CAN BE BUILT WHERE
#
# waydroid-bigtab01 and waydroid-overlay are noarch shell, Python, XML and
# prebuilt Android payload: they build anywhere rpmbuild runs, including on this
# Debian dev box. waydroid-sensord and waydroid-wifid compile C++ against
# libgbinder-devel and libglibutil-devel, which are Fedora packages -- a real
# source build needs a Fedora machine or mock. --prebuilt is the way round that
# on this box: it packages the binaries wifi/build.sh and sensors/build.sh
# already produced and deploy today. See packaging/README.md.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
TOP="${TOP:-$repo/build/rpm}"
DIST="${DIST:-.fc44}"

ALL_SPECS="waydroid-bigtab01 waydroid-sensord waydroid-wifid waydroid-overlay"
PREBUILT=0
SRPM_ONLY=0
specs=""

while [ $# -gt 0 ]; do
	case "$1" in
	--prebuilt) PREBUILT=1; shift ;;
	--srpm)     SRPM_ONLY=1; shift ;;
	-h|--help)  sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*)         echo "unknown argument: $1" >&2; exit 2 ;;
	*)          specs="$specs $1"; shift ;;
	esac
done
[ -n "$specs" ] || specs="$ALL_SPECS"

command -v rpmbuild >/dev/null 2>&1 || {
	echo "rpmbuild not found. On this Debian dev box: sudo apt-get install -y rpm" >&2
	exit 1
}

VERSION=$(awk '/^Version:/ { print $2; exit }' "$here/waydroid-bigtab01.spec")
PREFIX="waydroid-bigtab01-$VERSION"

mkdir -p "$TOP"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}

# ------------------------------------------------------------------- tarball
#
# From the working tree, not from HEAD: packaging is usually being edited when
# it is being built, and a tarball of HEAD would silently build the last commit
# instead of what is on disk. Tracked files plus untracked-but-not-ignored ones
# is exactly `git status` s view of "the tree", which is the honest thing to ship.

stage="$TOP/stage/$PREFIX"
rm -rf "$TOP/stage"
mkdir -p "$stage"

echo "== staging $PREFIX from the working tree"
git -C "$repo" ls-files -co --exclude-standard -z |
	tar -C "$repo" --null -T - -cf - | tar -C "$stage" -xf -

if [ "$PREBUILT" = 1 ]; then
	mkdir -p "$stage/prebuilt"
	for b in build/sensors/waydroid-sensord build/wifi/daemon/waydroid-wifid; do
		if [ -x "$repo/$b" ]; then
			cp -p "$repo/$b" "$stage/prebuilt/"
			echo "   prebuilt: $b"
		else
			echo "   MISSING:  $repo/$b -- build it first" >&2
			exit 1
		fi
	done
fi

tar -C "$TOP/stage" -czf "$TOP/SOURCES/$PREFIX.tar.gz" "$PREFIX"
echo "   $TOP/SOURCES/$PREFIX.tar.gz ($(du -h "$TOP/SOURCES/$PREFIX.tar.gz" | cut -f1))"

# ------------------------------------------------------------------- rpmbuild

defines=(--define "_topdir $TOP" --define "dist $DIST")
if [ "$PREBUILT" = 1 ]; then
	defines+=(--with prebuilt)
	# No source to make debuginfo from, and no build-id links wanted for a
	# binary this spec did not compile.
	defines+=(--define "debug_package %{nil}" --define "_build_id_links none")
fi

mode=-ba
[ "$SRPM_ONLY" = 1 ] && mode=-bs

rc=0
for s in $specs; do
	spec="$here/$s.spec"
	[ -f "$spec" ] || { echo "no such spec: $spec" >&2; rc=1; continue; }
	echo
	echo "== rpmbuild $mode $s"
	if rpmbuild "$mode" "${defines[@]}" "$spec"; then
		:
	else
		echo "== FAILED: $s" >&2
		rc=1
	fi
done

echo
echo "== built"
find "$TOP/RPMS" "$TOP/SRPMS" -name '*.rpm' -newermt '-10 minutes' 2>/dev/null |
	sort | sed 's/^/   /'
exit "$rc"
