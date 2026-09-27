#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stage one overlay component's payload for waydroid-overlay-sync.
#
# Reads the component's file table on stdin. There are three kinds of row and
# the kind is decided by the first field:
#
#     <mode> <path relative to the overlay> <file in this repo> [stock]
#     derive <mode> <path in the overlay> <image> <path in image> <stock sha256> <result sha256> <patch list>
#     link   <path in the overlay> <symlink target>
#
# A PLAIN ROW ships bytes: the file is copied into the staging tree and its
# sha256 recorded. The optional fourth column is the STOCK file this entry
# shadows -- what Waydroid's own image carries at that path -- and it may be
# either a file in this repo or, preferably, the bare sha256 itself. Only the
# hash is ever recorded, so naming the hash directly means the repository does
# not have to carry a copy of somebody else's binary to have a tripwire against
# it (docs/54-no-vendored-binaries.md). Rows with no fourth column add a new
# file rather than replacing one, and have no upstream to drift from.
#
# A DERIVE ROW ships no bytes at all. It records where the file lives inside
# the user's own Waydroid image, what that file must hash to, what the patched
# result must hash to, and the byte edits between them. waydroid-overlay-sync
# extracts, verifies, patches, verifies again and installs. This exists because
# a one-byte patch of a vendor binary is still a redistribution of that vendor
# binary, and every user who can run these packages already has the input on
# their own disk. The patch list is <hex offset>:<old>:<new>, comma-separated.
#
# A LINK ROW ships a symlink. It carries no mode -- a symlink's own mode is
# meaningless on Linux -- and no hash, because there are no contents to hash.
#
# The table itself lives in packaging/mods/<name>.mod, which is the single place
# a modification's payload is described. This script only knows the mechanics.
#
# Usage:
#     COMP=camera-gbm sh packaging/stage-overlay.sh < table
#     DESTDIR=%{buildroot} PREFIX=/usr COMP=... sh packaging/stage-overlay.sh < table
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
COMP=${COMP:?COMP must be set to the component name}
repo=$(cd "$(dirname "$0")/.." && pwd)

# /usr/lib, not /usr/share: most components carry Android ELF and /usr/share is
# for architecture-independent data. Overridable so the superseded
# artifacts/overlay/install.sh layout can still be produced.
STAGEDIR=${STAGEDIR:-$PREFIX/lib/waydroid-overlay}
stage="$DESTDIR$STAGEDIR"
manifest="$stage/manifests/$COMP.manifest"
commit=$(cd "$repo" && git rev-parse --short HEAD 2>/dev/null || echo unknown)

# A component whose every row is derived or linked stages no payload, but the
# generated %files still lists the component directory, so it has to exist.
mkdir -p "$stage/manifests" "$stage/$COMP"

is_sha256() {
	[ "${#1}" -eq 64 ] || return 1
	case "$1" in *[!0-9a-f]*) return 1 ;; esac
	return 0
}

die() { echo "$COMP: $*" >&2; exit 1; }

{
	echo "# waydroid overlay component: $COMP"
	echo "# staged from bigtab01-waydroid $commit by packaging/stage-overlay.sh"
	echo "#"
	echo "# <mode> <sha256> <path relative to /var/lib/waydroid/overlay>"
	echo "# derive <mode> <image> <path in image> <stock sha256> <result sha256> <patches> <path>"
	echo "# link <target> <path>"
	echo "# '# stock <sha256> <path>' records the image file this component replaces."
} >"$manifest.new"

n=0
while IFS= read -r row; do
	case "$row" in '' | \#*) continue ;; esac
	# Word splitting is the parse here: overlay paths are Android paths and
	# contain no spaces. Every row type keeps the overlay path last, which is
	# what lets waydroid-overlay-sync recover it as the tail of the line.
	# shellcheck disable=SC2086
	set -- $row

	case "$1" in
	derive)
		[ $# -eq 8 ] || die "derive row needs 8 fields, got $#: $row"
		mode=$2 rel=$3 image=$4 inimg=$5 stock=$6 result=$7 patch=$8
		is_sha256 "$stock" || die "derive row stock hash is not a sha256: $stock"
		is_sha256 "$result" || die "derive row result hash is not a sha256: $result"
		case "$image" in system | vendor) ;; *) die "derive row image must be system or vendor, got $image" ;; esac
		case "$inimg" in /*) ;; *) die "derive row path in image must be absolute: $inimg" ;; esac
		# Validate the patch list here rather than at reconcile time, where it
		# would fail on the user's machine at boot instead of in our build.
		# Split with IFS in this shell and not through a pipe, because die() in
		# a pipeline exits the subshell and the bad row ships anyway.
		oldifs=$IFS
		IFS=,
		for p in $patch; do
			IFS=$oldifs
			[ -n "$p" ] || continue
			off=${p%%:*}
			rest=${p#*:}
			old=${rest%%:*}
			new=${rest#*:}
			case "$off" in '' | *[!0-9a-fA-F]*) die "bad patch offset: $p" ;; esac
			[ "${#old}" -eq 2 ] && [ "${#new}" -eq 2 ] || die "patch bytes must be two hex digits: $p"
			case "$old$new" in *[!0-9a-fA-F]*) die "patch bytes must be hex: $p" ;; esac
			IFS=,
		done
		IFS=$oldifs
		printf 'derive %s %s %s %s %s %s %s\n' \
			"$mode" "$image" "$inimg" "$stock" "$result" "$patch" "$rel" >>"$manifest.new"
		printf '# stock %s %s\n' "$stock" "$rel" >>"$manifest.new"
		;;
	link)
		[ $# -eq 3 ] || die "link row needs 3 fields, got $#: $row"
		rel=$2 target=$3
		# A relative target, always. An absolute one would resolve against the
		# host's / at reconcile time and against Android's / at run time, and
		# those are not the same filesystem.
		case "$target" in /*) die "link target must be relative to the link, got $target" ;; esac
		printf 'link %s %s\n' "$target" "$rel" >>"$manifest.new"
		;;
	*)
		[ $# -ge 3 ] || die "file row needs at least 3 fields: $row"
		mode=$1 rel=$2 from=$3 stock=${4:-}
		[ -f "$repo/$from" ] || die "missing payload: $repo/$from"

		install -D -m "$mode" "$repo/$from" "$stage/$COMP/$rel"
		sha=$(sha256sum "$repo/$from" | cut -d' ' -f1)
		printf '%s %s %s\n' "$mode" "$sha" "$rel" >>"$manifest.new"

		if [ -n "$stock" ]; then
			if is_sha256 "$stock"; then
				ssha=$stock
			else
				[ -f "$repo/$stock" ] || die "missing stock copy: $repo/$stock"
				ssha=$(sha256sum "$repo/$stock" | cut -d' ' -f1)
			fi
			printf '# stock %s %s\n' "$ssha" "$rel" >>"$manifest.new"
		fi
		;;
	esac
	n=$((n + 1))
done

mv -f "$manifest.new" "$manifest"
echo "staged $COMP ($n rows)"

[ -n "$DESTDIR" ] && exit 0

command -v restorecon >/dev/null 2>&1 && restorecon -R "$stage" 2>/dev/null || true
cat <<EOM

Staged, but NOT yet in the overlay. Reconcile with:
  waydroid-overlay-sync --verify     # what would change
  waydroid-overlay-sync              # change it
EOM
