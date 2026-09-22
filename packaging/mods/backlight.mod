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
# Either half alone is completely inert, which is why they are not separable
# modifications however tempting the symmetry.
#
# CIL and not .te on purpose: semodule compiles CIL directly, so this needs no
# selinux-policy-devel, which on an rpm-ostree host would cost a layered
# install and a reboot.

VERSION=1.0.0
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
# also how this was verified. That package is not split out of
# waydroid-sensord.spec yet, so today this is a forward reference.
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
artifacts/backlight/99-waydroid-backlight.rules"

# UDEVRULESDIR is overridden away from the installer's /etc default. A packaged
# rule belongs in %{_udevrulesdir}, which udev reads equally, and that leaves
# /etc free for an admin override -- and avoids shipping a %config file that no
# admin is expected to edit. The macro comes from systemd-rpm-macros; on a
# builder without it, build-mod.sh defines it the same way it defines _unitdir.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    CILDIR=%{_datadir}/waydroid-backlight \
    UDEVRULESDIR=%{_udevrulesdir} \
    sh artifacts/backlight/install.sh'

# semodule -i is idempotent and performs the upgrade too, so there is no $1
# guard on %post: a changed CIL has to land on upgrade as well as on install.
# selinuxenabled keeps the whole thing inert on a host built without SELinux,
# where the module would be meaningless rather than wrong. `|| :` throughout
# because no scriptlet may fail a transaction.
SCRIPTLETS='%post
if selinuxenabled 2>/dev/null; then
    semodule -i %{_datadir}/waydroid-backlight/waydroid_backlight.cil || :
fi
udevadm control --reload || :
udevadm trigger --subsystem-match=backlight --action=add || :

%postun
# $1 -eq 0 is uninstall. On upgrade the incoming install scriptlet reloads
# anyway, and removing the module here would briefly unlabel a working panel.
if [ $1 -eq 0 ]; then
    if selinuxenabled 2>/dev/null; then
        semodule -r waydroid_backlight || :
    fi
    udevadm control --reload || :
fi
'

PAYLOAD_FILES='%dir %{_datadir}/waydroid-backlight
%{_datadir}/waydroid-backlight/waydroid_backlight.cil
%{_udevrulesdir}/99-waydroid-backlight.rules'
