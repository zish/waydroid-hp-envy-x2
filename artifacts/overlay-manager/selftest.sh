#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# selftest.sh -- waydroid-overlay-sync's derive rows, end to end, offline.
#
#     sh artifacts/overlay-manager/selftest.sh
#
# Rows written the way a .mod writes them go through packaging/stage-overlay.sh,
# which validates them and writes the component manifest, and that manifest goes
# through waydroid-overlay-sync, which extracts, checks, edits, checks and
# installs. Nothing is real but the two scripts: the overlay, the state
# directory and the images are temp directories, and debugfs is a stub that
# serves files out of "<image>.d/" -- the one piece that needs e2fsprogs and an
# ext4 image, neither of which a build root or the dev box can be assumed to
# have. Needs no root.
#
# Every expected result is built here with printf and hashed independently, so
# the edits are judged by bytes this test spelled out, not by the code under
# test. Covers the one-byte replacement every derive row has used since 1.1.0,
# the insertion added in 1.2.0 for waydroid-ext-strongbox's manifest, the order
# rule that makes stock offsets safe (highest first; a replacement before an
# insertion at the same offset), both refusals, --verify, convergence, and the
# validation stage-overlay.sh does at build time.
set -eu

here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
SYNC="$here/waydroid-overlay-sync"
STAGE="$repo/packaging/stage-overlay.sh"

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT INT TERM
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  [PASS] $*"; }
no() { fail=$((fail + 1)); echo "  [FAIL] $*"; }

# --- the stand-in image ------------------------------------------------------
mkdir -p "$t/images/vendor.img.d/etc" "$t/bin" "$t/var/lib/waydroid"
: >"$t/images/vendor.img"
printf 'line1\nline2\nline3\n' >"$t/images/vendor.img.d/etc/test.txt"
STOCK=$(sha256sum "$t/images/vendor.img.d/etc/test.txt" | cut -d' ' -f1)

# debugfs -R "dump <path in image> <out>" <image>; counts its calls, so the
# converged run can be shown not to open the image at all.
cat >"$t/bin/debugfs" <<'EOF'
#!/bin/sh
echo x >>"${DEBUGFS_LOG:?}"
[ "$1" = -R ] || exit 1
set -- $2 "$3"
[ "$1" = dump ] || exit 1
cp "$4.d$2" "$3" 2>/dev/null
exit 0
EOF
chmod +x "$t/bin/debugfs"

sha() { printf "$1" | sha256sum | cut -d' ' -f1; }

# Edit offsets are hex, into the 18-byte stock 'line1\nline2\nline3\n': "6" is
# where line2 starts, and "12" is 0x12 = 18, the end of the file.
R_SWAP=$(sha 'Line1\nline2\nline3\n')
R_INS=$(sha 'line1\ninserted\nline2\nline3\ntail\n')
R_TIE=$(sha 'line1\nX\nLine2\nline3\n')
R_HEAD=$(sha 'head\nline1\nline2\nline3\n')
BOGUS=0000000000000000000000000000000000000000000000000000000000000000

stage_rows() {
	COMP=$1 DESTDIR="$t/root" PREFIX=/usr STAGEDIR=/usr/lib/waydroid-overlay \
		sh "$STAGE" >/dev/null
}

sync() {
	DEBUGFS_LOG="$t/debugfs.log" PATH="$t/bin:$PATH" \
	STAGE_DIRS="$t/root/usr/lib/waydroid-overlay" \
	OVERLAY_DIR="$t/var/lib/waydroid/overlay" STATE_DIR="$t/state" \
	WAYDROID_CFG="$t/no-cfg" RW_DIR="$t/no-rw" IMAGES_DIR="$t/images" \
		sh "$SYNC" "$@"
}

hash_of() { sha256sum "$t/var/lib/waydroid/overlay/$1" 2>/dev/null | cut -d' ' -f1; }

echo "== stage-overlay.sh: what a .mod may say"
stage_rows good <<EOF
derive 0644 vendor/etc/swap.txt  vendor /etc/test.txt $STOCK $R_SWAP 0:6c:4c
derive 0644 vendor/etc/ins.txt   vendor /etc/test.txt $STOCK $R_INS  6+696e7365727465640a,12+7461696c0a
derive 0644 vendor/etc/tie.txt   vendor /etc/test.txt $STOCK $R_TIE  6+580a,6:6c:4c
derive 0644 vendor/etc/head.txt  vendor /etc/test.txt $STOCK $R_HEAD 0+686561640a
EOF
ok "replacements, insertions and a mix are accepted"

for bad in '6+abc' '6+zz' '6+' 'g+0a' '6:6c:4' '6:6c:zz'; do
	if stage_rows bad 2>/dev/null <<EOF
derive 0644 vendor/etc/x.txt vendor /etc/test.txt $STOCK $R_SWAP $bad
EOF
	then no "stage-overlay.sh accepted the bad edit '$bad'"
	else ok "stage-overlay.sh refuses the bad edit '$bad'"
	fi
done
rm -f "$t/root/usr/lib/waydroid-overlay/manifests/bad.manifest"

echo "== waydroid-overlay-sync: deriving"
: >"$t/debugfs.log"
if sync --quiet >"$t/out" 2>&1; then ok "reconcile succeeds"; else no "reconcile failed:"; cat "$t/out"; fi
[ "$(hash_of vendor/etc/swap.txt)" = "$R_SWAP" ] && ok "a one-byte replacement, as since 1.1.0" || no "replacement produced $(hash_of vendor/etc/swap.txt)"
[ "$(hash_of vendor/etc/ins.txt)" = "$R_INS" ] && ok "two insertions, mid-file and at the end, both at stock offsets" || no "insertion produced $(hash_of vendor/etc/ins.txt)"
[ "$(hash_of vendor/etc/tie.txt)" = "$R_TIE" ] && ok "a replacement and an insertion at one offset: the byte is replaced, the insertion lands before it" || no "tie produced $(hash_of vendor/etc/tie.txt)"
[ "$(hash_of vendor/etc/head.txt)" = "$R_HEAD" ] && ok "an insertion at offset 0" || no "offset-0 insertion produced $(hash_of vendor/etc/head.txt)"
[ "$(stat -c %a "$t/var/lib/waydroid/overlay/vendor/etc/ins.txt" 2>/dev/null)" = 644 ] && ok "installed with the row's mode" || no "wrong mode"

if sync --verify >"$t/out" 2>&1 && grep -q 'overlay matches' "$t/out"; then
	ok "--verify agrees"
else
	no "--verify disagrees:"; cat "$t/out"
fi
: >"$t/debugfs.log"
sync --quiet >/dev/null 2>&1 || true
[ ! -s "$t/debugfs.log" ] && ok "a converged overlay opens no image" || no "a converged run extracted $(wc -l <"$t/debugfs.log") file(s)"

echo "== waydroid-overlay-sync: refusing"
rm -rf "$t/root" "$t/var/lib/waydroid/overlay" "$t/state"
stage_rows moved <<EOF
derive 0644 vendor/etc/moved.txt vendor /etc/test.txt $BOGUS $R_INS 6+696e7365727465640a,12+7461696c0a
EOF
if sync --quiet >"$t/out" 2>&1; then no "a moved stock file was not refused"; else
	grep -q 'has changed under it' "$t/out" && ok "a stock hash that moved is refused, and says so" || { no "refused, but not for the stock hash:"; cat "$t/out"; }
fi
[ ! -e "$t/var/lib/waydroid/overlay/vendor/etc/moved.txt" ] && ok "and nothing is installed" || no "a refused row installed a file"

rm -rf "$t/root" "$t/var/lib/waydroid/overlay" "$t/state"
stage_rows wrong <<EOF
derive 0644 vendor/etc/wrong.txt vendor /etc/test.txt $STOCK $R_INS 6+696e7365727465640a
EOF
if sync --quiet >"$t/out" 2>&1; then no "a wrong result was not refused"; else
	grep -q 'got the wrong result' "$t/out" && ok "an edit that does not produce the result hash is refused" || { no "refused, but not for the result:"; cat "$t/out"; }
fi
[ ! -e "$t/var/lib/waydroid/overlay/vendor/etc/wrong.txt" ] && ok "and nothing is installed" || no "a wrong result was installed"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
