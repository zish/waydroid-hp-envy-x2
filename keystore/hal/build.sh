#!/usr/bin/env bash
#
# Build waydroid-keystored -- a host-side HIDL
# android.hardware.keymaster@4.0::IKeymasterDevice served over hwbinder via
# libgbinder, registered as the "strongbox" instance, backed by the stage-1 TPM
# keyblob engine (keystore/). docs/65 stage 3, docs/73.
#
# Same build model as sensors/build.sh: builds on the dev box, never on bigtab01.
# Headers come from the exact upstream tags matching the host's installed
# libraries; the .so files are copied off the host so the ABI cannot drift;
# libstdc++/libgcc are linked statically so the only runtime deps are glibc,
# glib and libgbinder -- all already on bigtab01 as Waydroid's own deps.
#
#   keystore/hal/build.sh            # build the daemon and km-bench
#   keystore/hal/build.sh --deps     # (re)fetch gbinder/glibutil headers + host .so
#   keystore/hal/build.sh --check    # build, then report runtime deps vs the host
#   keystore/hal/build.sh --install  # build, then install to bigtab01 (sudo there)
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
OUT="${OUT:-$repo/build/keystore-hal}"

GBINDER_TAG=1.1.47      # must match libgbinder on the host
GLIBUTIL_TAG=1.0.82     # must match libglibutil on the host

DO_DEPS=0; DO_CHECK=0; DO_INSTALL=0
while [ $# -gt 0 ]; do
	case "$1" in
	--deps) DO_DEPS=1; shift ;;
	--check) DO_CHECK=1; shift ;;
	--install) DO_INSTALL=1; DO_CHECK=1; shift ;;
	*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
done

mkdir -p "$OUT"

# ---------------------------------------------------------------- dependencies
if [ "$DO_DEPS" = 1 ] || [ ! -d "$OUT/libgbinder" ]; then
	echo "== fetching libgbinder $GBINDER_TAG and libglibutil $GLIBUTIL_TAG"
	rm -rf "$OUT/libgbinder" "$OUT/libglibutil"
	git clone -q --depth 1 --branch "$GLIBUTIL_TAG" \
		https://github.com/sailfishos/libglibutil.git "$OUT/libglibutil"
	git clone -q --depth 1 --branch "$GBINDER_TAG" \
		https://github.com/mer-hybris/libgbinder.git "$OUT/libgbinder"
fi
if [ "$DO_DEPS" = 1 ] || [ ! -e "$OUT/sysroot/lib/libgbinder.so" ]; then
	echo "== copying libgbinder/libglibutil .so off $HOST (guarantees ABI match)"
	mkdir -p "$OUT/sysroot/lib"
	scp -q "$HOST:/usr/lib64/libgbinder.so.$GBINDER_TAG" \
	       "$HOST:/usr/lib64/libglibutil.so.$GLIBUTIL_TAG" "$OUT/sysroot/lib/"
	ln -sf "libgbinder.so.$GBINDER_TAG"   "$OUT/sysroot/lib/libgbinder.so"
	ln -sf "libglibutil.so.$GLIBUTIL_TAG" "$OUT/sysroot/lib/libglibutil.so"
fi
for f in "$OUT/libgbinder/include/gbinder.h" \
         "$OUT/libglibutil/include/gutil_log.h" \
         "$OUT/sysroot/lib/libgbinder.so"; do
	[ -e "$f" ] || { echo "missing $f -- run with --deps" >&2; exit 1; }
done

# --------------------------------------------------------------------- compile
GLIB_CFLAGS="$(pkg-config --cflags glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0)"
GLIB_LIBS="$(pkg-config --libs glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0)"

CXXFLAGS=(
	-O2 -g -Wall -Wextra -Wno-unused-parameter
	-std=gnu++17 -pthread
	-ffunction-sections -fdata-sections
	-I"$here" -I"$here/.."
	-I"$OUT/libgbinder/include" -I"$OUT/libglibutil/include"
)
# shellcheck disable=SC2206
CXXFLAGS+=($GLIB_CFLAGS)
LDFLAGS=( -L"$OUT/sysroot/lib" -Wl,--gc-sections -static-libstdc++ -static-libgcc )

# service.cpp needs gbinder/glib; the engine TUs are plain C++17.
SRCS=( "$here/service.cpp" "$here/../km_blob.cpp" "$here/../tools_backend.cpp"
       "$here/../engine.cpp" "$here/../soft_crypto.cpp" )
OBJS=()
echo "== compiling"
for s in "${SRCS[@]}"; do
	o="$OUT/$(basename "${s%.cpp}").o"
	echo "   $(basename "$s")"
	g++ "${CXXFLAGS[@]}" -c "$s" -o "$o"
	OBJS+=("$o")
done

echo "== linking"
# shellcheck disable=SC2206
g++ "${OBJS[@]}" -o "$OUT/waydroid-keystored" "${LDFLAGS[@]}" \
	-lgbinder -lglibutil $GLIB_LIBS -lpthread -lm
echo "== built $OUT/waydroid-keystored"
ls -l "$OUT/waydroid-keystored"

# km-bench: the host-side binder client that drives a second, bench-only
# instance of the daemon (see kmbench.cpp). Built alongside, never installed.
g++ "${CXXFLAGS[@]}" -c "$here/kmbench.cpp" -o "$OUT/kmbench.o"
# shellcheck disable=SC2206
g++ "$OUT/kmbench.o" "$OUT/km_blob.o" "$OUT/soft_crypto.o" -o "$OUT/km-bench" \
	"${LDFLAGS[@]}" -lgbinder -lglibutil $GLIB_LIBS -lpthread
echo "== built $OUT/km-bench"

if [ "$DO_CHECK" = 1 ]; then
	echo; echo "== runtime dependencies"
	readelf -d "$OUT/waydroid-keystored" | grep NEEDED
	echo; echo "== host check"
	ssh "$HOST" 'for l in libgbinder.so.1 libglibutil.so.1 libglib-2.0.so.0 \
	                      libgio-2.0.so.0 libgobject-2.0.so.0; do
	                 p=$(ls /usr/lib64/$l 2>/dev/null || echo MISSING); echo "  $l -> $p"
	             done'
fi

if [ "$DO_INSTALL" = 1 ]; then
	echo; echo "== installing to $HOST:/usr/local/bin/waydroid-keystored"
	scp -q "$OUT/waydroid-keystored" "$HOST:/tmp/waydroid-keystored.new"
	ssh "$HOST" 'sudo install -m 0755 -o root -g root \
	                 /tmp/waydroid-keystored.new /usr/local/bin/waydroid-keystored &&
	             rm -f /tmp/waydroid-keystored.new &&
	             ls -l /usr/local/bin/waydroid-keystored'
fi
