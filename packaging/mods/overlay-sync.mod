# waydroid-ext-overlay-sync -- docs/36-packaging.md, docs/47-package-split.md
#
# The keystone. Every overlay component hard-requires this package, and until it
# existed none of them could be installed at all -- they build cleanly and then
# fail at `rpm -i` on an unsatisfiable dependency (packaging/README.md).
#
# WHAT IT IS FOR
#
# An RPM cannot own Waydroid's overlay. /var/lib/waydroid/overlay is state: it is
# emptied by `waydroid init -f`, by an image upgrade and by a container rebuild,
# and on an rpm-ostree host /var is outside the deployment entirely, so content a
# package puts there is not in the ostree commit and is not restored by a
# rollback. So components ship their payload into /usr -- read-only, versioned,
# part of the commit -- and this package ships the one tool that materialises it
# into /var, plus the boot unit that does so before the container starts.
#
# The ordering is the whole point: the overlay directory becomes the lowerdir of
# an overlayfs mount at container start, and a file added after that mount is on
# disk, visible to `ls`, and invisible to Android. Running Before= the container
# means the sync is always in effect, never merely written.
#
# WHAT IT DELIBERATELY DOES NOT DO
#
# It never restarts waydroid-container.service on its own. On a kiosk host that
# drops the session back to the SDDM greeter and needs someone at the machine, so
# it prints the restart and lets a human choose. --apply opts in.

VERSION=1.1.0
RELEASE=1
KIND=host

# Shell and a unit file. Nothing here is architecture-dependent -- the Android
# ELF lives in the component packages, which are correctly not noarch.
ARCH=noarch

SUMMARY="Reconcile Waydroid's overlay from packaged payload before container start"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}, same as every other package here that ships a unit.
BUILDREQUIRES="systemd-rpm-macros"

# coreutils for sha256sum, stat, install and mktemp, which the reconciler uses
# on every file it considers; gawk for the manifest merge. Both are effectively
# always present, and both are named anyway because a package that silently
# no-ops when a tool is missing is the failure mode this whole tool exists to
# prevent. systemd for the unit. waydroid because /var/lib/waydroid is the
# subject -- with no Waydroid there is nothing to reconcile.
# e2fsprogs for debugfs, which is how a derive row reads its input out of the
# user's own system.img or vendor.img. Read-only and unprivileged -- the images
# are 0644 ext2/4, so no loop mount and no root is needed for the read. It is a
# Requires and not a Recommends because a component that ships a patch instead
# of a binary deploys NOTHING without it, and would do so quietly.
REQUIRES="waydroid
systemd
coreutils
gawk
e2fsprogs"

# restorecon relabels what the tool places, and the tool guards its absence with
# command -v, so this is a genuine Recommends and not a Requires: on a host built
# without SELinux the package is correct and complete without it.
RECOMMENDS="policycoreutils"

DOCS="docs/user/overlay.md docs/36-packaging.md docs/47-package-split.md"

DESCRIPTION="Waydroid's overlay directory is state, not installed content, so no
package can own the files in it. This one owns the mechanism instead: a
reconciler that copies each component's staged payload from /usr into
/var/lib/waydroid/overlay, and a oneshot unit that runs it on every boot
before waydroid-container.service.

That ordering is load-bearing. The overlay directory becomes the lowerdir
of an overlayfs mount when the container starts, and a file added to a
mounted lowerdir is undefined behaviour -- here it is simply invisible, on
disk and unreadable by Android, with nothing warning that it did not take.
Reconciling before the mount means what is staged is what is in effect.

It answers the question the other way round too. --verify reports drift and
changes nothing, exiting 3 if the live overlay no longer matches what the
installed components say it should be: a wiped overlay, a hand-edit made
while chasing something and then forgotten, or a restore of /var from a
backup older than the packages.

Some components ship no payload at all. A component may instead record where
the file lives inside your own Waydroid image, what it must hash to, and the
handful of bytes to change -- and the reconciler then extracts it, checks it
is the file the package was built against, patches it, checks the result and
installs that. Nothing is downloaded and nothing of somebody else's is
redistributed; the input was already on your disk. If the image no longer
matches what the package was built against, it refuses and says so, which is
the alarm worth having: it means an image update has moved under a file a
package silently replaces. --check-upstream asks that question for every such
file without changing anything.

Files edited since deployment are never removed. Each is compared against
the hash recorded when it was placed, and one that no longer matches is
reported and left alone, because it is somebody's work in progress and not
the tool's to discard. --force is the way to say otherwise, and it has to
be typed.

Nothing here restarts the container. On a kiosk host that ends the running
session and drops back to the greeter, so a change that needs a restart to
reach Android says so and stops."

SOURCES="artifacts/overlay-manager/install.sh
artifacts/overlay-manager/waydroid-overlay-sync
artifacts/overlay-manager/waydroid-overlay-sync.service"

# UNITDIR is passed explicitly so the unit lands in %{_unitdir} rather than the
# installer's /etc default. A packaged unit belongs in /usr/lib/systemd/system;
# that leaves /etc free for an admin drop-in, which is then unambiguously theirs
# and is neither owned nor removed by this package.
#
# STAGEDIR is passed explicitly too, even though it is what the installer would
# default to, because it is the contract between this package and every overlay
# component: gen-spec.sh renders their payload into %{_prefix}/lib/waydroid-overlay
# and this is the other half of that agreement.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    STAGEDIR=%{_prefix}/lib/waydroid-overlay \
    sh artifacts/overlay-manager/install.sh'

# The two staging directories are owned HERE and by nothing else. Component
# packages list only their own subdirectory and their own manifest, so without
# these two lines both parents would be unowned on an installed system.
#
# Nothing in this package is %config. The reconciler and the unit are not files
# an admin edits -- the supported override is a drop-in under /etc, which this
# package does not ship and therefore cannot take away.
PAYLOAD_FILES='%{_bindir}/waydroid-overlay-sync
%{_unitdir}/waydroid-overlay-sync.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-overlay-sync.service
%dir %{_prefix}/lib/waydroid-overlay
%dir %{_prefix}/lib/waydroid-overlay/manifests'

# Reconcile on install so a fresh install of the tool alongside already-staged
# components converges immediately rather than at the next boot.
#
# On removal, say what is being left behind and name any drift, while the tool
# that can still answer the question is installed -- a second later it is gone.
# The overlay itself is NOT touched: it is state this package materialised but
# does not own, and deleting Android's working configuration because its
# reconciler was uninstalled would be the tool exceeding its brief.
#
# $1 -eq 0 because %preun also runs on upgrade, where none of this applies, and
# every line ends `|| :` because no scriptlet may fail a transaction -- an erase
# that aborts leaves a package that cannot be removed without --noscripts.
SCRIPTLETS='%post
%{_bindir}/waydroid-overlay-sync --quiet || :

%preun
if [ $1 -eq 0 ]; then
    echo "overlay-sync: /var/lib/waydroid/overlay is state and is left alone." >&2
    echo "  What is staged there stays in effect until it is cleared by hand." >&2
    %{_bindir}/waydroid-overlay-sync --verify || :
fi'
