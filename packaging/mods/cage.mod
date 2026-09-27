# waydroid-ext-cage -- docs/25-waydroid-in-cage.md
#
# Waydroid *as* the desktop rather than Waydroid *in* one: pick "Waydroid in Cage"
# at the greeter and the whole machine is Android, full-screen, with no host UI
# behind it. Two files, and neither is the interesting part. The interesting part is
# that the obvious session entry --
#
#     Exec=cage -- waydroid show-full-ui
#
# -- cannot work, and none of the three reasons is a bug. Each is a consequence of
# Waydroid splitting itself into a root container daemon and an unprivileged session
# manager (docs/25). So this package ships one session entry and one wrapper that is
# cage's child, and the wrapper is the whole modification.
#
# WHY A WRAPPER AND NOT A ONE-LINE Exec=
#
# 1. cage exits when its child exits, and `waydroid show-full-ui` only blocks when
#    NO session is registered. maybeLaunchLater() catches the "no session" D-Bus
#    error and calls session_manager.start(background=False), which holds the
#    session main loop -- but with a session already tracked it fires the intent and
#    returns, cage exits, and the user is back at the greeter. A stale session cannot
#    be inherited either: generate_session_lxc_config binds the compositor's Wayland
#    socket by INODE and cage unlinks its socket on exit, so the leftover container
#    holds a dead inode that a new cage at the same path does not restore. It has to
#    be cleared, not reused.
#
# 2. Android's power-off is never announced to the host in this image. The host
#    implements IHardware transaction 7 (shutdownRequest); the guest client in
#    org.lineageos.platform.jar implements enableNFC, enableBluetooth, suspend,
#    reboot, upgrade and upgrade2 and nothing else. This is version skew, not a
#    design gap -- the guest half is android_vendor_waydroid#50, merged 2026-05-09,
#    and the image is dated 2026-04-03. Without a watchdog the session manager
#    blocks forever against a dead container and cage never exits: a black screen,
#    not a logout.
#
# 3. cage has no sway-systemd equivalent. `rpm -ql cage` is a binary and a man page:
#    no units, no graphical-session.target integration. So docs/24's
#    waydroid-graceful-exit.service backstop, which is
#    PartOf=graphical-session.target, never starts under cage and its ExecStop never
#    runs. Under cage the wrapper owns that teardown itself, which is why docs/24
#    grew --keep-session: here the session manager is the wrapper's own child and
#    releases itself, so the ladder must shut Android down and then keep its hands
#    off the session record.
#
# WHAT THE WATCHDOG COSTS
#
# A 2 s poll of GetSession for the life of the session, over busctl rather than
# `waydroid status`: 9 ms against 220 ms measured on this host, because the latter
# starts a Python interpreter to make the same D-Bus call. STOPPED must be seen
# three polls running before it counts as a shutdown, because Android's own
# "Restart" is transaction 4 and hardware_manager.reboot() is lxc-stop immediately
# followed by lxc-start -- without the confirmation count, rebooting Android would
# log the user out. That costs about 6 s on a real shutdown.
#
# WHERE THE SESSION ENTRY GOES -- PROVISIONAL, SEE THE REPORT
#
# %{_datadir}/wayland-sessions, not the installer's /etc/wayland-sessions default.
# docs/25's packaging section already prescribes exactly this
# (SESSIONDIR=/usr/share/wayland-sessions) and its host audit gives two reasons:
#
#   - %{_datadir}/wayland-sessions is owned by filesystem-3.18-52.fc44, so the
#     package installs into it without owning the directory, which is what a
#     packaged session entry is supposed to do.
#   - SDDM's COMPILED-IN SessionDir already includes it. /etc/wayland-sessions is
#     read on this host only because of a local /etc/sddm.conf.d/wayland-paths.conf
#     drop-in that is not packaged by anything. A package shipping into /etc would
#     therefore install correctly on a stock Fedora and then be invisible at the
#     greeter -- the "installed, and did nothing" failure mode docs/42 and
#     backlight.mod were bitten by, reached from a different direction.
#
# It is the same move waydroid-ext-backlight made for %{_udevrulesdir} on
# 2026-09-24, and it is still marked provisional for one reason the coordinator
# settles rather than this file: the host already carries a hand-placed
# /etc/wayland-sessions/waydroid-cage.desktop (packaging/README.md's audit, unowned
# by any package) whose Exec= points at /usr/local/bin/waydroid-cage-session.
# Installing this package does not replace that file -- it adds a second one -- so
# the migration has to delete the /etc copy by hand or the greeter offers two
# entries with the same name and different targets. Which of the two SDDM would
# prefer with both SessionDirs configured has not been checked on the host.
#
# THIS PACKAGE DOES NOT MAKE ITSELF THE DEFAULT SESSION
#
# Checked, because a package that silently changes what the machine boots into would
# have to be opt-in: artifacts/cage/install.sh writes two files and touches no SDDM
# configuration, no autologin key and no default-session setting. The RPM keeps it
# that way. Taking over a machine's login is the administrator's decision, and on a
# host whose kiosk has no in-band way back from a sleeping Android it is not one to
# make from a %post.
#
# NO BuildRequires: this package references no %{_unitdir}, %{_userunitdir} or
# %{_udevrulesdir}, so it needs nothing from systemd-rpm-macros; %{_bindir} and
# %{_datadir} are core rpm macros. The absence is deliberate -- there is no unit to
# enable, because cage starts nothing, which is finding 3 above.
#
# WHAT IS NOT PACKAGED HERE
#
# waydroid-graceful-exit, which the wrapper calls on both its exit paths. It is its
# own modification (waydroid-ext-graceful-exit, docs/24) whose sway hook and user
# unit have nothing to do with a kiosk, and it ships
# %{_bindir}/waydroid-graceful-exit, which is exactly where the wrapper built with
# PREFIX=%{_prefix} looks -- so the two fit without either knowing about the other.
#
# That split has a migration trap worth naming, against the HOST rather than against
# the other package: the wrapper's GRACEFUL_EXIT is substituted from PREFIX at
# install time, so the packaged copy looks in %{_bindir} while the hand-installed
# ladder on bigtab01 lives in /usr/local/bin. Install this package without
# waydroid-ext-graceful-exit and the wrapper will not find the copy that is already
# there. It degrades rather than fails -- [ -x ] is false, the wrapper logs "Android
# will be killed, not shut down" and the session still runs -- but that is a real
# regression against today's host, so the two should migrate together.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Log in to a session that is Waydroid's Android and nothing else"

LICENSE="GPL-3.0-or-later"

# cage is hard, and not merely because the entry's Exec= names it: a greeter
# session whose compositor is absent does not degrade, it fails to start, and the
# user gets a flash and the greeter back with the reason only in the journal.
# waydroid is hard for the same kind of reason -- /usr/bin/waydroid is a literal in
# the wrapper and `waydroid show-full-ui` IS the session. systemd is for busctl,
# also a literal at /usr/bin/busctl: every state read the entry check and the
# watchdog make goes through it, and with no busctl the wrapper bails before
# starting anything. coreutils for date, id and sleep -- the anti-bounce guard, the
# ownership check, the poll loop -- and gawk for the busctl field parser; both are
# effectively always present and named anyway, as waydroid-ext-overlay-sync names
# them.
#
# Deliberately NOT a dependency: sddm. The payload is a plain freedesktop session
# entry in the directory display managers search, so nothing here is SDDM-specific,
# and a package naming one display manager would be wrong on a host running
# another. Nor policycoreutils: install.sh skips restorecon whenever DESTDIR is
# set, so it never runs in %install, and on rpm-ostree labels come from the
# compose.
REQUIRES="waydroid
cage
systemd
coreutils
gawk"

# waydroid-ext-graceful-exit: the ladder the wrapper runs to clear a stale session
# at entry and to shut Android down on SIGTERM. Weak and not hard because the
# wrapper guards it with [ -x ] and logs a degraded path rather than refusing to
# start -- the same strength and reasoning as waydroid-ext-backlight's Recommends
# on waydroid-ext-sensord. A hard Requires would also make this session entry
# refuse to install over a logout handler that is hand-placed and working, which is
# the state bigtab01 is in today.
#
# waydroid-ext-android-power: the one weak dependency here that is a judgement
# rather than a code path, and the coordinator may prefer the waydroid-ext-kiosk
# group docs/47 plans over cage, graceful-exit, graceful-shutdown and android-power
# instead. Why it is defensible here: under cage a sleeping Android has no in-band
# way back -- KEY_POWER is dropped by the guest hwcomposer, ordinary keys do not
# wake a non-interactive Android, and there is no host UI to relaunch anything
# from. docs/27's suspend/resume hook is the only out-of-band route and docs/52 is
# a real incident of needing it.
#
# util-linux for logger, used under command -v and skipped when absent: without it
# the journal trail survives as the session scope's stderr, just untagged, so
# `journalctl -t waydroid-cage-session` stops working and nothing else changes.
RECOMMENDS="waydroid-ext-graceful-exit
waydroid-ext-android-power
util-linux"

# docs/24 and docs/52 belong to other modifications and are shipped here anyway,
# which is the precedent eight overlay mods already set with docs/user/overlay.md:
# --keep-session exists for this session and the division of teardown labour is
# only written down in docs/24, and docs/52 is the note a kiosk operator needs at
# the moment the screen goes black. Both are also what the DESCRIPTION means by
# "the bundled notes".
DOCS="docs/25-waydroid-in-cage.md
docs/24-graceful-logout.md
docs/52-launcher-lock-and-wake.md"

DESCRIPTION="Adds a greeter session in which Waydroid's Android is the entire machine:
full-screen under the cage kiosk compositor, with no host desktop, no panel and
no other window behind it. Power Android off from inside and the session ends,
leaving the host clean and ready to do it again.

What it takes over is the display, and only while the session is chosen. The
entry is additive: it changes no default, touches no autologin setting, and the
way back to an ordinary desktop is to pick a different session at the greeter.
The compositor is started with VT switching left enabled on purpose, so on a
machine whose only session is a kiosk there is also a way out that does not go
through the kiosk.

What it takes away is everything a host session would have provided. There is
no terminal, no settings application and no file manager, so host-side work
means ssh or a different session. graphical-session.target is never started
under cage -- the package ships no units and no compositor integration, because
there is none to integrate with -- so any user unit ordered against that target
is inert in this session. Waydroid's own logout backstop is one of those, which
is why the session wrapper performs that teardown itself; nothing else on the
host was audited for it.

The cost that catches people out is that a sleeping Android under cage has no
in-band way back. If Android's idle timeout fires, or an app with device-admin
rights calls lockNow, the panel goes black with its power still on and the host
stays wide awake. The power key never reaches Android and ordinary keys do not
wake it, so the routes back are a host suspend and resume, or ssh and an
injected wake keyevent. The bundled notes cover both, and the companion
suspend-hook package is recommended for exactly this reason.

Most of the work is lifecycle, and it is there because Waydroid splits into a
root container daemon and an unprivileged session manager that know less about
each other than a kiosk needs. A session left over from a previous login is
cleared rather than reused, because the container binds the compositor's
Wayland socket by inode and the old one is gone. A container that stops without
telling anybody ends the session, which is what makes Android's own power-off
work as a logout on this image -- the guest framework here predates upstream's
shutdown notification by five weeks and never sends one. An Android reboot is
not mistaken for a shutdown, because a stop has to be observed three polls
running. A session that fails in under fifteen seconds pauses before handing
the greeter back, so autologin cannot spin.

All of it is unprivileged. The container daemon's Stop and GetSession are
reachable by an ordinary caller, which is the whole reason this is a session
script and not a service, and the host's container unit is never restarted by
any of it -- restarting it re-probes drivers and would drop the session anyway.

Host suspend and resume were verified through this session, twice, including
the lid: the container rides the suspend out with the rest of the machine,
because the power key and the lid are consumed by logind and Android is never
consulted. The paths that have not been exercised on real hardware are
Android's own display-timeout freeze and a long-lived session; the notes say so
plainly."

SOURCES="artifacts/cage/install.sh
artifacts/cage/waydroid-cage-session
artifacts/cage/waydroid-cage.desktop"

# SESSIONDIR is overridden away from the installer's /etc default; the header says
# why, and why it is provisional. PREFIX substitutes @BINDIR@ into BOTH shipped
# files -- the entry's Exec= and the wrapper's own GRACEFUL_EXIT= -- and getting
# that wrong once already shipped a literal @BINDIR@ to the host, where it failed
# silently (docs/25).
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} \
    SESSIONDIR=%{_datadir}/wayland-sessions \
    sh artifacts/cage/install.sh'

# Verified by staging DESTDIR=... PREFIX=/usr SESSIONDIR=/usr/share/wayland-sessions:
# exactly these two paths and no others.
#
# No %dir for %{_datadir}/wayland-sessions: filesystem owns it (docs/25), so the
# package installs into it and does not claim it.
#
# Nothing is %config, because nothing is in /etc, which is how
# packaging/test-install.sh's rule is satisfied rather than argued with. Neither
# file is one an administrator edits in place: the wrapper is a program, and the
# entry's Exec= is substituted at build time, so an admin who wants a different one
# drops a copy in /etc/wayland-sessions instead of editing ours.
PAYLOAD_FILES='%{_bindir}/waydroid-cage-session
%{_datadir}/wayland-sessions/waydroid-cage.desktop'
