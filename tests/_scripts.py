# Copyright 2026 Jeremy Melanson
# SPDX-License-Identifier: GPL-3.0-or-later
"""Import the project's extensionless daemons as modules.

The daemons under artifacts/ are installed as bare executables
(/usr/bin/waydroid-mediad, not waydroid_mediad.py), so `import` cannot find
them. Every one of them guards main() with `if __name__ == "__main__"`, so
loading one under any other name only defines its functions, which is what the
tests need.

waydroid-btd imports dbus and gi at module level and the dev box has neither.
Where the real bindings are missing, a minimal stand-in is installed: just
enough for the module body to execute, plus the two dbus types unwrap()
distinguishes. The tests that depend on dbus's real type hierarchy say so and
are worth re-running wherever python3-dbus is installed -- CI installs it.
"""

import importlib.machinery
import importlib.util
import os
import sys
import types

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def path(rel):
    return os.path.join(REPO, rel)


def load(rel):
    """Load repo-relative script `rel` as a fresh module."""
    name = "_t_" + os.path.basename(rel).replace("-", "_").replace(".", "_")
    loader = importlib.machinery.SourceFileLoader(name, path(rel))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


def have_real_dbus():
    try:
        import dbus  # noqa: F401
        import gi    # noqa: F401
    except ImportError:
        return False
    return not getattr(sys.modules["dbus"], "_IS_STUB", False)


def install_dbus_stub():
    """Stand-ins for dbus-python and PyGObject, only where they are absent."""
    if have_real_dbus():
        return False

    dbus = types.ModuleType("dbus")
    dbus._IS_STUB = True

    class DBusException(Exception):
        _dbus_error_name = None

        def get_dbus_name(self):
            return self._dbus_error_name

    # The real classes subclass int and bytes, which is the whole reason
    # unwrap() orders its tests the way it does.
    class Boolean(int):
        pass

    class ByteArray(bytes):
        pass

    dbus.DBusException = DBusException
    dbus.Boolean = Boolean
    dbus.ByteArray = ByteArray
    for attr in ("SystemBus", "Interface", "ObjectPath", "String",
                 "Dictionary", "Array", "UInt32", "Int16", "Byte"):
        setattr(dbus, attr, type(attr, (object,), {}))

    service = types.ModuleType("dbus.service")

    class Object(object):
        def __init__(self, *a, **kw):
            pass

    def method(*a, **kw):
        return lambda fn: fn

    service.Object = Object
    service.method = method
    service.signal = method
    dbus.service = service

    mainloop = types.ModuleType("dbus.mainloop")
    glib = types.ModuleType("dbus.mainloop.glib")
    glib.DBusGMainLoop = lambda *a, **kw: None
    mainloop.glib = glib
    dbus.mainloop = mainloop

    gi = types.ModuleType("gi")
    repo = types.ModuleType("gi.repository")
    noop = lambda *a, **kw: None
    repo.GLib = types.SimpleNamespace(unix_signal_add=noop, MainLoop=noop,
                                      idle_add=noop, timeout_add=noop,
                                      PRIORITY_DEFAULT=0)
    # PyGObject 3.56 moved unix_signal_add to GLibUnix; btd tries both.
    repo.GLibUnix = types.SimpleNamespace(signal_add=noop)
    gi.repository = repo

    sys.modules.update({
        "dbus": dbus, "dbus.service": service, "dbus.mainloop": mainloop,
        "dbus.mainloop.glib": glib, "gi": gi, "gi.repository": repo,
    })
    return True
