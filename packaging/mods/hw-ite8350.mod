# waydroid-ext-hw-ite8350 -- docs/19-sensor-hub-suspend-wedge.md
#
# docs/19's safety net for the s2idle wedge: on every resume, test the ITE8350
# hub's accelerometer for staleness and reprobe the I2C HID device only if it is
# stuck. It has to be an active check rather than an error path because the
# wedged hub's reads still SUCCEED.
#
# WHY THE NAME SAYS hw-, AND WHAT THAT PREFIX PROMISES
#
# This is the first waydroid-ext-hw-* package. docs/47 reserves that prefix for
# anything that names this machine's hardware, on the grounds that most of what
# this project produced is NOT HP Envy x2 specific and that "a package named
# after one laptop will not be installed by anyone else". The prefix is a warning
# label, not a namespace: it exists so that installing the useful two thirds of
# this project does not drag in one laptop's I2C device names. Nothing outside
# waydroid-ext-hw-* may depend on this package, and this package depends on
# nothing that would be pulled onto a machine for its sake. The other side of
# that promise -- being INERT on the wrong machine rather than merely unwanted --
# was NOT kept by 1.0.0 and is kept as of 1.0.1; see below.
#
# WHY TWO UNITS AND NOT A system-sleep HOOK
#
# It was /etc/systemd/system-sleep/ite8350 from 2026-09-06 to 2026-09-07, on the
# stated assumption that systemd searches /etc alongside /usr/lib. It does not:
# systemd 259 has exactly one hook directory compiled in,
# /usr/lib/systemd/system-sleep, empty and read-only on this rpm-ostree host.
# Measured in docs/27 -- nine suspends in one boot, zero hook runs -- so docs/19's
# safety net was inert for its entire first day.
#
# DESCRIPTION has the two-unit shape. The property worth recording here is that
# the replacement's `systemctl start --no-block` preserves the dead hook's one
# good property: systemd waits for system-sleep scripts, and this check
# deliberately takes about 11 s, so nothing may ever wait for it.
#
# artifacts/sensor-hub/ite8350-sleep-hook is still in the repository as the record
# of that mistake and is deliberately NOT in SOURCES: install.sh does not install
# it, and shipping a hook into a directory docs/27 says must stay empty would ship
# a safety net that cannot fire. install.sh's removal of a pre-existing dead hook
# is skipped when DESTDIR is set, correctly -- a buildroot has no host to clean --
# so this package does not clean up after the manual install either.
#
# WHAT USED TO HAPPEN ON A MACHINE THAT HAS NO ITE8350 -- FIXED IN 1.0.1
#
# 1.0.0 failed its unit on every resume on any machine without the hub, and the
# path was read out of the script rather than guessed at: accel_path() finds no
# iio node named accel_3d, accel_is_stale() returns true because "gone entirely
# counts as stale", and the reprobe writes i2c-ITE8350:00 to
# /sys/bus/i2c/drivers/i2c_hid_acpi/unbind, which fails without that device.
# So the wrong hardware logged "accelerometer stale after resume -- reprobing
# i2c-ITE8350:00" and "unbind failed" and failed ite8350-resume-check.service
# about 11 s after every resume, forever.
#
# Reproduced on the Debian dev box, which has no such hub: 8 s, then the reprobe,
# then exit 1. Never dangerous -- the write names one device by its exact ACPI id,
# so another machine's i2c-HID touchpad or touchscreen is never unbound -- but
# noisy failure is the wrong behaviour for a hw- package, because a metapackage or
# a curious user eventually installs it somewhere it does not belong.
#
# The fix is a precondition at the top of the script, and it tests the I2C DEVICE
# rather than the accelerometer: unbinding the driver removes the driver link and
# leaves /sys/bus/i2c/devices/i2c-ITE8350:00 in place, so the test is true exactly
# while the hardware is present and stays true in the wedged state the script
# exists to repair. Testing for accel_3d instead would have made the script exit 0
# on precisely the failure it is for. It runs BEFORE the 8 s settle wait, so the
# wrong machine pays nothing: measured at 0 s and exit 0, against 8 s and exit 1
# before.
#
# WHY NEITHER waydroid NOR waydroid-ext-sensord IS A DEPENDENCY
#
# Every other host modification here Requires waydroid, and this one must not:
# the payload never addresses the container, the bridge, binder or an Android
# property. It reads /sys/bus/iio and writes /sys/bus/i2c, and a wedged hub is a
# host fault with host symptoms -- iio-sensor-proxy, any desktop's auto-rotate.
#
# waydroid-ext-sensord is the consumer, and docs/47's test is whether this package
# WITHOUT the dependency is worse than stock. It is not: the reprobe revives the
# host's own accelerometer either way. The weak dependency that would help points
# the other way -- sensord is what suffers from the wedge -- and sensord must not
# Recommend a package named after one laptop, which is the point of the prefix.
# So neither, in either direction; waydroid-ext-hw-envyx2 is where the two are
# joined for the machine that has both, and it does not exist yet.
#
# One coupling is real and needs no dependency to express: a reprobe renumbers
# every iio:deviceN, so a consumer that resolved its paths once would read the
# wrong node forever. SensorIIO::ReadSensor() re-resolves by name on a failed read
# as of docs/19, and that is in every packaged sensord, so there is no version
# floor left to state.
#
# ONE THING UNRESOLVED
#
# The detector cannot distinguish a wedged hub from a genuinely motionless
# machine: it only knows that a live accelerometer jitters by an LSB or two. A
# false positive costs one unbind/bind pair and one renumber, which nothing
# downstream now notices -- but docs/27 records the check firing on two
# consecutive resumes, which sits oddly with docs/19's "intermittent" framing and
# has not been explained.

VERSION=1.0.1
RELEASE=1
KIND=host

# noarch, against the temptation to write ARCH=x86_64. The payload is one bash
# script and two unit files: text, identical on every architecture. rpm's arch
# field is about what the PAYLOAD can run on, not where it is useful -- "only
# useful on one x86_64 laptop" is a different claim, and the hw- prefix and the
# description carry it. ARCH here would make gen-spec.sh emit ExclusiveArch and
# refuse to BUILD on an aarch64 builder, which buys nothing the name does not
# already say.
ARCH=noarch

SUMMARY="Revive the ITE8350 HID sensor hub when it does not survive suspend"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason waydroid-ext-btd and waydroid-ext-wifid declare it.
BUILDREQUIRES="systemd-rpm-macros"

# Exhaustive, not representative: a resume hook that cannot run its recovery
# command is a failure nobody is watching. Three programs between the script and
# the two units.
#
#   systemd    systemd-cat (the check's whole stdout is a process substitution
#              into it, tag ite8350-resume), the systemctl in
#              ite8350-sleep.service's ExecStop, sleep.target, and the unit
#              manager that owns both units.
#   bash       ite8350-resume-check is #!/bin/bash and cannot be POSIX sh:
#              `exec 1> >(systemd-cat ...)` is process substitution,
#              in_accel_{x,y,z}_raw is brace expansion, and the helpers use
#              `local`. rpm's interpreter dependency would find it; named for
#              the same reason the other mods name python3.
#   coreutils  cat, tr, seq, /bin/true, and `sleep 0.2` -- a fractional argument
#              is GNU's extension, so the 3 s staleness window depends on this
#              package and not merely on a shell builtin.
#
# Deliberately absent, having grepped for them: no modprobe, no udevadm, no
# i2c-tools, no python. The reprobe is two shell writes to
# /sys/bus/i2c/drivers/i2c_hid_acpi/{unbind,bind}, so the only thing it needs
# that no package can provide is i2c_hid_acpi being bound -- kernel, not a
# dependency.
REQUIRES="systemd
bash
coreutils"

# No Recommends. waydroid-ext-sensord is the obvious candidate and is argued
# against above: the useful direction of that weak dependency is the one the hw-
# prefix forbids.

DOCS="docs/19-sensor-hub-suspend-wedge.md docs/27-android-power-button.md"

DESCRIPTION="Recovers ONE named piece of hardware: the ITE8350 HID sensor hub in an HP Envy
x2 (i2c-ITE8350:00). It is packaged under the waydroid-ext-hw- prefix because
of that, and on a machine without the device it is not useful -- it is worse
than useless, because the resume check treats a missing accelerometer as a
stale one, tries to reprobe a device that is not there, and fails its unit
about eleven seconds after every resume. It unbinds nothing else: the reprobe
names one ACPI device exactly. If this machine is not an Envy x2, do not
install this package.

The fault it exists for is narrow and was hard to see. After suspend-to-idle
the hub can come back half alive -- the accelerometer, device rotation and
inclinometer stop publishing while the gyroscope and magnetometer keep going.
Reads still succeed and return the same numbers forever, so nothing downstream
can tell a dead hub from a still machine, and Android pins the display to the
rotation implied by the last live sample. That is indistinguishable, from
Android's side, from a sign-convention bug fixed earlier in this project, which
is the trap worth remembering.

Two systemd units do the work. One is ordered before sleep.target and holds
itself active across the suspend, so that leaving sleep.target on resume runs
its ExecStop, which starts the other with --no-block. The check then waits
eight seconds -- a single suspend usually recovers unaided and the kernel's
-121 on resume is common and self-healing, so acting sooner would churn the hub
on every wake -- and samples the accelerometer for three seconds. A live
accelerometer jitters by a least significant bit or two even sitting on a desk,
so identical readings across that window mean the hub has stopped publishing.
Nothing waits for any of this: resume is not delayed by a millisecond.

Only a driver reprobe clears the wedge. Rewriting the sampling frequency
revives the device-rotation node and never the accelerometer, even when a
genuinely different value is written and confirmed applied. So the recovery is
an unbind and a bind of the I2C HID device, which is safe here because only
HID-SENSOR-* function nodes sit behind it -- there are no input devices, so the
touchscreen and keyboard are untouched.

A reprobe renumbers the IIO device nodes, and not always back to the same
numbers, so any consumer that resolves those paths once and caches them will
read the wrong node afterwards. Waydroid's host-side sensors daemon re-resolves
by name whenever a read fails, so recovery needs no container or session
restart; a different consumer may need restarting. This package deliberately
does not depend on that daemon, and nothing that is not itself
hardware-specific should depend on this package.

What it cannot do is distinguish a wedged hub from a machine that is genuinely
not moving. A false positive costs one reprobe and one renumber, which is the
price of a detector that works at all on reads that succeed."

# ite8350-sleep-hook is NOT here. install.sh does not install it -- it removes
# it -- and a source package should not carry a hook that cannot run.
SOURCES="artifacts/sensor-hub/install.sh
artifacts/sensor-hub/ite8350-resume-check
artifacts/sensor-hub/ite8350-resume-check.service
artifacts/sensor-hub/ite8350-sleep.service"

# UNITDIR matters: the installer defaults to /etc/systemd/system, right for the
# manual install and wrong for a package, while /usr/local is a symlink to
# /var/usrlocal, which SELinux labels lib_t, and init_t may not start a unit
# whose file is lib_t. That bit exactly this modification, because
# ite8350-sleep.service's ExecStop is the only unit here that asks systemd over
# D-Bus to start ANOTHER unit, which is the path that checks the target's label
# (docs/27). %{_unitdir} is systemd_unit_file_t like /etc/systemd/system is.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/sensor-hub/install.sh'

# Exactly the tree install.sh produces with those variables, verified by running
# it into a scratch DESTDIR. Nothing lands in /etc, so there is no %config here
# and packaging/test-install.sh's rule has nothing to check.
#
# %dir for sleep.target.wants for the reason waydroid-ext-btd owns
# multi-user.target.wants: the enable is a .wants symlink the installer creates,
# which is what `systemctl enable` would have created, so no %post is needed --
# but then somebody has to own the directory holding it. rpm allows
# co-ownership, so another package shipping a sleep.target hook is not a
# conflict.
PAYLOAD_FILES='%{_bindir}/ite8350-resume-check
%{_unitdir}/ite8350-resume-check.service
%{_unitdir}/ite8350-sleep.service
%dir %{_unitdir}/sleep.target.wants
%{_unitdir}/sleep.target.wants/ite8350-sleep.service'
