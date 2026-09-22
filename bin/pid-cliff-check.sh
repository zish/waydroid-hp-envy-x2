#!/bin/bash
# Report how close the Waydroid container is to the 32-bit bionic PID cliff.
# Usage: pid-cliff-check.sh
# Run ON bigtab01 as jmelanso. Needs sudo (nsenter into the container's pidns).
#
# 32-bit bionic aborts any process whose tid exceeds 65535, because the 32-bit
# pthread_mutex_t has only 16 bits for the owner. A Waydroid container is a
# long-lived PID namespace whose counter only climbs, so past roughly a day of
# uptime every newly started 32-bit process dies at birth -- and this image has
# five of them, including the audio HAL, the camera provider and zygote32.
#
# Read this as a WEATHER REPORT, not a health check. Crossing 65535 breaks
# nothing by itself: already-running processes keep their low PIDs and are fine.
# The fault only appears when something RESTARTS a 32-bit process afterwards,
# which may be a day later. "Still working" above the cliff is not safety.
#
# See docs/51-pid-namespace-32bit-cliff.md.
set -u
CLIFF=65535
WARN_AT=55000
LXC_PATH=/var/lib/waydroid/lxc
MNT=/run/pid-cliff-check
RC=0

sudo -n true 2>/dev/null || { echo "needs passwordless sudo"; exit 1; }

echo "### container PID namespace"
LXC=$(pgrep -f "lxc-start -P $LXC_PATH" | head -1)
if [ -z "$LXC" ]; then
    echo "  container is not running -- nothing to measure"
    exit 0
fi
INIT=$(sudo -n awk '{print $1}' "/proc/$LXC/task/$LXC/children" 2>/dev/null)
if [ -z "$INIT" ]; then
    echo "  FAIL: lxc-start $LXC has no child -- cannot find container init"
    exit 1
fi
NS=$(sudo -n readlink "/proc/$INIT/ns/pid")
echo "  lxc-start     : $LXC"
echo "  container init: $INIT"
echo "  pidns         : $NS"

# /proc/sys is read-only inside the container (LXC proc:mixed), so reads go
# through a private procfs mounted for that pid namespace. Reads only here.
nsread() {
    sudo -n nsenter -t "$INIT" -p -- unshare -m --propagation private -- sh -c "
        mkdir -p '$MNT'; mount -t proc proc '$MNT' 2>/dev/null || exit 97
        cat '$MNT/sys/kernel/$1'; umount '$MNT' 2>/dev/null"
}
LAST=$(nsread ns_last_pid); PIDMAX=$(nsread pid_max)
HOSTMAX=$(cat /proc/sys/kernel/pid_max)
echo "  ns_last_pid   : $LAST"
echo "  ns pid_max    : $PIDMAX"
echo "  host pid_max  : $HOSTMAX"

echo "### verdict"
if [ "${PIDMAX:-0}" -le 65536 ] 2>/dev/null; then
    echo "  CAPPED -- pid_max $PIDMAX means the allocator wraps below the cliff."
    echo "  The 32-bit abort is unreachable in this namespace. (waydroid-pidguard)"
elif [ "${LAST:-0}" -gt "$CLIFF" ] 2>/dev/null; then
    echo "  PAST THE CLIFF -- ns_last_pid $LAST > $CLIFF."
    echo "  Any 32-bit service that restarts from here will wedge on startup."
    echo "  Fix: waydroid-pid-reset --kill-stuck, or restart the container."
    RC=1
elif [ "${LAST:-0}" -ge "$WARN_AT" ] 2>/dev/null; then
    echo "  CLOSE -- ns_last_pid $LAST, only $((CLIFF - LAST)) pids of headroom."
    RC=1
else
    echo "  uncapped, $((CLIFF - LAST)) pids of headroom below $CLIFF."
    echo "  Install artifacts/pidguard to make this structurally impossible."
fi

echo "### 32-bit binaries in this image (the blast radius)"
ROOT=/var/lib/waydroid/rootfs
if sudo -n test -d "$ROOT/vendor/bin/hw"; then
    for f in "$ROOT"/vendor/bin/hw/* "$ROOT"/system/bin/app_process32 "$ROOT"/system/bin/hw/*; do
        sudo -n test -f "$f" || continue
        cls=$(sudo -n od -An -tu1 -j4 -N1 "$f" 2>/dev/null | tr -d ' ')
        [ "$cls" = "1" ] && echo "  32-bit: ${f#$ROOT}"
    done
else
    echo "  SKIPPED -- $ROOT not mounted (container image not up)"
fi

echo "### 32-bit processes currently holding a PID above the cliff"
FOUND=0
for d in /proc/[0-9]*; do
    hpid=${d#/proc/}
    [ "$(sudo -n readlink "$d/ns/pid" 2>/dev/null)" = "$NS" ] || continue
    nspid=$(sudo -n awk '/^NSpid:/{print $NF}' "$d/status" 2>/dev/null)
    [ -n "$nspid" ] || continue
    [ "$nspid" -gt "$CLIFF" ] 2>/dev/null || continue
    cls=$(sudo -n od -An -tu1 -j4 -N1 "$d/exe" 2>/dev/null | tr -d ' ')
    [ "$cls" = "1" ] || continue
    nm=$(sudo -n awk '/^Name:/{print $2}' "$d/status")
    th=$(sudo -n awk '/^Threads:/{print $2}' "$d/status")
    wch=$(sudo -n cat "$d/wchan" 2>/dev/null)
    echo "  WEDGED hostpid=$hpid nspid=$nspid threads=$th name=$nm wchan=$wch"
    FOUND=1; RC=1
done
[ "$FOUND" = 0 ] && echo "  none"

echo "### Android services init has parked (the goal 7 symptom)"
PROPS=$(sudo -n waydroid shell -- sh -c 'getprop | grep "\[stopping\]"' 2>/dev/null \
        | grep -o 'init\.svc\.[a-zA-Z0-9._-]*')
if [ -n "$PROPS" ]; then
    echo "$PROPS" | sed 's/^/  stopping: /'
    echo "  These cannot be restarted by init (docs/48). If they are 32-bit and"
    echo "  the counter is past the cliff, the respawn would wedge anyway."
    RC=1
elif sudo -n waydroid status 2>/dev/null | grep -q "Session:.*RUNNING"; then
    echo "  none"
else
    echo "  SKIPPED -- no running session to read properties from"
fi

echo "### result"
[ "$RC" = 0 ] && echo "  OK" || echo "  ATTENTION NEEDED (see above)"
exit $RC
