# waydroid-ext-sensord -- docs/14-sensors.md
#
# The host-side sensors daemon: it serves android.hardware.sensors@1.0::ISensors
# over hwbinder, reading the ITE8350 sensor hub through Linux IIO sysfs, so
# Android gets real accelerometer, gyroscope and magnetometer data instead of the
# empty sensor list Waydroid's stub HAL returns.
#
# WHY A HOST DAEMON AND NOT A GUEST HAL, AND WHY THE INSTALL IS ONE FILE
#
# Waydroid's image ships a 10 KB stub whose whole main() registers an empty
# sensor list, and tools/helpers/images.py sets waydroid.stub_sensors_hal=1 only
# when waydroid-sensord is NOT on PATH. So putting this binary on PATH is the
# entire installation: the property stops being set, the guest stub returns at
# its first line, and container_manager.py starts this daemon instead. No overlay
# file, no image change, no prop edit -- which is why this package ships one
# binary and no unit. /dev/hwbinder is bind-mounted into the container, so host
# and guest share one hwbinder domain.
#
# It is also why this package unblocks waydroid-ext-backlight: that modification
# grants waydroid-sensord the SELinux permission to write /sys/class/backlight,
# and until this package existed it granted a permission to a binary no package
# installed. The daemon serves android.hardware.light@2.0::ILight from the same
# process for the reason sensors/build.sh explains -- its NAME is the install
# hook, so a second binary could not be picked up at all.
#
# WHY THERE IS A %bcond, AND WHY THE DEFAULT IS THE SOURCE BUILD
#
# The daemon compiles against libgbinder-devel and libglibutil-devel, which are
# Fedora packages; the dev box is Debian and cannot. The default arm is the real
# source build, because that is what a distribution builder runs and a source
# package that cannot be built from source is not one. `--prebuilt` selects the
# other arm, which packages the binary sensors/build.sh already produced, and is
# how this box can produce an installable RPM at all. packaging/README.md records
# which arm each recorded build used.
#
# The %build command is written out rather than delegated to sensors/build.sh,
# and that is deliberate: build.sh fetches libgbinder and libglibutil headers
# from GitHub and copies .so files off bigtab01 over ssh. That is right for a dev
# box matching a host it cannot install packages on, and wrong inside rpmbuild,
# which must be offline and must bind to this buildroot's libraries.

VERSION=1.0.1
RELEASE=1
KIND=host

# Compiled x86_64. NOT noarch, for the same reason camera-gbm is not: a noarch
# package would install on an aarch64 host and fail there rather than on the shelf.
ARCH=x86_64

SUMMARY="Serve Android's sensors and lights HALs from the host's IIO sensor hub"

# GPL-3.0-or-later, which is what sensors/LICENSE says and what the superseded
# waydroid-sensord.spec declared. service.cpp, Sensors.cpp and
# hybrisbindertypes.h come from droidian/waydroid-sensors, which is GPL-3.0; the
# IIO data source that replaces its sensorfw one is ours. sensors/build.sh has
# the full provenance.
LICENSE="GPL-3.0-or-later"

GLOBALS='%bcond_with prebuilt

# Both of these apply to the prebuilt arm ONLY; the source build a distribution
# runs is untouched and still produces a debuginfo package normally.
#
# debug_package: there is no source in this build tree for a debuginfo package
# to point at, and the extraction needs eu-strip, which Fedora has and the
# Debian dev box does not -- leaving it on makes the one build this box CAN do
# fail outright, which is how this was found.
#
# __brp_strip: the point of the prebuilt arm is to ship the exact binary that
# was built and tested against bigtab01. Stripping it here would package
# something that is no longer byte-for-byte that file.
%if %{with prebuilt}
%global debug_package %{nil}
%global __brp_strip %{nil}
%endif'

BUILDREQUIRES="gcc-c++
pkgconfig(libgbinder) >= 1.1.47
pkgconfig(libglibutil) >= 1.0.82
pkgconfig(glib-2.0)
pkgconfig(gobject-2.0)
pkgconfig(gio-2.0)
pkgconfig(gio-unix-2.0)"

# %{?_isa} on the three libraries: this is an x86_64 binary and it needs the
# x86_64 builds of what it links, not whatever a multilib host happens to have.
REQUIRES="waydroid
libgbinder%{?_isa} >= 1.1.47
libglibutil%{?_isa} >= 1.0.82
glib2%{?_isa}"

# waydroid-sensors.conf ships as documentation and NOT into /etc, deliberately:
# every key in it is shown at its built-in default, so installing it would give
# those defaults a second home that can drift from the code. Copy it to
# /etc/waydroid-sensors.conf only when something actually needs changing.
DOCS="docs/14-sensors.md
docs/18-sensor-axes.md
docs/19-sensor-hub-suspend-wedge.md
docs/37-brightness.md
artifacts/sensors/waydroid-sensors.conf"

DESCRIPTION="Waydroid gives Android an empty sensor list: its images ship a stub sensors
HAL whose entire implementation registers no sensors at all. This daemon
replaces it from the host side, reading the machine's IIO sensor hub through
Linux sysfs and serving android.hardware.sensors@1.0::ISensors over hwbinder,
which host and guest share because /dev/hwbinder is bind-mounted into the
container.

Installing it is putting it on PATH, and nothing else. Waydroid sets the
property that enables its own stub only when waydroid-sensord is absent, so
the stub stands down by itself and the container manager starts this instead.
There is no unit here and no configuration file, by design.

It also serves android.hardware.light@2.0::ILight, so Android's brightness
slider reaches /sys/class/backlight. That lives in this binary rather than
beside it because the binary's NAME is the install hook -- a separate lights
daemon would never be started. Writing the backlight additionally needs the
SELinux policy in waydroid-ext-backlight, which grants it to this daemon by
name."

SOURCES="sensors/SensorIIO.cpp
sensors/SensorIIO.h
sensors/Sensors.cpp
sensors/Sensors.h
sensors/Backlight.cpp
sensors/Backlight.h
sensors/Lights.cpp
sensors/Lights.h
sensors/service.cpp
sensors/hybrisbindertypes.h
artifacts/sensors/install.sh"

# Staged into prebuilt/ by build-mod.sh --prebuilt; ignored otherwise.
PREBUILT_FILES="build/sensors/waydroid-sensord"

BUILD='%if %{with prebuilt}
# Built by sensors/build.sh and carried in the tarball by
# packaging/build-mod.sh --prebuilt.
test -x prebuilt/waydroid-sensord
cp -p prebuilt/waydroid-sensord waydroid-sensord
%else
# -static-libstdc++/-static-libgcc are kept from the by-hand build: the daemon is
# copied to a host with a different gcc than the builder in that flow, and
# keeping the two builds identical is worth more than the few hundred KB.
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
%endif'

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} SENSORD_BIN=waydroid-sensord \
    sh artifacts/sensors/install.sh'

# One file, which is the whole point -- see the header. Nothing under /etc, so
# nothing here needs %config.
PAYLOAD_FILES='%{_bindir}/waydroid-sensord'
