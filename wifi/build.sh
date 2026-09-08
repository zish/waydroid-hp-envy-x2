#!/usr/bin/env bash
#
# Build waydroid-wifid for bigtab01 -- a host-side Linux daemon that serves
# Android's Wi-Fi native interfaces over binder, driving NetworkManager on the
# host instead of a radio the container cannot see.
#
# WHY A HOST DAEMON, AND WHY IT REPLACES WIFICOND
#
# wlp1s0 is this machine's only network interface, so handing phy0 to the
# container costs the host its network while saving almost none of the software
# work (docs/28-wifi-feasibility.md).  The alternative -- virt_wifi -- creates
# the netdev inside the container but pins its wiphy to init_net, and stock
# virt_wifi never sets WIPHY_FLAG_NETNS_OK, so "iw phy set netns" is refused
# with -EOPNOTSUPP and wificond reports "No wiphy is found".  Rather than carry
# an out-of-tree kernel module on a host that updates kernels often, we replace
# wificond in userspace and the wiphy stops mattering: wlan0 only has to be a
# netdev.  That decision is docs/29-wifi-plan.md, "Path U".
#
# The transport is the same one waydroid-sensord uses and the same one Waydroid
# itself uses for IPlatform/IUserMonitor/IClipboard: lxc/waydroid/config_nodes
# bind-mounts /dev/binder from the host into the container, so a host process
# can register services in the guest's binder domain.  Android 13 is API 33,
# which means the aidl3 protocol on both the service manager and the RPC header
# -- waydroid cached exactly that in /var/lib/waydroid/waydroid.cfg.
#
# BUILD POLICY
#
# Builds run on the dev box, never on bigtab01 (8 GB RAM, immutable OS).  We
# compile against headers from the upstream tags matching the host's installed
# libraries, and link against .so files copied off the host, so the ABI cannot
# drift.  libstdc++ and libgcc are linked statically, leaving glibc, glib/gio
# and libgbinder as the only runtime dependencies -- all already on bigtab01 as
# Waydroid's own dependencies.
#
# Usage:
#   wifi/build.sh              # build
#   wifi/build.sh --deps       # fetch/refresh headers and host .so files
#   wifi/build.sh --check      # build, then report runtime deps vs the host
#   wifi/build.sh --install    # build, then install to bigtab01 (needs sudo there)
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
OUT="${OUT:-$repo/build/wifi/daemon}"

GBINDER_TAG=1.1.47      # must match libgbinder on the host
GLIBUTIL_TAG=1.0.82     # must match libglibutil on the host

DO_DEPS=0
DO_CHECK=0
DO_INSTALL=0
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
#
# Shared with sensors/build.sh when that tree is already populated -- same tags,
# same host .so files, no reason to fetch twice.

SHARED="$repo/build/sensors"

if [ "$DO_DEPS" = 1 ] || [ ! -d "$OUT/libgbinder" ]; then
	if [ "$DO_DEPS" != 1 ] && [ -d "$SHARED/libgbinder" ] && [ -d "$SHARED/libglibutil" ]; then
		echo "== reusing libgbinder/libglibutil checkouts from $SHARED"
		ln -sfn "$SHARED/libgbinder" "$OUT/libgbinder"
		ln -sfn "$SHARED/libglibutil" "$OUT/libglibutil"
	else
		echo "== fetching libgbinder $GBINDER_TAG and libglibutil $GLIBUTIL_TAG"
		rm -rf "$OUT/libgbinder" "$OUT/libglibutil"
		git clone -q --depth 1 --branch "$GLIBUTIL_TAG" \
			https://github.com/sailfishos/libglibutil.git "$OUT/libglibutil"
		git clone -q --depth 1 --branch "$GBINDER_TAG" \
			https://github.com/mer-hybris/libgbinder.git "$OUT/libgbinder"
	fi
fi

if [ "$DO_DEPS" = 1 ] || [ ! -e "$OUT/sysroot/lib/libgbinder.so" ]; then
	mkdir -p "$OUT/sysroot/lib"
	if [ "$DO_DEPS" != 1 ] && [ -e "$SHARED/sysroot/lib/libgbinder.so.$GBINDER_TAG" ]; then
		echo "== reusing host .so files from $SHARED"
		cp -a "$SHARED/sysroot/lib/." "$OUT/sysroot/lib/"
	else
		echo "== copying libgbinder/libglibutil .so off $HOST (guarantees ABI match)"
		scp -q "$HOST:/usr/lib64/libgbinder.so.$GBINDER_TAG" \
		       "$HOST:/usr/lib64/libglibutil.so.$GLIBUTIL_TAG" "$OUT/sysroot/lib/"
	fi
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
	-I"$here"
	-I"$OUT/libgbinder/include"
	-I"$OUT/libglibutil/include"
)
# shellcheck disable=SC2206
CXXFLAGS+=($GLIB_CFLAGS)

LDFLAGS=(
	-L"$OUT/sysroot/lib"
	-Wl,--gc-sections
	-static-libstdc++ -static-libgcc
)

SRCS=(NativeScanResult.cpp NmBackend.cpp Wificond.cpp service.cpp)
OBJS=()

echo "== compiling"
for s in "${SRCS[@]}"; do
	o="$OUT/${s%.cpp}.o"
	echo "   $s"
	g++ "${CXXFLAGS[@]}" -c "$here/$s" -o "$o"
	OBJS+=("$o")
done

echo "== linking"
# shellcheck disable=SC2206
g++ "${OBJS[@]}" -o "$OUT/waydroid-wifid" "${LDFLAGS[@]}" \
	-lgbinder -lglibutil $GLIB_LIBS -lpthread

echo "== built $OUT/waydroid-wifid"
ls -l "$OUT/waydroid-wifid"

# ----------------------------------------------------------------- ABI check

if [ "$DO_CHECK" = 1 ]; then
	echo
	echo "== runtime dependencies"
	readelf -d "$OUT/waydroid-wifid" | grep NEEDED

	echo
	echo "== highest symbol versions required (must exist on the host)"
	readelf -V "$OUT/waydroid-wifid" 2>/dev/null |
		grep -oE 'GLIBC_[0-9.]+[0-9]|GLIBCXX_[0-9.]+[0-9]' | sort -uV | tail -5

	echo
	echo "== host check"
	ssh "$HOST" 'ldd --version | head -1;
	             for l in libgbinder.so.1 libglibutil.so.1 libglib-2.0.so.0 \
	                      libgio-2.0.so.0 libgobject-2.0.so.0; do
	                 p=$(ls /usr/lib64/$l 2>/dev/null || echo MISSING)
	                 echo "  $l -> $p"
	             done'
fi

# ------------------------------------------------------------------- install

if [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "== installing to $HOST:/usr/local/bin/waydroid-wifid"
	# /usr/local is a symlink to /var/usrlocal on this rpm-ostree host, so this
	# needs no layering and no reboot.
	scp -q "$OUT/waydroid-wifid" "$HOST:/tmp/waydroid-wifid.new"
	ssh "$HOST" 'sudo install -m 0755 -o root -g root \
	                 /tmp/waydroid-wifid.new /usr/local/bin/waydroid-wifid &&
	             rm -f /tmp/waydroid-wifid.new &&
	             ls -l /usr/local/bin/waydroid-wifid'
	echo
	echo "Unlike waydroid-sensord, the name waydroid-wifid means nothing to"
	echo "Waydroid -- nothing starts it automatically.  Start it by hand, or"
	echo "install the unit once Stage 5 packages one."
fi
