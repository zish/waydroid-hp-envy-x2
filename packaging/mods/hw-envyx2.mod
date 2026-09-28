# waydroid-ext-hw-envyx2 -- docs/00-host-baseline.md
#
# The machine metapackage: "this is an HP Envy x2, give me what is specific to
# it." Everything else in this project is asked for by feature -- camera, wifi,
# sensors, brightness -- and those groups are the same on any laptop. This is the
# one package whose answer differs per machine, which is why docs/47 reserves the
# waydroid-ext-hw-* prefix for it and for nothing else.
#
# WHAT A MACHINE PACKAGE MAY AND MAY NOT PULL
#
# It pulls the packages that are ABOUT this hardware. It does not decide which
# features the owner wants, because "I have this laptop" is not a statement about
# whether Android should have a camera. So waydroid-ext-hw-ite8350 is a hard
# Requires -- it is a member, it names this machine's I2C device, and it is
# useless anywhere else -- while waydroid-ext-sensord is a Recommends, and the
# distinction is the point rather than hedging.
#
# The reason sensord is not hard: reviving a wedged sensor hub is worth doing for
# the HOST as well as for Android. The iio devices that stop publishing are the
# host's own, and a host with no Waydroid session at all still wants its
# accelerometer back after suspend. So hw-ite8350 without sensord is a coherent
# thing to install, which is exactly the docs/47 test -- is the package without
# the dependency worse than stock? -- coming back "no". waydroid-ext-hw-ite8350
# itself declares neither, for the same reason, and this package is where the
# "and on this machine you probably also want the daemon" judgement belongs.
#
# Recommends is not a weak gesture here. dnf installs weak dependencies by
# default, so `dnf install waydroid-ext-hw-envyx2` does bring sensord; the
# strength only decides what happens to somebody who has turned weak dependencies
# off, or who later removes sensord, and in both cases the right answer is to let
# them.
#
# WHAT IS OWED: THE SECOND HALF
#
# docs/47 defines this package as hw-ite8350 PLUS the Core M-5Y70 dexopt values,
# and only the first half exists. The values are two lines --
# dalvik.vm.dex2oat-threads=2 and dalvik.vm.dex2oat-cpu-set=0,2 -- and 0,2 is this
# CPU's sibling numbering, so they are genuinely machine-specific and genuinely
# belong here rather than in a generic waydroid-ext-dexopt.
#
# They are not here because there is nothing yet to put them in.
# packaging/mods/dexopt.mod is written and deliberately unshipped -- it declares
# SHIPPED=no, so build-mod.sh --all skips it and says so: the RPM would
# install one data file and nothing that applies it, because
# artifacts/dexopt/install.sh is both halves in one script and the packaged half
# stops at the DESTDIR guard. So `rpm -i` changes nothing about a running Android.
# Adding a Requires on that package would make this metapackage promise dexopt
# tuning and deliver a file nobody reads. docs/53 item 1 scopes the fix: one
# generalised pre-start reconciler covering the overlay, waydroid_base.prop and
# lxc.net.0.name, rather than an RPM per item of mutable state. When it exists,
# the machine's values come here and this comment goes.
#
# So this package is deliberately thin for now, and a name plus one dependency is
# still worth shipping: it is the thing an Envy x2 owner installs, and docs/47's
# own argument for naming waydroid-ext-lxc-config before writing it applies here
# -- giving it a package name is the cheapest way to stop it being forgotten.

VERSION=1.0.0
RELEASE=1
KIND=group
ARCH=noarch

SUMMARY="Hardware support specific to the HP Envy x2 (Core M-5Y70)"

LICENSE="GPL-3.0-or-later"

REQUIRES="waydroid-ext-hw-ite8350"

# See the header: the hub revival helps the host whether or not Android reads it,
# so this is the judgement "on this machine you probably also want the daemon"
# and not a hard edge. dnf honours it by default.
RECOMMENDS="waydroid-ext-sensord"

DOCS="docs/00-host-baseline.md docs/19-sensor-hub-suspend-wedge.md"

DESCRIPTION="Everything in this project that is specific to one laptop -- an HP Envy x2
(13-j001dx, Core M-5Y70) -- as a single thing to install. On any other machine
this package is the wrong answer and its contents do nothing.

Today that is the ITE8350 sensor hub's resume recovery. The hub can come back
from s2idle in a state where the accelerometer still answers reads and returns
the same numbers forever, which is invisible to everything downstream: Android
keeps being told the machine is at whatever attitude the last live sample
caught, and the display stays pinned to that rotation. Only a driver reprobe
clears it, and this ships the units that detect the condition after each resume
and perform the reprobe without delaying the resume itself.

It suggests the host sensor daemon as well, because on this machine that is
what makes the hub worth reviving -- but does not require it, since a host
running no Android session at all still wants its own accelerometer back.

One thing docs/47 lists for this package is not here yet: the dex2oat tuning
for this CPU, two properties that pin compilation to the right pair of
hardware threads on a two-core Broadwell. Those live in Waydroid's mutable
state rather than in a file a package can own, and the reconciler that would
apply them does not exist yet, so shipping them would mean shipping a file
nothing reads. They arrive when it does.

This package contains no files of its own."
