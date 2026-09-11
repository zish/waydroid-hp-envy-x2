# Spec for the Waydroid overlay content built in this repository.
#
# STATUS: written 2026-09-09. See packaging/README.md for what has and has not
# been through rpmbuild.
#
# WHAT THESE PACKAGES DELIBERATELY DO NOT DO
#
# They do not own a single file in /var/lib/waydroid/overlay. Everything ships
# into %{_datadir}/waydroid-overlay and waydroid-overlay-sync copies it across,
# driven by a unit that runs before waydroid-container.service on every boot.
# Three reasons, and the first is the one that matters:
#
#   1. The overlay is STATE. `waydroid init -f`, an image upgrade, a container
#      rebuild or a restore of /var can empty it, and none of those are package
#      operations, so no amount of %files would notice. A boot-time reconcile
#      does, without anyone watching.
#   2. On an rpm-ostree host, /var is outside the deployment entirely. Files a
#      package ships there are not in the ostree commit and do not come back
#      with a rollback -- so /var is precisely the wrong place to put content
#      whose integrity you want the package manager to guarantee. /usr is right,
#      and /usr is read-only, which is what makes it a trustworthy source.
#   3. The overlay directory is the lowerdir of an overlayfs mount that
#      waydroid-container.service creates at container start. Files added to it
#      afterwards are invisible to Android with no error anywhere. Deployment
#      therefore has to be ordered against the container, which is a unit's job
#      and not a %post's.
#
# ONE COMPONENT PER SUBPACKAGE, because they are independent fixes to
# independent subsystems with different reasons to be installed or not: a host
# with no camera wants none of the camera payload, and the Widevine CDM is the
# one piece here with a licence question attached.
#
# THE PAYLOAD IS ANDROID BINARIES. rpm's automatic dependency generator would
# read those ELF files and emit unsatisfiable Requires -- libutils.so()(64bit)
# and friends, which no Fedora package provides -- making the packages
# uninstallable. The exclusions below are why that does not happen, and they are
# scoped to the payload directory so the manager's shell script still gets its
# ordinary /bin/sh dependency.

%global overlay_dir %{_datadir}/waydroid-overlay

%global __requires_exclude_from ^%{overlay_dir}/.*$
%global __provides_exclude_from ^%{overlay_dir}/.*$
# Foreign ELF: nothing here is ours to strip, and brp-strip would either mangle
# it or fail the build.
%global debug_package %{nil}
%global __brp_strip %{nil}
%global __brp_strip_comment_note %{nil}
%global __brp_strip_static_archive %{nil}
%global __brp_check_rpaths %{nil}

Name:           waydroid-overlay
Version:        1.0.0
Release:        2%{?dist}
Summary:        Deploy Waydroid overlay content, repeatably, from packaged payload

License:        GPL-3.0-or-later
URL:            https://github.com/zish/bigtab01-waydroid
Source0:        waydroid-bigtab01-%{version}.tar.gz

BuildArch:      noarch

# For %{_unitdir}. The only build-time dependency a package of prebuilt payload
# and shell has.
BuildRequires:  systemd-rpm-macros

Requires:       waydroid
Requires:       systemd
# sha256sum, stat, install, mktemp -- the reconciler is POSIX shell and these
# are the whole of its toolchain.
Requires:       coreutils
# restorecon. The overlay lives under /var/lib/waydroid and the labels there
# matter to the container; Recommends because the reconciler treats a missing
# restorecon as "this host does not use SELinux" and carries on.
Recommends:     policycoreutils

%description
Rebuilds /var/lib/waydroid/overlay from payload shipped in /usr, before the
container starts, on every boot.

The overlay is how this project changes files inside Waydroid's read-only
Android images without touching them, and it is state that several ordinary
Waydroid operations can wipe. This package makes it repeatable: components stage
their files under %{_datadir}/waydroid-overlay with a manifest, and
waydroid-overlay-sync reconciles the live overlay against them -- installing
what is missing, replacing what has drifted, removing what a component no longer
claims, and refusing to remove anything edited by hand.

Install this package with no components and it does nothing, correctly.

%package        camera
Summary:        Overlay content for the camera fixes
Requires:       %{name} = %{version}-%{release}

%description    camera
The minigbm gbm_mesa wrapper rebuilt so that importing the camera's fallback
buffer no longer produces a zero-width mapping -- the bug that made every
preview frame black -- for both ABIs, the external camera HAL rebuilt to report
LENS_FACING_BACK so that apps requiring a rear camera will open it, and the
external camera configuration.

%package        battery
Summary:        Overlay content for host battery reporting
Requires:       %{name} = %{version}-%{release}

%description    battery
Waydroid's health HAL reads the host's power supply correctly and then
healthd_board_battery_update() overwrites every field with hardcoded fakes --
85%%, charging -- on the one path that reaches Android's BatteryService. This is
that function patched out, so Android sees the real battery.

%package        wifi
Summary:        Overlay content for Android's Wi-Fi framework
Requires:       %{name} = %{version}-%{release}
# Not optional, and not a nicety. wificond.rc here execs /system/bin/true to
# stop the guest's own wificond taking the service name the host daemon must
# register. Install this without waydroid-wifid and Android has a Wi-Fi
# framework with no wificond at all behind it -- worse than the stock image,
# which at least fails honestly. docs/34-wifi-second-radio.md.
Requires:       waydroid-wifid

%description    wifi
The feature XML that wakes Android's dormant Wi-Fi framework, the init script
that stands the guest's wificond down in favour of the host daemon, and the
VINTF manifest entry for the supplicant HAL.

%package        brightness
Summary:        Overlay content for Android-controlled screen brightness
Requires:       %{name} = %{version}-%{release}
# Same shape as the wifi subpackage's dependency, and for the same reason. This
# component's only file neuters the guest light HAL, which is a stub that
# discards every call. Doing that without waydroid-sensord installed leaves
# ILight served by nobody instead of served by a stub -- no worse in effect,
# since neither moves the panel, but there is no reason to ship half of a fix.
Requires:       waydroid-sensord

%description    brightness
The init script that stands the guest's stub light HAL down in favour of the
host daemon, so Android's brightness slider reaches the real panel backlight.

Needed because both register android.hardware.light@2.0::ILight/default and the
last registration wins: container_manager.py starts waydroid-sensord before
lxc-start, so without this the guest stub is guaranteed to register second and
take the name back.

%package        widevine
Summary:        Overlay content for the Widevine L3 CDM
Requires:       %{name} = %{version}-%{release}

%description    widevine
The Widevine L3 CDM and its lazy DRM HAL service, which give MediaDrm a
registered Widevine scheme inside the container. Note that this makes DRM
playback possible, not permitted: some services refuse to run in a container for
reasons unrelated to the CDM.

%prep
%autosetup -n waydroid-bigtab01-%{version}

%build
# Nothing to build. The payload is prebuilt Android binaries and XML, and the
# reconciler is shell.

%install
DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/overlay-manager/install.sh

DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    sh artifacts/overlay/install.sh camera battery wifi widevine brightness

%files
%license LICENSE
%doc docs/36-packaging.md
%{_bindir}/waydroid-overlay-sync
%{_unitdir}/waydroid-overlay-sync.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-overlay-sync.service
%dir %{overlay_dir}
%dir %{overlay_dir}/manifests
# /var/lib/waydroid-overlay, where the reconciler records what it placed, is
# deliberately not owned by any package: on an ostree host /var is outside the
# deployment, and the directory is created on first run anyway.

%files camera
%doc docs/08-camera-fixed.md docs/11-camera-facing.md
%{overlay_dir}/camera/
%{overlay_dir}/manifests/camera.manifest

%files battery
%doc docs/10-battery-fixed.md
%{overlay_dir}/battery/
%{overlay_dir}/manifests/battery.manifest

%files wifi
%doc docs/29-wifi-plan.md docs/34-wifi-second-radio.md
%{overlay_dir}/wifi/
%{overlay_dir}/manifests/wifi.manifest

%files widevine
%doc docs/21-netflix-widevine.md docs/22-netflix-container-detection.md
%{overlay_dir}/widevine/
%{overlay_dir}/manifests/widevine.manifest

%files brightness
%doc docs/37-brightness.md
%{overlay_dir}/brightness/
%{overlay_dir}/manifests/brightness.manifest

%changelog
* Tue Sep 09 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-2
- Add the brightness subpackage: stands the guest stub light HAL down so
  waydroid-sensord can own ILight and drive the real panel backlight.

* Tue Sep 09 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-1
- First spec. Components stage into /usr; waydroid-overlay-sync deploys to /var.
