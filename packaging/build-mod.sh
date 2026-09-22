#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Build one modification's RPM: its own tarball, its generated spec, rpmbuild.
#
# WHY A TARBALL PER MODIFICATION
#
# The unit of release is the modification (docs/47-package-split.md), so an SRPM
# must contain that modification and nothing else. One shared tarball would put
# 100 MB of Android payload and somebody else's proprietary blob into every
# source package, and would make every SRPM change whenever anything changed --
# which is the churn this split exists to stop.
#
# The file list is DERIVED for overlay components, from the same FILES table the
# %install step consumes, so a payload file can never be in the spec but missing
# from the tarball. Other kinds declare SOURCES explicitly.
#
# Usage:
#   packaging/build-mod.sh camera-gbm            # tarball, spec, rpmbuild -ba
#   packaging/build-mod.sh --srpm camera-gbm     # source package only
#   packaging/build-mod.sh --lint camera-gbm     # ... and run rpmlint on the result
#   packaging/build-mod.sh --all                 # every mod in packaging/mods
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
TOP="${TOP:-$repo/build/rpm}"
MODDIR="$here/mods"

SRPM_ONLY=0
LINT=0
mods=""

while [ $# -gt 0 ]; do
	case "$1" in
	--srpm) SRPM_ONLY=1; shift ;;
	--lint) LINT=1; shift ;;
	--all)  for m in "$MODDIR"/*.mod; do mods="$mods $(basename "$m" .mod)"; done; shift ;;
	-h|--help) sed -n '19,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) echo "unknown argument: $1" >&2; exit 2 ;;
	*)  mods="$mods $1"; shift ;;
	esac
done
[ -n "$mods" ] || { echo "usage: $0 [--srpm] [--lint] <mod>... | --all" >&2; exit 2; }

command -v rpmbuild >/dev/null 2>&1 || {
	echo "rpmbuild not found. On a Debian dev box: sudo apt-get install -y rpm" >&2
	exit 1
}

mkdir -p "$TOP"/SOURCES "$TOP"/SPECS "$TOP"/BUILD "$TOP"/BUILDROOT "$TOP"/RPMS "$TOP"/SRPMS

# systemd-rpm-macros is a Fedora package and this box is Debian, so %{_unitdir}
# and %{_userunitdir} are undefined here and would land in %files as literal
# text. Define them to the values systemd-rpm-macros would, only when missing --
# on a Fedora builder the real macros win and this is inert.
# Built as positional parameters, not as a string: `rpm --define` takes
# "name body" as ONE argument, and a shell-split string gives it an empty body.
set -- --define "_topdir $TOP"
if ! rpm --eval '%{_unitdir}' | grep -q '^/'; then
	set -- "$@" --define "_unitdir /usr/lib/systemd/system" \
	            --define "_userunitdir /usr/lib/systemd/user" \
	            --define "_udevrulesdir /usr/lib/udev/rules.d"
	echo "note: systemd-rpm-macros absent, defining unit/udev dirs locally"
fi

for mod in $mods; do
	modfile="$MODDIR/$mod.mod"
	[ -f "$modfile" ] || { echo "no such modification: $mod" >&2; exit 1; }

	NAME=$mod VERSION=0.0.0 KIND=host FILES="" SOURCES="" DOCS=""
	# shellcheck disable=SC1090
	. "$modfile"

	pkg="waydroid-ext-$NAME"
	prefix="$pkg-$VERSION"
	stage="$TOP/stage/$prefix"

	# ------------------------------------------------------- the file list
	list=$(mktemp)
	trap 'rm -f "$list"' EXIT INT TERM
	echo "LICENSE" >"$list"
	for d in $DOCS; do echo "$d" >>"$list"; done

	case "$KIND" in
	overlay)
		echo "packaging/stage-overlay.sh" >>"$list"
		printf '%s\n' "$FILES" | while read -r mode rel from stock; do
			case "$mode" in '' | \#*) continue ;; esac
			echo "$from"
			[ -n "${stock:-}" ] && echo "$stock"
		done >>"$list" ;;
	group)
		: ;;
	*)
		[ -n "$SOURCES" ] || { echo "$mod: KIND=$KIND needs SOURCES=" >&2; exit 1; }
		for f in $SOURCES; do echo "$f" >>"$list"; done ;;
	esac

	# ----------------------------------------------------------- the tarball
	rm -rf "$stage"
	mkdir -p "$stage"
	sort -u "$list" | while read -r f; do
		[ -n "$f" ] || continue
		[ -e "$repo/$f" ] || { echo "$mod: $f does not exist" >&2; exit 1; }
		if [ -d "$repo/$f" ]; then
			mkdir -p "$stage/$f"
			(cd "$repo" && tar -cf - "$f") | tar -C "$stage" --strip-components=0 -xf -
		else
			install -D -m "$(stat -c %a "$repo/$f")" "$repo/$f" "$stage/$f"
		fi
	done
	tar -C "$TOP/stage" -czf "$TOP/SOURCES/$prefix.tar.gz" "$prefix"
	echo "== $pkg: tarball $(du -h "$TOP/SOURCES/$prefix.tar.gz" | cut -f1), $(sort -u "$list" | grep -c .) source paths"

	# -------------------------------------------------------------- rpmbuild
	"$here/gen-spec.sh" -o "$TOP/SPECS" "$mod" >/dev/null
	spec="$TOP/SPECS/$pkg.spec"

	[ "$SRPM_ONLY" = 1 ] && mode=-bs || mode=-ba
	rpmbuild "$mode" "$@" "$spec"

	if [ "$LINT" = 1 ] && command -v rpmlint >/dev/null 2>&1; then
		echo "== $pkg: rpmlint"
		find "$TOP/RPMS" "$TOP/SRPMS" -name "$pkg-$VERSION-*.rpm" \
			-exec rpmlint --ignore-unused-rpmlintrc \
			     -r "$here/waydroid-ext.rpmlintrc" {} + || true
	fi

	rm -f "$list"
	trap - EXIT INT TERM
done

echo
echo "built into $TOP/RPMS and $TOP/SRPMS"
