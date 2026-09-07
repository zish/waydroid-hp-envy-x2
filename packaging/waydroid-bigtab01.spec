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
# FIXME: the repository has no LICENSE file. The tag below is a PLACEHOLDER and must
# be confirmed before this is built or distributed anywhere.

Name:           waydroid-bigtab01
Version:        1.0.0
Release:        1%{?dist}
Summary:        Host-side Waydroid integration for the HP Envy x2 (bigtab01)

License:        GPL-3.0-or-later
URL:            https://github.com/zish/bigtab01-waydroid
Source0:        %{name}-%{version}.tar.gz

BuildArch:      noarch

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
Requires:       sway-config-fedora

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
# own. /usr/lib/systemd/system is labelled systemd_unit_file_t, so the reason the
# manual install avoids $PREFIX/lib (SELinux lib_t, which init_t may not start) does
# not apply here. docs/27 has the measurement.
%global waydroid_units %{_prefix}/lib/systemd/system

DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{waydroid_units} \
    sh artifacts/android-power/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{waydroid_units} \
    sh artifacts/sensor-hub/install.sh

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
%doc docs/27-android-power-button.md docs/19-sensor-hub-suspend-wedge.md
%{_bindir}/waydroid-android-key
%{_bindir}/waydroid-android-lock
%{_bindir}/ite8350-resume-check
%{waydroid_units}/waydroid-android-lock.service
%{waydroid_units}/ite8350-sleep.service
%{waydroid_units}/ite8350-resume-check.service
# Created by this package; systemd owns the parent but not this .wants directory.
%dir %{waydroid_units}/sleep.target.wants
%{waydroid_units}/sleep.target.wants/waydroid-android-lock.service
%{waydroid_units}/sleep.target.wants/ite8350-sleep.service

%files graceful-exit
%doc docs/24-graceful-logout.md
%{_bindir}/waydroid-graceful-exit
%{_prefix}/lib/systemd/user/waydroid-graceful-exit.service
%dir %{_prefix}/lib/systemd/user/graphical-session.target.wants
%{_prefix}/lib/systemd/user/graphical-session.target.wants/waydroid-graceful-exit.service
%{_datadir}/sway/config.d/95-waydroid-graceful-exit.conf

%files cage
%doc docs/25-waydroid-in-cage.md
%{_bindir}/waydroid-cage-session
%{_datadir}/wayland-sessions/waydroid-cage.desktop

# No %post/%postun scriptlets anywhere on purpose. Units are enabled by the packaged
# .wants symlinks, and SELinux labels come from the rpm-ostree compose rather than
# from a restorecon in a scriptlet -- both requirements of an ostree host. See docs/25.

%changelog
* Mon Sep 07 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-1
- First spec. Payload verified by staging; never built.
