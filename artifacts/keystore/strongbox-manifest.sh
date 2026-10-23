#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# strongbox-manifest.sh -- derive the vendor VINTF manifest that declares a
# second keymaster@4.0 instance, "strongbox", from the image's own manifest.
#
#   strongbox-manifest.sh [--image VENDOR_IMG] [--out FILE]
#
# keystore2 only engages a strongbox the device manifest declares, and a
# manifest *fragment* re-declaring android.hardware.keymaster@4.0 conflicts with
# the vendor manifest and breaks boot (docs/73). So the whole
# /vendor/etc/vintf/manifest.xml is overridden, with "strongbox" added as a
# second <instance> and <fqname> inside the existing keymaster <hal>.
#
# That file is the image's, so per AGENTS.md it is derived on the machine rather
# than committed: extracted from vendor.img with debugfs (unprivileged, no loop
# mount), checked against the stock hash, edited, and checked against the result
# hash. A stock hash that has moved means the image changed under us, and the
# script refuses rather than guess -- the same rule waydroid-overlay-sync's
# derive rows follow. It is an insertion, not a byte swap, which is why it is a
# script and not yet a derive row (docs/73).
#
# The result hash is the stage-3a override that keystore2 bound on 2026-10-22,
# reproduced byte for byte.
set -eu

STOCK_SHA=0695403b549a7902442641adc6bc821d6787319174464bce0330b122ab16c7cc
RESULT_SHA=3f2a8b70cce41e6d5b2bb1e6e11ef6c09169f4b5e3b4a0b042c0dc40feb0fc86

img=/etc/waydroid-extra/images/vendor.img
out=-
while [ $# -gt 0 ]; do
	case "$1" in
	--image) img=$2; shift 2 ;;
	--out) out=$2; shift 2 ;;
	*) echo "usage: $0 [--image VENDOR_IMG] [--out FILE]" >&2; exit 2 ;;
	esac
done

command -v debugfs >/dev/null 2>&1 || { echo "debugfs not found (e2fsprogs)" >&2; exit 2; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM

debugfs -R "dump /etc/vintf/manifest.xml $tmp/stock.xml" "$img" >/dev/null 2>&1 || true
[ -s "$tmp/stock.xml" ] || { echo "could not extract /etc/vintf/manifest.xml from $img" >&2; exit 3; }
got=$(sha256sum "$tmp/stock.xml" | cut -d' ' -f1)
if [ "$got" != "$STOCK_SHA" ]; then
	echo "refusing: $img's manifest is $got, expected $STOCK_SHA" >&2
	echo "the image has changed; re-derive the edit before trusting it" >&2
	exit 3
fi

# Inside the keymaster <hal> only, repeat the default instance and fqname lines
# as strongbox ones, keeping their indentation.
awk '
	/<name>android\.hardware\.keymaster<\/name>/ { inkm = 1 }
	{ print }
	inkm && /<instance>default<\/instance>/ {
		line = $0; sub(/default/, "strongbox", line); print line; n++
	}
	inkm && /<fqname>@4\.0::IKeymasterDevice\/default<\/fqname>/ {
		line = $0; sub(/\/default/, "/strongbox", line); print line; n++
	}
	/<\/hal>/ { inkm = 0 }
	END { if (n != 2) exit 4 }
' "$tmp/stock.xml" > "$tmp/out.xml" || { echo "keymaster <hal> not as expected" >&2; exit 3; }

got=$(sha256sum "$tmp/out.xml" | cut -d' ' -f1)
if [ "$got" != "$RESULT_SHA" ]; then
	echo "refusing: derived manifest is $got, expected $RESULT_SHA" >&2
	exit 3
fi

if [ "$out" = - ]; then cat "$tmp/out.xml"; else cp "$tmp/out.xml" "$out"; fi
