# waydroid-ext-graceful-exit -- docs/24-graceful-logout.md
#
# Every way of stopping Waydroid converges on one line, `lxc-stop -k`: SIGKILL to
# every process in the container, no ACTION_SHUTDOWN broadcast, no flush of
# packages.xml or the settings providers (docs/23). Logging out of the compositor
# was the path that reached that line with nothing even trying to prevent it, and
# on this image the result is worse than "Android stops": the container is
# bind-mounted onto the compositor's Wayland socket *inode*, not its path. Sway
# unlinks the socket when it exits, the next sway creates a new one at the same
# path, and the container still holds the old unlinked inode -- so logging back in
# does not restore Android's display, and only a session stop and start does.
# Whether that presented as a SIGKILL or as an Android crash-looping its composer
# against a dead socket depended on where the session process happened to live
# (docs/24).
#
# This package is the trigger that was missing, plus a backstop for the logouts
# the trigger cannot see. docs/23 closed the *host shutdown* path and named this
# one as its known gap; the two stay separate packages because that one is root --
# a logind delay lock on PrepareForShutdown from a system unit, plus a
# waydroid-container.service.d drop-in -- and this package's entire claim is that a
# logout needs no privilege at all. docs/47's table already lists them as two
# members of the kiosk group rather than one.
#
# WHY EVERYTHING IS UNPRIVILEGED
#
# At logout the actor is an ordinary user, and requiring sudo for a logout is not
# a design. So the ladder uses only levers a normal user already holds, all four
# verified on the host as an ordinary user (docs/24): `waydroid status` and
# `busctl ... Unfreeze` are D-Bus calls that id.waydro.Container.conf grants to
# context="default" -- which is also why lxc-info is not used for status, it
# answers "Insufficent privileges to control waydroid" -- while `waydroid app
# intent` and `waydroid prop set` go over /dev/binder, mode 0666. Hence a script in
# %{_bindir} and a --user unit, with no scriptlet and no system service.
#
# WHICH HOOK IS THE REAL TRIGGER
#
# The chord is, and the unit is the backstop -- the opposite of how the two file
# sizes read. The chord runs the wrapper to completion with the compositor still
# up, so the framework rung can actually complete. The unit necessarily races,
# because sway-systemd only starts sway-session-shutdown.target once sway's IPC
# "shutdown" event has fired, which is sway already on its way out; when it loses,
# the ladder falls through to the init rung (sys.powerctl), which needs nothing
# from Wayland. There is no fixing that from the packaging side -- logind has no
# PrepareForLogout to take a delay lock on, so the compositor's exit action is the
# only thing that runs BEFORE teardown (docs/24).
#
# %{_userunitdir} and not %{_unitdir} because a logout is a session event and the
# wrapper must run as the user logging out. The enable symlink goes in
# graphical-session.target.wants, not the default.target.wants waydroid-ext-pwd
# uses: the trigger is that target ENDING, so the unit has to be pulled in by it to
# be stopped with it. Shipping the symlink as a packaged file enables the backstop
# for every user with no %post and nothing written to any home directory, because
# /usr/lib/systemd/user is in systemd's user unit search path and systemd merges
# .wants across it -- not a convenience, since rpm-ostree forbids
# filesystem-mutating scriptlets (docs/25).
#
# THE SWAY DROP-IN: A DROP-IN, NOT AN EDIT -- AND ONE OPEN QUESTION
#
# It lands in %{_datadir}/sway/config.d. The manual install defaults to
# /etc/sway/config.d, which is right on an immutable host and is not a path an rpm
# may own; install.sh takes the directory as a variable for exactly this reason.
# /usr/share/sway/config.d is owned by sway-config-fedora-0.4.3-3.fc44, which ships
# its own thirteen drop-ins there, so docs/24 calls it "a path a package may
# legitimately populate" -- and this package populates it without owning it.
#
# So this is NOT one of docs/53's "cannot be applied and unapplied by RPM" cases,
# whose only in-place-edit entry is avahi-daemon.conf. There is no edit here,
# nothing another package's `rpm -V` will lie about, and an uninstall deletes one
# file and returns the stock exit chord exactly. What the drop-in overrides is a
# BINDING, not a file: sway's stock config ends with an include of config.d, parsed
# after the exit binding earlier in the file, and a later bindsym wins.
#
# OPEN, for the coordinator and not for this file: docs/25's host audit says a
# package shipping there "must `Requires: sway-config-fedora` rather than own the
# directory", where RECOMMENDS below makes it weak, with its reasoning stated
# there. One of the two has to give.
#
# The caveat is a different thing, about efficacy rather than ownership: whether
# the /usr/share layer is included at all is a per-user config choice. Fedora's
# stock /etc/sway/config includes all three layers, but the reference host's own
# ~/.config/sway/config has that line commented out in favour of a two-path variant
# covering only /etc/sway/config.d and ~/.config/sway/config.d, because that home
# directory holds its own copies of the same thirteen files. On such a host this
# package installs correctly and its chord is silently inert -- "the RPM installed"
# is not "the exit chord is live" -- and the backstop is all you get (docs/24,
# docs/25). It is in the DESCRIPTION too, because it is the single most likely way
# for somebody to conclude this package does nothing.
#
# Two details in the drop-in are load-bearing, and its own comments say why:
# `--no-warn`, without which sway raises an undebuggable config nag on every reload
# and login while the override itself works perfectly, and a binding written as one
# physical line rather than leaning on backslash continuation in a file that breaks
# a login if it misparses. `pgrep swaynag` after a reload is the check that
# discriminates, because neither the reload's return value nor `sway --validate`
# can see that fault (docs/24).
#
# WHAT IT COSTS
#
# Seconds at a logout, bounded. Measured from a live session: 7.07 s to
# Container: STOPPED on the framework path, 7.75 s including the session release,
# of which the framework half itself is 1.45 s (docs/24). The ladder's timeouts are
# 12 + 8 + 10 s, so the worst case is 30 s and the unit's TimeoutStopSec=45 is that
# plus margin. The other cost is scope: the chord is replaced for every user on the
# host, not just the Waydroid user, and a user who has redefined that binding in
# their own config.d layer keeps theirs.
#
# ALSO RULED OUT
#
#   android.intent.action.ACTION_REQUEST_SHUTDOWN -- the name the web still cites.
#     It resolves to nothing on an Android 13 image, so it would have produced a
#     package that installed cleanly and did nothing (docs/24).
#   Editing /etc/sway/config or any ~/.config/sway/config -- the drop-in directory
#     exists precisely so a package does not have to.
#   android-tools -- adb was used heavily to investigate and nothing shipped uses
#     it.
#   A %post enabling the unit, and a restorecon scriptlet -- the packaged .wants
#     symlink does the first, and on rpm-ostree SELinux labels come from the
#     compose. install.sh skips its own restorecon whenever DESTDIR is set.

VERSION=1.0.0
RELEASE=1
KIND=host
ARCH=noarch

SUMMARY="Shut Android down cleanly at logout instead of killing the container"

# Checked: no SPDX header in any of the four payload files, so the repository's
# own licence governs. None of the wrapper is derived from Waydroid's source.
LICENSE="GPL-3.0-or-later"

# For %{_userunitdir}. Same reason waydroid-ext-pwd declares it; this package
# ships no system unit and no udev rule, but the user unit alone is enough.
BUILDREQUIRES="systemd-rpm-macros"

# Every external command the wrapper runs. The unguarded ones are hard; the
# guarded ones (swaynag, logger) are Recommends below.
#
#   waydroid   /usr/bin/waydroid, hardcoded: status, app intent, prop set,
#              session stop. The entire subject of the package.
#   busctl     /usr/bin/busctl, hardcoded, on the thaw path -- this host freezes
#              the container on suspend and a frozen container cannot run its own
#              shutdown. systemd also provides the --user unit machinery.
#   awk        field() parses the tab-separated `waydroid status` output with it,
#              unguarded; without it the script cannot tell RUNNING from STOPPED
#              and every rung of the ladder misfires.
#   id, sleep  the ownership check and the poll loops. coreutils.
#
# No Python and nothing to import: one POSIX shell script, one unit, one sway
# config file. swaymsg is hardcoded too but only on the --exit-sway path, which is
# the chord's, so it rides with sway below rather than being hard here.
REQUIRES="waydroid
systemd
coreutils
gawk"

# sway is the compositor whose exit chord this replaces, and it provides the
# swaymsg --exit-sway execs and the swaynag that shows the notice.
# sway-config-fedora owns %{_datadir}/sway/config.d and ships the /etc/sway/config
# whose three-path include is what makes a drop-in there read at all.
#
# Weak and not hard, by docs/47's test -- is the package without the dependency
# worse than stock? It is not: the drop-in becomes an unread file in a directory
# nothing parses, while the compositor-independent backstop still turns a logout
# into a real shutdown instead of SIGKILL. Dead weight, not breakage, and unlike
# waydroid-ext-wifi-hostd's hard Requires, where the missing half leaves Android
# worse off than it started. Weak also keeps a Fedora-specific package name from
# making this uninstallable on a distribution that ships the same directory inside
# sway itself, since an unsatisfiable Recommends is skipped rather than fatal.
#
# This is the point where docs/25 says "must `Requires: sway-config-fedora`". The
# header flags the disagreement; it is not settled here.
#
# logger is guarded with command -v, so util-linux is weak too: without it the
# script logs to stderr only, which under the --user unit still reaches the
# journal.
RECOMMENDS="sway
sway-config-fedora
util-linux"

DOCS="docs/24-graceful-logout.md"

DESCRIPTION="Shuts Android down rather than letting it be killed when the user logs out of
the compositor.

Stock Waydroid stops the container with 'lxc-stop -k', which is SIGKILL to
every process inside it: no ACTION_SHUTDOWN broadcast to apps, no
PackageManager or settings-provider flush, no sync. At logout it is worse than
it sounds, because the container is bind-mounted onto the compositor's Wayland
socket inode rather than its path -- so a session that survives the logout can
never reconnect to the next compositor, and sits there restarting its composer
forever. This package asks Android to shut itself down first, and waits for it.

There are two hooks, because only one of the ways a session ends is under our
control. The first is the compositor's exit chord, rebound by a sway drop-in so
that the shutdown runs to completion, with the compositor still up, and only
then exits sway -- race-free by construction. The second is a systemd --user
unit pulled in by graphical-session.target, with the work in ExecStop, which
catches the logouts that bypass the chord: the display manager ending the
session, 'swaymsg exit' typed by hand, the compositor crashing. The backstop
does race the compositor's own teardown, and when it loses that race the
framework path stalls and it falls back to Android's init shutdown, which needs
nothing from Wayland. Degraded, and still a real shutdown rather than a kill.

Nothing here needs privilege. No sudo, no polkit, no setuid, no system service:
the shutdown is requested through D-Bus calls the container policy grants to
any user and through /dev/binder, which is world-writable, and the script only
ever touches a Waydroid session owned by the user running it.

WHAT IT ASSUMES. The chord half assumes sway, and assumes the host's sway
config includes the /usr/share/sway/config.d layer -- Fedora's stock
/etc/sway/config does, but a personal config derived from it may not, and such
a config is exactly what the reference host has. On that host the drop-in
installs correctly and is silently inert, leaving the backstop as the only
hook. 'grep bindsym /usr/share/sway/config.d/95-waydroid-graceful-exit.conf'
shows what would be bound; after a 'swaymsg reload', 'pgrep swaynag' is the
check that the drop-in parsed cleanly, because neither the reload's own return
value nor 'sway --validate' can see this class of fault. Under a different
compositor the file is unread and harmless. Under cage there is no chord and
graphical-session.target is never started, so neither hook fires -- the cage
session invokes the same wrapper itself, with --keep-session, and owns the
teardown (docs/25).

WHAT IT COSTS. Seconds at a logout: 7.07 s measured to a stopped container on
the framework path, 7.75 s including the host-side session release that
Waydroid's own cleanup never performs on this path. The fallback ladder is
bounded at 30 s and the unit allows 45, so a guest that refuses to shut down
delays a logout by up to that long before being stopped outright. The shutdown
path always exits successfully: a logout must not be blocked by Android.

This is not the host-shutdown path. Reboot and poweroff are covered by a
separate modification with a separate trigger, a root system unit and a logind
delay lock (docs/23); this package deliberately contains none of that, and each
is useful without the other."

SOURCES="artifacts/graceful-exit/95-waydroid-graceful-exit.conf
artifacts/graceful-exit/install.sh
artifacts/graceful-exit/waydroid-graceful-exit
artifacts/graceful-exit/waydroid-graceful-exit.service"

# SWAY_CONFD is the one variable that has to be passed: the installer defaults it
# to /etc/sway/config.d, which is correct for the manual install on an immutable
# host and is not a path an rpm may own.
#
# This installer reads no UNITDIR or USERUNITDIR. Unlike the ones
# waydroid-ext-btd and waydroid-ext-pwd use, it derives the user unit directory
# from PREFIX as $PREFIX/lib/systemd/user, which is what systemd-rpm-macros
# defines %{_userunitdir} to be. Passing a variable the installer ignores would
# look like a guarantee and be none, so it is not passed; if a distribution ever
# defines %{_userunitdir} elsewhere, %files stops matching the staged tree and
# rpmbuild fails loudly rather than shipping a unit nothing reads.
INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} SWAY_CONFD=%{_datadir}/sway/config.d \
    sh artifacts/graceful-exit/install.sh'

# Verified by staging: DESTDIR=... PREFIX=/usr SWAY_CONFD=/usr/share/sway/config.d
# produces exactly these five paths and no others, with @BINDIR@ substituted to
# /usr/bin in all three files that embed it -- the unit's ExecStop, the drop-in's
# bindsym, and the wrapper's own installed-at comment. That kind of miss is not
# hypothetical: an earlier installer here shipped a literal @BINDIR@ and failed
# silently (docs/25).
#
# The .wants directory is ours to declare: systemd owns %{_userunitdir}, but
# nothing owns graphical-session.target.wants under it until a package drops a
# symlink in -- the same situation waydroid-ext-pwd's default.target.wants is in.
#
# %{_datadir}/sway/config.d is NOT declared, with or without %dir: it belongs to
# sway-config-fedora and this package populates it without owning it. Nothing is
# %config, because with SWAY_CONFD pointed at %{_datadir} the whole payload is
# under /usr, which is read-only on the target host -- so the rule
# packaging/test-install.sh enforces has nothing to apply to. The wrapper's three
# timeouts are environment variables, so tuning them is a systemd drop-in and
# needs no config file either.
PAYLOAD_FILES='%{_bindir}/waydroid-graceful-exit
%{_userunitdir}/waydroid-graceful-exit.service
%dir %{_userunitdir}/graphical-session.target.wants
%{_userunitdir}/graphical-session.target.wants/waydroid-graceful-exit.service
%{_datadir}/sway/config.d/95-waydroid-graceful-exit.conf'
