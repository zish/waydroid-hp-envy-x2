# waydroid-ext-restartd -- docs/48-battery-frozen-and-netd-stale.md
#
# Android's init stops a service through libprocessgroup, which signals the pids
# in that service's cgroup.procs. Waydroid mounts the container's /sys/fs/cgroup
# read-only, so those cgroups were never created, the kill reaches nobody, and
# init parks the service in STOPPING for ever. The consequence is broad and
# badly hidden: NO Android service in the container can be restarted -- not by
# `restart`, not by ctl.restart, not by init's own crash recovery.
#
# This is a MITIGATION and says so. The real fix is to give the container a
# writable cgroup hierarchy so libprocessgroup can do its own job; until then
# this delivers the signal from the host, where it lands.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Unstick Android init services Waydroid's container cannot kill"

LICENSE="GPL-3.0-or-later"

# Stdlib Python only -- no third-party imports at all, which is deliberate on an
# immutable host where every dependency is a layered package and a reboot.
# lxc-attach and lxc-info are called directly rather than through `waydroid
# shell`, so lxc is named even though waydroid already pulls it in: this package
# would break if that indirect dependency ever went away.
# For %{_unitdir}. Same reason waydroid-ext-wifid declares it.
BUILDREQUIRES="systemd-rpm-macros"

REQUIRES="waydroid
systemd
python3
lxc"

DOCS="docs/48-battery-frozen-and-netd-stale.md"

DESCRIPTION="Watches for Android services that init has parked in STOPPING and cannot
kill, and delivers the signal from the host so init finally gets its SIGCHLD
and respawns them.

Waydroid mounts the container's /sys/fs/cgroup read-only, so libprocessgroup
never created the per-service cgroups it kills through. KillProcessGroup()
therefore signals an empty set, init waits for a child that will never exit,
and the service stays in STOPPING indefinitely. init.svc.<name> is the tell.

The cost of that is not theoretical. A netd which outlived its own restart kept
the netIds of a previous system_server, so the next one could not take its
interface back -- networkAddInterface failed EBUSY and every per-network
routing table stayed empty. Android showed a connected network with a correct
address, gateway and DNS, and no route to anything, for 38 hours.

Read the daemon's header before changing the intervals. The fast cascade poll
is what stops the mutual netd/zygote onrestart pair from ping-ponging, and
there is a circuit breaker underneath it for when that reasoning turns out to
be wrong.

This mitigates rather than fixes. The real repair is a writable cgroup
hierarchy inside the container, which would also let Android's per-app freezer
work; this package exists because that is a larger change and services are
wedging now."

SOURCES="artifacts/restartd/install.sh
artifacts/restartd/waydroid-restartd
artifacts/restartd/waydroid-restartd.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/restartd/install.sh'

# The unit reads /etc/waydroid-restartd.conf through EnvironmentFile=- and the
# package ships no default, so there is no %config to own -- the leading dash
# is what makes its absence a non-error.
PAYLOAD_FILES='%{_bindir}/waydroid-restartd
%{_unitdir}/waydroid-restartd.service
%dir %{_unitdir}/multi-user.target.wants
%{_unitdir}/multi-user.target.wants/waydroid-restartd.service'
