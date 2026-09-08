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
#   wifi/build.sh --install --unit
#                              # ... and install/enable the systemd unit, which
#                              # is what makes the daemon survive a reboot
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
DO_UNIT=0
while [ $# -gt 0 ]; do
	case "$1" in
	--deps) DO_DEPS=1; shift ;;
	--check) DO_CHECK=1; shift ;;
	--install) DO_INSTALL=1; DO_CHECK=1; shift ;;
	--unit) DO_UNIT=1; DO_INSTALL=1; DO_CHECK=1; shift ;;
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

SRCS=(NativeScanResult.cpp NmBackend.cpp Supplicant.cpp Wificond.cpp service.cpp)
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
fi

# --------------------------------------------------------------------- unit
#
# Separate from --install because replacing the binary is a routine part of
# developing and installing the unit is not: --install on its own leaves
# whatever start method is already in use alone, so an iteration cycle cannot
# accidentally enable a service on the host or restart one that is being
# watched.  --unit is the deliberate act.
#
# The conf file is installed only if it is not already there, because it is the
# one file on the host an operator is expected to edit -- overwriting somebody's
# --device with the adapter this repo happens to know about is exactly the
# failure the fatal-on-missing-device rule exists to prevent.

if [ "$DO_UNIT" = 1 ]; then
	echo
	echo "== installing the systemd unit on $HOST"
	scp -q "$repo/artifacts/wifi/waydroid-wifid.service" \
	       "$repo/artifacts/wifi/waydroid-wifid.conf" \
	       "$repo/artifacts/wifi/waydroid-wifi-nudge" \
	       "$repo/artifacts/wifi/waydroid-wifi-sync" \
	       "$repo/artifacts/wifi/waydroid-wifi-sync.service" \
	       "$repo/artifacts/wifi/waydroid-wifi-sync.timer" \
	       "$repo/artifacts/wifi/waydroid-wifi-share.conf" "$HOST:/tmp/"
	ssh "$HOST" 'set -e
	    sudo install -m 0644 -o root -g root \
	        /tmp/waydroid-wifid.service /etc/systemd/system/waydroid-wifid.service
	    sudo install -m 0755 -o root -g root \
	        /tmp/waydroid-wifi-nudge /usr/local/bin/waydroid-wifi-nudge
	    sudo install -m 0755 -o root -g root \
	        /tmp/waydroid-wifi-sync /usr/local/bin/waydroid-wifi-sync
	    sudo install -m 0644 -o root -g root \
	        /tmp/waydroid-wifi-sync.service \
	        /etc/systemd/system/waydroid-wifi-sync.service
	    sudo install -m 0644 -o root -g root \
	        /tmp/waydroid-wifi-sync.timer \
	        /etc/systemd/system/waydroid-wifi-sync.timer
	    # 0600: this file names the networks whose passphrases get copied into
	    # the container, so it is the audit trail for that and not world-readable.
	    if [ -e /etc/waydroid-wifi-share.conf ]; then
	        echo "keeping the existing /etc/waydroid-wifi-share.conf:"
	        grep -v "^#" /etc/waydroid-wifi-share.conf | grep . ||
	            echo "  (nothing opted in)"
	    else
	        sudo install -m 0600 -o root -g root \
	            /tmp/waydroid-wifi-share.conf /etc/waydroid-wifi-share.conf
	        echo "installed /etc/waydroid-wifi-share.conf (nothing opted in yet)"
	    fi
	    if [ -e /etc/waydroid-wifid.conf ]; then
	        echo "keeping the existing /etc/waydroid-wifid.conf:"
	        grep -v "^#" /etc/waydroid-wifid.conf | grep . || true
	    else
	        sudo install -m 0644 -o root -g root \
	            /tmp/waydroid-wifid.conf /etc/waydroid-wifid.conf
	        echo "installed /etc/waydroid-wifid.conf"
	    fi
	    rm -f /tmp/waydroid-wifid.service /tmp/waydroid-wifid.conf \
	          /tmp/waydroid-wifi-nudge /tmp/waydroid-wifi-sync \
	          /tmp/waydroid-wifi-sync.service /tmp/waydroid-wifi-sync.timer \
	          /tmp/waydroid-wifi-share.conf
	    sudo systemctl daemon-reload
	    sudo systemctl enable waydroid-wifid.service
	    sudo systemctl restart waydroid-wifid.service
	    # The timer, not the service: the sync runs on a schedule, and starting
	    # it here would fire a reconciliation before anyone has opted anything in.
	    sudo systemctl enable --now waydroid-wifi-sync.timer
	    sleep 2
	    systemctl --no-pager --full status waydroid-wifid.service || true'
	echo
	echo "Started under systemd.  Follow it with:"
	echo "    ssh $HOST journalctl -u waydroid-wifid -f"
elif [ "$DO_INSTALL" = 1 ]; then
	echo
	echo "Binary only -- the start method on the host is untouched.  Pass"
	echo "--unit to install and enable waydroid-wifid.service, which is what"
	echo "makes the daemon survive a reboot; if the unit is already installed,"
	echo "  ssh $HOST sudo systemctl restart waydroid-wifid"
	echo "picks this binary up."
fi
