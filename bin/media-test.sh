#!/bin/sh
# media-test.sh -- verify removable media reaches Android (goal 6, docs/46).
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/media-test.sh
#
# Checks the whole chain, host to app, and says which link is broken rather than
# just failing. Needs root: `waydroid shell` has no unprivileged form and
# <data>/media/0 is media_rw:media_rw mode 0770.
#
# Insert at least one USB stick or memory card before running, or every volume
# check reports SKIPPED rather than failing -- an empty slot is not a fault.

set -u

PKG=lan.syshlt.removablemedia
pass=0; fail=0; skip=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
na()   { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

ash() { waydroid shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1'; }

# The daemon autodetects this the same way; there is only ever one session user.
BASE=$(ls -d /home/*/.local/share/waydroid/data/media/0/Removable 2>/dev/null | head -1)

head_ "1. The host daemon"
if systemctl is-active --quiet waydroid-mediad; then
    ok "waydroid-mediad.service is active"
else
    no "waydroid-mediad.service is not active (systemctl status waydroid-mediad)"
fi
if [ -n "$BASE" ] && [ -d "$BASE" ]; then
    ok "base directory exists: $BASE"
else
    no "base directory missing -- has the daemon ever run?"
    BASE=""
fi

head_ "2. Mounts on the host"
MOUNTS=$(findmnt -rn -o TARGET,SOURCE,FSTYPE 2>/dev/null | grep '/Removable/' || true)
if [ -n "$MOUNTS" ]; then
    echo "$MOUNTS" | while read -r t s f; do
        printf '        %s  <-  %s (%s)\n' "${t##*/Removable/}" "$s" "$f"
    done
    ok "$(echo "$MOUNTS" | wc -l) volume(s) mounted"
else
    na "nothing mounted -- insert a USB stick or card, or nothing is attached"
fi

head_ "3. The container can see them"
if [ -z "$MOUNTS" ]; then
    na "no volumes to check"
else
    inside=$(ash 'grep -c /Removable/ /proc/mounts' | tr -dc '0-9')
    if [ "${inside:-0}" -gt 0 ] 2>/dev/null; then
        ok "mounts propagated into the container"
    else
        no "mounts did NOT propagate -- check that /var/home is still 'shared' (findmnt -o PROPAGATION)"
    fi
fi

head_ "4. Android can read them through FUSE"
if [ -z "$MOUNTS" ]; then
    na "no volumes to check"
else
    listing=$(ash 'ls /storage/emulated/0/Removable 2>&1')
    if [ -n "$listing" ] && ! echo "$listing" | grep -qi 'no such file'; then
        echo "$listing" | sed 's/^/        /'
        ok "visible at /sdcard/Removable"
    else
        no "not visible through FUSE: $listing"
    fi
fi

head_ "5. The helper app"
if ash "pm list packages" | grep -q "$PKG"; then
    ok "$PKG is installed"
    if ash "dumpsys package $PKG" | grep -q 'POST_NOTIFICATIONS: granted=true'; then
        ok "POST_NOTIFICATIONS is granted"
    else
        no "POST_NOTIFICATIONS not granted -- pm grant $PKG android.permission.POST_NOTIFICATIONS"
    fi
else
    na "$PKG not installed -- media-app/build.sh --install"
fi

head_ "6. Notifications currently posted"
if ash "pm list packages" | grep -q "$PKG"; then
    # Count RECORDS, not matching lines: each record mentions the package on
    # several lines (pkg=, opPkg=, key=). Exclude Android's own auto-generated
    # group summary (tag=ranker_group, id=Integer.MAX_VALUE), which GroupHelper
    # adds whenever one app has two ungrouped notifications -- it is not ours.
    posted=$(ash "dumpsys notification --noredact" \
        | grep "NotificationRecord(.*pkg=$PKG" | grep -vc 'tag=ranker_group' || true)
    if [ "${posted:-0}" -gt 0 ] 2>/dev/null; then
        ok "$posted notification(s) posted by the helper"
    elif [ -z "$MOUNTS" ]; then
        na "no volumes attached, so none expected"
    else
        no "volumes are mounted but no notification is posted -- restart waydroid-mediad to re-broadcast"
    fi
else
    na "helper not installed"
fi

head_ "7. A file manager exists to open them"
if ash "pm list packages" | grep -qE 'documentsui|amaze|nbu.files'; then
    ok "a file manager is installed"
else
    no "no file manager -- the notification tap has nowhere to land"
fi

printf '\n\033[1m%d passed, %d failed, %d skipped\033[0m\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
