#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Exercise waydroid-overlay-sync's manifest handling against a synthetic overlay
# and a synthetic Waydroid image. Run on the dev box: no sudo, no container, no
# reboot, and bigtab01 is never touched.
#
# WHY A SYNTHETIC IMAGE RATHER THAN THE REAL ONE
#
# The derive row is the interesting case and it reads from the user's own
# system.img/vendor.img, so testing it needs an ext2 image containing a file at a
# known path. mke2fs -d builds one from a directory without privilege, which
# means the whole extract -> verify -> patch -> verify -> install path can be run
# here rather than on the host it will run on. The ORACLE is the patched binary
# this repository already carries: deriving from the stock copy must reproduce it
# byte for byte, and that is the assertion that matters.
#
# WHAT THIS DOES NOT COVER
#
# SELinux relabelling, the container-running warning, and the overlay_rw shadow
# sweep all need a real host. packaging/test-install.sh covers rpm's own file
# handling. This covers the manifest format and the reconciler's decisions.
#
# Usage:
#   bin/overlay-sync-test.sh          run every check
#   bin/overlay-sync-test.sh --keep   leave the scratch tree for inspection
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)
SYNC="$repo/artifacts/overlay-manager/waydroid-overlay-sync"
STAGE_SH="$repo/packaging/stage-overlay.sh"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

pass=0
fail=0
ok()   { printf '  ok   %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail + 1)); }
note() { printf '       %s\n' "$*"; }
head() { printf '\n== %s\n' "$*"; }

for t in mke2fs debugfs sha256sum; do
	command -v "$t" >/dev/null 2>&1 || {
		# debugfs and mke2fs are in /sbin, which is not always on a user PATH.
		for p in /sbin /usr/sbin; do [ -x "$p/$t" ] && PATH="$PATH:$p"; done
	}
done
export PATH
for t in mke2fs debugfs sha256sum; do
	command -v "$t" >/dev/null 2>&1 || { echo "$t not found -- install e2fsprogs" >&2; exit 1; }
done

T=$(mktemp -d)
cleanup() { [ "$KEEP" = 1 ] && echo "kept: $T" || rm -rf "$T"; }
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------- the fixture
#
# The two modifications that become derive rows, with the stock file as the image
# content and the patched file as the oracle.

CAM_REL='vendor/lib/camera.device@3.4-external-impl.so'
CAM_IMG='/lib/camera.device@3.4-external-impl.so'
CAM_STOCK="$repo/artifacts/camera/camera.device@3.4-external-impl.so.orig"
CAM_WANT="$repo/artifacts/camera/camera.device@3.4-external-impl.so.back"
CAM_PATCH='2c061:02:01'

BAT_REL='vendor/bin/hw/android.hardware.health@2.0-service.waydroid'
BAT_IMG='/bin/hw/android.hardware.health@2.0-service.waydroid'
BAT_STOCK="$repo/artifacts/health/android.hardware.health@2.0-service.waydroid.orig"
BAT_WANT="$repo/artifacts/health/android.hardware.health@2.0-service.waydroid"
BAT_PATCH='6720:48:c3,6730:50:31,6731:66:c0,6732:c7:c3,cbd1:09:07'

for f in "$CAM_STOCK" "$CAM_WANT" "$BAT_STOCK" "$BAT_WANT"; do
	[ -f "$f" ] || { echo "fixture input missing: $f" >&2; exit 1; }
done

sha() { sha256sum "$1" | cut -d' ' -f1; }

CAM_STOCK_SHA=$(sha "$CAM_STOCK")
CAM_WANT_SHA=$(sha "$CAM_WANT")
BAT_STOCK_SHA=$(sha "$BAT_STOCK")
BAT_WANT_SHA=$(sha "$BAT_WANT")

head "building the fixture"

mkdir -p "$T/imgsrc/lib" "$T/imgsrc/bin/hw"
cp "$CAM_STOCK" "$T/imgsrc$CAM_IMG"
cp "$BAT_STOCK" "$T/imgsrc$BAT_IMG"
mkdir -p "$T/images"
mke2fs -q -t ext2 -b 1024 -d "$T/imgsrc" "$T/images/vendor.img" 8192 2>/dev/null
[ -f "$T/images/vendor.img" ] && ok "built a $(du -h "$T/images/vendor.img" | cut -f1) ext2 vendor.img" \
	|| bad "mke2fs produced no image"

# A real repo file for the plain-row half of the tests, because
# stage-overlay.sh resolves payload paths against the repository -- which is
# itself worth exercising rather than working around.
PLAIN_SRC='artifacts/dexopt/dexopt.prop'
[ -f "$repo/$PLAIN_SRC" ] || { echo "fixture input missing: $repo/$PLAIN_SRC" >&2; exit 1; }
PLAIN_SHA=$(sha "$repo/$PLAIN_SRC")

mkdir -p "$T/var/lib/waydroid"
cat >"$T/var/lib/waydroid/waydroid.cfg" <<EOF
[waydroid]
mount_overlays = True
images_path = $T/images
EOF

OVERLAY="$T/var/lib/waydroid/overlay"
STATE="$T/var/lib/waydroid-overlay"
STAGE="$T/usr/lib/waydroid-overlay"

run_sync() {
	env STAGE_DIRS="$STAGE" OVERLAY_DIR="$OVERLAY" STATE_DIR="$STATE" \
		WAYDROID_CFG="$T/var/lib/waydroid/waydroid.cfg" RW_DIR="$T/var/lib/waydroid/overlay_rw" \
		sh "$SYNC" "$@"
}

stage_comp() {
	comp=$1
	shift
	printf '%s\n' "$@" | env COMP="$comp" DESTDIR="$T" PREFIX=/usr \
		STAGEDIR=/usr/lib/waydroid-overlay sh "$STAGE_SH" >/dev/null
}

# --------------------------------------------------------------- staging works

head "staging: a derive row, a link row and a plain row"

stage_comp camera-hal \
	"derive 0644 $CAM_REL vendor $CAM_IMG $CAM_STOCK_SHA $CAM_WANT_SHA $CAM_PATCH"
stage_comp battery \
	"derive 0755 $BAT_REL vendor $BAT_IMG $BAT_STOCK_SHA $BAT_WANT_SHA $BAT_PATCH"
stage_comp demo \
	"0644 vendor/etc/plain.txt $PLAIN_SRC" \
	"link vendor/lib64/libprotobuf-cpp-lite.so libprotobuf-cpp-lite-3.9.1.so"

[ -f "$STAGE/manifests/camera-hal.manifest" ] && ok "camera-hal manifest written" || bad "no camera-hal manifest"
grep -q "^derive 0644 vendor $CAM_IMG $CAM_STOCK_SHA $CAM_WANT_SHA $CAM_PATCH $CAM_REL$" \
	"$STAGE/manifests/camera-hal.manifest" && ok "derive row recorded verbatim" || {
	bad "derive row malformed"; sed -n '/^derive/p' "$STAGE/manifests/camera-hal.manifest" | sed 's/^/       /'
}
grep -q "^# stock $CAM_STOCK_SHA $CAM_REL$" "$STAGE/manifests/camera-hal.manifest" &&
	ok "derive row also recorded its stock hash for --check-upstream" || bad "derive row recorded no stock hash"
[ ! -e "$STAGE/camera-hal/$CAM_REL" ] && ok "derive row staged NO payload (the point of it)" \
	|| bad "derive row staged a copy of the vendor binary"
grep -q "^link libprotobuf-cpp-lite-3.9.1.so vendor/lib64/libprotobuf-cpp-lite.so$" \
	"$STAGE/manifests/demo.manifest" && ok "link row recorded" || bad "link row malformed"

head "staging: bad rows are refused at build time, not at boot"

try_stage() {
	if printf '%s\n' "$2" | env COMP=bad DESTDIR="$T/reject" PREFIX=/usr \
		STAGEDIR=/usr/lib/waydroid-overlay sh "$STAGE_SH" >/dev/null 2>&1; then
		bad "$1 was accepted"
	else
		ok "$1 refused"
	fi
}
try_stage "a non-sha256 stock hash"   "derive 0644 vendor/x vendor /x deadbeef $CAM_WANT_SHA 10:00:01"
try_stage "an unknown image name"     "derive 0644 vendor/x boot /x $CAM_STOCK_SHA $CAM_WANT_SHA 10:00:01"
try_stage "a relative in-image path"  "derive 0644 vendor/x vendor x $CAM_STOCK_SHA $CAM_WANT_SHA 10:00:01"
try_stage "a one-digit patch byte"    "derive 0644 vendor/x vendor /x $CAM_STOCK_SHA $CAM_WANT_SHA 10:0:01"
try_stage "a non-hex patch byte"      "derive 0644 vendor/x vendor /x $CAM_STOCK_SHA $CAM_WANT_SHA 10:zz:01"
try_stage "an absolute link target"   "link vendor/x /abs/target"
try_stage "a short derive row"        "derive 0644 vendor/x vendor /x $CAM_STOCK_SHA"

# ------------------------------------------------------------- the derive path

head "reconcile: derive from the image and prove the result byte for byte"

run_sync --quiet || bad "first reconcile exited $?"

if [ -f "$OVERLAY/$CAM_REL" ]; then
	got=$(sha "$OVERLAY/$CAM_REL")
	[ "$got" = "$CAM_WANT_SHA" ] &&
		ok "camera HAL derived from vendor.img is byte-identical to the patched oracle" || {
		bad "camera HAL derived wrongly"; note "want $CAM_WANT_SHA"; note "got  $got"; }
	m=$(stat -c %a "$OVERLAY/$CAM_REL")
	[ "$m" = "644" ] && ok "camera HAL installed 0644" || bad "camera HAL mode is $m, want 644"
else
	bad "camera HAL was not installed at all"
fi

if [ -f "$OVERLAY/$BAT_REL" ]; then
	got=$(sha "$OVERLAY/$BAT_REL")
	[ "$got" = "$BAT_WANT_SHA" ] &&
		ok "health HAL derived from vendor.img is byte-identical to the patched oracle (5 bytes, 3 sites)" || {
		bad "health HAL derived wrongly"; note "want $BAT_WANT_SHA"; note "got  $got"; }
	m=$(stat -c %a "$OVERLAY/$BAT_REL")
	[ "$m" = "755" ] && ok "health HAL installed 0755" || bad "health HAL mode is $m, want 755"
else
	bad "health HAL was not installed at all"
fi

if [ -L "$OVERLAY/vendor/lib64/libprotobuf-cpp-lite.so" ]; then
	t=$(readlink "$OVERLAY/vendor/lib64/libprotobuf-cpp-lite.so")
	[ "$t" = "libprotobuf-cpp-lite-3.9.1.so" ] && ok "link row created the symlink, relative" \
		|| bad "symlink points at $t"
else
	bad "link row created no symlink"
fi

[ -f "$OVERLAY/vendor/etc/plain.txt" ] && ok "plain row still installs (no regression)" \
	|| bad "plain row did not install"

head "reconcile: the second run is a no-op"

out=$(run_sync 2>&1) || bad "second reconcile exited non-zero"
echo "$out" | grep -q "already matches" && ok "second run reports the overlay already matches" || {
	bad "second run did work it did not need to"; echo "$out" | sed 's/^/       /'; }

run_sync --verify >/dev/null 2>&1 && ok "--verify exits 0 on a converged overlay" \
	|| bad "--verify exited $? on a converged overlay"

head "reconcile: a derived file edited behind our back is put back"

printf 'tampered\n' >>"$OVERLAY/$CAM_REL"
run_sync --verify >/dev/null 2>&1 && bad "--verify missed a tampered derived file" \
	|| ok "--verify notices a tampered derived file (exit 3)"
run_sync --quiet >/dev/null 2>&1 || true
[ "$(sha "$OVERLAY/$CAM_REL")" = "$CAM_WANT_SHA" ] && ok "reconcile re-derived it correctly" \
	|| bad "reconcile did not restore the tampered derived file"

# ------------------------------------------------------------- the refusal

head "reconcile: REFUSES when the image has moved under the patch"

mkdir -p "$T/imgsrc2/lib" "$T/imgsrc2/bin/hw"
# One byte different from stock, somewhere the patch list does not touch.
cp "$CAM_STOCK" "$T/imgsrc2$CAM_IMG"
printf '\377' | dd of="$T/imgsrc2$CAM_IMG" bs=1 seek=1024 conv=notrunc 2>/dev/null
cp "$BAT_STOCK" "$T/imgsrc2$BAT_IMG"
mkdir -p "$T/images2"
mke2fs -q -t ext2 -b 1024 -d "$T/imgsrc2" "$T/images2/vendor.img" 8192 2>/dev/null

rm -f "$OVERLAY/$CAM_REL"
out=$(env STAGE_DIRS="$STAGE" OVERLAY_DIR="$OVERLAY" STATE_DIR="$STATE" \
	WAYDROID_CFG="$T/var/lib/waydroid/waydroid.cfg" IMAGES_DIR="$T/images2" \
	sh "$SYNC" 2>&1) && bad "reconcile succeeded against a changed image" \
	|| ok "reconcile exits non-zero against a changed image"
echo "$out" | grep -q "has changed under it" && ok "and says the image changed under the patch" || {
	bad "the refusal did not explain itself"; echo "$out" | sed 's/^/       /'; }
[ ! -f "$OVERLAY/$CAM_REL" ] && ok "and installed nothing rather than something wrong" \
	|| bad "it installed a file derived from an unrecognised image"

# The other row in the same run must still be handled: one bad row does not
# abandon the rest of the overlay.
[ -f "$OVERLAY/$BAT_REL" ] && ok "the row whose image DID match was still installed" \
	|| bad "a single bad row aborted the whole reconcile"

head "--check-upstream"

out=$(run_sync --check-upstream 2>&1) && ok "--check-upstream exits 0 when the image matches" || {
	bad "--check-upstream exited non-zero on a matching image"; echo "$out" | sed 's/^/       /'; }
echo "$out" | grep -q "checked 2 upstream file" && ok "it checked both recorded stock hashes" || {
	bad "wrong number of rows checked"; echo "$out" | sed 's/^/       /'; }

out=$(env STAGE_DIRS="$STAGE" OVERLAY_DIR="$OVERLAY" STATE_DIR="$STATE" \
	WAYDROID_CFG="$T/var/lib/waydroid/waydroid.cfg" IMAGES_DIR="$T/images2" \
	sh "$SYNC" --check-upstream 2>&1) && bad "--check-upstream passed a changed image" \
	|| ok "--check-upstream exits 3 when an image has changed"
echo "$out" | grep -q "^CHANGED: $CAM_REL" && ok "and names the file that changed" || {
	bad "--check-upstream did not name the changed file"; echo "$out" | sed 's/^/       /'; }

# ------------------------------------------------------------------- removal

head "removal: a component that goes away takes its files with it"

rm -f "$STAGE/manifests/demo.manifest"
run_sync --quiet >/dev/null 2>&1 || true
[ ! -e "$OVERLAY/vendor/etc/plain.txt" ] && ok "the plain file was removed" || bad "plain file survived its component"
[ ! -L "$OVERLAY/vendor/lib64/libprotobuf-cpp-lite.so" ] && ok "the symlink was removed" \
	|| bad "symlink survived its component"

head "removal: an edited orphan is reported and kept"

stage_comp demo2 "0644 vendor/etc/plain2.txt $PLAIN_SRC"
run_sync --quiet >/dev/null 2>&1 || true
printf 'somebody was working on this\n' >>"$OVERLAY/vendor/etc/plain2.txt"
rm -f "$STAGE/manifests/demo2.manifest"
out=$(run_sync 2>&1) || true
echo "$out" | grep -q "NOT removing: vendor/etc/plain2.txt" && ok "an edited orphan is kept and reported" \
	|| { bad "edited orphan was not reported"; echo "$out" | sed 's/^/       /'; }
[ -f "$OVERLAY/vendor/etc/plain2.txt" ] && ok "and it is still on disk" || bad "edited orphan was deleted"
grep -q "vendor/etc/plain2.txt" "$STATE/deployed.list" &&
	ok "and it stays in deployed.list so --force still has something to act on" \
	|| bad "the kept orphan was dropped from deployed.list"

head "deployed.list records a symlink as a link, not as a hash"

stage_comp demo3 "link vendor/lib64/liblink.so libreal.so"
run_sync --quiet >/dev/null 2>&1 || true
grep -q "^link:libreal.so vendor/lib64/liblink.so$" "$STATE/deployed.list" &&
	ok "deployed.list carries link:<target>" || {
	bad "symlink recorded wrongly in deployed.list"; grep liblink "$STATE/deployed.list" | sed 's/^/       /'; }

printf '\n== %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
