# Spec for the host-side Wi-Fi daemon built in this repository.
#
# STATUS: written 2026-09-09. See packaging/README.md for what has and has not
# been through rpmbuild.
#
# WHY THIS IS ITS OWN PACKAGE
#
# Same three reasons as waydroid-sensord -- compiled, so arch-specific; its own
# libgbinder/libglibutil dependency set; and a licence story of its own -- plus
# one this daemon has alone: it is the only thing here that depends on
# NetworkManager, and that dependency is a CHOICE the design is built to allow
# reversing. WifiBackend.h is a pluggable seam, NmBackend is one implementation,
# and an iwd or connman backend would ship as a different subpackage against a
# different Requires. Folding it into a general "integration" package would bury
# that.
#
# Unlike waydroid-sensord, none of this is derived from anything: the AIDL wire
# format was disassembled from the running image (docs/30-wifi-aidl-surface.md),
# not copied from AOSP.
#
# MIGRATION TRAP. Same as waydroid-sensord: the by-hand install puts the binary
# in /usr/local/bin, which precedes /usr/bin on root's PATH, and the by-hand
# unit in /etc/systemd/system, which OVERRIDES the packaged unit in
# /usr/lib/systemd/system entirely. An /etc unit left behind means the package
# can be upgraded forever with no effect. Remove both first:
#     systemctl disable --now waydroid-wifid waydroid-wifi-sync.timer
#     rm -f /etc/systemd/system/waydroid-wifid.service \
#           /etc/systemd/system/waydroid-wifi-sync.{service,timer} \
#           /usr/local/bin/waydroid-wifi{d,-nudge,-sync}
#
# THE SELinux LINE IS LOAD-BEARING. waydroid-wifid.service carries
# SELinuxContext=system_u:unconfined_r:unconfined_t:s0, and without it the
# daemon runs as unconfined_service_t, where the host policy DENIES
# binder { transfer } from container_runtime_t -- so every call carrying a
# callback fails with a bare DeadObjectException and the rule is dontaudit'ed,
# leaving nothing in the audit log. Do not "clean up" that directive. The full
# measurement is in docs/35-wifi-stage5.md.

# DISTRO PORTABILITY
#
# One spec, several RPM distros -- see docs/36-packaging.md, "One spec set, many
# distros". The three levers used here:
#
#   * pkgconfig() BuildRequires instead of -devel package names. Fedora calls it
#     libgbinder-devel; another distro may call it libgbinder1-devel or ship it
#     inside libgbinder. All of them provide pkgconfig(libgbinder), because the
#     .pc file is in the payload, so this asks for the thing rather than for
#     somebody's name for it.
#   * %{_unitdir} instead of a hardcoded /usr/lib/systemd/system.
#   * Explicit runtime Requires only where the package name is known to be
#     right, with rpm's own ELF-generated soname dependencies carrying the rest
#     everywhere else -- correct on every distro, just less legible.
#
# BUILDING WITHOUT A FEDORA BUILDER
#
# `--with prebuilt` packages a binary that wifi/build.sh already produced, instead of
# compiling in %%build. It exists because of where this project can build: the
# dev box has no Fedora toolchain and no working container runtime, and bigtab01
# itself is an 8 GB immutable host where a toolchain costs a layered install and
# a reboot. The default is still a real source build -- use it on any Fedora
# machine or in mock. A prebuilt package is honest about what it is: rpm still
# reads the ELF and generates the same soname dependencies.
%bcond_with prebuilt

Name:           waydroid-wifid
Version:        1.0.0
Release:        1%{?dist}
Summary:        Host-side Wi-Fi native services for Waydroid's Android container

License:        GPL-3.0-or-later
URL:            https://github.com/zish/bigtab01-waydroid
Source0:        waydroid-bigtab01-%{version}.tar.gz

%if %{without prebuilt}
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  pkgconfig(libgbinder) >= 1.1.47
BuildRequires:  pkgconfig(libglibutil) >= 1.0.82
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gobject-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gio-unix-2.0)
%endif
BuildRequires:  systemd-rpm-macros

Requires:       waydroid
# The backend. NmBackend::init() refuses to start if NetworkManager is not
# answering on the system bus, so this is a hard dependency of the only backend
# that currently exists -- see the header above.
Requires:       NetworkManager
# As in waydroid-sensord: rpm generates the soname dependencies itself; these
# name the packages behind them so a patch-level question has a direct answer.
%if 0%{?fedora} || 0%{?rhel}
Requires:       libgbinder%{?_isa} >= 1.1.47
Requires:       libglibutil%{?_isa} >= 1.0.82
Requires:       glib2%{?_isa}
%endif
# Elsewhere these are left to rpm's ELF scan, which emits libgbinder.so.1 and
# friends and is satisfied by whatever package provides them under whatever name
# that distro uses. Nothing is lost but the readability of `rpm -q --requires`.
Requires:       systemd
%{?systemd_requires}

# Android's Wi-Fi framework stays dormant without the overlay files that declare
# the feature and stand the guest's own wificond down -- see
# waydroid-overlay-wifi, which requires this package back. Recommends, not
# Requires, because the pair is deliberately not a cycle: the daemon is
# independently testable (bin/wifi-test.sh) against an image that has never had
# an overlay file, and that is how Stage 2 was verified.
Recommends:     waydroid-overlay-wifi

%description
Serves the native Wi-Fi interfaces Android's framework expects -- IWificond,
IClientInterface, IWifiScannerImpl and the supplicant AIDL surface -- from the
host over binder, and drives NetworkManager instead of a radio the container
cannot see. Android's own Wi-Fi settings scan, connect and roam; NetworkManager
owns the credentials and the hardware.

Replaces the guest's wificond rather than talking to it: wlp1s0 is this
machine's only built-in interface, and handing its phy to the container would
cost the host its network.

%package        sync
Summary:        Reconcile Wi-Fi credentials between NetworkManager and Android
Requires:       %{name} = %{version}-%{release}
Requires:       waydroid
Requires:       NetworkManager

%description    sync
Copies the passphrases of explicitly opted-in networks from NetworkManager into
Android, on a timer and when Android turns Wi-Fi on, so a network joined on the
host does not have to be typed again in the container.

Nothing is shared until a network is named in /etc/waydroid-wifi-share.conf,
which is installed empty and 0600 -- it is the audit trail for which
credentials leave the host.

%prep
%autosetup -n waydroid-bigtab01-%{version}

%build
%if %{with prebuilt}
# Built by wifi/build.sh and carried in the source tarball by
# packaging/build-rpms.sh --prebuilt.
test -x prebuilt/waydroid-wifid
cp -p prebuilt/waydroid-wifid waydroid-wifid
%else
# Not wifi/build.sh -- see the same note in waydroid-sensord.spec. Same flags,
# system headers instead of vendored ones.
g++ %{optflags} -std=gnu++17 -pthread \
    -ffunction-sections -fdata-sections \
    -Iwifi \
    $(pkg-config --cflags libgbinder libglibutil glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0) \
    wifi/NativeScanResult.cpp wifi/NmBackend.cpp wifi/Supplicant.cpp \
    wifi/Wificond.cpp wifi/service.cpp \
    -o waydroid-wifid \
    -Wl,--gc-sections -static-libstdc++ -static-libgcc \
    $(pkg-config --libs libgbinder libglibutil glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0) \
    -lpthread

%endif

%install
# UNITDIR is passed explicitly: the installer defaults to /etc/systemd/system,
# which is right for a manual install on an immutable host but is not a path an
# RPM may own. %{_unitdir} comes from systemd-rpm-macros and is correct on every
# distro this targets. See the same note in packaging/waydroid-bigtab01.spec.
DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    SYSCONFDIR=%{_sysconfdir} WIFID_BIN=waydroid-wifid \
    sh artifacts/wifi/install.sh

%files
%license LICENSE
%doc docs/31-wifi-stage2.md docs/32-wifi-stage3.md docs/34-wifi-second-radio.md
%doc docs/35-wifi-stage5.md
%{_bindir}/waydroid-wifid
%{_bindir}/waydroid-wifi-nudge
%{_unitdir}/waydroid-wifid.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-wifid.service
# noreplace: this file names the radio to hand Android. Overwriting an
# operator's --device on upgrade could hand Android the host's own link.
%config(noreplace) %{_sysconfdir}/waydroid-wifid.conf

%files sync
%license LICENSE
%{_bindir}/waydroid-wifi-sync
%{_unitdir}/waydroid-wifi-sync.service
%{_unitdir}/waydroid-wifi-sync.timer
%dir %{_unitdir}/timers.target.wants
%{_unitdir}/timers.target.wants/waydroid-wifi-sync.timer
# noreplace and 0600: the list of networks whose passphrases may be copied into
# the container. An upgrade must never silently widen or narrow it.
%config(noreplace) %attr(0600,root,root) %{_sysconfdir}/waydroid-wifi-share.conf

# No %post/%postun scriptlets: units are enabled by the packaged .wants symlinks
# and SELinux labels come from the compose. Same rule as waydroid-bigtab01.

%changelog
* Tue Sep 09 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-1
- First spec. Stage 5's systemd unit, credential sync split into a subpackage.
