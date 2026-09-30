# waydroid-ext-appfuse -- docs/55-appfuse.md
#
# Android's AppFuse did not work in the container, so every openDocument in a
# DocumentsProvider that synthesises its bytes failed -- cloud storage clients,
# archive browsers, MTP hosts, encrypted vaults. Such an app installs and browses
# correctly and fails only when something opens a document, which is why this can
# sit unnoticed behind an app that looks half-working.
#
# vold asks mount(2) for context="u:object_r:app_fuse_file:s0" and
# fscontext=u:object_r:app_fusefs:s0, and a MAINLINE Waydroid runs against the
# HOST's SELinux policy rather than Android's. Fedora cannot parse either, so
# mount returns EINVAL before FUSE is reached.
#
# THREE IDENTIFIERS ARE MISSING, NOT ONE. Both types are Android-only, and so is
# the SELinux *user* `u` -- u:object_r:fusefs_t:s0 is invalid on a Fedora host
# with a type Fedora certainly has. Declaring the two types alone still returns
# EINVAL. Declaring a user is safe: policydb_context_isvalid special-cases
# object_r, checking only that user, role and type exist, so `u` needs no roles
# and no process ever runs as it.
#
# DECLARATIONS PLUS EXACTLY ONE ALLOW RULE, and every line proven load-bearing by
# removal. The two failure modes differ from each other, which is what makes them
# diagnosable: dropping the file_type attribute yields FuseUnavailableMountException
# -- the mount succeeds and the app still cannot use it -- while dropping the one
# associate rule goes back to Failed to mount. A first draft carried four
# container_runtime_t rules and a wide file and dir grant; all of it was redundant,
# because that domain already holds those permissions through the base policy's
# attribute-based rules. Assigning file_type and filesystem_type is what makes
# existing rules apply to the new types.
#
# THE DIAGNOSTIC TRAP IS WORTH MORE THAN THE FIX. ausearch is completely clean for
# this, because a context that cannot be parsed never becomes an AVC -- there is
# no SID to deny anything to. The kernel says it in dmesg:
# security_context_str_to_sid (u:object_r:app_fuse_file:s0) failed with errno=-22.
# That is not a dontaudit like waydroid-ext-backlight's sysfs write; it is
# pre-audit. Anyone debugging this package's failure should read dmesg.
#
# HOW THE POLICY GETS LOADED, AND WHY NOT FROM %post ALONE
#
# The same reason waydroid-ext-backlight learned on 2026-09-24: on an rpm-ostree
# host a scriptlet runs against the compose, not the booted system, so semodule -i
# from %post never reaches the running machine and the package installs having done
# nothing. waydroid-appfuse-policy.service does the load at boot. %post still calls
# the loader, which is right on an ordinary host -- the fix lands immediately there
# -- and is a harmless no-op on ostree.
#
# UNLIKE BACKLIGHT, NOTHING NEEDS REAPPLYING EVERY BOOT. That module's loader also
# exists because sysfs labels do not persist; this one only declares policy, and
# semodule -i writes it into /etc/selinux/targeted/active/modules where it stays.
# The unit is there purely to get the load to happen on the booted system once.
#
# THE LOADER VERIFIES RATHER THAN ASSUMING. semodule exiting 0 is not evidence the
# fix is in force, because the whole fault is an unparseable context reported with
# nothing in the audit log. The loader writes each context vold needs to
# /sys/fs/selinux/context -- mode 0666, so no privilege and no setools -- and the
# kernel returns EINVAL if it cannot parse it. Same principle as
# waydroid-backlight-policy reading its label back: absence of errors is not success.
#
# NO CONTAINER RESTART, EVER. vold performs the AppFuse mount on demand, per
# openProxyFileDescriptor call, so a policy that lands late costs only the calls
# made before it. That is why this package can be installed on a running kiosk
# without dropping the session to the greeter.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Make Android's AppFuse work so apps can open files they generate"

LICENSE="GPL-3.0-or-later"

BUILDREQUIRES="systemd-rpm-macros"

# semodule is policycoreutils; selinuxenabled is libselinux-utils. Both are used
# by the loader rather than at runtime, but a Requires is still right: a package
# whose loader cannot run installs successfully and then does nothing, which is
# the exact failure mode this modification exists to avoid.
REQUIRES="waydroid
policycoreutils
libselinux-utils"

# Deliberately no Recommends. This grants a permission to the Android framework
# itself rather than to any daemon in this repo, so there is no companion package
# to suggest -- it is useful on its own to anyone running an app that needs it.

DOCS="docs/55-appfuse.md"

DESCRIPTION="Lets Android apps serve a real file descriptor for content they generate,
which is what every storage app that has no files behind it depends on.

Android calls this AppFuse. When an app implements a DocumentsProvider over
content it synthesises -- a cloud client, an archive browser, an encrypted
vault -- StorageManager.openProxyFileDescriptor() is what turns that into an
ordinary seekable fd another app can read. vold mounts a small FUSE filesystem
per open and the app itself answers the protocol.

On a Linux host none of it worked. vold asks the kernel to label that mount
with SELinux names that exist only in Android's own policy, including an
SELinux user called simply 'u', and a MAINLINE Waydroid is checked against the
host's policy instead. The kernel cannot parse the request, mount fails with
EINVAL, and the app sees 'Failed to mount' on every attempt -- after having
listed its files perfectly well, which makes it look like a broken app rather
than a missing permission. Nothing appears in the audit log, because a context
that cannot be parsed never produces a denial to log.

This package teaches the host policy the three names it was missing, as
private types so nothing else on the system is widened, and loads that policy
at boot. It changes nothing inside the Android images and needs no container
restart: the mount is performed per call, so the next open already succeeds."

SOURCES="artifacts/appfuse/install.sh
artifacts/appfuse/waydroid_appfuse.cil
artifacts/appfuse/waydroid-appfuse-policy
artifacts/appfuse/waydroid-appfuse-policy.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    CILDIR=%{_datadir}/waydroid-appfuse \
    UNITDIR=%{_unitdir} \
    sh artifacts/appfuse/install.sh'

# semodule -i is idempotent and performs the upgrade too, and the loader is
# idempotent by CIL hash on top of that, so there is no $1 guard on %post: a
# changed CIL has to land on upgrade as well as on install. `|| :` because no
# scriptlet may fail a transaction.
SCRIPTLETS='%post
# The loader, not semodule directly: it is idempotent by CIL hash and it verifies
# that the kernel will actually parse the contexts vold needs. On an ordinary host
# this makes the fix effective immediately; on rpm-ostree this scriptlet runs
# against the compose and does nothing, which is why the boot unit above exists and
# is what actually loads the policy there.
%{_bindir}/waydroid-appfuse-policy --quiet || :

%postun
# $1 -eq 0 is uninstall. On upgrade the incoming install scriptlet reloads anyway,
# and removing the module here would break AppFuse for the gap between the two.
#
# On rpm-ostree this does NOT unload the module, for the same compose-versus-
# booted-system reason as the install scriptlet -- so an uninstall leaves policy
# loaded and harmless, declaring two types and a user that nothing then uses.
# `waydroid-appfuse-policy --unload` is the way to actually drop it, and this
# package says so rather than pretending the scriptlet did it.
if [ $1 -eq 0 ]; then
    if selinuxenabled 2>/dev/null; then
        semodule -r waydroid_appfuse || :
    fi
    rm -f /var/lib/waydroid-appfuse/policy.sha256 || :
    rmdir /var/lib/waydroid-appfuse 2>/dev/null || :
fi
'

PAYLOAD_FILES='%dir %{_datadir}/waydroid-appfuse
%{_datadir}/waydroid-appfuse/waydroid_appfuse.cil
%{_bindir}/waydroid-appfuse-policy
%{_unitdir}/waydroid-appfuse-policy.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-appfuse-policy.service'
