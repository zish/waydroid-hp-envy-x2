# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""waydroid-restartd: which services it decides to signal, and its config.

stuck_services() is the decision that matters -- signalling the wrong pid in
the container is the failure to guard against -- so the property maps below
are shaped like real `getprop` output from the 2026-10-01 incident (docs/61),
where eight services were in STOPPING at once.
"""

import argparse
import os
import unittest
from unittest import mock

import _scripts

restartd = _scripts.load("artifacts/restartd/waydroid-restartd")


def cfg(**env):
    with mock.patch.dict(os.environ, env, clear=False):
        return restartd.Config(argparse.Namespace(dry_run=False, verbose=False))


class StuckServices(unittest.TestCase):
    def test_only_stopping_is_actionable(self):
        props = {
            "init.svc.netd": "stopping",   "init.svc_debug_pid.netd": "312",
            "init.svc.zygote": "running",  "init.svc_debug_pid.zygote": "400",
            # wificond's overlay .rc execs /system/bin/true: STOPPED is correct.
            "init.svc.wificond": "stopped",
            "init.svc.audioserver": "restarting",
        }
        self.assertEqual(restartd.stuck_services(props, cfg()), [("netd", 312)])

    def test_the_docs61_cascade(self):
        names = ["idmap2d", "zygote", "audioserver", "cameraserver", "media",
                 "netd", "vendor.audio-hal", "zygote_secondary"]
        props = {}
        for i, n in enumerate(names):
            props["init.svc." + n] = "stopping"
            props["init.svc_debug_pid." + n] = str(1000 + i)
        got = restartd.stuck_services(props, cfg())
        self.assertEqual([n for n, _ in got], sorted(names))
        self.assertTrue(all(isinstance(p, int) for _, p in got))

    def test_missing_or_bad_pid_is_reported_not_signalled(self):
        props = {"init.svc.a": "stopping",
                 "init.svc.b": "stopping", "init.svc_debug_pid.b": "",
                 "init.svc.c": "stopping", "init.svc_debug_pid.c": "12x"}
        self.assertEqual(restartd.stuck_services(props, cfg()),
                         [("a", None), ("b", None), ("c", None)])

    def test_exclude(self):
        props = {"init.svc.netd": "stopping", "init.svc_debug_pid.netd": "1",
                 "init.svc.media": "stopping", "init.svc_debug_pid.media": "2"}
        c = cfg(WAYDROID_RESTARTD_EXCLUDE="netd  zygote")
        self.assertEqual(restartd.stuck_services(props, c), [("media", 2)])

    def test_debug_pid_prefix_is_not_a_service(self):
        # "init.svc_debug_pid." does not start with "init.svc." -- the
        # underscore is what keeps a pid property from parsing as a service.
        props = {"init.svc_debug_pid.netd": "stopping"}
        self.assertEqual(restartd.stuck_services(props, cfg()), [])


class Config(unittest.TestCase):
    def test_defaults(self):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith("WAYDROID_RESTARTD_")}
        with mock.patch.dict(os.environ, env, clear=True):
            c = restartd.Config(argparse.Namespace(dry_run=False, verbose=False))
        # docs/61 argues against raising MAX_KILLS; pin the shipped breaker.
        self.assertEqual(c.max_kills, 8)
        self.assertEqual(c.breaker_window, 300.0)
        self.assertEqual(c.exclude, set())

    def test_garbage_env_falls_back(self):
        c = cfg(WAYDROID_RESTARTD_MAX_KILLS="lots",
                WAYDROID_RESTARTD_FAST_INTERVAL="")
        self.assertEqual(c.max_kills, 8)
        self.assertEqual(c.fast_interval, 0.2)

    def test_confirm_polls_floor(self):
        self.assertEqual(cfg(WAYDROID_RESTARTD_CONFIRM_POLLS="0").confirm_polls, 1)


class ReadProps(unittest.TestCase):
    def test_parses_getprop_output(self):
        out = ("[init.svc.netd]: [stopping]\n"
               "[ro.build.fingerprint]: [a/b:13/c]\n"
               "[empty]: []\n"
               "garbage line\n")
        with mock.patch.object(restartd, "attach", return_value=out):
            self.assertEqual(restartd.read_props(), {
                "init.svc.netd": "stopping",
                "ro.build.fingerprint": "a/b:13/c",
                "empty": "",
            })

    def test_failed_attach_is_none(self):
        with mock.patch.object(restartd, "attach", return_value=None):
            self.assertIsNone(restartd.read_props())


if __name__ == "__main__":
    unittest.main()
