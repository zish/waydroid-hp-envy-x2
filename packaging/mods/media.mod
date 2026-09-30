# waydroid-ext-media -- docs/46-removable-media.md, docs/49-desktop-session-media.md
#
# Goal 6. Waydroid's Android cannot see a USB stick or an SD card at all, and not
# for want of a volume manager: vold IS running in the image. What it has to work
# with is nothing -- config_nodes has 23 entries and no block device among them,
# and NETLINK_KOBJECT_UEVENT is scoped to a network namespace the container has
# its own of, so no uevent announcing a stick ever reaches it. Nothing mounts the
# stick on the host either: automounting is desktop-shell policy, a cage kiosk
# runs no shell, and the probe found /run/media/<user> did not exist at all with
# two devices attached (docs/46).
#
# WHY THE MOUNT LANDS IN THE FUSE LOWER DIRECTORY
#
# Three plans were written and the third shipped. Handing the container the block
# device was ruled out on cost: it means supplying nodes AND uevents, and the host
# wants to keep reading the stick too. A static lxc.mount.entry was ruled out on
# ordering -- config_nodes is included BEFORE config_session, so an entry
# targeting data/media/0/Removable creates that directory in the image's /data
# and the /data rbind then covers it, which would have presented as a propagation
# failure and sent the investigation to the wrong half. An nsenter bind into the
# container's init mount namespace was measured dead: every app is in its own
# namespace and all of them differ from init's.
#
# What works is that apps do not reach storage through a mount they can see at
# all. They reach it through FUSE, and FUSE serves CONTENT, which crosses mount
# namespaces freely. The lower directory of /storage/emulated/0 is literally
# <data>/media/0 on the host, so mounting at <data>/media/0/Removable/<label>
# puts the volume at /sdcard/Removable/<label> with no LXC edit, no nsenter, no
# propagation flag and -- the part that matters operationally -- no container
# restart, which on a kiosk drops the session to the SDDM greeter. Measured
# 2026-09-15 and correct on the first attempt (docs/46).
#
# WHY THERE IS NO SELINUX MODULE HERE
#
# Worth recording, because the sibling waydroid-ext-backlight ships a CIL module
# and an earlier draft of docs/46 had a denial table saying this package needed
# one too. That table measured waydroid_t, the domain of the HOST daemons
# container_manager.py spawns. The container has no lxc.selinux.context line, so
# it inherits container_runtime_t, which reads dosfs_t perfectly well -- the real
# vfat card was readable through FUSE immediately (docs/46). No policy here, no
# scriptlet, no %post.
#
# WHAT IT COSTS
#
# A root daemon that calls mount(8) on device nodes it picked itself. The guard is
# a strict allowlist -- USB, MMC or optical transport, a recognised filesystem,
# and no disk that carries a mount anywhere -- and docs/46 records that the first
# version's system-disk guard was INERT, because it asked `findmnt -o SOURCE /`
# and an rpm-ostree host answers "overlay" rather than a block device. A guard
# that silently protects nothing reads as safe, which is why the working one is
# derived from lsblk instead.
#
# The DESCRIPTION says why root and why not a --user unit driving udisks2. One
# reason belongs here rather than there, because it is about the mechanism and not
# the privilege: udisks2 filters mount options against an allowlist, and the whole
# point of these mounts is uid=1023,gid=1023.
#
# The Android half ("Removable Media", media-app/) is not packaged, for the reason
# no app in this repository is: an APK needs the Android SDK and the Kotlin
# compiler at build time, neither a Fedora BuildRequires, and a prebuilt one would
# be the vendored binary docs/54-no-vendored-binaries.md rules out.
# media-app/build.sh --install is the delivery mechanism.

VERSION=1.1.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Make the host's USB sticks, SD cards and data discs appear in Waydroid"

# No SPDX header in any of the three payload files, so the repository's own
# licence governs. Checked rather than assumed.
LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason waydroid-ext-btd and waydroid-ext-pwd declare it.
BUILDREQUIRES="systemd-rpm-macros"

# The daemon is stdlib-only Python -- argparse, json, os, re, signal, subprocess,
# sys, threading, time, glob and nothing else -- so there is no Python dependency
# beyond the interpreter. Everything else it execs, and each is named with the
# package that owns it, because a daemon that starts and then cannot run the
# command it needs is the failure mode this list exists to prevent.
#
#   waydroid          `waydroid status` finds the session user's data directory
#                     and `waydroid shell -- am broadcast` announces a volume.
#                     Also the subject: no Waydroid, no FUSE lower directory.
#   systemd           the unit.
#   python3           the shebang. rpm's generator would find it anyway; named
#                     as btd and pwd name theirs.
#   util-linux-core   mount, umount, lsblk, findmnt. lsblk is the entire view of
#                     the world, and mount is the job.
#   coreutils         stdbuf. `stdbuf -oL udevadm monitor` is what makes the
#                     event stream line-buffered; without it the Popen raises
#                     FileNotFoundError at startup and the daemon restart-loops
#                     having mounted nothing.
#   systemd-udev      udevadm, the only event source there is. Named separately
#                     from systemd as waydroid-ext-backlight names it.
#
# util-linux-core and not util-linux: all four commands are in the core
# subpackage, which an Atomic image is guaranteed to carry.
# waydroid-ext-pidguard names the outer package for nsenter and unshare, also in
# core; reconciling the two is a packaging question, not one about this
# modification.
#
# Not here: policycoreutils, because install.sh calls restorecon only when
# DESTDIR is unset and guards it with `command -v`, and under rpm the labelling
# is rpm's own. Nor udisks2 -- docs/49 proposes routing eject through it and that
# is not built.
REQUIRES="waydroid
systemd
python3
util-linux-core
coreutils
systemd-udev"

# ntfs-3g provides /usr/sbin/mount.ntfs, which is what `mount -t ntfs` needs:
# blkid reports an NTFS volume as fstype "ntfs", and without the helper that one
# mount fails while every other filesystem class still works. That is the
# docs/47 test for a weak dependency exactly -- the package without it is not
# worse than stock, it is merely narrower -- so Recommends and not Requires.
# vfat, msdos, exfat, ntfs3, iso9660 and udf are in-kernel on Fedora and need no
# userspace helper at all.
RECOMMENDS="ntfs-3g"

# bin/media-test.sh is the end-to-end check and is deliberately not here: the
# test scripts are waydroid-ext-tools' payload in docs/47's split, and shipping
# one of them as this package's %doc would start the drift that split prevents.
DOCS="docs/46-removable-media.md
docs/49-desktop-session-media.md"

DESCRIPTION="Mounts the host's removable volumes where Waydroid's Android can already see
them, so a USB stick or an SD card inserted on the host turns up at
/sdcard/Removable/<label> and is browsable by the file manager in the image.

Nothing in Android discovers a volume by itself here: the container is bound no
block devices and receives no uevents, so its own volume manager has nothing to
find. What it does have is a FUSE view of primary external storage whose lower
directory is plain host filesystem, and FUSE serves content rather than a
mount, so it crosses the per-app mount namespaces that make an in-container
bind useless. Mounting into that lower directory needs no LXC configuration
edit, no privileged entry into the container's namespace, and no container
restart -- which on a kiosk would drop the session to the greeter.

A udev block event only wakes the daemon; a reconcile pass then compares what
should be mounted against what is and fixes the difference. Startup, a missed
event and a hotplug are therefore one code path. Insertion and removal were
verified by hand, in both directions, with the daemon untouched.

It runs as root, and a systemd --user unit could not do this job: mounting
needs privilege, the lower directory is mode 0770 owned by Android's media_rw,
and a --user service is not in a login session, so asking udisks2 to mount on
its behalf falls through polkit to an admin password prompt with nobody there
to answer it.

Scope is USB mass storage, SD and MicroSD, and optical DATA discs. Audio CDs
and blank media have no mountable filesystem and are a deliberate no-op rather
than a bug. MTP and PTP phones are not supported at all: they need a FUSE
helper mounted with allow_other, which is a different mechanism. Volumes are
chosen by a strict allowlist, and any disk carrying a mount anywhere -- the
host's own system disk first of all -- is refused.

vfat, exfat and NTFS are mounted read-write with uid and gid 1023, which is
Android's media_rw and, there being no idmap, host uid 1023 as well; that is
what lets Android's FUSE daemon read the files and serve them on. ext4, btrfs
and xfs are mounted READ-ONLY on purpose, because they carry real on-disk
ownership, have no uid= mount option, and writing as the wrong uid is worse
than not writing. Anything unrecognised is read-only too.

It is designed for a host where nothing else mounts removable
media. Under a GNOME session the desktop's own
automounter gets there first and this daemon then skips the device, so nothing
appears in Android at all; under KDE, where automount is off by default, this
daemon wins instead. Ejecting from the desktop a volume this daemon mounted
prompts for an admin password. docs/49 measures all of that and designs the
fix -- follow the desktop's mounts rather than own them -- and that work is not
built, so on a desktop session treat this package as unsupported.

The arrival notification and the Eject action live in the Android app, which is
not part of this package (see media-app/build.sh --install), so the daemon
alone has no way to eject from inside Android. The first read of a volume that
has replaced another one at the same path -- two unlabelled sticks, or the same
stick reformatted -- can return the previous volume's contents once, which is
Android's media cache and not the mount; the second read is correct."

SOURCES="artifacts/media/install.sh
artifacts/media/waydroid-mediad
artifacts/media/waydroid-mediad.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/media/install.sh'

# Exactly what install.sh stages, verified by diffing a scratch buildroot rather
# than read off the installer. BINDIR and UNITDIR are the only paths it honours:
# there is no user unit, no udev rule and nothing under /etc, so nothing here is
# %config and the only macro directory referenced is %{_unitdir}.
#
# %dir on multi-user.target.wants because the installer drops an enable symlink
# into it rather than relying on a %post `systemctl enable` an ostree host could
# not count on. Same idiom as waydroid-ext-btd.
#
# No state directory question arises: the unit declares no StateDirectory=, and
# the one directory the daemon creates -- <data>/media/0/Removable, chowned to
# Android's media_rw -- is inside the session user's home, which no package can
# own and no buildroot can contain.
PAYLOAD_FILES='%{_bindir}/waydroid-mediad
%{_unitdir}/waydroid-mediad.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-mediad.service'
