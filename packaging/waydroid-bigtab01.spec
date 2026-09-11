# Spec for the host-side Waydroid integration built in this repository.
#
# STATUS: written 2026-09-07, NOT BUILT. There is no rpm toolchain on the dev box
# (no rpmbuild, no rpmspec) and layering one onto bigtab01 costs a reboot, so this
# has never been through rpmbuild -- not even a syntax parse. What HAS been checked
# is the payload: every installer below was run with DESTDIR into a scratch
# buildroot and the resulting tree matches the %files lists file for file, with no
# unsubstituted @BINDIR@ left anywhere. Treat %files as verified and everything
# else as unproven.
#
# Build a source tarball with:
#     git archive --format=tar.gz --prefix=waydroid-bigtab01-%{version}/ \
#         -o waydroid-bigtab01-%{version}.tar.gz HEAD
#
# WHY THE INSTALLERS ARE REUSED AS %install
#
# Each artifacts/*/install.sh honours DESTDIR, PREFIX and (where relevant) UNITDIR,
# SWAY_CONFD and SESSIONDIR, and suppresses its "installed, now do X" epilogue when
# DESTDIR is set. That keeps exactly one description of the layout, used by both the
# manual install on the immutable host and the package. See docs/25 and docs/27.
#
# The licence matches Waydroid's own source headers exactly -- 31 files under
# /usr/lib/waydroid/tools carry `SPDX-License-Identifier: GPL-3.0-or-later` -- so
# anything that migrates from this repository into Waydroid upstream raises no
# licensing question. Note Fedora's waydroid package tags itself GPL-3.0-only, which
# appears to understate upstream's own "or later"; the source headers are the
# authority on upstream's intent.
#
# None of the packaged content is derived from Waydroid: it is original shell and
# Python that calls waydroid and busctl. The licence is a choice, not an obligation.
# That is NOT true of everything in this repository -- sensors/waydroid-sensord keeps
# upstream's libgbinder ISensors server (docs/14) and is a derivative work -- but none
# of that is packaged here.

Name:           waydroid-bigtab01
Version:        1.0.0
Release:        1%{?dist}
Summary:        Host-side Waydroid integration for the HP Envy x2 (bigtab01)

License:        GPL-3.0-or-later
URL:            https://github.com/zish/bigtab01-waydroid
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

# For %{_unitdir} and %{_userunitdir}. Nothing here compiles; this is the only
# build-time dependency, and it is what keeps the unit paths distro-portable
# rather than hardcoded. See docs/36-packaging.md.
BuildRequires:  systemd-rpm-macros

# Everything here is shell and stdlib Python; nothing is compiled.
Requires:       waydroid
Requires:       systemd
Requires:       python3
Requires:       coreutils

%description
Host-side integration that makes Waydroid behave like the tablet this hardware is:
Android sleeps and locks when the machine suspends and wakes with it, and the
ITE8350 sensor hub is revived when it fails to come back from s2idle.

Contains no Android-side content. The camera, battery and sensor fixes this project
also produced live in the Waydroid vendor overlay and in a separate host daemon, and
are not packaged here.

%package        graceful-exit
Summary:        Shut Android down cleanly when a Waydroid session ends
Requires:       waydroid
Requires:       systemd
# Owns /usr/share/sway/config.d; this package installs into it without owning it.
# The package that owns it is distro-specific -- Fedora splits the distribution
# config out, others ship it in sway itself.
%if 0%{?fedora}
Requires:       sway-config-fedora
%else
Requires:       sway
%endif

%description    graceful-exit
Shuts Android down rather than killing it when the user logs out, both from a key
chord and from a graphical-session.target backstop that catches logouts bypassing
it. See docs/24.

%package        cage
Summary:        Run Waydroid as a full-screen kiosk session under cage
Requires:       cage
Requires:       %{name}-graceful-exit = %{version}-%{release}

%description    cage
An SDDM session that runs Waydroid full-screen under cage, with an entry check for
stale sessions and a watchdog that turns Android's own power-off into a session
exit. See docs/25.

%prep
%autosetup

%build
# Nothing to build.

%install
# UNITDIR is passed explicitly: the installers default to /etc/systemd/system, which
# is right for a manual install on an immutable host but is not a path an RPM may
# own. %{_unitdir} is labelled systemd_unit_file_t, so the reason the manual
# install avoids $PREFIX/lib (SELinux lib_t, which init_t may not start) does not
# apply here. docs/27 has the measurement.

DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/android-power/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/sensor-hub/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/container/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} SWAY_CONFD=%{_datadir}/sway/config.d \
    sh artifacts/graceful-exit/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} SESSIONDIR=%{_datadir}/wayland-sessions \
    sh artifacts/cage/install.sh

# NOT PACKAGED: artifacts/power/install-sleep-unit.sh. It is DESTDIR-ready and would
# slot in here unchanged, but it ships only the sleep and resume legs of the periodic
# sync feature, whose other half -- waydroid-sync, waydroid-bt-restore and the timer
# -- is not packaged and whose timer is deliberately left disabled pending testing
# (docs/06, docs/17). Shipping half a dormant feature would be worse than shipping
# none of it. Add it here together with the rest when that feature is finished.

%files
%license LICENSE
%doc docs/27-android-power-button.md docs/19-sensor-hub-suspend-wedge.md
%doc docs/40-binder-nice.md
%{_bindir}/waydroid-android-key
%{_bindir}/waydroid-android-lock
%{_bindir}/ite8350-resume-check
%{_unitdir}/waydroid-android-lock.service
%{_unitdir}/ite8350-sleep.service
%{_unitdir}/ite8350-resume-check.service
# Created by this package; systemd owns the parent but not this .wants directory.
%dir %{_unitdir}/sleep.target.wants
%{_unitdir}/sleep.target.wants/waydroid-android-lock.service
%{_unitdir}/sleep.target.wants/ite8350-sleep.service
# Likewise: the waydroid package owns waydroid-container.service, but nothing
# owns its drop-in directory until something drops a file in it. docs/40.
%dir %{_unitdir}/waydroid-container.service.d
%{_unitdir}/waydroid-container.service.d/nice-limit.conf

%files graceful-exit
%license LICENSE
%doc docs/24-graceful-logout.md
%{_bindir}/waydroid-graceful-exit
%{_userunitdir}/waydroid-graceful-exit.service
%dir %{_userunitdir}/graphical-session.target.wants
%{_userunitdir}/graphical-session.target.wants/waydroid-graceful-exit.service
%{_datadir}/sway/config.d/95-waydroid-graceful-exit.conf

%files cage
%license LICENSE
%doc docs/25-waydroid-in-cage.md
%{_bindir}/waydroid-cage-session
%{_datadir}/wayland-sessions/waydroid-cage.desktop

# No %post/%postun scriptlets anywhere on purpose. Units are enabled by the packaged
# .wants symlinks, and SELinux labels come from the rpm-ostree compose rather than
# from a restorecon in a scriptlet -- both requirements of an ostree host. See docs/25.

%changelog
* Mon Sep 07 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-1
- First spec. Payload verified by staging; never built.
