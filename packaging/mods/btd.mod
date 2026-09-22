# waydroid-ext-btd -- docs/50-bluetooth.md
#
# Waydroid's image has no Bluetooth app and no vendor HAL: com.android.btservices
# is present and BluetoothManagerService has been trying since boot, but
# Bluetooth.apk itself is absent, so the framework can never come up. Handing
# the container hci0 was rejected for the same reason docs/28 rejected handing
# it the Wi-Fi phy -- it is the only controller, and the owner's keyboard is
# paired to it.
#
# So the host keeps the radio and Android gets a client. This is the host half:
# a daemon that is a D-Bus client AND server to BlueZ. The server half is not
# optional -- a pairing prompt is BlueZ calling OUT to an org.bluez.Agent1
# object, which is what rules out busctl (it cannot serve an object) and rules
# out scraping bluetoothctl (it registers a competing agent).
#
# The Android half is a separate modification: it is an APK with its own build,
# its own release cadence and no host dependencies, and coupling them would
# reissue one every time the other changed.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Manage the host's BlueZ from Waydroid's Android, over the container bridge"

LICENSE="GPL-3.0-or-later"

# dbus-python and PyGObject are hard: the daemon exports an org.bluez.Agent1
# object and runs a GLib main loop, so neither is substitutable for the other
# and neither is optional. bluez provides bluetoothd, which is the entire
# subject of the daemon -- without it there is nothing on the bus to manage.
# For %{_unitdir}. Same reason waydroid-ext-wifid declares it.
BUILDREQUIRES="systemd-rpm-macros"

REQUIRES="waydroid
systemd
bluez
python3
python3-dbus
python3-gobject-base"

DOCS="docs/50-bluetooth.md"

DESCRIPTION="Exposes the host's BlueZ to an Android app running under Waydroid, so a
headset or a keyboard can be paired from inside Android on a host that has no
desktop session to pair it from.

Under a kiosk compositor there is no host UI at all, so pairing otherwise means
an ssh session and bluetoothctl. This daemon scans, pairs, connects, trusts and
forgets devices on the host's controller and reports adapter and device state
back, while the controller stays the host's throughout.

It is a D-Bus server as well as a client, because a pairing prompt is BlueZ
calling out to an org.bluez.Agent1 object that somebody must export. The agent
registers as KeyboardDisplay, so modern devices get numeric comparison. Every
device verb is asynchronous: Pair() blocks until pairing completes and its
agent callbacks arrive on the same connection, so a blocking call would
deadlock against its own prompt.

The transport is newline-delimited JSON over TCP on the container bridge, not
binder, because an ordinary Android app cannot reach an arbitrary binder name
-- non-SDK getService, a service_contexts edit and an untrusted_app find rule
all stand in the way. TLS is available and is pinned by certificate SHA-256
rather than CA-validated, there being no name to verify on a bridge.

It runs as root for exactly one reason, and the obvious guess is wrong: BlueZ
is not polkit-gated here, so an unprivileged caller could pair perfectly well.
What needs root is writing the connection profile into the Android app's
private directory, which is owned by the app's uid and mode 0700. With
--no-profile this could be a user unit."

SOURCES="artifacts/bluetooth/install.sh
artifacts/bluetooth/waydroid-btd
artifacts/bluetooth/waydroid-btd.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/bluetooth/install.sh'

# No %dir for the state directory: the unit declares StateDirectory=, so
# systemd creates /var/lib/waydroid-btd with mode 0700 at start and owns its
# lifecycle. Packaging it too would hand rpm a directory systemd manages.
PAYLOAD_FILES='%{_bindir}/waydroid-btd
%{_unitdir}/waydroid-btd.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-btd.service'
