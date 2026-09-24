# waydroid-ext-backlight -- docs/42-backlight-selinux.md
#
# The SELinux half of the brightness fix. container_manager.py spawns
# waydroid-sensord as waydroid_t, which may read sysfs but not write it, so
# ILight::setLight returned Status::UNKNOWN from an EACCES and Android's
# brightness slider moved nothing. Being root does not help -- SELinux denies
# the domain, not the user -- and the denial is dontaudit'ed, so ausearch shows
# nothing at all.
#
# TWO HALVES, ONE PACKAGE. The CIL module declares waydroid_backlight_t and
# allows waydroid_t to write it; the udev rule puts that label on the
# brightness attribute on every boot, because sysfs labels do not persist.
#
# A PRIVATE TYPE TAKES ACCESS AWAY AS WELL AS GRANTING IT, which cost this
# modification a regression it carried silently for a fortnight. Relabelling
# brightness to waydroid_backlight_t means the base policy's rules about
# sysfs_t stop applying to it, so systemd-backlight -- which had been saving
# and restoring the panel value perfectly well as init_t -- started failing
# with EACCES on 2026-09-10, the day this module first landed, and failed 978
# times before anyone connected the two. The CIL now grants init_t back the
# access the relabel took from it. Anything else that legitimately writes that
# attribute will need the same treatment; the symptom is a permission error
# with no AVC to explain it.
#
# HOW THE POLICY GETS LOADED, AND WHY NOT FROM %post
#
# It used to be %post, and on the first real install (2026-09-24) that was found
# to do nothing on an rpm-ostree host: scriptlets run against the compose, not
# the booted system, so the module never reached the running machine. Proved by
# inspecting the deployment's pristine /usr/etc -- which is what the live /etc is
# merged from at boot -- and finding no waydroid_backlight in it. The package
# installed, its SELinux half did nothing, and nothing reported a problem; the
# only reason brightness still worked on that host was a copy hand-loaded weeks
# earlier and carried through ostree's /etc merge.
#
# So the module is now loaded at boot by waydroid-backlight-policy.service,
# which is the answer artifacts/overlay-manager already uses for the same
# reason. The loader is idempotent by CIL hash rather than by module name,
# because `semodule -l` cannot tell this policy from a differently-versioned one
# of the same name, and semodule -i rebuilds the whole store and is not free.
#
# %post still calls the loader, which is right on an ordinary host -- the fix
# lands immediately there instead of at the next boot -- and is a harmless no-op
# on ostree, where the unit is what actually does the work.

VERSION=1.0.3
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Let Waydroid's sensor daemon write the panel backlight under SELinux"

LICENSE="GPL-3.0-or-later"

# semodule is policycoreutils; selinuxenabled is libselinux-utils; udevadm is
# systemd-udev. All three are used by the scriptlets rather than at runtime,
# but a Requires is still right: a package whose %post cannot run installs
# successfully and then does nothing, which is the failure mode this whole
# modification exists to avoid.
BUILDREQUIRES="systemd-rpm-macros"

REQUIRES="waydroid
policycoreutils
libselinux-utils
systemd-udev"

# The daemon that benefits. Not a hard Requires: the label and the policy are
# correct on their own and can be staged before the daemon exists, which is
# also how this was verified. It stays a Recommends now that
# waydroid-ext-sensord exists (2026-09-24) -- a weak dependency is pulled in by
# default and can still be declined, which is the right strength for "this
# grants a permission to something you probably also want".
RECOMMENDS="waydroid-ext-sensord"

DOCS="docs/42-backlight-selinux.md docs/37-brightness.md"

DESCRIPTION="Gives Waydroid's host-side sensor daemon permission to write the panel
backlight, so Android's brightness slider drives the real display.

The daemon serves android.hardware.light@2.0::ILight and writes
/sys/class/backlight, but container_manager.py spawns it as waydroid_t, and
that domain may read sysfs and not write it. Every setLight therefore failed,
and failed invisibly: the denial is dontaudit'ed, so ausearch reports nothing
and the daemon's own logs show only an EACCES with no explanation. Running as
root changes nothing, because SELinux denies the domain rather than the user.

Rather than granting waydroid_t write on all of sysfs, this declares a private
type for exactly one attribute and allows only that. The udev rule reapplies
the label on every boot, since sysfs is not persistent and a label set by hand
is gone at the next reboot.

Both halves are required and neither does anything alone, so they install and
revert together. A running daemon needs no restart: SELinux checks each write
as it happens, so an already-spawned daemon simply stops being denied."

SOURCES="artifacts/backlight/install.sh
artifacts/backlight/waydroid_backlight.cil
artifacts/backlight/99-waydroid-backlight.rules
artifacts/backlight/waydroid-backlight-policy
artifacts/backlight/waydroid-backlight-policy.service"

# UDEVRULESDIR is overridden away from the installer's /etc default. A packaged
# rule belongs in %{_udevrulesdir}, which udev reads equally, and that leaves
# /etc free for an admin override -- and avoids shipping a %config file that no
# admin is expected to edit. The macro comes from systemd-rpm-macros; on a
# builder without it, build-mod.sh defines it the same way it defines _unitdir.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    CILDIR=%{_datadir}/waydroid-backlight \
    UDEVRULESDIR=%{_udevrulesdir} \
    UNITDIR=%{_unitdir} \
    sh artifacts/backlight/install.sh'

# semodule -i is idempotent and performs the upgrade too, so there is no $1
# guard on %post: a changed CIL has to land on upgrade as well as on install.
# selinuxenabled keeps the whole thing inert on a host built without SELinux,
# where the module would be meaningless rather than wrong. `|| :` throughout
# because no scriptlet may fail a transaction.
SCRIPTLETS='%post
# The loader, not semodule directly: it is idempotent by CIL hash, re-applies
# the udev label and reports a label that did not land. On an ordinary host this
# makes the fix effective immediately; on rpm-ostree this scriptlet runs against
# the compose and does nothing, which is exactly why the boot unit above exists
# and is what actually loads the policy there. No $1 guard: a changed CIL must
# land on upgrade too, and the hash check makes a no-op upgrade cheap.
%{_bindir}/waydroid-backlight-policy --quiet || :

%postun
# $1 -eq 0 is uninstall. On upgrade the incoming install scriptlet reloads
# anyway, and removing the module here would briefly unlabel a working panel.
#
# On rpm-ostree this does NOT unload the module, for the same compose-versus-
# booted-system reason as the install scriptlet -- so an uninstall leaves policy
# loaded and harmless, granting a write to a type no remaining file carries.
# `waydroid-backlight-policy --unload` is the way to actually drop it, and the
# package README says so rather than pretending the scriptlet did it.
if [ $1 -eq 0 ]; then
    if selinuxenabled 2>/dev/null; then
        semodule -r waydroid_backlight || :
    fi
    rm -f /var/lib/waydroid-backlight/policy.sha256 || :
    udevadm control --reload || :
fi
'

PAYLOAD_FILES='%dir %{_datadir}/waydroid-backlight
%{_datadir}/waydroid-backlight/waydroid_backlight.cil
%{_udevrulesdir}/99-waydroid-backlight.rules
%{_bindir}/waydroid-backlight-policy
%{_unitdir}/waydroid-backlight-policy.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-backlight-policy.service'
