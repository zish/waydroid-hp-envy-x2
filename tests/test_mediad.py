# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""waydroid-mediad's device selection: what it will and will not mount.

candidates() is the function whose failure mode is mounting the host's system
disk into Android, so most of this file is about refusals. The device dicts are
shaped exactly as lsblk() produces them -- lsblk -J's keys, with `tran`
inherited from the parent -- and the scenarios are the ones docs/46 met on
bigtab01, not invented ones.
"""

import os
import tempfile
import unittest

import _scripts

mediad = _scripts.load("artifacts/media/waydroid-mediad")

BASE = "/var/home/u/.local/share/waydroid/data/media/0/Removable"


def dev(name, **kw):
    d = {"name": name, "path": "/dev/" + name, "type": "part",
         "tran": None, "fstype": None, "label": None, "uuid": None,
         "mountpoint": None, "pkname": None}
    d.update(kw)
    return d


# bigtab01's internal eMMC as rpm-ostree mounts it: / is "overlay", so nothing
# here is mounted at "/" -- the guard has to find the disk through /sysroot.
SYSTEM_DISK = [
    dev("mmcblk0", type="disk", tran=None),
    dev("mmcblk0p1", pkname="mmcblk0", fstype="vfat", mountpoint="/boot/efi"),
    dev("mmcblk0p2", pkname="mmcblk0", fstype="ext4", mountpoint="/boot"),
    dev("mmcblk0p3", pkname="mmcblk0", fstype="btrfs", mountpoint="/sysroot"),
]


class SafeName(unittest.TestCase):
    def test_label_is_used_and_cleaned(self):
        self.assertEqual(mediad.safe_name(dev("sdb1", label="My Stick")),
                         "My_Stick")

    def test_label_cannot_traverse(self):
        # The name becomes a directory under BASE, so it must never be a path.
        for label in ("..", ".", "../../etc", "/", "a/b"):
            name = mediad.safe_name(dev("sdb1", label=label, tran="usb"))
            self.assertNotIn("/", name)
            self.assertNotIn(name, ("", ".", ".."))

    def test_label_is_truncated(self):
        self.assertEqual(len(mediad.safe_name(dev("sdb1", label="x" * 200))), 48)

    def test_unlabelled_is_named_by_kind(self):
        self.assertEqual(mediad.safe_name(dev("sdb1", tran="usb", uuid="4CFC-8D0A")),
                         "USB_Drive_4CFC8D")
        self.assertEqual(mediad.safe_name(dev("mmcblk1p1")), "SD_Card")
        self.assertEqual(mediad.safe_name(dev("sr0", type="rom")), "Disc")
        self.assertEqual(mediad.safe_name(dev("vdb1")), "Volume")


class IsOurs(unittest.TestCase):
    def test_symlinked_home_still_matches(self):
        # /home -> /var/home on an Atomic host. lsblk reports one spelling and
        # the configured base may be the other; a string compare misses it and
        # reconcile() unmounts its own work. docs/46.
        with tempfile.TemporaryDirectory() as tmp:
            real = os.path.join(tmp, "var", "home")
            os.makedirs(os.path.join(real, "Removable", "stick"))
            os.symlink(real, os.path.join(tmp, "home"))
            base_real = os.path.realpath(os.path.join(tmp, "home", "Removable"))
            self.assertTrue(mediad.is_ours(
                os.path.join(tmp, "home", "Removable", "stick"), base_real))
            self.assertTrue(mediad.is_ours(
                os.path.join(real, "Removable", "stick"), base_real))

    def test_prefix_is_not_a_parent(self):
        self.assertFalse(mediad.is_ours(BASE + "-other/x", BASE))

    def test_empty(self):
        self.assertFalse(mediad.is_ours(None, BASE))
        self.assertFalse(mediad.is_ours("", BASE))


class ProtectedNames(unittest.TestCase):
    def test_any_mounted_child_protects_the_whole_disk(self):
        devs = SYSTEM_DISK + [dev("mmcblk0p4", pkname="mmcblk0", fstype="vfat")]
        prot = mediad.protected_names(devs, BASE)
        self.assertIn("mmcblk0", prot)
        self.assertIn("mmcblk0p3", prot)

    def test_our_own_mounts_do_not_protect(self):
        devs = [dev("sdb", type="disk", tran="usb"),
                dev("sdb1", pkname="sdb", tran="usb", fstype="vfat",
                    mountpoint=BASE + "/Stick")]
        self.assertEqual(mediad.protected_names(devs, BASE), set())


class Candidates(unittest.TestCase):
    def pick(self, devs):
        prot = mediad.protected_names(devs, BASE)
        return [d["name"] for d in mediad.candidates(devs, prot, BASE)]

    def test_system_disk_is_never_a_candidate(self):
        # An unmounted vfat partition on the internal mmcblk0 looks exactly
        # like an SD card by name. Only the protected-disk guard stops it.
        devs = SYSTEM_DISK + [dev("mmcblk0p4", pkname="mmcblk0", fstype="vfat")]
        self.assertEqual(self.pick(devs), [])

    def test_usb_stick_and_sd_card(self):
        devs = SYSTEM_DISK + [
            dev("sdb", type="disk", tran="usb"),
            dev("sdb1", pkname="sdb", tran="usb", fstype="exfat"),
            dev("mmcblk1", type="disk", tran=None),
            dev("mmcblk1p1", pkname="mmcblk1", fstype="vfat"),
        ]
        self.assertEqual(self.pick(devs), ["sdb1", "mmcblk1p1"])

    def test_non_removable_transport_is_refused(self):
        devs = [dev("sda", type="disk", tran="sata"),
                dev("sda1", pkname="sda", tran="sata", fstype="ext4"),
                dev("nvme0n1p1", tran="nvme", fstype="vfat")]
        self.assertEqual(self.pick(devs), [])

    def test_containers_and_swap_are_refused(self):
        devs = [dev("sdb1", tran="usb", fstype=t)
                for t in sorted(mediad.SKIP_FSTYPES)]
        devs.append(dev("sdb9", tran="usb", fstype=None))
        self.assertEqual(self.pick(devs), [])

    def test_someone_elses_mount_is_left_alone(self):
        # GNOME's udisks2 got there first: docs/49. Not ours to remount.
        devs = [dev("sdb", type="disk", tran="usb"),
                dev("sdb1", pkname="sdb", tran="usb", fstype="vfat",
                    mountpoint="/run/media/u/STICK")]
        self.assertEqual(self.pick(devs), [])

    def test_our_mount_stays_a_candidate(self):
        devs = [dev("sdb", type="disk", tran="usb"),
                dev("sdb1", pkname="sdb", tran="usb", fstype="vfat",
                    mountpoint=BASE + "/STICK")]
        self.assertEqual(self.pick(devs), ["sdb1"])

    def test_isohybrid_prefers_the_whole_disk(self):
        # /dev/sdb and /dev/sdb1 both iso9660; mounting both produced two
        # "Can't open blockdev" failures per insertion.
        devs = [dev("sdb", type="disk", tran="usb", fstype="iso9660"),
                dev("sdb1", pkname="sdb", tran="usb", fstype="iso9660"),
                dev("sdb2", pkname="sdb", tran="usb", fstype="vfat")]
        self.assertEqual(self.pick(devs), ["sdb"])

    def test_optical(self):
        self.assertEqual(self.pick([dev("sr0", type="rom", tran="sata",
                                        fstype="udf")]), ["sr0"])


class MountOptions(unittest.TestCase):
    def test_every_writable_fs_maps_to_media_rw(self):
        # The uid/gid pair is what makes the volume readable through
        # MediaProvider's FUSE; an entry without it mounts and shows nothing.
        for fstype, opts in mediad.FS_OPTS.items():
            self.assertIn("uid=1023", opts, fstype)
            self.assertIn("gid=1023", opts, fstype)

    def test_optical_is_read_only(self):
        for fstype in ("iso9660", "udf"):
            self.assertTrue(mediad.FS_OPTS[fstype].startswith("ro,"), fstype)


if __name__ == "__main__":
    unittest.main()
