# Spec for the host-side sensors daemon built in this repository.
#
# STATUS: written 2026-09-09. See packaging/README.md for what has and has not
# been through rpmbuild.
#
# WHY THIS IS ITS OWN PACKAGE AND NOT PART OF waydroid-bigtab01
#
# Three reasons, in order of weight:
#
#   1. It is a compiled binary, so the package is arch-specific.
#      waydroid-bigtab01 is noarch shell and Python and must stay that way.
#   2. It is a derivative work. service.cpp, Sensors.cpp and hybrisbindertypes.h
#      come from droidian/waydroid-sensors (GPL-3.0); what this repository
#      replaced is the data source -- upstream reads sensorfw, which Fedora does
#      not package, and SensorIIO.{h,cpp} reads /sys/bus/iio/devices instead.
#      waydroid-bigtab01's header can say "none of the packaged content is
#      derived from Waydroid"; this package cannot, and the distinction should
#      be visible in `rpm -qi`, not buried.
#   3. It has its own dependency set -- libgbinder and libglibutil -- which the
#      noarch package does not carry, and which is the reason to package this at
#      all: a hand-copied binary in /usr/local/bin tells nobody which libraries
#      it was built against, while `rpm -q --requires` does.
#
# NO UNIT, ON PURPOSE. Waydroid's container_manager.py starts a host daemon
# named waydroid-sensord if one is on PATH, and images.py sets
# waydroid.stub_sensors_hal=1 only when it is not -- so the guest stub stands
# down by itself. Being installed IS the installation. docs/14-sensors.md.
#
# MIGRATION TRAP. The by-hand install this replaces puts the binary in
# /usr/local/bin, which precedes /usr/bin on root's PATH. Installing this
# package while that copy exists means Waydroid keeps starting the OLD binary,
# with nothing to indicate it. Remove it first:
#     rm -f /usr/local/bin/waydroid-sensord

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
# `--with prebuilt` packages a binary that sensors/build.sh already produced, instead of
# compiling in %%build. It exists because of where this project can build: the
# dev box has no Fedora toolchain and no working container runtime, and bigtab01
# itself is an 8 GB immutable host where a toolchain costs a layered install and
# a reboot. The default is still a real source build -- use it on any Fedora
# machine or in mock. A prebuilt package is honest about what it is: rpm still
# reads the ELF and generates the same soname dependencies.
%bcond_with prebuilt

Name:           waydroid-sensord
Version:        1.0.0
Release:        2%{?dist}
Summary:        Host-side sensors HAL for Waydroid's Android container

License:        GPL-3.0-or-later
URL:            https://github.com/zish/waydroid-hp-envy-x2
Source0:        waydroid-bigtab01-%{version}.tar.gz

%if %{without prebuilt}
BuildRequires:  gcc-c++
BuildRequires:  make
# The exact libraries the daemon binds to. libgbinder's ABI is the reason
# sensors/build.sh goes to the trouble of compiling against headers from the
# tag matching the host: gbinder_* has no stable ABI promise across versions.
BuildRequires:  pkgconfig(libgbinder) >= 1.1.47
BuildRequires:  pkgconfig(libglibutil) >= 1.0.82
BuildRequires:  pkgconfig(glib-2.0)
BuildRequires:  pkgconfig(gobject-2.0)
BuildRequires:  pkgconfig(gio-2.0)
BuildRequires:  pkgconfig(gio-unix-2.0)
%endif

# Runtime. rpm's ELF scan generates the soname dependencies on its own; these
# name the PACKAGES those sonames come from, so that `rpm -q --requires
# waydroid-sensord` answers "what do I have to keep patched for this daemon"
# without anyone having to map libgbinder.so.1 back to a source package first.
Requires:       waydroid
%if 0%{?fedora} || 0%{?rhel}
Requires:       libgbinder%{?_isa} >= 1.1.47
Requires:       libglibutil%{?_isa} >= 1.0.82
Requires:       glib2%{?_isa}
%endif
# Elsewhere: rpm's ELF scan generates the soname dependencies, which every
# distro satisfies under its own package names.

# The ITE8350 does not reliably survive s2idle: it can keep answering reads with
# a frozen value, which looks exactly like correct data that stopped changing.
# Recovery is a driver reprobe, and the units that do it are in waydroid-bigtab01.
# Recommends rather than Requires -- the daemon is correct without it, it just
# has no safety net. docs/19-sensor-hub-suspend-wedge.md.
Recommends:     waydroid-bigtab01

# The daemon also serves android.hardware.light@2.0::ILight, but it can only
# KEEP that name if the guest's stub light HAL is stood down, which is what
# waydroid-overlay-brightness does. Without it the daemon still registers and
# is simply overwritten by the stub a moment later, because container_manager.py
# starts us before lxc-start. Recommends and not Requires: the sensors half is
# entirely unaffected, and a host that only wants sensors is a legitimate
# configuration. docs/37-brightness.md.
Recommends:     waydroid-overlay-brightness

%description
Serves android.hardware.sensors@1.0::ISensors over hwbinder from the host side,
reading the ITE8350 sensor hub through Linux IIO sysfs. Android gets a live
accelerometer, gyroscope, magnetometer, orientation and rotation vector, and
synthesises eight more sensor types on top of them.

It also serves android.hardware.light@2.0::ILight, mapping Android's 0..255
brightness onto the host's panel backlight in /sys/class/backlight. That half
lives in this binary rather than a daemon of its own because the name
waydroid-sensord IS the install hook -- container_manager.py starts exactly one
host daemon and gates it on that literal name, which also means the process
inherits waydroid_t rather than the unconfined_service_t a systemd unit would
get. This machine has no ambient light sensor, so Android's automatic
brightness cannot work here; the manual slider now does.

It runs on the host rather than in the container because /dev/hwbinder is
bind-mounted into the container, so both share one hwbinder domain, and because
Waydroid's own container manager already looks for exactly this binary on PATH.

Contains work derived from droidian/waydroid-sensors (GPL-3.0), whose libgbinder
ISensors server is kept intact; the sensorfw data source is replaced with a
direct IIO reader.

%prep
%autosetup -n waydroid-bigtab01-%{version}

%build
%if %{with prebuilt}
# Built by sensors/build.sh and carried in the source tarball by
# packaging/build-rpms.sh --prebuilt.
test -x prebuilt/waydroid-sensord
cp -p prebuilt/waydroid-sensord waydroid-sensord
%else
# Not sensors/build.sh: that script fetches libgbinder and libglibutil headers
# from GitHub and copies .so files off bigtab01 over ssh, which is right for a
# dev box that must match a host it cannot install packages on, and wrong for a
# package build, which must be offline and must bind to THIS buildroot's
# libraries. The flags below are the same ones, minus the vendored headers.
#
# -static-libstdc++/-static-libgcc are kept: the daemon is copied to a host with
# a different gcc than the builder in the by-hand flow, and keeping the two
# builds identical is worth more than the few hundred KB.
g++ %{optflags} -std=gnu++17 -pthread \
    -ffunction-sections -fdata-sections \
    -Isensors \
    $(pkg-config --cflags libgbinder libglibutil glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0) \
    sensors/SensorIIO.cpp sensors/Sensors.cpp \
    sensors/Backlight.cpp sensors/Lights.cpp sensors/service.cpp \
    -o waydroid-sensord \
    -Wl,--gc-sections -static-libstdc++ -static-libgcc \
    $(pkg-config --libs libgbinder libglibutil glib-2.0 gobject-2.0 gio-2.0 gio-unix-2.0) \
    -lpthread -lm

%endif

%install
DESTDIR=%{buildroot} PREFIX=%{_prefix} SENSORD_BIN=waydroid-sensord \
    sh artifacts/sensors/install.sh

%files
%license sensors/LICENSE
%doc docs/14-sensors.md docs/18-sensor-axes.md docs/19-sensor-hub-suspend-wedge.md
%doc docs/37-brightness.md
%doc artifacts/sensors/waydroid-sensors.conf
%{_bindir}/waydroid-sensord

%changelog
* Tue Sep 09 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-2
- Serve android.hardware.light@2.0::ILight as well, driving the host panel
  backlight from Android's brightness setting. Adds Backlight.cpp and Lights.cpp.


* Tue Sep 09 2026 Jeremy Melanson <1080872+zish@users.noreply.github.com> - 1.0.0-1
- First spec, split out of waydroid-bigtab01 because this one compiles.
