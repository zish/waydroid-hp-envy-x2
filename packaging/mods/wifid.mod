# waydroid-ext-wifid -- docs/31 through docs/35
#
# The host-side replacement for Android's wificond. Registers wifinl80211 and
# the supplicant on the container's binder and drives NetworkManager on the
# host, so Android's Wi-Fi settings control a real radio without the container
# ever owning a phy. WifiBackend.h is the seam: NmBackend is one implementation
# and iwd or connman could be others.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=x86_64

SUMMARY="Host-side wificond and supplicant for Waydroid, driving NetworkManager"

LICENSE="GPL-3.0-or-later"

# WHY THERE IS A %bcond, AND WHY THE DEFAULT IS THE SOURCE BUILD
#
# The same two arms as waydroid-ext-sensord and for the same reason: the daemon
# compiles against libgbinder-devel and libglibutil-devel, which are Fedora
# packages, and the dev box is Debian and cannot. The default arm is the real
# source build, because that is what a distribution builder runs and a source
# package that cannot be built from source is not one. `--prebuilt` selects the
# other arm, which packages the binary wifi/build.sh already produced, and is how
# this box can produce an installable RPM at all. packaging/README.md records
# which arm each recorded build used.
GLOBALS='%bcond_with prebuilt

# Both of these apply to the prebuilt arm ONLY; the source build a distribution
# runs is untouched and still produces a debuginfo package normally.
#
# debug_package: there is no source in this build tree for a debuginfo package to
# point at, and the extraction needs eu-strip, which Fedora has and the Debian dev
# box does not -- leaving it on makes the one build this box CAN do fail outright.
#
# __brp_strip: the point of the prebuilt arm is to ship the exact binary that was
# built and verified against bigtab01. Stripping it here would package something
# that is no longer byte-for-byte that file.
%if %{with prebuilt}
%global debug_package %{nil}
%global __brp_strip %{nil}
%endif'

# Named as packages, not just sonames: libgbinder.so.1 does not tell an operator
# which source package to watch for security updates, which is the whole reason
# these are packaged at all. Floors, not pins -- they are what the daemon was
# built and verified against, and gbinder_* carries no stable-ABI promise.
#
# The glib four carry no floor because nothing here needs one: wifi/build.sh
# --rpm asks pkg-config for them by name, and any version shipping the headers
# will do. They are named at all because without them the source build fails in
# %build rather than in the dependency solve, which is the more confusing failure.
BUILDREQUIRES="pkgconfig(libgbinder) >= 1.1.47
pkgconfig(libglibutil) >= 1.0.82
pkgconfig(glib-2.0)
pkgconfig(gobject-2.0)
pkgconfig(gio-2.0)
pkgconfig(gio-unix-2.0)
systemd-rpm-macros
gcc-c++"

# NetworkManager is hard: NmBackend::init() refuses to start without it on the
# system bus. It is also the one dependency this design exists to let somebody
# replace, which is why the backend is pluggable and why this is its own package.
REQUIRES="waydroid
systemd
NetworkManager"

# The other direction from waydroid-ext-wifi-hostd's hard Requires on this
# package, and deliberately not a Requires, so the pair is not a cycle: the
# daemon is independently testable against an image that has never had an
# overlay file, which is how Stage 2 was verified.
RECOMMENDS="waydroid-ext-wifi-hostd
waydroid-ext-wifi-framework"

DOCS="docs/user/lxc-config.md docs/user/overlay.md docs/29-wifi-plan.md docs/31-wifi-stage2.md docs/34-wifi-second-radio.md docs/35-wifi-stage5.md"

DESCRIPTION="Serves Android's Wi-Fi native interfaces -- IWificond, IClientInterface,
IWifiScannerImpl and the supplicant AIDL surface -- from the host, over the
binder node Waydroid already bind-mounts into the container, and satisfies them
from NetworkManager.

Android scans, associates, and reaches validated internet over a network it
believes it controls, while the radio stays the host's. Scan results are
synthesised down to the 802.11 beacon information elements Android parses
security out of, because NetworkManager keeps the conclusions and discards the
beacon.

The unit carries SELinuxContext=: systemd runs a bin_t binary as
unconfined_service_t, and the host policy denies binder { transfer } from
container_runtime_t to that domain, so every callback-passing call fails with a
bare DeadObjectException and the rule is dontaudited. On a distribution without
SELinux the directive is inert, which is correct."

# What goes in this modification's source tarball. Named file by file rather
# than as the whole directory because artifacts/wifi also holds captured logs
# and the disassembled AIDL surface -- evidence, not payload.
#
# artifacts/wifi/install.sh serves two modifications, so it is called below with
# the component argument it grew for exactly that: `wifid` installs the daemon,
# its unit and its conf, and none of waydroid-ext-wifi-sync's files. That is what
# makes an -ba build possible here at all -- while the installer laid down both
# halves, rpmbuild failed on the half %files did not list. Its default is still
# `all`, so the superseded packaging/waydroid-wifid.spec keeps building unchanged.
# docs/47-package-split.md.
#
# The reconciler's four files -- waydroid-wifi-sync, its service and timer, and
# waydroid-wifi-share.conf -- left this list with the modification they belong
# to. They were only ever here because the installer could not be told to leave
# them alone, and carrying them would mean a fix to a shell script on a timer
# changed this daemon's source package, which is the churn the split exists to
# stop.
SOURCES="wifi
artifacts/wifi/install.sh
artifacts/wifi/waydroid-wifid.conf
artifacts/wifi/waydroid-wifid.service
artifacts/wifi/waydroid-wifi-nudge"

# Staged into prebuilt/ by build-mod.sh --prebuilt; ignored otherwise. This is
# where a plain wifi/build.sh leaves its output, and staging it is the only way
# this Debian box can produce an installable waydroid-ext-wifid at all.
PREBUILT_FILES="build/wifi/daemon/waydroid-wifid"

# WHY THE SOURCE ARM DELEGATES WHERE sensord's WRITES THE COMPILE OUT
#
# waydroid-ext-sensord spells its g++ line out in its own .mod file. This one
# calls wifi/build.sh --rpm instead, and the difference is five source files
# against one: the file list and the link line keep exactly one home, so an rpm
# build and a by-hand build cannot come to disagree about what the daemon is made
# of.
#
# --rpm is the mode written for this. It locates libgbinder and libglibutil with
# pkg-config rather than from the upstream checkouts and host .so copies the
# other modes use, takes its optimisation and hardening flags from the rpm build
# environment, never clones, never scps, never touches bigtab01, and does not
# install -- it compiles and stops, because the install section below is where
# the layout lives. It refuses outright to be combined with the modes that do
# reach the network, so no future flag ordering can turn a package build into
# an ssh session.
#
# bash and not sh: wifi/build.sh is a bash script and uses arrays, so `sh` is a
# syntax error wherever /bin/sh is dash rather than bash -- which is where this
# repository is developed. bash is in rpm's own minimal buildroot, so naming it
# here costs no BuildRequires.
BUILD='%if %{with prebuilt}
# Built by wifi/build.sh and carried in the tarball by
# packaging/build-mod.sh --prebuilt. Copied to where the source arm leaves its
# output, so the install section names one path whichever arm ran.
test -x prebuilt/waydroid-wifid
mkdir -p build/wifi/daemon
cp -p prebuilt/waydroid-wifid build/wifi/daemon/waydroid-wifid
%else
bash wifi/build.sh --rpm
%endif'

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} SYSCONFDIR=%{_sysconfdir} \
    WIFID_BIN=build/wifi/daemon/waydroid-wifid \
    sh artifacts/wifi/install.sh wifid'

# Exactly the wifid half of what artifacts/wifi/install.sh lays down, which is
# what the `wifid` argument above installs and nothing more: waydroid-wifi-sync,
# its service and timer, its timers.target.wants symlink and
# /etc/waydroid-wifi-share.conf are waydroid-ext-wifi-sync's files, not these.
PAYLOAD_FILES='%{_bindir}/waydroid-wifid
%{_bindir}/waydroid-wifi-nudge
%{_unitdir}/waydroid-wifid.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-wifid.service
%config(noreplace) %{_sysconfdir}/waydroid-wifid.conf'
