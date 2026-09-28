# waydroid-ext-dexopt -- docs/43-app-freezer.md, docs/47-package-split.md
#
# Two property lines that confine Android's background dex2oat to one physical
# core.
#
# WHAT THIS PACKAGE DOES NOT SHIP, AND MUST NOT BE READ AS SHIPPING
#
# The reconciler. artifacts/dexopt/install.sh is both halves in one script and
# the RPM only ever reaches the first, by the installer's own line:
#
#     # RPM %install stage ends here: /var/lib/waydroid is state, not packaged content.
#     if [ -n "$DESTDIR" ]; then
#             echo "staged: $payload"
#             exit 0
#     fi
#
# So the payload below is one file -- the values -- and this package installs no
# copy of that script, no unit and no scriptlet that applies them. Nothing in it
# runs Before=waydroid-container.service. As built, `rpm -i` of this package
# changes nothing about a running Android, and the name "dexopt property
# reconciler" that docs/47 gives it is not yet earned.
#
# The reason is a decision taken elsewhere. packaging/README.md rejects one RPM
# per mutable-state item and asks instead for ONE reconciler covering all three
# pre-start inputs -- the overlay payload, `lxc.net.0.name = wlan0`, and these
# properties -- wired as a single ExecStartPre on waydroid-container.service,
# plus one ExecStartPost one-shot for the use_compaction device_config flag.
# docs/47 in turn asks each non-overlay reconciler for "a %post and an
# ExecStartPre". Both need a reconciler in the payload first, and a %post calling
# a path this package does not install would fail on every install -- and be
# inert on the rpm-ostree target regardless, where scriptlets run against the
# compose and /var/lib/waydroid does not exist. So there is no SCRIPTLETS block,
# and DESCRIPTION says plainly that applying these values is
# `sh artifacts/dexopt/install.sh` from a checkout.
#
# WHAT WAS RULED OUT
#
# DESCRIPTION has why properties are the lever available here. All six of the
# dalvik.vm.*dex2oat-{threads,cpu-set} properties installd reads were unset,
# which is why the storm ran four threads; they were verified with `strings`
# against this image rather than from memory.
#
# Three alternatives were on the table and each is worse. Widening lxc.mount.auto
# to cgroup:mixed buys back the freezer and process groups but not Android's
# scheduling layer, and is a change to the container (docs/43). Writing
# /sys/fs/cgroup/lxc.payload.waydroid/cpu.max is one reversible write, but it is
# whole-container granularity and does nothing about prioritisation inside
# Android, which is the actual problem. And an APK cannot do any of it: an app can
# set no system property and write no waydroid_base.prop, and the device_config
# half needs signature-level WRITE_DEVICE_CONFIG (packaging/README.md).
#
# WHY NO PACKAGE CAN OWN THE FILE THAT MATTERS
#
# The values have to reach /var/lib/waydroid/waydroid_base.prop, which
# make_prop() copies line for line into waydroid.prop and bind-mounts into the
# container. They are not ro.* properties, so artifacts/build-prop/README.md's
# first trap does not apply. But that file is STATE: make_base_props() rewrites it
# from scratch, from exactly two call sites -- initializer.py:164 and
# upgrader.py:58 -- so the edit survives reboots and container restarts and is
# erased by `waydroid init -f` or `waydroid upgrade`. On an rpm-ostree host /var
# is outside the deployment besides, so content a package put there would be in no
# commit and restored by no rollback.
#
# So the package ships the values into /usr, where they are versioned and part of
# the commit, and the applying is a reconciler -- exactly the split
# waydroid-ext-overlay-sync makes for the overlay. docs/47.
#
# WHOSE VALUES THESE ARE
#
# cpu-set=0,2 is not a generic default; DESCRIPTION says why, and both the
# sibling numbering and the thread count are read off one CPU.
#
# docs/47 puts the Core M-5Y70 dexopt values behind the waydroid-ext-hw-envyx2
# metapackage and keeps a generic waydroid-ext-dexopt for the reconciler. By that
# division artifacts/dexopt/dexopt.prop as it stands is entirely the
# machine-specific half, and this package is shipping one laptop's tuning under a
# generic name. %config(noreplace) is what keeps that survivable -- an admin edits
# the values once and no upgrade takes the edit away -- and is not the same thing
# as the split having been made.

VERSION=1.0.0
RELEASE=1
KIND=host

# NOT built by `build-mod.sh --all`, and therefore not tested by
# `test-install.sh --all`, which globs what --all built. Naming it explicitly
# still works -- `build-mod.sh --lint dexopt` is how the findings below were
# reproduced -- so this hides nothing and blocks no inspection.
#
# The three reasons are docs/53 item 1 and the header above, and the third is the
# one a build would trip over: this package fails packaging/test-install.sh 5/6.
# An edited %config(noreplace) under /usr/share becomes a .rpmsave that rpm does
# not own and will not remove, so /usr/share/waydroid-dexopt survives erase --
# reproduced, not assumed. rpmlint also adds
# non-etc-or-var-file-marked-as-conffile, a class no other package here reports.
#
# Until this key is removed, "deliberately unshipped" is something the tooling
# enforces rather than something three comments assert. hw-envyx2.mod and docs/53
# both describe this file as written and not shipped; this is what makes that
# checkable. Removing the key is the last step of the reconciler work, not a
# tidy-up.
SHIPPED=no

# Two lines of ASCII text. The machine-specificity of the VALUES is not an ARCH
# question: cpu-set names a CPU topology, not an instruction set, and
# ExclusiveArch cannot express "hosts whose cpu0 and cpu2 are siblings".
ARCH=noarch

SUMMARY="Stop Waydroid's background dexopt from saturating every CPU"

LICENSE="GPL-3.0-or-later"

# No systemd-rpm-macros: %files references no unit directory, because this
# package ships no unit. That is the finding at the top of this file, not an
# oversight here.

# waydroid, and nothing else. /var/lib/waydroid/waydroid_base.prop is the only
# destination these values have, and without waydroid the file is inert text.
#
# Deliberately NOT declared: coreutils, grep and diffutils. Those are what
# artifacts/dexopt/install.sh runs -- install, mktemp, cp, mv; grep for the
# per-key drop that makes the merge idempotent; cmp, which is diffutils and not
# coreutils, and which decides whether waydroid_base.prop is rewritten at all --
# but this package installs no copy of that script, so declaring them would name
# dependencies of a payload that is not here. They belong to whichever package
# ends up shipping the reconciler.
REQUIRES="waydroid"

DOCS="docs/43-app-freezer.md
docs/47-package-split.md"

DESCRIPTION="Confines Android's background dex2oat to one physical core, so Play Store's
background dexopt job cannot take the whole machine while somebody is using it.

Measured on this host before the change: 46 minutes after a reboot, on AC and
idle, the dexopt job ran 91.6 per cent busy across all four CPUs, with CPU
pressure at some avg10 = 35 per cent and dex2oat logging 'threads: 4'. Nothing
contained it, because the cgroups stock Android would have contained it with do
not exist here -- Android 13 asks for cgroup v1 controllers and the host is
cgroup v2 unified, so /dev/cpuctl and /dev/cpuset are empty stubs. Two
properties that installd already reads do the containment instead, and
--cpu-set is a sched_setaffinity() call rather than a cgroup, which is why it
works where the cgroup path cannot.

What it costs is time, not space. dex2oat gets two threads instead of four, so
the same compilation takes longer in wall clock and an app just installed or
updated stays less optimised for longer. Nothing about the compiled output
changes, so there is no extra storage, and first boot is untouched -- the boot-
and restore- variants of these properties are deliberately left unset, because
boot dexopt runs before there is any UI to protect.

The values are re-applied, not owned. They belong in
/var/lib/waydroid/waydroid_base.prop, which Waydroid regenerates: 'waydroid
init -f' and 'waydroid upgrade' rewrite that file from scratch, and the values
are gone from Android until something puts them back. So this package ships
them as editable configuration under /usr/share and something else reconciles
them into place, the same division waydroid-ext-overlay-sync makes for the
overlay directory.

This release ships the values only. It installs no unit and no scriptlet that
applies them, so applying them means running artifacts/dexopt/install.sh from a
checkout of this repository -- once now, and again after any 'waydroid
upgrade'. That script is idempotent, keeps the untouched original as
waydroid_base.prop.pre-dexopt, and needs no container restart: installd reads
these properties per dexopt invocation rather than latching them at boot, so it
also sets them live with setprop. A container restart is worth avoiding on a
kiosk host, where it drops the session back to the greeter.

The values are tuned to one CPU and an administrator on any other should edit
them. On Core M-5Y70, cpu0 and cpu2 are the two threads of one physical core,
so a cpu-set of 0,2 hands dex2oat a whole core and leaves the other for the UI;
on a CPU that numbers its siblings differently the same string takes half of
each core and makes matters worse. That is why the file is marked as
configuration rpm never replaces: an edit made to it is kept across upgrades."

SOURCES="artifacts/dexopt/dexopt.prop
artifacts/dexopt/install.sh"

# WAYDROID_WORK is honoured by the installer and deliberately NOT passed: with
# DESTDIR set the script exits before it reads that variable, and naming it here
# would suggest the %install step goes near /var/lib/waydroid. PREFIX is passed
# so the payload lands under %{_datadir} rather than the installer's /usr/local.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    sh artifacts/dexopt/install.sh'

# Exactly what the installer stages with DESTDIR set, verified by running it into
# a scratch DESTDIR: one 0644 file under %{_datadir}/waydroid-dexopt. The
# directory is owned here because nothing else puts anything in it.
#
# %config(noreplace) and not plain %config, per docs/47, which specifies "values
# in %config(noreplace)" for this package. The flag is the point rather than a
# formality: these two lines are the one part of this modification an admin
# legitimately tunes, because the right cpu-set is a property of their CPU. Plain
# %config would move the admin's edit to .rpmsave on every upgrade and install
# ours as the live ones, silently reintroducing the pathological pinning the edit
# existed to fix.
#
# One consequence to settle before this is built, and it is not this file's call:
# the payload is under /usr/share and not /etc, because that is where the
# installer puts it and this modification does not change the installer. rpmlint
# reports a %config file outside /etc and /var as
# non-etc-or-var-file-marked-as-conffile, and on the rpm-ostree target /usr is
# read-only, so the file rpm is protecting is one the admin cannot edit in place
# anyway. The two coherent endings are an installer that honours a CONFDIR and
# ships to /etc/waydroid-dexopt, or dropping the flag and putting the override
# elsewhere. Both are changes outside this modification.
PAYLOAD_FILES='%dir %{_datadir}/waydroid-dexopt
%config(noreplace) %{_datadir}/waydroid-dexopt/dexopt.prop'
