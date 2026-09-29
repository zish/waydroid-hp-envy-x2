# waydroid-ext-pwd -- docs/56-pipewire-control.md
#
# Granular control of the host's PipeWire graph from inside Android: nodes,
# ports, links, volumes, defaults, device profiles and the graph quantum.
#
# WHY THIS IS NOT THE AUDIO WORK, AND SHIPS INDEPENDENTLY OF IT
#
# docs/44 is about the data plane and concluded that nobody should write a native
# PipeWire client for the guest, because pipewire-pulse already terminates the
# PulseAudio protocol and a native client would buy milliseconds against a HAL
# that spends 85 ms. That reasoning does not transfer to graph *control*: the
# PulseAudio protocol carries sinks, sources and sink-inputs -- a mixer -- and
# has no concept of a port or a link, so the container has no graph access at all
# today and there is no incumbent to improve on.
#
# Which is why this package touches nothing else: no overlay file, no vendor .so,
# no HAL, no SELinux policy, no image surface. It is a host daemon, and it can
# ship and be used before any of docs/44 is started.
#
# WHY A DAEMON AND NOT A MOUNTED SOCKET
#
# Bind-mounting /run/user/1000/pipewire-0 into the container was measured and
# rejected: access.socket is commented out in pipewire.conf so every client is
# pipewire.access=unrestricted, SELinux is Disabled inside the container so there
# is no per-app gate on a mounted path, and PipeWire cannot tell container apps
# apart anyway -- the Waydroid client's pipewire.sec.* props are
# pipewire-pulse's own. A token in the app's 0700 private directory is enforced
# by uid, which is the one boundary that actually holds here.
#
# WHY TWO BINARIES AND TWO UNITS
#
# waydroid-pwd needs no privilege at all: PipeWire is a user service, so it is a
# --user unit. The single thing that does need root -- writing the connection
# profile into the Android app's 0700 private directory -- is
# waydroid-pwd-publish, a system unit that holds no PipeWire connection. This is
# waydroid-ext-btd's own unit comment ("With --no-profile this could be a user
# unit") taken up rather than repeated.
#
# The Android half is NOT packaged here, for the reason no app in this repository
# is: building an APK needs the Android SDK and the Kotlin compiler, neither of
# which is a Fedora BuildRequires, and shipping a prebuilt one would be the
# vendored binary docs/54 rules out. pw-app/build.sh --install is the delivery
# mechanism, as bt-app/build.sh is for Bluetooth.

VERSION=1.2.1
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Control the host's PipeWire graph from Waydroid's Android"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir} and %{_userunitdir}. Same reason waydroid-ext-btd and
# waydroid-ext-wifid declare it.
BUILDREQUIRES="systemd-rpm-macros"

# Nothing here is a Python dependency: the daemon is stdlib-only, and every
# question it asks PipeWire goes through the CLI tools rather than a binding.
# That is deliberate -- `pw-dump -m` is already a delta protocol, so a binding
# would add a version coupling to the host's PipeWire for no capability.
#
# pipewire-utils provides pw-dump, pw-link, pw-metadata and pw-loopback;
# wireplumber provides wpctl; pipewire provides the `pipewire -c` used to host a
# module instance in its own process. All four verified on the host.
REQUIRES="waydroid
systemd
python3
pipewire
pipewire-utils
wireplumber"

DOCS="docs/56-pipewire-control.md
artifacts/pipewire/policy.conf.example
artifacts/pipewire/eq6-sink.conf.example"

DESCRIPTION="Exposes the host's PipeWire graph to an Android app running under Waydroid, so
the machine's audio routing can be driven from inside Android on a host that
has no desktop session to drive it from.

Under a kiosk compositor there is no host UI at all, so changing a sink,
making a link or lowering the graph quantum otherwise means an ssh session and
pw-link. This daemon mirrors the graph and carries out changes to it, while
every sample stays on the host side of the bridge -- nothing about the audio
path changes.

It needs no PipeWire bindings. 'pw-dump --monitor' already emits a delta
protocol: complete top-level JSON arrays, an initial snapshot and then one
array per change, with removals arriving as a null info. Acting on the graph
is likewise the shipped tools, addressed by numeric id throughout, because
pw-link's name form puts the node:port separator inside port names and cannot
be parsed back.

The transport is newline-delimited JSON over TCP on the container bridge, not
binder, because an ordinary Android app cannot reach an arbitrary binder name
-- non-SDK getService, a service_contexts edit and an untrusted_app find rule
all stand in the way. TLS is available and is pinned by certificate SHA-256
rather than CA-validated, there being no name to verify on a bridge.

What the app may do is a host-side policy, not the app's choice. Volume,
defaults, device profiles, links and the graph quantum are permitted by
default; links whose source is a capture device or a sink's monitor port are
not, because such a link is a recording tap and is mechanically
indistinguishable from any other link. Creating nodes, and hosting module
instances, are off by default too.

The daemon itself runs unprivileged as a systemd --user unit, because PipeWire
is a user service and there is nothing here root could do that the session
user could not. Only the profile publisher is root, and only because the
Android app's private directory is mode 0700 owned by the app's uid."

SOURCES="artifacts/pipewire/install.sh
artifacts/pipewire/policy.conf.example
artifacts/pipewire/waydroid-pwd
artifacts/pipewire/waydroid-pwd-publish
artifacts/pipewire/waydroid-pwd-publish.service
artifacts/pipewire/waydroid-pwd.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    USERUNITDIR=%{_userunitdir} sh artifacts/pipewire/install.sh'

# The policy ships as %doc and never into /etc. Two reasons and both matter: a
# policy file the package owned would silently change what an already-running
# deployment permits on upgrade, and a file in /etc that is never edited in place
# is exactly what rpmlint's non-conffile-in-etc objects to. The daemon's built-in
# defaults are the values the example documents, so a host with no
# /etc/waydroid-pwd/policy.conf behaves as it describes.
#
# No %dir for the state directory: the unit declares StateDirectory=, so systemd
# creates it (under the user's ~/.local/state for a --user unit) and owns its
# lifecycle. Packaging it would hand rpm a directory systemd manages.
PAYLOAD_FILES='%{_bindir}/waydroid-pwd
%{_bindir}/waydroid-pwd-publish
%{_userunitdir}/waydroid-pwd.service
%dir %{_userunitdir}/default.target.wants
%{_userunitdir}/default.target.wants/waydroid-pwd.service
%{_unitdir}/waydroid-pwd-publish.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-pwd-publish.service'
