#!/usr/bin/env bash
# Cross-compile the phase 1 GBM probe for Android x86_64 (bionic, API 33 = Android 13).
#
# The Waydroid image's own libraries are built "for Android 33" (readelf on
# /vendor/lib64/libgbm_mesa.so says so), so target the same API level.
#
# Set NDK to an unpacked Android NDK; r27c was used. Only the clang toolchain and
# the x86_64 sysroot are needed -- no AOSP tree.
set -euo pipefail

NDK="${NDK:-$HOME/ndk-dl/android-ndk-r27c}"
CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/x86_64-linux-android33-clang"
here="$(cd "$(dirname "$0")" && pwd)"

[ -x "$CC" ] || { echo "no NDK clang at $CC (set NDK=...)" >&2; exit 1; }

# -static-libstdc++ is irrelevant (pure C); nothing but libc/libdl is linked, so the
# binary runs anywhere in the container without pushing extra libraries.
"$CC" -O1 -Wall -Wextra -o "$here/gbm-android-test" "$here/gbm-android-test.c"
"$CC" -O1 -Wall -Wextra -o "$here/gbm-import-android" "$here/gbm-import-android.c"
echo "built: $here/gbm-android-test $here/gbm-import-android"
file "$here/gbm-android-test" 2>/dev/null || true
