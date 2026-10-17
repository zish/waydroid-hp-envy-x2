# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""waydroid-btd's protocol negotiation and the helpers around it.

negotiate_api() is the contract docs/58 describes: its reason strings are what
the app shows the user, so they are pinned here verbatim.
"""

import os
import stat
import subprocess
import tempfile
import unittest

import _scripts

STUBBED = _scripts.install_dbus_stub()
btd = _scripts.load("artifacts/bluetooth/waydroid-btd")
btd.log = lambda message: None
dbus = __import__("dbus")


class ApiRange(unittest.TestCase):
    def test_absent_means_api_1(self):
        # Every app built before negotiation existed sends no range.
        self.assertEqual(btd.api_range({}), (1, 1))

    def test_explicit(self):
        self.assertEqual(btd.api_range({"api_min": 1, "api_max": 3}), (1, 3))

    def test_malformed_falls_back_rather_than_raising(self):
        for bad in ("2", 2.0, None, True, [2]):
            self.assertEqual(btd.api_range({"api_min": bad, "api_max": bad}),
                             (1, 1), repr(bad))


class NegotiateApi(unittest.TestCase):
    def test_overlap_picks_highest_common(self):
        self.assertEqual(btd.negotiate_api(1, 99), (btd.API_MAX, None))
        self.assertEqual(btd.negotiate_api(btd.API_MIN, btd.API_MIN),
                         (btd.API_MIN, None))

    def test_reasons(self):
        self.assertEqual(btd.negotiate_api(3, 2), (None, "app_range_invalid"))
        self.assertEqual(btd.negotiate_api(btd.API_MAX + 1, btd.API_MAX + 5),
                         (None, "app_too_new"))
        if btd.API_MIN > 1:
            self.assertEqual(btd.negotiate_api(0, btd.API_MIN - 1),
                             (None, "app_too_old"))
        self.assertEqual(btd.negotiate_api(-5, 0), (None, "app_too_old"))


class Unwrap(unittest.TestCase):
    def test_boolean_before_int(self):
        # dbus.Boolean subclasses int; tested the other way round every
        # boolean on the wire becomes 0/1.
        self.assertIs(btd.unwrap(dbus.Boolean(1)), True)
        self.assertIs(btd.unwrap(dbus.Boolean(0)), False)

    def test_bytes_become_int_lists(self):
        self.assertEqual(btd.unwrap(dbus.ByteArray(b"\x01\xff")), [1, 255])
        self.assertEqual(btd.unwrap(b"ab"), [97, 98])

    def test_nested(self):
        got = btd.unwrap({"Paired": dbus.Boolean(1), "RSSI": -60,
                          "UUIDs": ("a", "b"), "Data": {1: b"\x00"}})
        self.assertEqual(got, {"Paired": True, "RSSI": -60,
                               "UUIDs": ["a", "b"], "Data": {"1": [0]}})


class Token(unittest.TestCase):
    def test_generated_once_and_private(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "sub", "token")
            first = btd.ensure_token(path)
            self.assertRegex(first, r"^[0-9a-f]{64}$")
            self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)
            self.assertEqual(btd.ensure_token(path), first)

    def test_empty_file_is_replaced(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "token")
            open(path, "w").close()
            self.assertRegex(btd.ensure_token(path), r"^[0-9a-f]{64}$")


@unittest.skipUnless(subprocess.run(["sh", "-c", "command -v openssl"],
                                    capture_output=True).returncode == 0,
                     "openssl not installed")
class Tls(unittest.TestCase):
    def test_fingerprint_matches_openssl(self):
        # The app pins this value, so it must be the SHA-256 of the DER
        # certificate -- the same number `openssl x509 -fingerprint` prints.
        with tempfile.TemporaryDirectory() as tmp:
            cert, key = btd.ensure_tls_material(tmp, None, None, "192.168.240.1")
            self.assertEqual(stat.S_IMODE(os.stat(key).st_mode), 0o600)
            out = subprocess.run(
                ["openssl", "x509", "-in", cert, "-noout", "-fingerprint",
                 "-sha256"], capture_output=True, text=True, check=True).stdout
            want = out.split("=", 1)[1].strip().replace(":", "").lower()
            self.assertEqual(btd.cert_fingerprint(cert), want)
            # Second call reuses rather than regenerating -- a new cert would
            # break every app that pinned the old one.
            self.assertEqual(btd.ensure_tls_material(tmp, None, None, "x"),
                             (cert, key))


if __name__ == "__main__":
    unittest.main()
