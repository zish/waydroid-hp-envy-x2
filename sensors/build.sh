#!/usr/bin/env bash
#
# Build waydroid-sensord for bigtab01 -- a host-side Linux daemon that serves
# Android's android.hardware.sensors@1.0::ISensors over hwbinder, reading the
# ITE8350 sensor hub through Linux IIO sysfs.
#
# WHY A HOST DAEMON RATHER THAN A GUEST HAL
#
# Waydroid's images ship /vendor/bin/hw/android.hardware.sensors@1.0-service.waydroid,
# a 10 KB stub whose entire main() is:
#
#     if (!property_get_bool("waydroid.stub_sensors_hal", false)) return 0;
#     configureRpcThreadpool(1, true);
#     ISensors::registerAsService("default");        // an empty sensor list
#
# and tools/helpers/images.py:152 sets that property only when waydroid-sensord
# is NOT on PATH:
#
#     if which("waydroid-sensord") is None:
#         props.append("waydroid.stub_sensors_hal=1")
#
# So dropping this binary onto PATH is self-installing: waydroid stops setting
# the property, the guest stub then returns at its first line, and
# container_manager.py starts this daemon instead. No overlay files, no image
# changes, no prop edits. /dev/hwbinder is bind-mounted into the container
# (lxc/waydroid/config_nodes), so host and guest share one hwbinder domain.
#
# WHAT IS UPSTREAM AND WHAT IS OURS
#
# service.cpp, Sensors.cpp and hybrisbindertypes.h come from
# droidian/waydroid-sensors (GPL-3.0). Its libgbinder ISensors server is
# correct and worth keeping -- sizeof(sensor_t) == 112 there matches the 0x70
# element stride in the shipped stub's own disassembly.
#
# What we replace is its *data source*. Upstream reads sensorfw, Sailfish's
# Qt/D-Bus sensor daemon, which is not packaged for Fedora and would cost a
# layered rpm-ostree install plus a reboot. SensorIIO.{h,cpp} reads
# /sys/bus/iio/devices directly instead, which drops Qt, D-Bus and sensorfw and
# leaves only glib + libgbinder -- both already on bigtab01 as Waydroid's own
# dependencies (libgbinder-1.1.47, libglibutil-1.0.82).
#
# WHY THE LIGHTS HAL IS IN A BINARY CALLED "SENSORD"
#
# Because the name is the install hook, and nothing else is. container_manager.py
# starts exactly one host daemon, gated on a literal name:
#
#     if which("waydroid-sensord"):
#         ... run ["waydroid-sensord", "/dev/" + args.HWBINDER_DRIVER]
#
# Riding that buys three things a separate waydroid-lightd would have to earn
# back. It needs no systemd unit, and therefore cannot repeat the trap that cost
# Wi-Fi Stage 5 a day: a systemd-started bin_t binary runs as
# unconfined_service_t, and container_runtime_t is denied binder { transfer } to
# it under a dontaudit rule, so the failure is invisible in ausearch. Spawned
# from container_manager.py we inherit waydroid_t, which already works -- the
# same reason service.cpp's lock file lives where it does. It runs as root, so
# the backlight is a plain sysfs write rather than a logind session call. And
# ILight is hwbinder/hidl exactly like ISensors, so it is one more local object
# on the connection this process already holds.
#
# The cost is a misleading binary name. That is cheaper than the alternative.
# Lights are kept in their own translation units (Backlight.cpp, Lights.cpp) so
# the two halves stay separable if the hook ever changes.
#
# BUILD POLICY
#
# Builds run on the dev box, never on bigtab01 (8 GB RAM, immutable OS). We
# link against headers from the exact upstream tags matching the host's
# installed libraries, and against .so files copied off the host, so the ABI
# cannot drift. libstdc++ and libgcc are linked statically so the only runtime
# dependencies are glibc, glib and libgbinder.
#
# Usage:
#   sensors/build.sh              # build
#   sensors/build.sh --deps       # fetch/refresh headers and host .so files
#   sensors/build.sh --check      # build, then report runtime deps vs the host
#   sensors/build.sh --install    # build, then install to bigtab01 (needs sudo there)
#
# Env: HOST=<ip>  OUT=<dir>
set -euo pipefail

HOST="${HOST:-10.42.0.137}"

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"
OUT="${OUT:-$repo/build/sensors}"

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

SRCS=(SensorIIO.cpp Sensors.cpp Backlight.cpp Lights.cpp service.cpp)
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
g++ "${OBJS[@]}" -o "$OUT/waydroid-sensord" "${LDFLAGS[@]}" \
	-lgbinder -lglibutil $GLIB_LIBS -lpthread -lm

echo "== built $OUT/waydroid-sensord"
ls -l "$OUT/waydroid-sensord"

# ----------------------------------------------------------------- ABI check

if [ "$DO_CHECK" = 1 ]; then
	echo
	echo "== runtime dependencies"
	readelf -d "$OUT/waydroid-sensord" | grep NEEDED

	echo
	echo "== highest symbol versions required (must exist on the host)"
	need="$(readelf -V "$OUT/waydroid-sensord" 2>/dev/null |
		grep -oE 'GLIBC_[0-9.]+[0-9]|GLIBCXX_[0-9.]+[0-9]' | sort -uV | tail -5)"
	echo "$need"

	echo
	echo "== host check"
	# Every DT_NEEDED must resolve on bigtab01, and the host's glibc must be at
	# least as new as the one we built against. Building on Debian 13 (older)
	# for Fedora 44 (newer) is the safe direction, but verify rather than assume.
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
	echo "== installing to $HOST:/usr/local/bin/waydroid-sensord"
	# /usr/local is a symlink to /var/usrlocal on this rpm-ostree host, so this
	# needs no layering and no reboot, and /usr/local/bin is on root's PATH --
	# which is what container_manager.py's which() searches.
	scp -q "$OUT/waydroid-sensord" "$HOST:/tmp/waydroid-sensord.new"
	ssh "$HOST" 'sudo install -m 0755 -o root -g root \
	                 /tmp/waydroid-sensord.new /usr/local/bin/waydroid-sensord &&
	             rm -f /tmp/waydroid-sensord.new &&
	             echo "installed:" && ls -l /usr/local/bin/waydroid-sensord &&
	             command -v waydroid-sensord'
	echo
	echo "Now restart the session so waydroid.prop is regenerated without"
	echo "waydroid.stub_sensors_hal=1:"
	echo "    waydroid session stop && waydroid session start"
	echo
	echo "For the ILight half, the guest stub must also be neutered, or it will"
	echo "take the \"default\" name after us -- we start before lxc-start does:"
	echo "    artifacts/overlay/install.sh   (then restart waydroid-container)"
fi
