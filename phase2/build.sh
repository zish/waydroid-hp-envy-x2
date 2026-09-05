#!/usr/bin/env bash
#
# Rebuild /vendor/lib{,64}/libgbm_mesa_wrapper.so with the NDK alone -- no AOSP tree.
#
# Why this is possible: the wrapper is a small, self-contained shim. Its only real
# dependency is libgbm_mesa.so (we keep a copy of each ABI pulled off the device),
# plus liblog and libcutils for two functions that can be stubbed at link time.
#
# The gralloc modules that load it are NOT rebuilt, so the gbm_ops / alloc_args
# ABI must not change. That is why this targets the exact commit the shipped
# binaries fingerprint to, and why the build verifies itself against them.
#
# BOTH ABIs matter. Allocation happens in the 64-bit
# android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa, but the
# import and map that fail happen in the 32-bit
# android.hardware.camera.provider@2.7-external-service -- so the camera fix has
# to land in /vendor/lib, not /vendor/lib64. See docs/08.
#
# Usage:
#   phase2/build.sh [--fix] [--abi 32|64]      (default: --abi 64, no fix)
#
# Env: NDK=<path>  MINIGBM=<path>  OUT=<dir>  COMMIT=<sha>
set -euo pipefail

NDK="${NDK:-$HOME/ndk-dl/android-ndk-r27c}"
MINIGBM="${MINIGBM:-/home/coder/extra_space/minigbm-yuv}"
OUT="${OUT:-/home/coder/extra_space/wrapper-build}"
COMMIT="${COMMIT:-a9367e8}"     # the commit docs/07 fingerprinted both shipped .so files to

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

WANT_FIX=0
DEBUG=0
ABI=64
while [ $# -gt 0 ]; do
	case "$1" in
	--fix) WANT_FIX=1; shift ;;
	--debug) DEBUG=1; shift ;;
	--abi) ABI="$2"; shift 2 ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

case "$ABI" in
64) TRIPLE=x86_64-linux-android33
    SHIPPED="$repo/artifacts/lib/libgbm_mesa_wrapper.so"
    GBM_MESA="$repo/artifacts/lib/android-libgbm_mesa.so" ;;
32) TRIPLE=i686-linux-android33
    SHIPPED="$repo/artifacts/lib/libgbm_mesa_wrapper-32.so"
    GBM_MESA="$repo/artifacts/lib/android-libgbm_mesa-32.so" ;;
*)  echo "--abi must be 32 or 64" >&2; exit 2 ;;
esac

BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
CXX="$BIN/$TRIPLE-clang++"
CC="$BIN/$TRIPLE-clang"
[ -x "$CXX" ] || { echo "no NDK clang++ at $CXX (set NDK=...)" >&2; exit 1; }
[ -d "$MINIGBM/.git" ] || { echo "no minigbm checkout at $MINIGBM (set MINIGBM=...)" >&2; exit 1; }
[ -s "$SHIPPED" ] || { echo "missing shipped reference $SHIPPED" >&2; exit 1; }

out="$OUT/$ABI"
src="$out/src"
mkdir -p "$OUT/include" "$src" "$out/stubs"

# --- 0. the one header neither the NDK nor minigbm provides -------------------
# gbm.h is the public, stable Mesa GBM API. Every symbol the wrapper calls was
# confirmed present in the device's own libgbm_mesa.so (docs/07). drm_fourcc.h is
# vendored in phase2/include as aliases of gbm.h's fourccs.
if [ ! -s "$OUT/include/gbm.h" ]; then
	curl -sSL --max-time 60 -o "$OUT/include/gbm.h" \
		https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/gbm/main/gbm.h
	grep -q gbm_bo_create_with_modifiers2 "$OUT/include/gbm.h" || {
		echo "bad gbm.h download" >&2; rm -f "$OUT/include/gbm.h"; exit 1; }
	echo "fetched: gbm.h"
fi

# --- 1. wrapper sources at the shipped commit --------------------------------
git -C "$MINIGBM" show "$COMMIT:gbm_mesa_driver/gbm_mesa_wrapper.cpp" > "$src/gbm_mesa_wrapper.cpp"
git -C "$MINIGBM" show "$COMMIT:gbm_mesa_driver/gbm_mesa_wrapper.h"   > "$src/gbm_mesa_wrapper.h"

# --- 2. always-applied correctness patch -------------------------------------
# The source at $COMMIT reads `if (addr == NULL)` inside gbm_map(), where `addr`
# is the void** parameter and so is never NULL -- a dead branch. The SHIPPED
# binaries do not behave that way: their guard tests the RETURN VALUE of
# gbm_bo_map (test %rax,%rax at 0x5524 in the 64-bit one). Rebuilding verbatim
# would be a regression, leaving *addr NULL instead of MAP_FAILED, which is what
# minigbm checks for. Restore the shipped behaviour. See docs/07.
perl -0777 -pi -e 's/\tif \(addr == NULL\) \{\n\t\t\*addr = MAP_FAILED;/\tif (*addr == NULL) {\n\t\t*addr = MAP_FAILED;/' "$src/gbm_mesa_wrapper.cpp"
grep -q 'if (\*addr == NULL)' "$src/gbm_mesa_wrapper.cpp" || {
	echo "ERROR: gbm_map null-check patch did not apply" >&2; exit 1; }

# --- 3. optional: the phase 1 geometry fix -----------------------------------
if [ "$WANT_FIX" = 1 ]; then
	patch -s -p0 -d "$src" < "$here/0001-gbm_import-geometry.patch"
	echo "applied: gbm_import geometry fix"
fi

# --- 4. link stubs, so nothing has to be pulled off the device ---------------
"$CC" -shared -fPIC -DSTUB_LOG    -Wl,-soname,liblog.so    -o "$out/stubs/liblog.so"    "$here/stubs/stubs.c"
"$CC" -shared -fPIC -DSTUB_CUTILS -Wl,-soname,libcutils.so -o "$out/stubs/libcutils.so" "$here/stubs/stubs.c"

# --- 5. build ----------------------------------------------------------------
# -static-libstdc++ keeps libc++ inside the .so, so the result does not care
# which libc++ the image ships. No C++ type crosses the gbm_ops boundary -- it is
# a plain C struct of function pointers -- so this is safe. exports.map then
# keeps the dynamic symbol table identical to the shipped one anyway.
"$CXX" -shared -fPIC -O2 -std=gnu++17 \
	-DLOG_TAG='"GBM-MESA-WRAPPER"' -DGBM_MESA_DEBUG=$DEBUG \
	-I"$here/include" -I"$OUT/include" -I"$src" \
	-Wl,-soname,libgbm_mesa_wrapper.so \
	-Wl,--version-script="$here/exports.map" -Wl,--exclude-libs,ALL \
	-o "$out/libgbm_mesa_wrapper.so" \
	"$src/gbm_mesa_wrapper.cpp" "$GBM_MESA" \
	"$out/stubs/liblog.so" "$out/stubs/libcutils.so" \
	-static-libstdc++

echo
echo "built (${ABI}-bit): $out/libgbm_mesa_wrapper.so"
"$BIN/llvm-readelf" -dW "$out/libgbm_mesa_wrapper.so" | grep -E 'NEEDED|SONAME' | sed 's/^/  /'

# --- 6. verify against the shipped binary ------------------------------------
# a) exported interface must be identical -- the gralloc modules dlopen this and
#    call get_gbm_ops(); anything else exported, or missing, is a red flag.
echo "exported symbols:"
diff <("$BIN/llvm-readelf" --dyn-syms -W "$SHIPPED"                    | awk '$5=="GLOBAL"&&$7!="UND"{print $8}' | sort -u) \
     <("$BIN/llvm-readelf" --dyn-syms -W "$out/libgbm_mesa_wrapper.so" | awk '$5=="GLOBAL"&&$7!="UND"{print $8}' | sort -u) \
     && echo "  identical to shipped"

# b) the DRM->GBM format table must match byte-for-byte. This is what proves the
#    vendored drm_fourcc.h aliases are right, rather than merely plausible.
tbl() {
	"$BIN/llvm-objcopy" -O binary --only-section=.rodata "$1" "$out/.rodata.bin" 2>/dev/null
	xxd -p -c1 "$out/.rodata.bin" | tr -d '\n' | grep -oE '5238202052382020.{208}' | head -1
}
echo "format table:"
if [ -n "$(tbl "$SHIPPED")" ] && [ "$(tbl "$SHIPPED")" = "$(tbl "$out/libgbm_mesa_wrapper.so")" ]; then
	echo "  identical to shipped (14 entries)"
else
	echo "  *** DIFFERS from shipped -- check phase2/include/drm_fourcc.h ***"
	echo "    shipped: $(tbl "$SHIPPED")"
	echo "    built:   $(tbl "$out/libgbm_mesa_wrapper.so")"
	exit 1
fi
rm -f "$out/.rodata.bin"

# --- 7. the harness that exercises the result before it is ever installed -----
"$CC" -O1 -Wall -Wextra -I"$src" -o "$out/wrapper-harness" "$here/wrapper-harness.c"
echo "built (${ABI}-bit): $out/wrapper-harness"
