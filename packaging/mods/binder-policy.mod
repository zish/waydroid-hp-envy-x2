# waydroid-ext-binder-policy -- docs/64-vidiot01-atv-host.md, docs/47-package-split.md
#
# Two allow rules that decide whether Android boots at all on a Fedora host.
#
# WHAT IS BROKEN WITHOUT IT
#
# Waydroid's LXC container runs as container_runtime_t, but an Android image
# whose HALs are packaged as APEXes runs those HALs in spc_t -- and Fedora's
# policy allows binder between the two in neither direction. Every transaction
# between a HAL and the rest of the container is refused. Android does not
# fail loudly; it simply never finishes booting, sitting in bootanim while
# init restarts the same crash-looping services forever.
#
# Measured by an A/B boot pair on vidiot01, 2026-10-08, host Enforcing
# throughout:
#
#   BARE    no sys.boot_completed in 240 s, bootanim running, six services
#           [restarting], 657 AVCs, every one `denied { call }
#           spc_t -> container_runtime_t`, plus `binder: N:N transaction
#           credentials failed` in the kernel ring buffer.
#   MODULE  sys.boot_completed after 18 SECONDS, zero binder AVCs, every
#           service running, setup wizard rendered on the GNOME desktop.
#
# THIS IS A GAP IN FEDORA'S POLICY, AND THAT IS WHY IT IS PACKAGED HERE
#
# Fedora 43's selinux-policy-43.10-1.fc43 already ships a `waydroid` module at
# priority 200 that already thinks about binder. Decompiled from the live
# system with `semodule -E waydroid` and /usr/libexec/selinux/hll/pp, it grants
# exactly these permissions to waydroid_t, unconfined_t and
# unconfined_service_t -- and not to spc_t. There is no dontaudit hiding it;
# the rule was simply never written.
#
# So this package is a STOPGAP for a distribution bug, and the header of the
# .cil says so too. The real fix belongs in selinux-policy, where it would land
# at priority 200 and make this package redundant rather than wrong. Nothing
# here should be read as a Waydroid defect.
#
# THE ONE MODIFICATION IN THIS REPOSITORY THAT IS NOT HOST-SPECIFIC
#
# Everything else here is shaped by one machine: an HP Envy x2's sensor hub, a
# particular camera, a particular panel. This is not. It is noarch, compiles
# nothing, contains no host-specific value, and reproduces on any Fedora host
# running Waydroid with an APEX-HAL image. docs/53 answers "could a general
# user build and install?" with a flat no, because the two compiled daemons
# cannot be built off the dev box -- that blocker does not apply to this one,
# which makes it the easiest thing in the project to hand to a stranger.
#
# WHY NOT JUST `semodule -i` IN %post
#
# Because on an rpm-ostree host that silently does nothing: scriptlets run
# against the compose, not the booted system. waydroid_backlight was found
# failing exactly that way on its first real install (2026-09-24) -- package
# present, policy absent, nothing reporting a problem. The boot unit is what
# actually loads the policy there, and the %post is the optimisation for
# ordinary hosts. Same shape as waydroid-ext-appfuse and waydroid-ext-backlight.
#
# WHAT THE LOADER CHECKS, AND WHY IT IS NOT semodule's EXIT STATUS
#
# `semodule -i` exiting 0 means the CIL compiled and was stored, not that the
# decision came out the way we wanted -- a higher-priority module or a renamed
# type would leave it loaded and the permission still refused. Here the cost of
# finding that out the other way is a container that will not boot and a
# 240-second wait, so the loader asks the kernel instead, through
# /sys/fs/selinux/access (the security_compute_av interface, mode 0666, no
# setools and no privilege). Two things learned doing it, both written into the
# loader because both would otherwise bite silently:
#
#   * /sys/fs/selinux/class/binder/perms/<p> holds a 1-BASED BIT POSITION, not
#     a bitmask -- on F43 impersonate=1, call=2, set_context_mgr=3, transfer=4,
#     which are plainly indices. The mask is 1 << (pos - 1). Verified against a
#     live decision: allowed=0xa is exactly call|transfer.
#   * selinuxfs replies WITHOUT a trailing newline, so `read` hits EOF before a
#     delimiter and returns 1 WHILE HAVING ASSIGNED THE VARIABLES CORRECTLY
#     (measured: rc=1, value "a"). Branching on read's exit status made the
#     check fail on a host where the policy was demonstrably in force -- a false
#     "Android will not boot" alarm, which is worse than no check. The loader
#     tests the variable, and says why.
#
# Both the positive and the negative path were exercised on vidiot01 before
# this file was written: the real pair reports ok, and demanding a permission
# the CIL does not grant (impersonate) reports REFUSED with allowed=0xa and
# exits 3.
#
# WHAT IT DOES NOT SHIP
#
#   a16-boot-vidiot01.png. It is the evidence the boot happened and it belongs
#     beside the .cil in the repository, not in a binary package.
#   Anything about the images. The WayDroid-ATV Android 16 build this was found
#     against is not ours to redistribute, and the module is not specific to it
#     -- any image whose HALs are APEX-packaged needs the same rules.

VERSION=1.0.0
RELEASE=1
KIND=host

# One CIL, one POSIX shell loader, one unit. Nothing compiled, nothing that
# names a CPU or a machine.
ARCH=noarch

SUMMARY="Let Android's APEX-packaged HALs use binder, so the container boots"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. The only build-time dependency a package of text and shell has.
BUILDREQUIRES="systemd-rpm-macros"

# container-selinux is the hard one and the easy one to miss: spc_t and
# container_runtime_t are ITS types, not Waydroid's and not ours, so without it
# the CIL does not merely fail to help -- `semodule -i` refuses to compile it.
# Fedora's own waydroid-selinux requires it for the same reason.
#
# waydroid, because a policy exception for Waydroid's container on a host with
# no Waydroid is inert. Same strength as waydroid-ext-backlight uses.
#
# Everything the loader actually runs:
#   policycoreutils    semodule, for -l, -i and -r.
#   libselinux-utils   selinuxenabled, which is the "is this host relevant" gate.
#   coreutils          sha256sum, cut, cat, mkdir, rm, printf, install.
#   systemd            the unit machinery.
# grep and cmp are used too and are in grep/diffutils; both are base-system here
# and every other mod in this repository that uses them declares them, so they
# are declared.
REQUIRES="waydroid
container-selinux
policycoreutils
libselinux-utils
coreutils
systemd
grep
diffutils"

# The package whose gap this fills. Weak rather than hard on purpose: the module
# depends on container-selinux's TYPES but on nothing waydroid-selinux defines,
# so a host running Waydroid built from source rather than from Fedora's RPM is
# served perfectly well and should not be excluded. Naming it anyway is the same
# courtesy waydroid-ext-mdns pays avahi -- a package whose entire subject is
# another package's policy should say whose.
RECOMMENDS="waydroid-selinux"

DOCS="docs/64-vidiot01-atv-host.md
docs/63-second-host-and-android-16.md"

DESCRIPTION="Grants binder IPC between the two SELinux domains Waydroid's container
actually runs in, which on a Fedora host is the difference between Android
booting and Android never finishing its boot.

Waydroid's container runs as container_runtime_t. An Android image that
packages its HALs as APEXes runs those HALs in spc_t. Fedora's policy allows
binder between the two in neither direction, so every call from a HAL to the
rest of the container is refused -- and the failure is quiet in the worst way:
there is no crash and no error dialog, just bootanim forever while init
restarts the same services. On the reference host a bare boot produced 657
denials and never completed in four minutes; with this module it reached
sys.boot_completed in eighteen seconds with none.

THIS IS A GAP IN THE DISTRIBUTION'S POLICY, NOT A BUG IN WAYDROID. Fedora
already ships a waydroid policy module that grants these exact binder
permissions to waydroid_t, unconfined_t and unconfined_service_t. It does not
grant them to spc_t, and nothing dontaudits the result. The right long-term
fix is in selinux-policy, at which point this package becomes unnecessary.

IT VERIFIES RATHER THAN ASSUMING. Loading a policy module and having the
permission actually in force are different claims, and the usual way to
discover the difference here is a container that will not start. So after
loading, the tool asks the kernel for the live access-vector decision through
/sys/fs/selinux/access and reports, per direction, whether call and transfer
are really allowed. It needs no setools and no privilege to do it.

NOTHING INSIDE THE ANDROID IMAGES CHANGES. This is host policy only -- no
overlay content, no patched vendor binary, nothing that an image upgrade can
invalidate. The policy applies to each binder transaction as it happens, so a
container that has not started yet simply boots. A container that ALREADY
failed to boot for want of these rules does not recover on its own: its init
gave up on the crash-looping HALs long ago, and only a fresh session picks the
policy up. Installing this package names that restart and does not perform it,
because on a kiosk host it drops the session to the greeter.

Removing the package removes the rules, and on a host running an APEX-HAL
image that means Android stops booting again."

SOURCES="artifacts/binder/install.sh
artifacts/binder/selftest.sh
artifacts/binder/waydroid_binder.cil
artifacts/binder/waydroid-binder-policy
artifacts/binder/waydroid-binder-policy.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    CILDIR=%{_datadir}/waydroid-binder \
    UNITDIR=%{_unitdir} \
    sh artifacts/binder/install.sh'

# The loader does NOT parse the CIL -- it carries its own hardcoded idea of
# which permissions and which pair of domains to verify, which its header
# defends on the grounds that those are what Android's boot demands. The cost of
# that choice is drift: edit the .cil and the loader goes on checking the old
# rules, reporting "ok" for permissions the policy no longer grants. Nothing
# surfaces that until a container will not boot.
#
# So %check cross-validates the two, and the rest of the package's assumptions
# with it: that the CIL is two allow rules and nothing else (no dontaudit
# sneaking in to hide the very denials this exists to remove), that install.sh
# stages exactly the file set %files claims, that the unit's @BINDIR@ is really
# substituted -- an earlier installer here shipped the literal token and failed
# silently, docs/25 -- and that the loader exits 0 rather than failing on a host
# with no SELinux, which is every build host.
#
# No root, no SELinux, no container, no network. The drift case was exercised
# by injecting a changed permission into a copy of the CIL and confirming the
# check fails, rather than assuming it would.
#
# This is the second host-kind modification to declare a CHECK, after mdns.
CHECK='%check
sh artifacts/binder/selftest.sh'

# semodule -i is idempotent and performs the upgrade too, and the loader is
# idempotent by CIL hash on top of that, so there is no $1 guard on %post: a
# changed CIL has to land on upgrade as well as on install. `|| :` because no
# scriptlet may fail a transaction -- and this one legitimately exits 3 when the
# kernel disagrees that the rules are in force, which is a thing to report and
# not a reason to fail an install.
SCRIPTLETS='%post
# The loader, not semodule directly: idempotent by CIL hash, and it asks the
# kernel whether the decision really came out right. On an ordinary host this
# makes the fix effective immediately; on rpm-ostree this scriptlet runs against
# the compose and does nothing, which is why the boot unit above exists and is
# what actually loads the policy there.
%{_bindir}/waydroid-binder-policy --quiet || :

%postun
# $1 -eq 0 is uninstall. On upgrade the incoming install scriptlet reloads
# anyway, and removing the module here would leave a window in which the
# container could not boot.
#
# On rpm-ostree this does NOT unload the module, for the same compose-versus-
# booted-system reason as the install scriptlet, so an uninstall there leaves
# the policy loaded and harmless. `waydroid-binder-policy --unload` is the way
# to actually drop it, and this package says so rather than pretending the
# scriptlet did it.
if [ $1 -eq 0 ]; then
    if selinuxenabled 2>/dev/null; then
        semodule -r waydroid_binder || :
    fi
    rm -f /var/lib/waydroid-binder/policy.sha256 || :
    rmdir /var/lib/waydroid-binder 2>/dev/null || :
fi
'

PAYLOAD_FILES='%dir %{_datadir}/waydroid-binder
%{_datadir}/waydroid-binder/waydroid_binder.cil
%{_bindir}/waydroid-binder-policy
%{_unitdir}/waydroid-binder-policy.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-binder-policy.service'
