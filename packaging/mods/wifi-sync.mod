# waydroid-ext-wifi-sync -- docs/36-wifi-credential-sync.md
#
# Makes NetworkManager the source of truth for the Wi-Fi networks Android knows
# about. waydroid-wifid carries credentials in ONE direction: Android keeps its
# own copy of every passphrase, pushes it down on each connect, and the daemon
# calls Update on the NM profile -- so NM is a write-through projection of
# Android's config, a host-side edit is silently overwritten, and a network
# joined on the host is invisible to Android entirely.
#
# WHY THIS IS NOT PART OF waydroid-ext-wifid
#
# It is a different thing on a different clock. The daemon is a compiled binary
# that serves binder interfaces; this is a shell script on a five-minute timer
# that drives nmcli and `waydroid shell`. They fail differently, they are
# debugged differently, and a fix to the reconciler has no business reissuing a
# C++ daemon that has been running untouched -- which is what the single
# waydroid-wifid.spec, with its `sync` subpackage, did. docs/47-package-split.md.
#
# WHY THE SUPPLICANT SEAM COULD NOT DO IT
#
# The supplicant AIDL has no "here are my saved networks" direction and Android
# never asks -- listNetworks() concerns the supplicant's transient list, not
# saved config. No amount of work on the daemon's shim would help. Android's own
# `cmd wifi add-network` does exactly this job, so the reconciliation lives on
# the host and reaches in, in the same shape as waydroid-wifi-nudge.
#
# NOTHING IS SHARED UNTIL IT IS NAMED, AND THAT FILE IS THE AUDIT TRAIL
#
# Importing a network copies its passphrase into Android's WifiConfigStore.xml,
# which is cleartext at rest, and a laptop accumulates conference and
# coffee-shop credentials that have no business inside a container. So the
# package installs /etc/waydroid-wifi-share.conf at 0600 with no network named in
# it -- the shipped file is comments and nothing else -- and does nothing at all
# until an SSID is written into it. A per-profile NM marker was
# the intended design and Fedora's NetworkManager is built without the `user`
# setting, so it was impossible -- and the one file turned out to be the better
# answer anyway, because you can read every passphrase that has left the host
# out of a single file.
#
# WHY THE TIMER IS ENABLED AND THE SERVICE IS NOT
#
# The installer ships the timers.target.wants symlink and NOT a
# multi-user.target.wants one. Enabling the service would fire one
# reconciliation at boot before anybody has opted a network in. The daemon also
# asks for a run when Android turns Wi-Fi on, through `systemctl start
# --no-block`, and that call is designed to fail silently: a host with this
# package absent must still bring Wi-Fi up normally.

VERSION=1.0.0
RELEASE=1
KIND=host

# noarch, unlike waydroid-ext-wifid: this half is a shell script, two units and
# a conf file, with nothing compiled in it.
ARCH=noarch

SUMMARY="Reconcile Wi-Fi credentials between NetworkManager and Android"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason waydroid-ext-wifid and waydroid-ext-btd declare it.
BUILDREQUIRES="systemd-rpm-macros"

# waydroid-ext-wifid is hard, and it is the same edge the superseded
# waydroid-wifid.spec drew when this was its `sync` subpackage: the networks
# being imported are credentials for a Wi-Fi stack that only exists because the
# daemon serves it, and the daemon is also what asks for a sync when Android
# turns Wi-Fi on. Not a cycle -- the daemon does not require this package back,
# because it has to stay testable and useful with nothing opted in.
#
# NetworkManager is hard for a second reason than the daemon's: this reads
# passphrases out of profiles with `nmcli -s -g 802-11-wireless-security.psk`,
# so nmcli itself is the dependency and not just a running service. bash and
# waydroid likewise are what the script is written in and what it talks to --
# rpm's script generator would find /bin/bash on its own, and naming it keeps
# `rpm -q --requires` answerable without reading the payload.
#
# The rest are the remaining programs the reconciler execs, grepped out of it
# rather than guessed, because a missing one is a sync that fails on a host where
# everything looks installed:
#
#   gawk             awk, five invocations: the parse of `cmd wifi
#                    list-networks` and every nmcli field split.
#   sed              strips waydroid's own chatter out of every `waydroid shell`
#                    answer, so without it every comparison reads the noise.
#   grep             the -o 'dev [^ ]*' naming the default-route interface, and
#                    the -qxF membership test against Android's list.
#   coreutils        id, tr, head, mkdir, dirname.
#   iproute          `ip -o route get 1.1.1.1` finds the interface carrying the
#                    host's default route, one of the four guards on deleting a
#                    profile.
#   util-linux-core  flock, and not optional: the timer and the daemon's
#                    Wi-Fi-enable trigger can fire together, and two runs racing
#                    interleave their reads of the state file that licenses
#                    DELETIONS. Without flock that guard silently does nothing.
REQUIRES="waydroid
waydroid-ext-wifid
systemd
NetworkManager
bash
gawk
sed
grep
coreutils
iproute
util-linux-core"

DOCS="docs/36-wifi-credential-sync.md"

DESCRIPTION="Copies the passphrases of explicitly opted-in networks from NetworkManager into
Android, on a five-minute timer and whenever Android turns Wi-Fi on, so a
network joined on the host does not have to be typed again in the container --
and deletes the host profile when the corresponding network is forgotten in
Android, so the two sides can be kept in step in both directions.

Nothing is shared until a network is named in /etc/waydroid-wifi-share.conf,
which is installed at mode 0600 with no network in it -- the shipped file is
comments. That file is the audit trail for which credentials have left the
host, and until something is added to it this package is inert.

Deleting NetworkManager profiles is the dangerous half, so it is guarded four
ways: never a profile active on any device, never one pinned to the interface
carrying the host's default route, never the daemon's own (Waydroid) profiles,
and never more than one network per run -- a wholesale disappearance is a wiped
Android config store, not somebody forgetting networks one at a time. An
allow-list line may also carry nodelete, which shares the network and never
lets a forget in Android remove the host's profile; that is the right setting
for any network the host itself depends on.

It adds networks Android does not have and never overwrites one it does. The
cost, which is real: a passphrase changed on the host does not reach a network
Android already knows, and the way to get it there is to forget the network in
Android and let the next run import it afresh. Overwriting instead would push
the host's key-mgmt onto a working connection using a mapping already known to
be unreliable here, where the host joins with wpa-psk and Android over the
second adapter can only complete the handshake with SAE."

# Only the reconciler's own files. artifacts/wifi/install.sh is shared with
# waydroid-ext-wifid and takes a component argument for exactly that reason; the
# daemon, its unit, waydroid-wifi-nudge and /etc/waydroid-wifid.conf are that
# package's and are deliberately absent from this tarball.
SOURCES="artifacts/wifi/install.sh
artifacts/wifi/waydroid-wifi-sync
artifacts/wifi/waydroid-wifi-sync.service
artifacts/wifi/waydroid-wifi-sync.timer
artifacts/wifi/waydroid-wifi-share.conf"

# No WIFID_BIN, unlike waydroid-ext-wifid's %install: the wifi-sync component
# never looks at the daemon binary, which is what makes this modification
# buildable on a box that cannot compile the daemon at all.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} SYSCONFDIR=%{_sysconfdir} \
    sh artifacts/wifi/install.sh wifi-sync'

# Exactly the tree `install.sh wifi-sync` produces, verified by running it into a
# scratch DESTDIR. Same list the superseded waydroid-wifid.spec's `sync`
# subpackage carried, which is the point of the split.
#
# noreplace and 0600 on the allow-list: it is the record of which networks may
# have their passphrases copied into the container, and an upgrade must never
# silently widen or narrow it. %attr because rpm would otherwise take the mode
# from the buildroot -- which is 0600 today, and should not have to stay right
# by accident. It is also the only file here under /etc, so it is the only one
# packaging/test-install.sh's %config rule has anything to say about.
PAYLOAD_FILES='%{_bindir}/waydroid-wifi-sync
%{_unitdir}/waydroid-wifi-sync.service
%{_unitdir}/waydroid-wifi-sync.timer
%dir %{_unitdir}/timers.target.wants
%{_unitdir}/timers.target.wants/waydroid-wifi-sync.timer
%config(noreplace) %attr(0600,root,root) %{_sysconfdir}/waydroid-wifi-share.conf'
