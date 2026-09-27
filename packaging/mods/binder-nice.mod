# waydroid-ext-binder-nice -- docs/40-binder-nice.md
#
# One drop-in on waydroid-container.service, one line in it: LimitNICE=40.
#
# WHY THIS IS A PACKAGE AND NOT A NOTE ABOUT SILENCING A LOG MESSAGE
#
# DESCRIPTION has the mechanism. What belongs here is that it makes silencing a
# non-option: the message and the dropped inheritance are one event, so clearing
# bit 0 of binder's debug_mask removes the evidence and not the defect -- and
# with it every other binder user error, which is how docs/33 found the Wi-Fi
# parcel bugs. Also that the fault is entirely ours: 33,977 of the 33,984 lines
# printed in a 6 h 23 m boot came from two hwbinder threads of one
# waydroid-sensord, and no Android process contributed.
#
# WHY A DROP-IN RATHER THAN POLICY OR CODE
#
# The RLIMIT_NICE branch is reached only when the receiving task lacks
# CAP_SYS_NICE, and the kernel asks with has_capability_noaudit(), so SELinux
# gets a vote and records nothing: sensord is waydroid_t and wifid unconfined_t,
# identical rlimits and POSIX capabilities, opposite outcomes, ausearch empty.
# docs/40 is careful that waydroid_t lacking `capability sys_nice` is inferred
# from that comparison and not confirmed -- sesearch is not installed here.
#
# Granting waydroid_t the capability needs a host policy module for what one line
# fixes; setrlimit() inside sensord needs CAP_SYS_RESOURCE to raise its own hard
# limit, which waydroid_t may also withhold, and was not attempted. The drop-in
# wins on a point neither has: systemd applies LimitNICE as PID 1, BEFORE the
# SELinux transition, so the fix cannot be defeated by the restriction it routes
# around. All three rejections are in docs/40.
#
# WHERE THE DROP-IN GOES -- %{_unitdir}, NOT /etc
#
# The installer defaults to /etc/systemd/system/waydroid-container.service.d,
# which is where the file sits on the host today (packaging/README.md's audit).
# That is right for a by-hand install on an immutable host, where /usr is
# read-only and $PREFIX/lib would be /usr/local/lib -- a symlink into /var that
# SELinux labels lib_t, which init_t may not start a unit from (docs/27). None of
# it applies to an RPM writing the real /usr/lib.
#
# So UNITDIR is overridden, following waydroid-ext-backlight, which settled this
# same question for its udev rule on 2026-09-24, and matching
# packaging/waydroid-bigtab01.spec, the monolithic spec being split up, which
# already shipped this exact file to %{_unitdir}. The admin loses nothing:
# systemd.unit(5) reads drop-ins from /etc ahead of /run ahead of /usr/lib, so a
# same-named nice-limit.conf under /etc overrides this one and an empty one
# neutralises it -- an override the /etc location could not offer, because there
# the packaged file would BE the file to edit. /etc also has no good answer
# available: packaging/test-install.sh's 2026-09-23 policy requires %config
# there, which would declare a file nobody edits to be configuration, while
# shipping it plain is what rpmlint's non-conffile-in-etc objects to.
#
# %dir ON ANOTHER PACKAGE'S DROP-IN DIRECTORY
#
# Fedora's waydroid ships the unit, not a directory for other people's overrides
# of it, so waydroid-container.service.d does not exist until something drops a
# file in. This package must own it or rpm leaves an unowned path behind on
# uninstall. Two packages owning one directory is shared, not a conflict, so
# co-ownership stays correct if waydroid ever ships it; the only way that becomes
# a real conflict is a disagreement about mode or ownership, and this ships the
# 0755 root:root `install -D` produces.
#
# WHO BENEFITS, AND WHY NOTHING IS DEPENDED ON FOR IT
#
# The limit reaches waydroid-container.service and everything Waydroid starts
# beneath it -- waydroid-sensord, which has no unit of its own on purpose, and
# the container's Android processes. So sensord BENEFITS and this package does
# not need it. docs/47's test for a hard dependency is whether the package
# without it is worse than stock, and a raised rlimit nothing exercises is inert,
# not broken. Nor a Recommends, which is installed by default and would pull a
# C++ daemon and libgbinder onto a host that asked for one text file. The
# defensible dependency points the other way, and docs/47 already expresses it
# where it belongs: the waydroid-ext-sensors group is sensord plus binder-nice.
#
# NO SCRIPTLETS AT ALL
#
# systemd's own file trigger on %{_unitdir} does the daemon-reload, and nothing
# restarts the container: on a kiosk host that drops the session to the display
# manager (docs/47). So the drop-in lands at the next natural start of
# waydroid-container.service, and until then the running daemon can be corrected
# in place -- which is how the fix was proven before anything was installed:
# prlimit --pid $(pidof waydroid-sensord) --nice=40:40. Reverting is deleting the
# file.

VERSION=1.0.0
RELEASE=1
KIND=host

# Genuinely noarch: the payload is one text file of systemd directives.
ARCH=noarch

SUMMARY="Restore binder priority inheritance in the Waydroid container"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason waydroid-ext-wifid declares it.
BUILDREQUIRES="systemd-rpm-macros"

# waydroid owns waydroid-container.service, the unit this drop-in extends:
# without it the package configures a unit that does not exist. systemd is what
# reads the drop-in and what LimitNICE is addressed to -- the file is inert text
# to anything else -- and it owns the %{_unitdir} the payload lands in. Nothing
# else: the payload execs no command.
#
# No dependency on waydroid-ext-sensord in either strength; see WHO BENEFITS. No
# kernel floor either: docs/51 records why a Requires on a kernel is wrong on an
# rpm-ostree host, which composes against whatever kernel its image carries, so
# the dependency would make the package uninstallable rather than inert.
REQUIRES="waydroid
systemd"

DOCS="docs/40-binder-nice.md"

DESCRIPTION="Raises RLIMIT_NICE for the Waydroid container, so the kernel's binder driver
applies priority inheritance instead of skipping it -- and stops logging that
it skipped it, which on this host was roughly a million journal records a boot.

The symptom to recognise is the journal filling with

    binder: 1574 RLIMIT_NICE not set
    binder_user_error: 291 callbacks suppressed

at tens of lines a second, where the number is a thread id belonging to a
host-side Waydroid daemon rather than to anything inside Android. Measured over
one 6 1/2 hour boot: 33,984 lines printed, 994,195 more counted by the rate
limiter's own suppression records, 1,028,179 events in total.

The message and a real defect are the same event, which is the reason to fix
this rather than silence it. systemd defaults RLIMIT_NICE to 0; the binder
driver converts that into a floor of nice 20, one above the maximum, reads it
as never having been set, logs the line and returns without applying the
calling thread's priority. Every record is therefore an inheritance already
lost, so turning the message off through binder's debug mask would leave the
defect in place, remove the evidence for it, and hide every other binder error
with it.

The package is one systemd drop-in containing LimitNICE=40, which permits a
nice floor of -20. That raises a ceiling rather than requesting a priority, so
nothing runs at a priority it did not ask for. systemd applies the limit as
PID 1, before the SELinux transition, which matters because the reason the
limit is needed is SELinux withholding CAP_SYS_NICE from the domain the
affected daemon runs in -- unauditably, so there is nothing in ausearch to find
and nothing anywhere that names SELinux as the cause.

The drop-in lands at the next start of waydroid-container.service and nothing
here restarts that unit: on a kiosk host a container restart drops the session
back to the display manager. Until then the running daemon can be corrected
with prlimit and no restart at all. Uninstalling removes the one file and
restores stock behaviour exactly."

SOURCES="artifacts/container/install.sh
artifacts/container/nice-limit.conf"

# No PREFIX. The installer's header says PREFIX is accepted and ignored because
# nothing lands outside UNITDIR, and it references the variable nowhere -- so
# passing it would only suggest it had a use.
INSTALL='DESTDIR=%{buildroot} UNITDIR=%{_unitdir} \
    sh artifacts/container/install.sh'

# Exactly the tree the installer produces, verified by running it into a scratch
# DESTDIR. %dir because Fedora's waydroid ships no drop-in directory for its own
# unit; see the %dir section above for why co-ownership is safe if that changes.
PAYLOAD_FILES='%dir %{_unitdir}/waydroid-container.service.d
%{_unitdir}/waydroid-container.service.d/nice-limit.conf'
