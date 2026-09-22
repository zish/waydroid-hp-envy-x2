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

# Named as packages, not just sonames: libgbinder.so.1 does not tell an operator
# which source package to watch for security updates, which is the whole reason
# these are packaged at all. Floors, not pins -- they are what the daemon was
# built and verified against, and gbinder_* carries no stable-ABI promise.
BUILDREQUIRES="pkgconfig(libgbinder) >= 1.1.47
pkgconfig(libglibutil) >= 1.0.82
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

# The daemon binary comes from the RPM's %build on a host that has
# libgbinder-devel, or from build/ via build-rpms.sh --prebuilt on a dev box
# that does not. wifi/build.sh is the deploy-over-ssh path and is not used here:
# it cross-builds against headers fetched from upstream tags and links against
# .so files copied off bigtab01, which is the right answer for a machine that
# cannot compile and the wrong one inside rpmbuild.
# What goes in this modification's source tarball. Named file by file rather
# than as the whole directory because artifacts/wifi also holds captured logs
# and the disassembled AIDL surface -- evidence, not payload.
#
# KNOWN GAP, found by actually building: artifacts/wifi/install.sh installs the
# daemon AND waydroid-wifi-sync unconditionally, so it cannot yet serve either
# modification alone -- an -ba build fails on unpackaged files. It needs the
# component-argument treatment artifacts/overlay/install.sh already has, with
# "all" as the default so the superseded waydroid-wifid.spec keeps working.
# Until then only --srpm is meaningful here. docs/47-package-split.md.
SOURCES="wifi
artifacts/wifi/install.sh
artifacts/wifi/waydroid-wifid.conf
artifacts/wifi/waydroid-wifid.service
artifacts/wifi/waydroid-wifi-nudge
artifacts/wifi/waydroid-wifi-share.conf
artifacts/wifi/waydroid-wifi-sync
artifacts/wifi/waydroid-wifi-sync.service
artifacts/wifi/waydroid-wifi-sync.timer"

BUILD='sh wifi/build.sh --rpm'

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} SYSCONFDIR=%{_sysconfdir} \
    WIFID_BIN=build/wifi/daemon/waydroid-wifid \
    sh artifacts/wifi/install.sh'

PAYLOAD_FILES='%{_bindir}/waydroid-wifid
%{_bindir}/waydroid-wifi-nudge
%{_unitdir}/waydroid-wifid.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-wifid.service
%config(noreplace) %{_sysconfdir}/waydroid-wifid.conf'
