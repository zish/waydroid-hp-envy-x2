# waydroid-ext-pidguard -- docs/51-pid-namespace-32bit-cliff.md
#
# 32-bit bionic packs a pthread_mutex_t owner tid into 16 bits and aborts any
# process whose tid exceeds 65535. A Waydroid container is a long-lived PID
# namespace whose counter only climbs, so after about a day of uptime every
# NEWLY STARTED 32-bit process dies at birth -- the audio HAL, the camera
# provider and zygote32 among them, which presents as a permanent boot
# animation. This caps the container's own pid_max so the counter wraps below
# the cliff instead of walking off it.
#
# Nothing here is HP Envy x2 specific. It reaches any host that runs Waydroid
# long enough, which is why it is upstream as waydroid#2071 -- open, with a
# host-wide cap as the only suggested workaround.

VERSION=1.0.0
RELEASE=1
KIND=host

# Genuinely noarch: two bash scripts and two units, no ELF anywhere. The real
# constraint is a KERNEL VERSION, not an architecture -- per-namespace pid_max
# arrived in Linux 6.14 (Brauner, merged Dec 2024) -- and that is deliberately
# NOT expressed as Requires: kernel >= 6.14. An rpm-ostree host composes against
# whatever kernel the image carries, a Requires on it would make the package
# uninstallable rather than inert, and the guard already detects the old-kernel
# case itself: it reads the host's pid_max before and after every write, and if
# a write moved it -- which is what a pre-6.14 global pid_max does -- it restores
# the host's value and refuses to continue. Failing safe at runtime is better
# than failing to install.
ARCH=noarch

SUMMARY="Cap Waydroid's PID namespace below the 32-bit bionic cliff"

LICENSE="GPL-3.0-or-later"

# nsenter and unshare are util-linux; pgrep is procps-ng. Named as packages
# rather than as bare command paths so an operator can see which source package
# to watch, the same reasoning as waydroid-ext-wifid's pkgconfig() floors.
# For %{_unitdir}. Same reason waydroid-ext-wifid declares it.
BUILDREQUIRES="systemd-rpm-macros"

REQUIRES="waydroid
systemd
util-linux
procps-ng"

DOCS="docs/51-pid-namespace-32bit-cliff.md artifacts/pidguard/README.md"

DESCRIPTION="Keeps the Waydroid container's PID namespace below the 65535 ceiling that
32-bit bionic cannot represent, so long-uptime containers stop losing every
32-bit process they try to start.

The failure this prevents is slow and badly disguised. Crossing 65535 breaks
nothing by itself -- processes already running keep their low PIDs -- so the
container works normally for hours afterwards and then fails the moment
something restarts a 32-bit service. Depending on which one restarts first that
presents as no audio, a broken camera, apps that will not launch, or a device
stuck on the boot animation for ever, and none of those looks like a PID
problem.

The cap makes the cliff unreachable rather than distant: the allocator is
cyclic over [pid_min, pid_max), so with pid_max=65536 the counter wraps to the
low free PIDs instead of climbing past the limit. Measured, not assumed --
primed to 65529, allocation ran 65530...65535 and then 300, 301, 302.

Applied by a five-minute timer rather than on a container event, because a
container restart creates a fresh uncapped namespace with no clean hook to
catch: waydroid-container.service goes active long before a session creates
the actual LXC container. A fresh namespace needs more than a day to approach
the cliff, so the interval is about promptness in the journal, not safety.

Also ships waydroid-pid-reset, which recovers a container that is already past
the cliff without restarting it -- a container restart works but drops a kiosk
session to the display manager, which needs somebody at the machine."

SOURCES="artifacts/pidguard/install.sh
artifacts/pidguard/waydroid-pidguard
artifacts/pidguard/waydroid-pid-reset
artifacts/pidguard/waydroid-pidguard.service
artifacts/pidguard/waydroid-pidguard.timer"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/pidguard/install.sh'

# No %config for /etc/waydroid-pidguard.conf: the guard sources it if it is
# readable and ships no default, so there is nothing for rpm to own. Packaging
# an empty one would invent a file the admin never wrote.
PAYLOAD_FILES='%{_bindir}/waydroid-pidguard
%{_bindir}/waydroid-pid-reset
%{_unitdir}/waydroid-pidguard.service
%{_unitdir}/waydroid-pidguard.timer
%dir %{_unitdir}/timers.target.wants
%{_unitdir}/timers.target.wants/waydroid-pidguard.timer'
