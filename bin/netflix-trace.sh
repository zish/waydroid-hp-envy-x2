#!/bin/bash
# Trace what Netflix does in the seconds before it terminates itself.
# Usage: netflix-trace.sh [package]      (default: com.netflix.mediaclient)
# Run ON bigtab01 as jmelanso. Needs sudo (strace, waydroid shell).
#
# WHY THIS EXISTS. Netflix's release build logs nothing under its own tags, produces
# no exception, no ANR and no tombstone -- it simply calls Process.killProcess() on
# itself about 5 s after its UI appears (docs/22). Every in-container avenue for
# finding out *why* has been exhausted. This goes outside the container instead.
#
# Waydroid's Android runs under lxc-start in a PID namespace, but the HOST can still
# see every container process (`ps -eo pid,args` lists com.netflix.mediaclient with a
# host-side pid). strace is installed on bigtab01, so the app's syscalls are readable
# from the host without touching the image, the app or the container.
#
# The filter is deliberately narrow. A full -f trace of an ART process is enormous and
# slows the app enough to change its timing; openat/access/readlinkat show which files
# it probes (the usual shape of a device check), and kill/tgkill/exit_group pin the
# exact moment and thread of the self-termination.
set -u
PKG="${1:-com.netflix.mediaclient}"
OUT=/tmp/netflix.strace

command -v strace >/dev/null || { echo "strace not installed on this host" >&2; exit 1; }

echo "== stopping $PKG"
sudo -n waydroid shell -- sh -c "am force-stop $PKG" >/dev/null 2>&1
sleep 1

ACT=$(sudo -n waydroid shell -- sh -c "cmd package resolve-activity --brief $PKG" 2>/dev/null | tail -1)
[ -n "$ACT" ] || { echo "cannot resolve launcher activity for $PKG" >&2; exit 1; }

echo "== launching $ACT"
sudo -n waydroid shell -- sh -c "am start -n $ACT" >/dev/null 2>&1 &

# Race the app's startup. The main process's argv is exactly the package name;
# the isolated helpers are "<pkg>:a:..." and the zygote is "<pkg>_zygote", so an
# anchored match on argv picks the one process that matters.
echo "== waiting for the main process"
PID=""
for _ in $(seq 1 300); do
	PID=$(pgrep -f "^${PKG}\$" | head -1)
	[ -n "$PID" ] && break
	sleep 0.05
done
[ -n "$PID" ] || { echo "never saw a main process for $PKG" >&2; exit 1; }
echo "   host pid $PID"

echo "== tracing until it exits (max 25 s)"
sudo -n timeout 25 strace -f -tt -s 200 \
	-e trace=openat,access,readlinkat,kill,tgkill,exit_group \
	-p "$PID" -o "$OUT" 2>/dev/null

echo "== trace written to $OUT ($(wc -l < "$OUT" 2>/dev/null || echo 0) lines)"
echo
echo "--- the self-kill and the 40 syscalls before it ---"
K=$(grep -n -E "kill\(|tgkill\(|exit_group\(" "$OUT" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$K" ]; then
	sed -n "$((K > 40 ? K - 40 : 1)),$((K + 5))p" "$OUT"
else
	echo "(no kill/exit_group seen -- process may have outlived the trace)"
	tail -40 "$OUT" 2>/dev/null
fi
