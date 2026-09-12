#!/bin/sh
# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Contain background dexopt. Run on the host, as root, or with DESTDIR set as
# the RPM's %install step.
#
# WHY THIS EXISTS
#
# On 2026-09-12, 46 minutes after a reboot, Play Store's background dexopt job
# took the machine to 91.6% busy across all four CPUs with CPU pressure at
# some avg10=35%, dex2oat32 running "threads: 4" and com.android.vending:background
# at 86% of a core. Nothing contained it, because every cgroup stock Android
# would have used to contain it is missing here: /dev/cpuctl, /dev/cpuset,
# /dev/blkio and /dev/memcg are empty tmpfs stubs, since Android 13's
# cgroups.json asks for cgroup v1 controllers and this host -- like every
# distro since about 2021 -- is cgroup v2 unified. See docs/43-app-freezer.md.
#
# WHY PROPERTIES AND NOT CGROUPS
#
# installd reads six properties and passes them to dex2oat as -j and --cpu-set.
# Verified against this image rather than from memory:
#
#     $ strings /system/bin/installd | grep -E 'dex2oat-(threads|cpu-set)'
#     dalvik.vm.boot-dex2oat-cpu-set     dalvik.vm.boot-dex2oat-threads
#     dalvik.vm.dex2oat-cpu-set          dalvik.vm.dex2oat-threads
#     dalvik.vm.restore-dex2oat-cpu-set  dalvik.vm.restore-dex2oat-threads
#
# and /apex/com.android.art/bin/dex2oat32 carries "--cpu-set=". That flag is a
# sched_setaffinity() call, NOT a cgroup, which is the whole point: it is the
# one lever that still works on a host where Android's cgroup layer is inert.
#
# WHY 2 THREADS ON CPUs 0,2
#
# Core M-5Y70 is two physical cores with HyperThreading:
#     cpu0 core_id=0 siblings=0,2      cpu1 core_id=1 siblings=1,3
#     cpu2 core_id=0 siblings=0,2      cpu3 core_id=1 siblings=1,3
# so 0,2 is exactly one physical core. dex2oat gets that core and the UI keeps
# the other one whole. Pinning to 0,1 would instead take one thread from each
# physical core and slow everything down.
#
# boot- and restore- are deliberately left unset. Boot dexopt runs before there
# is any UI to protect, and throttling it would only lengthen boot.
#
# WHY waydroid_base.prop
#
# These are not ro.* properties, so artifacts/build-prop/README.md's first trap
# does not apply -- they can be set after a build.prop is read, and no build.prop
# in this image defines them. make_prop() in tools/helpers/images.py copies every
# line of waydroid_base.prop into waydroid.prop verbatim and bind-mounts that
# into the container, so one line here becomes one property inside Android.
#
# DURABILITY, AND THE TRAP IT SHARES WITH THE LXC CONFIG
#
# make_base_props() rewrites waydroid_base.prop, and it is called from exactly
# two places -- initializer.py:164 and upgrader.py:58 -- the same two that call
# set_lxc_config(). So this edit survives reboots and container restarts, and is
# erased by `waydroid init -f` or `waydroid upgrade`, exactly like the
# `lxc.net.0.name = wlan0` rename from docs/34. Re-run this script after either.
#
# Usage:
#     sh artifacts/dexopt/install.sh              # merge and apply live
#     DESTDIR=%{buildroot} sh .../install.sh      # stage payload only
set -eu

PREFIX=${PREFIX:-/usr/local}
DESTDIR=${DESTDIR:-}
WAYDROID_WORK=${WAYDROID_WORK:-/var/lib/waydroid}
src=$(dirname "$0")

payload=$PREFIX/share/waydroid-dexopt/dexopt.prop
install -D -m 0644 "$src/dexopt.prop" "$DESTDIR$payload"

# RPM %install stage ends here: /var/lib/waydroid is state, not packaged content.
if [ -n "$DESTDIR" ]; then
	echo "staged: $payload"
	exit 0
fi

base=$WAYDROID_WORK/waydroid_base.prop
if [ ! -f "$base" ]; then
	echo "$base not found -- is Waydroid initialised?" >&2
	exit 1
fi

# Idempotent merge: for each key in the payload, drop any existing line for that
# key and append ours. Re-running is a no-op; changing a value here updates it.
tmp=$(mktemp)
trap 'rm -f "$tmp" "$tmp.new"' EXIT INT TERM
cp "$base" "$tmp"
while IFS= read -r line; do
	case "$line" in '' | \#*) continue ;; esac
	key=${line%%=*}
	grep -v "^${key}=" "$tmp" > "$tmp.new" || true
	mv "$tmp.new" "$tmp"
	printf '%s\n' "$line" >> "$tmp"
done < "$src/dexopt.prop"

if cmp -s "$tmp" "$base"; then
	echo "unchanged: $base"
else
	# Keep the pristine original, but never let a re-run overwrite it with an
	# already-modified copy.
	[ -f "$base.pre-dexopt" ] || cp -p "$base" "$base.pre-dexopt"
	install -m 0644 "$tmp" "$base"
	echo "updated:  $base  (original kept at $base.pre-dexopt)"
fi

# Apply live too. installd reads these per dexopt invocation rather than latching
# them at boot, so this takes effect without the container restart that would
# otherwise drop the kiosk session to the SDDM greeter.
if command -v waydroid >/dev/null 2>&1; then
	while IFS= read -r line; do
		case "$line" in '' | \#*) continue ;; esac
		key=${line%%=*}
		value=${line#*=}
		waydroid shell -- setprop "$key" "$value" >/dev/null 2>&1 || true
	done < "$src/dexopt.prop"
	echo "applied live via setprop (no container restart needed)"
fi
