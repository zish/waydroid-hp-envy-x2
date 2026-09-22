#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Stage one overlay component's payload for waydroid-overlay-sync.
#
# Reads the component's file table on stdin, one row per file:
#
#     <mode> <path relative to the overlay> <file in this repo> [stock file in this repo]
#
# The fourth column is optional and is the STOCK file this entry shadows -- the
# copy of what Waydroid's own image ships at that path. It is not staged; its
# sha256 is recorded in the manifest as a comment so that
# `waydroid-overlay-sync --check-upstream` can tell when an image upgrade has
# changed a file we are silently replacing. Rows with no fourth column add a new
# file rather than replacing one, and have no upstream to drift from.
# See docs/47-package-split.md.
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

mkdir -p "$stage/manifests"

{
	echo "# waydroid overlay component: $COMP"
	echo "# staged from bigtab01-waydroid $commit by packaging/stage-overlay.sh"
	echo "# <mode> <sha256> <path relative to /var/lib/waydroid/overlay>"
	echo "# '# stock <sha256> <path>' records the image file this component replaces."
} >"$manifest.new"

n=0
while read -r mode rel from stock; do
	case "$mode" in '' | \#*) continue ;; esac
	[ -f "$repo/$from" ] || { echo "missing payload: $repo/$from" >&2; exit 1; }

	install -D -m "$mode" "$repo/$from" "$stage/$COMP/$rel"
	sha=$(sha256sum "$repo/$from" | cut -d' ' -f1)
	printf '%s %s %s\n' "$mode" "$sha" "$rel" >>"$manifest.new"

	if [ -n "${stock:-}" ]; then
		[ -f "$repo/$stock" ] || { echo "missing stock copy: $repo/$stock" >&2; exit 1; }
		ssha=$(sha256sum "$repo/$stock" | cut -d' ' -f1)
		printf '# stock %s %s\n' "$ssha" "$rel" >>"$manifest.new"
	fi
	n=$((n + 1))
done

mv -f "$manifest.new" "$manifest"
echo "staged $COMP ($n files)"

[ -n "$DESTDIR" ] && exit 0

command -v restorecon >/dev/null 2>&1 && restorecon -R "$stage" 2>/dev/null || true
cat <<EOM

Staged, but NOT yet in the overlay. Reconcile with:
  waydroid-overlay-sync --verify     # what would change
  waydroid-overlay-sync              # change it
EOM
