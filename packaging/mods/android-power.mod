# waydroid-ext-android-power -- docs/27-android-power-button.md
#
# The power button and the lid already suspend this host correctly, through logind
# (docs/15, confirmed inside a cage session in docs/25). logind never tells Android
# anything, which is the whole gap this package fills; the DESCRIPTION says what
# that buys. What follows is the evidence and the mechanism.
#
# WHY IT IS ALSO THE ONLY WAY BACK FROM A BLACK SCREEN
#
# docs/27 measured three mechanisms which together close every in-band wake path.
# 479 ms after Android's display group powers down, InputReader disables
# wayland_touch outright -- "because the associated viewport is not active" -- so
# taps never reach the input pipeline rather than being discarded. Ordinary keys do
# not wake it either: injected KEY_SPACE left Android Asleep for 13 s where
# KEY_WAKEUP woke it in under 4. And KEY_POWER, the one key that would, is dropped
# by the guest hwcomposer's keyboard_handle_key() before Android sees it, on every
# upstream branch. docs/52 is a real incident of needing the way out that leaves.
#
# HOW A KEY GETS IN AT ALL
#
# The container gets no /dev/input and no /dev/uinput; config_nodes has nothing of
# the kind. All Android input arrives over the Wayland socket: the guest hwcomposer
# mkfifo()s three pipes and a patched InputFlinger reads them as ordinary input
# devices, with Generic.kl carrying key 142 SLEEP and key 143 WAKEUP. A 24-byte
# struct input_event written into that FIFO is indistinguishable from a real button.
# The pipe is prwxrwxrwx and owned by uid 1000, which the host shares with the
# container, but the container's /dev is a tmpfs in its own mount namespace, so it
# is reachable only as
# /proc/<container pid>/root/dev/input/wl_keyboard_events -- and THAT traversal is
# the one thing here that needs root. Hence a system unit rather than the --user
# unit waydroid-ext-pwd gets to use.
#
# Using SLEEP and WAKEUP rather than POWER is upstream's own choice in this same
# pipe (android_hardware_waydroid, dev/lineage-23.2). Its reason is what every retry
# here rests on: sleeping an already-asleep Android is a no-op, so the first of two
# power-button taps during a blackout does no harm, where KEY_POWER would have
# toggled it awake and the resume's wakeup would have toggled it black again.
#
# WHY A UNIT AND NO SLEEP HOOK, IN EITHER DIRECTORY
#
# A systemd-sleep hook was the first implementation and never executed once. Two
# independent measured reasons, and the second outlives the first:
#
#  1. systemd 259 scans ONLY /usr/lib/systemd/system-sleep, which here is empty and
#     read-only. The strings are not the strongest evidence: the previous boot had
#     NINE suspends and the two hooks already sitting in /etc fired on none of them.
#     docs/19's sensor-hub reprobe and docs/17's waydroid-sync were both installed
#     that way and had been inert since the day they were written; both are units
#     now, and /etc/systemd/system-sleep must stay empty.
#
#  2. Even in the directory systemd does scan, a hook could not do this job.
#     systemd-sleep(8) on this host: user.slice is frozen while the hooks run, which
#     "prevents the hooks ... from communicating with any user session process
#     during sleep". Android is in user.slice, so a KEY_SLEEP written by a hook
#     would sit unread in the FIFO until the thaw.
#
# docs/27 notes that a package CAN ship into /usr/lib/systemd/system-sleep where a
# manual install on an immutable host cannot, and keeps the unit anyway so both
# installs use one mechanism. Reason 2 is why that costs nothing. So the ordering is
# Before=sleep.target: systemd-suspend.service is Requires= plus After=sleep.target,
# so the pre leg runs ahead of it and therefore ahead of the freeze. Journal: "sent
# sleep (142)" 17:10:49, "Successfully froze unit 'user.slice'" 17:10:50, thaw
# 17:11:19, the two wakeups after it.
#
# WHY THE UNIT GOES TO %{_unitdir} AND THE MANUAL INSTALL TO /etc
#
# Not a preference. /usr/local is a symlink to /var/usrlocal, which SELinux labels
# lib_t, and init_t may not start a service whose unit file is lib_t -- measured on
# the sibling unit from docs/19, "avc: denied { start } ... tclass=service". Only
# dependency activation escapes that check, which is why two of the three units of
# that generation worked and the third did not, and why a systemctl start typed at a
# shell does not reproduce it. So install.sh defaults UNITDIR to /etc/systemd/system
# for the manual case and the package passes %{_unitdir}, which matchpathcon labels
# correctly too. A host-wide semanage fcontext on /var/usrlocal was rejected as a
# far larger footprint. Enablement is the packaged sleep.target.wants symlink, byte
# for byte what systemctl enable would write, so there is no scriptlet.
#
# WHAT THE WAITS ARE DERIVED FROM
#
# The pre leg's second is measured, not guessed: logcat puts goToSleep at .461 and
# the power group asleep at .976, so 515 ms, doubled. Without it the host can
# suspend mid-transition and the far-side wakeup may race a sleep that never
# finished, which is a black screen with no way back. The post leg sends wakeup
# twice, two seconds apart, because a lost wakeup on a kiosk is a machine nobody can
# wake and an extra one is free.
#
# GENERIC, NOT HP ENVY x2 -- CHECKED RATHER THAN ASSUMED
#
# docs/47 reserves waydroid-ext-hw-* for anything naming this machine's hardware,
# and nothing in the payload does: the keycodes are evdev's, the FIFO and Generic.kl
# are Waydroid's own patched guest, the container state comes from Waydroid's D-Bus
# name, sleep.target is systemd's. No device path, no ACPI or PCI id, nothing about
# the three power-switch devices docs/15 enumerates here. What it does assume is
# configuration and not hardware, and that is in the DESCRIPTION.

VERSION=1.0.0
RELEASE=1
KIND=host

# Genuinely noarch: one POSIX shell script, one stdlib Python script, one unit
# file, no ELF. One caveat, recorded here rather than expressed as an ExclusiveArch:
# waydroid-android-key hardcodes struct input_event for LP64 ("llHHi", 24 bytes) and
# asserts that size at import, so on a 32-bit host python the assert fires and the
# injector does nothing. ExclusiveArch was rejected for waydroid-ext-pidguard's
# reason -- an rpm-ostree host composes against the image it has, and an
# uninstallable package is worse than an inert file -- and the failure is already
# safe: the lock script calls the injector tolerantly and exits 0, so a suspend
# proceeds untouched.
ARCH=noarch

SUMMARY="Put Android to sleep with the host and bring it back locked on resume"

LICENSE="GPL-3.0-or-later"

# For %{_unitdir}. Same reason waydroid-ext-btd and waydroid-ext-wifid declare it.
BUILDREQUIRES="systemd-rpm-macros"

# Every external command the payload runs, and the subject.
#
# waydroid: the mechanism is finding a container process and writing into the FIFO
#   under its /proc/<pid>/root. Without a container the package is not degraded, it
#   is empty.
# systemd: the unit IS the ordering mechanism -- Before=sleep.target is the whole
#   reason the pre leg beats the user.slice freeze -- and busctl, hardcoded at
#   /usr/bin/busctl, is how the lock script reads the container state: 9 ms against
#   220 ms for `waydroid status`, which starts a Python interpreter to make the
#   same call (docs/25).
# python3: waydroid-android-key, stdlib only -- os, struct, sys, time, and a /proc
#   walk in place of pgrep, so no third-party import and no layered package.
# coreutils: sleep for the pre-leg wait and the retry gap, tr and tail for the
#   busctl reply parse.
# grep: the same parse, and GNU grep specifically, since `grep -A1 -m1` is not
#   POSIX. Named for the reason waydroid-ext-overlay-sync names gawk: without it
#   container_state prints nothing, every state reads as absent, and both legs
#   silently no-op while the suspend still succeeds. docs/27's own dependency list
#   omits grep; the script uses it.
REQUIRES="waydroid
systemd
python3
coreutils
grep"

# No RECOMMENDS, and three absences are decisions rather than oversights.
# policycoreutils: install.sh runs restorecon only when DESTDIR is unset, and this
# package has no scriptlet at all. waydroid-ext-cage: docs/47 puts both in the
# kiosk group, but this package is correct under a windowed sway session too, and
# docs/47 is explicit that groups are convenience while hard edges belong on the
# individual package. util-linux: rtcwake appears only in the advice the manual
# installer prints, never in the payload.

DOCS="docs/27-android-power-button.md
docs/52-launcher-lock-and-wake.md"

DESCRIPTION="Makes the host's power button and lid behave like a tablet's on a machine whose
only session is Android: on the way down Android's keyguard arms, and on the
way back up the machine resumes with the lock screen already showing.

Nothing about the button itself changes, and nothing here configures it. logind
already suspends this host on a short press and on the lid, below the
compositor and without caring which one is running. What logind does not do is
tell Android, so before this package the machine slept with Android still awake
and resumed into an unlocked UI -- with no host lock screen behind it, because
a kiosk session has no host UI at all.

The second thing it buys is a way back from a black screen. When Android's
display group powers off, the touchscreen is disabled rather than ignored,
ordinary keys do not wake it, and the one key that would is dropped by the
guest compositor path before Android sees it, so a sleeping Android in a kiosk
session cannot be woken from inside the session. Every resume injects a wakeup
unconditionally, which makes a suspend and a resume the general-purpose
recovery for whatever put Android to sleep -- including an app with
device-admin rights calling lockNow(), which is how this was first needed in
anger.

The mechanism is an input event written into the pipe the patched guest
InputFlinger reads as a keyboard, reached through the container's
/proc/<pid>/root, and that traversal is the one thing here that needs root: it
is why this is a system unit and not a user one. The keys are KEY_SLEEP and
KEY_WAKEUP rather than KEY_POWER because those two are absolute instead of a
toggle, so an injection that is lost or repeated cannot invert the state and
leave the screen off with no way back.

The ordering is a systemd unit wanted by sleep.target, and this package
installs no systemd-sleep hook in either hook directory: a hook under /etc is
never scanned on this host, and one in the directory that is scanned could
still not do the job, because user.slice is frozen while hooks run and Android
lives in user.slice.

It has no effect at all unless a Waydroid session is actually running. Both
legs read the container state over D-Bus first and do nothing unless it is
RUNNING, which is deliberate rather than defensive: a frozen container is not
reading its input pipe, so an injected event would be delivered at some
arbitrary later thaw and put Android to sleep then.

It also locks nothing until Android's keyguard is switched on, which Waydroid's
image ships disabled -- a sane default for a windowed desktop and wrong for a
kiosk. Turning it on is 'locksettings set-disabled false' plus 'settings put
secure lock_screen_lock_after_timeout 0' inside Android, and then a PIN or
pattern in Settings > Security. The second setting matters: KEY_SLEEP reaches
the framework as a sleep-button reason rather than a power-button one, so
AOSP's instant-lock shortcut does not apply and the keyguard would otherwise
arm after a five second grace period, long enough for a resume to show the
unlocked UI first. A lost credential is recovered by stopping the session and
deleting the host-visible locksettings.db under the session user's own waydroid
data directory; no root and no Android shell are involved.

Finally, it assumes something already takes the host to sleep.target. That is a
logind and sleep.conf drop-in which this package neither ships nor depends on;
without it the unit is still correct and simply never fires.

The cost is about a second added to each suspend and two to each resume, both
capped at ten seconds by the unit, and both legs exit successfully whatever
happens, because nothing here may be allowed to block a suspend or hold up a
resume."

SOURCES="artifacts/android-power/install.sh
artifacts/android-power/waydroid-android-key
artifacts/android-power/waydroid-android-lock
artifacts/android-power/waydroid-android-lock.service"

INSTALL='DESTDIR=%{buildroot} PREFIX=%{_prefix} UNITDIR=%{_unitdir} \
    sh artifacts/android-power/install.sh'

# Exactly the tree the installer stages, diffed against a scratch buildroot rather
# than read off the installer.
#
# Nothing is %config, because nothing lands in /etc in the packaged layout: the unit
# goes to %{_unitdir} and the two scripts to %{_bindir}. The installer's
# /etc/systemd/system default is the manual install only. The lock script's tunables
# (WAYDROID_LOCK_WAIT and the wake retry pair) are environment variables with
# built-in defaults, so there is no configuration file for rpm to own and a change
# is a systemd drop-in.
#
# %dir for sleep.target.wants because this package creates it: it may not exist on a
# host where nothing else is wanted by sleep.target, and an unowned directory left
# behind on uninstall is what waydroid-ext-btd's idiom avoids.
PAYLOAD_FILES='%{_bindir}/waydroid-android-key
%{_bindir}/waydroid-android-lock
%{_unitdir}/waydroid-android-lock.service
%dir %{_unitdir}/sleep.target.wants
%{_unitdir}/sleep.target.wants/waydroid-android-lock.service'
