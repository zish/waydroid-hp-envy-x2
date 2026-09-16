#!/bin/sh
# removable-probe.sh -- answer the open questions in docs/46-removable-media.md.
#
# Read-only throughout: it mounts nothing, edits no config, and starts no
# service. Run it on bigtab01 with the Waydroid container up.
#
#     ssh 10.42.0.137 'sudo sh -s' < bin/removable-probe.sh
#
# sudo is needed for exactly two things -- `waydroid shell`, which has no
# unprivileged form, and reading /var/lib/waydroid. Everything else runs fine
# as jmelanso, so `sh bin/removable-probe.sh` on the host is also useful and
# will simply mark those sections SKIPPED.
#
# Written because the host was unreachable when goal 6 was scoped (2026-09-15),
# so every claim in docs/46 about this machine is currently hypothesis. This
# turns the table at the end of that note into one run.

set -u

USER_NAME=${SUDO_USER:-${USER:-jmelanso}}
WAYDROID=/usr/bin/waydroid
LXC_DIR=/var/lib/waydroid/lxc/waydroid

say()  { printf '\n\033[1m== %s\033[0m\n' "$1"; }
item() { printf '  %-42s %s\n' "$1" "$2"; }
run()  { printf '  $ %s\n' "$*"; "$@" 2>&1 | sed 's/^/    /'; }

am_root() { [ "$(id -u)" = 0 ]; }

# waydroid shell prints a cosmetic "ERROR: [Errno 13] Permission denied: 1"
# after every command (AGENTS.md); output above that line is still valid.
ash() {
    if am_root; then
        "$WAYDROID" shell -- sh -c "$1" 2>&1 | grep -v 'Permission denied: 1' | sed 's/^/    /'
    else
        printf '    SKIPPED (needs root)\n'
    fi
}

say "Host identity"
item "hostname" "$(hostname 2>/dev/null)"
item "session user" "$USER_NAME"
item "kernel" "$(uname -r)"
item "uid" "$(id -u) ($(id -un))"

say "1. Is udisks2 there, and is gvfs?"
for p in udisks2 gvfs gvfs-client gvfs-mtp gvfs-gphoto2 simple-mtpfs jmtpfs; do
    item "$p" "$(rpm -q "$p" 2>&1 | head -1)"
done
item "udisksd running" "$(pgrep -x udisksd >/dev/null && echo yes || echo no)"
item "UDisks2 on system bus" \
     "$(busctl --system list --no-pager 2>/dev/null | grep -c org.freedesktop.UDisks2) name(s)"

say "2. What does /run/media look like now?"
run ls -la "/run/media/$USER_NAME"
item "anything mounted under it" \
     "$(findmnt -rn -o TARGET 2>/dev/null | grep -c "^/run/media/$USER_NAME/")"

say "3. Mount propagation -- THE decisive question (docs/46 half 2)"
# Plan A lives or dies here. The source must be in a shared peer group for a
# mount made after lxc-start to propagate into the container.
run findmnt -o TARGET,PROPAGATION,FSTYPE /run
if [ -d "/run/media/$USER_NAME" ]; then
    run findmnt -o TARGET,PROPAGATION,FSTYPE "/run/media/$USER_NAME"
else
    item "/run/media/$USER_NAME" "does not exist yet (nothing has ever mounted)"
fi
run findmnt -o TARGET,PROPAGATION,FSTYPE /

say "4. Storage hardware -- is the card reader SDHCI or an internal USB reader?"
run lsblk -o NAME,TRAN,TYPE,SIZE,FSTYPE,MOUNTPOINT
item "mmc hosts" "$(ls /sys/class/mmc_host 2>/dev/null | tr '\n' ' ')"
item "optical drives" "$(ls /dev/sr* 2>/dev/null | tr '\n' ' ' || echo none)"

say "5. Does the user manager reach default.target under cage?"
# Half 1 puts the udisks2 watcher in the user session so polkit sees an active
# seat. That only works if the user manager gets that far without
# graphical-session.target, which docs/25 says cage never starts.
if am_root; then
    run systemctl --user --machine="$USER_NAME@" is-active default.target
    run loginctl list-sessions --no-pager
else
    run systemctl --user is-active default.target
fi
# Show every session, not just the first -- the first is usually the ssh one
# running this probe, which has no seat and answers nothing about the console.
run loginctl list-sessions --no-pager
for sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    item "session $sid" "$(loginctl show-session "$sid" -p Class -p Type -p Seat -p Active -p Desktop --value 2>/dev/null | tr '\n' ' ')"
done
# polkit grants filesystem-mount to an ACTIVE session implicitly. A systemd
# --user service is NOT in a login session at all, so it does not qualify.
run pkaction --action-id org.freedesktop.udisks2.filesystem-mount --verbose

say "6. LXC include order -- config_nodes vs config_session (docs/46 Plan A)"
# If config_nodes is included first, a create=dir entry under data/ lands in the
# image's /data and config_session's bind then hides it.
if [ -r "$LXC_DIR/config" ]; then
    run grep -n 'include\|lxc.rootfs' "$LXC_DIR/config"
    item "config_nodes mount entries" "$(grep -c 'lxc.mount.entry' "$LXC_DIR/config_nodes" 2>/dev/null)"
    item "config_session mount entries" "$(grep -c 'lxc.mount.entry' "$LXC_DIR/config_session" 2>/dev/null)"
    run grep -n 'data' "$LXC_DIR/config_session"
else
    item "$LXC_DIR/config" "unreadable (needs root)"
fi

say "7. Android side"
item "container state" "$(am_root && "$WAYDROID" status 2>/dev/null | awk -F'\t' '/Container/{print $NF}' || echo 'SKIPPED (needs root)')"
printf '  persist.sys.fuse (is /sdcard a FUSE mount?)\n'; ash 'getprop persist.sys.fuse; getprop ro.build.version.sdk'
printf '  file manager present?\n';                        ash 'pm list packages | grep -iE "documentsui|files|filemanager"'
printf '  vold running?\n';                                ash 'ps -A | grep -w vold || echo "no vold"'
printf '  /sdcard and /data/media/0\n';                    ash 'ls -ld /sdcard /data/media/0; mount | grep -E " /storage| /data/media"'

say "8. SELinux -- can waydroid_t touch a vfat mount? (docs/46 half 3)"
item "enforcing" "$(getenforce 2>/dev/null)"
item "label on a real vfat mount (/boot/efi)" "$(ls -Zd /boot/efi 2>/dev/null | awk '{print $1}')"
if command -v sesearch >/dev/null 2>&1; then
    run sesearch -A -s waydroid_t -t dosfs_t
else
    item "sesearch" "not installed (setools-console); use selinux_check_access instead"
fi
# The denials that matter on this host have all been dontaudit'ed -- docs/35,
# docs/40, docs/42 -- so ask the kernel rather than waiting for an audit record.
if command -v python3 >/dev/null 2>&1; then
    printf '  kernel answer via selinux_check_access:\n'
    # 4 args, not 5: the Python binding has no audit-data parameter. It writes an
    # "avc: denied" line to stderr on refusal, which is NOT an audit record --
    # that is the point, per docs/42. 2>/dev/null keeps the report readable.
    python3 - 2>/dev/null <<'PY' | sed 's/^/    /'
try:
    import selinux
except ImportError:
    raise SystemExit("python3-libselinux not installed")
S = "system_u:system_r:waydroid_t:s0"
for tgt, cls, perm in (("dosfs_t", "dir", "search"), ("dosfs_t", "dir", "read"),
                       ("dosfs_t", "file", "read"), ("dosfs_t", "file", "write"),
                       ("iso9660_t", "dir", "search"), ("iso9660_t", "file", "read"),
                       ("removable_device_t", "blk_file", "read"),
                       ("fusefs_t", "dir", "search")):
    try:
        selinux.selinux_check_access(S, f"system_u:object_r:{tgt}:s0", cls, perm)
        print(f"ALLOW  waydroid_t -> {tgt:<20} {cls} {perm}")
    except PermissionError:
        print(f"DENY   waydroid_t -> {tgt:<20} {cls} {perm}")
    except Exception as e:
        print(f"ERROR  {tgt} {cls} {perm}: {e}")
PY
fi

say "Done"
printf '  Next: docs/46-removable-media.md, "The decisive experiment".\n'
printf '  That one is NOT read-only and is not run here -- it edits config_nodes\n'
printf '  and restarts the container, which drops a kiosk session to the greeter.\n\n'
