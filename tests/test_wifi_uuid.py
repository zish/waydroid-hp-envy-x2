# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""waydroid-wifi-sync's profile ownership: its UUIDv5 must be RFC 4122's.

waydroid-wifid (C++, NmBackend::connectionUuid) mints NetworkManager profile
UUIDs and waydroid-wifi-sync (bash) regenerates them to decide which profiles
it may reap. Ownership is BY that UUID (docs/59), so if the two ever disagree
the reaper either orphans every profile or -- worse -- stops recognising them
and leaves Android's forgotten passphrases on the host forever.

Python's uuid.uuid5 is the independent oracle here. tests/cpp/ checks the C++
side against the same oracle's output, so the three agree pairwise.
"""

import re
import subprocess
import unittest
import uuid

import _scripts

NAMESPACE = uuid.UUID(bytes=bytes([
    0x7f, 0x86, 0x2e, 0xff, 0x2c, 0xb3, 0x41, 0xe0,
    0xad, 0xa9, 0x31, 0x51, 0x20, 0x0e, 0xf9, 0x7f]))

# Spaces, quotes, a leading dash, a glob, multibyte UTF-8, and the longest
# legal SSID (32 bytes) -- the shapes a shell is most likely to mangle.
SSIDS = ["vidiot", "My Network", "it's \"quoted\"", "-n", "*", "café ☕",
         "x" * 32, "a\\nb", "%s%b"]


def read(rel):
    with open(_scripts.path(rel)) as handle:
        return handle.read()


def bash_uuid(ssid):
    src = read("artifacts/wifi/waydroid-wifi-sync")
    ns = re.search(r"^WAYDROID_UUID_NS=.*$", src, re.M).group(0)
    fn = re.search(r"^waydroid_uuid\(\) \{.*?^\}$", src, re.M | re.S).group(0)
    script = "%s\n%s\nwaydroid_uuid \"$1\"\n" % (ns, fn)
    return subprocess.run(["bash", "-c", script, "bash", ssid],
                          capture_output=True, text=True,
                          check=True).stdout.strip()


class WifiSyncUuid(unittest.TestCase):
    def test_namespace_matches_the_daemon(self):
        cpp = read("wifi/NmMapping.h")
        body = re.search(r"kNamespace\[16\] = \{(.*?)\}", cpp, re.S).group(1)
        got = bytes(int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", body))
        self.assertEqual(got, NAMESPACE.bytes)

    def test_matches_rfc4122_uuid5(self):
        for ssid in SSIDS:
            with self.subTest(ssid=ssid):
                self.assertEqual(bash_uuid(ssid), str(uuid.uuid5(NAMESPACE, ssid)))


if __name__ == "__main__":
    unittest.main()
