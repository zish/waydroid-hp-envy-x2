# The power button, Android's lock screen, and a sleep hook that never ran

**Date:** 2026-09-07. **Status: working and verified end to end on the host,** including a real
RTC-timed suspend cycle. Built after [25](25-waydroid-in-cage.md), and it closes a hang that note
did not know about.

The question was simple: in a cage kiosk session, can pressing the power button bring up Android's
own lock screen, the way a tablet does? The answer is yes, but almost nothing about the route is
what it looks like from the outside, and two of the three obvious approaches are dead ends for
reasons that only show up when measured.

## What was already true, and stays true

The power button needed **no work at all**. [15](15-power-button.md) put `HandlePowerKey=suspend`
and `MemorySleepMode=s2idle` in `/etc/systemd/logind.conf.d/` and `/etc/systemd/sleep.conf.d/`;
logind sits below the compositor and does not know which one is running. [25](25-waydroid-in-cage.md)
already recorded it working *inside* a cage session — `Power key pressed short.` →
`PM: suspend entry (s2idle)` at 15:31, and the lid at 15:36.

So the button was never the problem. **Android was simply never told.** The host suspends and
resumes around a container that has no idea anything happened, and on a kiosk whose only session is
Android there is no host lock screen behind it either.

## How input actually reaches Android

The container gets **no `/dev/input` and no `/dev/uinput`** — `config_nodes` has nothing of the
kind. Every Android input event arrives over the Wayland socket: the guest hwcomposer `mkfifo()`s
three pipes and a patched InputFlinger reads them as ordinary input devices. From `dumpsys input`
on this host:

```
Event Hub State:
  Devices:
    1: wayland_touch
      Path: /dev/input/wl_touch_events
    2: wayland_keyboard
      Classes: KEYBOARD | ALPHAKEY | DPAD
      Path: /dev/input/wl_keyboard_events
      KeyLayoutFile: /system/usr/keylayout/Generic.kl
```

`Generic.kl` in this image carries `key 116 POWER`, `key 142 SLEEP` and `key 143 WAKEUP`. So a
write into that FIFO is indistinguishable from a real button as far as Android is concerned — and
that is the whole mechanism.

The pipe is `prwxrwxrwx`, owned by uid 1000, which the host shares with the container. It is not
reachable directly, because the container's `/dev` is a tmpfs in its own mount namespace, but it is
reachable as `/proc/<any container pid>/root/dev/input/wl_keyboard_events`. That traversal is what
needs root; the FIFO itself would not.

`send_key_event()` in `wayland-hwc.cpp` writes **one bare `struct input_event` per transition** —
no `SYN_REPORT`, unlike a real evdev device — with a `CLOCK_MONOTONIC` timestamp. 24 bytes, well
under `PIPE_BUF`, so writes are atomic and a second writer cannot interleave with the hwcomposer's.

## Why the key cannot simply be forwarded

The obvious design — let cage deliver `KEY_POWER` to its client and let Waydroid pass it on — is
closed upstream, deliberately, on **every branch** (`lineage-17.1`, `18.1`, `20`, `dev/lineage-23.2`):

```c
static void keyboard_handle_key(void *data, struct wl_keyboard *,
                                uint32_t, uint32_t, uint32_t key, uint32_t state)
{
    if (key == KEY_POWER)
        return;
    send_key_event(...);
}
```

That filter is on the *compositor* path only. It does not apply to writes made directly into the
pipe, which is why this works at all.

### KEY_SLEEP / KEY_WAKEUP, not KEY_POWER

Upstream's own doze work on `dev/lineage-23.2` injects this same pair through this same pipe, and
states the reason in a comment:

> Unlike KEY_POWER these are not toggles, so a lost injection (input pipe not up yet during early
> boot) cannot invert the state.

Every retry in `waydroid-android-key` and in the lock script depends on that property: sending a
wakeup twice, or sending one to an already-awake Android, is a no-op rather than a screen that goes
dark. On a path whose failure mode is a kiosk nobody can wake, that matters more than elegance.

## The finding this note exists for: there is no in-band wake path

Three mechanisms close it, and each was measured separately.

**1. Touch is switched off, not ignored.** 479 ms after Android's display group powers down:

```
16:21:16.737  InputReader: Disabling wayland_touch (device 4)
              because the associated viewport is not active
```

Tapping the panel while asleep was tested with the owner watching: nine polls over 43 s, `Asleep`
throughout. The taps did not reach the input pipeline at all — the device was disabled, not the
events discarded. On resume the reader brings it back (`Viewport [0] to add: local:0, isActive:
true`, `Device reconfigured: ... mode 1`).

**2. Ordinary keys do not wake it.** Tested first with the Bluetooth keyboard (connected and live —
`bluetoothctl` listed it, `event15`/`event16` present) and then, to remove the keyboard as a
variable, by injecting into the pipe directly. Same writer, same process, same pipe, only the
keycode differs:

| injected | result |
|---|---|
| `KEY_SPACE` (57) | `Asleep`, `Asleep`, `Asleep` — 13 s |
| `KEY_WAKEUP` (143) | **`Awake`** within 4 s |

**3. The one key that would wake it is filtered**, per the hwcomposer code above.

Put together: **a sleeping Android under cage cannot be woken from inside the session.** Android's
screen timeout here is `mScreenOffTimeoutSetting=60000` with `Wake Locks: size=0`, so a cage session
that idles for a minute goes black and stays black until someone reaches the host over SSH. That is
a worse failure than the freeze gap [25](25-waydroid-in-cage.md) records, because it needs no freeze
— just inactivity. The unit below fixes it as a side effect: every resume injects a wakeup, so any
suspend/resume cycle is a recovery.

## What does *not* happen: display sleep does not freeze the container

This was expected to fire `IHardware` transaction 3 and freeze the container — the gap
[25](25-waydroid-in-cage.md) flags. It does not. Across every cycle tested the container polled
`RUNNING`, and `waydroid.log` records the last transaction 3 at **13:37**, hours before any of this
work. The freeze is bound to something other than Android's display state — most plausibly
`waydroid.active_apps` reaching `none`, which a full-UI kiosk never does.

That re-scopes docs/25's gap a second time and makes this design much cheaper: sleeping Android
under cage costs nothing that needs thawing.

## What does *not* happen either: the panel does not turn off

Worth recording because it looks exactly like it does. With Android asleep, the owner reported the
screen "off". The driver disagrees, and it was sampled across a full 40 s sleep:

```
16:08:56  AWAKE   pipeA_active=yes  backlight=937/937 bl_power=0  psr=PSR1 enabled
16:09:14  ASLEEP  pipeA_active=yes  backlight=937/937 bl_power=0  psr=PSR1 enabled
```

`hw: active=yes` on `[CRTC:53:pipe A]` means i915 never disabled the pipe, `actual_brightness` is
read back from the PWM register rather than being the last request, and PSR sitting in
`PSR1 enabled` / `SRDENT` means the panel was in self-refresh — displaying a static image from its
own memory, which is also why it looked so completely dead.

So Android asleep = **black pixels at full backlight**, not a dark panel. The consequence is a
design one: any variant that turns Android's screen off *without* suspending the host would need to
blank the backlight itself (`org.freedesktop.login1.Session.SetBrightness`, unprivileged; cage is
too minimal to have output-power IPC). Suspending the host, which is what this design does, turns
the panel off properly.

## The trap: `/etc/systemd/system-sleep/` hooks never run on this host

The first implementation was the obvious one — a `systemd-sleep` hook. It never executed once, and
finding out why turned up something the project needs to know.

**systemd 259 does not look in `/etc`.** The only hook directory compiled into the binary:

```
$ sudo grep -rhoa "[a-z/]*systemd/system-sleep" /usr/lib/systemd/
/usr/lib/systemd/system-sleep
```

That directory is empty here, and on an rpm-ostree host it is read-only. The strings are not the
only evidence, and not the strongest:

| check | result |
|---|---|
| suspends in the previous boot | **9** |
| `ite8350-resume-check` runs from those suspends | **0** |
| `/run/waydroid-sync.cycle`, created by `50-waydroid-sync`'s pre leg, after 3 suspends today | **absent** |
| SELinux denials | none |

The five `ite8350-resume-check` journal mentions that do exist are all from the manual test at
21:48:29 on 09-06, one second after the script was installed.

### This was not only our problem

**[19](19-sensor-hub-suspend-wedge.md)'s sensor-hub reprobe and [17](17-hybrid-sleep.md)'s
`50-waydroid-sync` were both installed as `/etc/systemd/system-sleep/` hooks, and neither had ever
run from a real suspend.** The `ite8350` hook even carried the assumption in its own comment —
*"the hook lives in /etc, which systemd searches alongside /usr/lib/systemd/system-sleep"*. That was
true of older systemd and is not true here. Both notes described safety nets that were inert.

Both have since been converted to units on the same pattern, and `/etc/systemd/system-sleep/` is now
empty. **It must stay empty:** anything dropped there is silently dead.

The `ite8350` conversion earned its keep on the very first suspend it was alive for:

```
17:49:20  ite8350-resume: accelerometer stale after resume -- reprobing i2c-ITE8350:00
17:49:32  ite8350-resume: accelerometer recovered at /sys/bus/iio/devices/iio:device0
```

Two reads afterwards differ (`x=11 y=-886 z=-484` → `x=15 y=-878 z=-480`), so the hub is genuinely
live again. The wedge docs/19 describes is real, it recurs, and it had no working safety net for a
day. It also retroactively explains [25](25-waydroid-in-cage.md)'s loose end, where the
accelerometer returned bit-identical values after a suspend and was charitably read as a filtered
sensor sitting still.

### And a hook could not have done this job anyway

From `systemd-sleep(8)` on this host:

> Note that by default these services freeze user.slice while they run. This prevents the execution
> of any process in any of the user sessions while the system is entering into and resuming from
> sleep. Thus, this prevents the hooks in /usr/lib/systemd/system-sleep/, or any other process for
> that matter, from communicating with any user session process during sleep.

Android is in `user.slice`. A `KEY_SLEEP` written by a hook would sit unread in the FIFO until the
thaw and be acted on *after* resume — the exact opposite of what is wanted. So even a hook in the
scanned directory would have been wrong. This is the second, independent reason the design is a
unit.

## The design

Two files in `$PREFIX/bin` and one unit.

`waydroid-android-key <sleep|wakeup|power|code>` finds any container process, reaches the FIFO
through its `/proc/<pid>/root`, and writes the down/up pair. It exits 0 with a message when there is
no container or the pipe has no reader, because a caller on the suspend path must be able to treat
"nothing to do" as success.

`waydroid-android-lock pre|post` is the policy: it no-ops unless the container is `RUNNING` (a
frozen container is not reading its pipe, so an injected event would be delivered at an arbitrary
later thaw), injects sleep and waits ~1 s on `pre`, and injects wakeup twice on `post`.

`waydroid-android-lock.service` is what makes the ordering work:

```ini
[Unit]
Before=sleep.target
StopWhenUnneeded=yes

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=@BINDIR@/waydroid-android-lock pre
ExecStop=@BINDIR@/waydroid-android-lock post

[Install]
WantedBy=sleep.target
```

`systemd-suspend.service` is `Requires=sleep.target` + `After=sleep.target`, so `Before=sleep.target`
puts the pre leg ahead of it — and therefore ahead of the `user.slice` freeze. `RemainAfterExit`
keeps the unit active across the suspend so that *leaving* `sleep.target` is what runs `ExecStop`;
`StopWhenUnneeded` is what makes it leave.

The 1 s wait is measured, not guessed: logcat puts `goToSleep(GO_TO_SLEEP_REASON_SLEEP_BUTTON)` at
`.461` and the power group asleep at `.976`, so 515 ms, doubled. Without it the host can suspend
mid-transition and the wakeup on the far side may race a sleep that never finished — a black screen
with no way back.

**`systemctl start` is not a valid test.** With `sleep.target` inactive the unit is unneeded the
instant it starts, so both legs run a second apart and it looks like nothing happened. Drive the
script directly, or do a real suspend.

## Verified on the host

The real path, with an RTC alarm (`rtcwake -m no -s 30 && systemctl suspend`) so it returned
unattended:

```
17:10:49  waydroid-android-lock: sent sleep (142)
17:10:50  Finished waydroid-android-lock.service
17:10:50  Reached target sleep.target
17:10:50  Successfully froze unit 'user.slice'      <-- after the pre leg
17:10:50  PM: suspend entry (s2idle)
17:11:19  PM: suspend exit
17:11:19  user.slice: Unit now thawed               <-- before the post leg
17:11:19  Stopped target sleep.target
17:11:19  Stopping waydroid-android-lock.service
17:11:20  sent wakeup (143)
17:11:22  sent wakeup (143)
```

Both ordering constraints met, and the end state was `mWakefulness=Awake` with `showing=true` —
resume lands on the lock screen. Confirmed visually by the owner.

| claim | evidence |
|---|---|
| injection sleeps Android | `mWakefulness` `Awake` → `Asleep`, `mHoldingDisplaySuspendBlocker` `true` → `false` |
| injection wakes it | `Waking up ... reason=WAKE_REASON_WAKE_KEY, details=android.policy:KEY` |
| the container is unaffected | `RUNNING` across every cycle; no transaction 3 |
| the keyguard arms on sleep | `showing=true` while `Asleep`, with `lock_screen_lock_after_timeout=0` |
| the keyguard survives resume | `showing=true`, `mKeyguardDrawComplete=true` after `PM: suspend exit` |
| it renders and takes input under cage | owner confirmed the lock screen on the panel, and that swiping up dismisses it |
| touch comes back | `Device reconfigured: id=4, name='wayland_touch', ... mode 1` |
| the cage session is untouched | `cage` and `waydroid-cage-session` the same pids across five sleep/wake cycles and two suspends; watchdog silent |

## Enabling the lock screen

The keyguard is present and wired up but **switched off in this image** — `locksettings
get-disabled` returned `true`, `KeyguardServiceDelegate: secure=false`. That is a sane Waydroid
default for a windowed desktop and wrong for a kiosk. Turned on with:

```bash
waydroid shell -- locksettings set-disabled false
waydroid shell -- settings put secure lock_screen_lock_after_timeout 0
```

The second one matters. `KEY_SLEEP` reaches `PhoneWindowManager` as
`GO_TO_SLEEP_REASON_SLEEP_BUTTON`, not `POWER_BUTTON`, so AOSP's "power button instantly locks"
shortcut does not apply and the keyguard would otherwise arm after the default 5 s grace — long
enough for a resume to show the unlocked UI first.

A PIN or pattern is then set normally in Settings > Security.

**The way back out of a lost credential** needs no root and no Android: stop the session and delete
`~/.local/share/waydroid/data/system/locksettings.db`, which is host-visible and owned by the
session user (`-rw-rw---- jmelanso jmelanso`). `locksettings clear` is *not* the escape hatch — it
requires `--old <CREDENTIAL>`.

## Bluetooth in s2idle

Asked while testing, and worth recording since it decides whether anything needs to be made
optional: **the Bluetooth keyboard is fully down in s2idle and cannot wake the machine.** Three
independent confirmations from one suspend:

```
/sys/bus/usb/devices/1-4/power/wakeup = disabled          (not armed as a wake source)
bluetoothd: Controller resume with wake event 0x0         (it did not wake anything)
kernel: input: HP Wireless ... Keyboard as .../input34    (link dropped, device re-created)
```

The input device is destroyed and rebuilt with new numbers across the cycle, which is why the
keyboard is unresponsive while suspended. Nothing to disable, and no battery cost.

## The second trap: a unit under `/usr/local` cannot be started by systemd

The units first went to `/usr/local/lib/systemd/system`, which `systemd-analyze unit-paths` does
list, matching the trick [24](24-graceful-logout.md) uses for user units. Two of the three worked.
The third failed on resume:

```
avc: denied { start } for path="/usr/local/lib/systemd/system/ite8350-resume-check.service"
     scontext=system_u:system_r:init_t:s0 tcontext=system_u:object_r:lib_t:s0 tclass=service
```

`/usr/local` is a symlink to `/var/usrlocal`, and `matchpathcon` gives everything under it `lib_t`.
`init_t` may not *start* a service whose unit file is `lib_t`.

Why only the third: the other two units are only ever **dependency-activated** by `sleep.target`,
which systemd does internally with no such check. `ite8350-sleep.service` is the only one whose
`ExecStop` asks systemd, over D-Bus, to start *another* unit — and that path checks the target unit
file's label. A `systemctl start` typed at a shell does not fail, because the caller is then
`unconfined_t`; this is only reachable from inside systemd, which is exactly where it matters.

The fix is `/etc/systemd/system`, which `matchpathcon` labels `systemd_unit_file_t`, and which is
already where this project puts its other system units. So the installers take `UNITDIR`, defaulting
to `/etc/systemd/system` for the manual install and set to `/usr/lib/systemd/system` — also
correctly labelled — for the package. `semanage fcontext` on `/var/usrlocal/lib/systemd/system`
would have worked too, and was rejected: a host-wide policy edit is a much larger footprint than
putting the file where the policy already expects it.

## Packaging

`artifacts/android-power/install.sh` honours `DESTDIR` and `PREFIX` like the others, so it doubles
as the spec's `%install`:

```
DESTDIR=%{buildroot} PREFIX=/usr sh artifacts/android-power/install.sh
```

Verified by staging into a scratch buildroot:

```
-rwxr-xr-x /usr/bin/waydroid-android-key
-rwxr-xr-x /usr/bin/waydroid-android-lock
-rw-r--r-- /usr/lib/systemd/system/waydroid-android-lock.service
lrwxrwxrwx /usr/lib/systemd/system/sleep.target.wants/waydroid-android-lock.service
```

Nothing in `/etc`, nothing in `/var`, nothing in `/usr/local`, and no literal `@BINDIR@` left in any
staged file — checked explicitly, because docs/25 records that exact failure shipping quietly once.
The three embedded paths that must be substituted are the unit's `ExecStart=` and `ExecStop=`, and
the lock script's own `KEY=`.

Unit enablement is the packaged `.wants` symlink rather than a scriptlet, the same trick
[24](24-graceful-logout.md) uses for user units; `/usr/local/lib/systemd/system` is in the search
path (`systemd-analyze unit-paths`), so the manual install is enabled the same way with nothing
written to `/etc`. Runtime dependencies are `waydroid`, `systemd` (for `busctl`), `python3` and
`coreutils`.

An RPM shipping into `/usr/lib/systemd/system-sleep/` **would** work on this host, since that is the
one directory systemd scans. That option is open to a package and closed to a manual install on an
immutable host — which is exactly why this uses a unit instead. Units were kept for the packaged
case too, so both installs use one mechanism.

### The spec

[packaging/waydroid-bigtab01.spec](../packaging/waydroid-bigtab01.spec) is the project's first, and
covers four of the five DESTDIR-ready installers: a main package (this note plus
[19](19-sensor-hub-suspend-wedge.md)'s resume check), a `-graceful-exit` subpackage
([24](24-graceful-logout.md), which needs `sway-config-fedora` for `/usr/share/sway/config.d`) and a
`-cage` subpackage ([25](25-waydroid-in-cage.md), which needs `cage` and graceful-exit). `%install`
is the installers themselves, so there is still exactly one description of the layout.

[17](17-hybrid-sleep.md)'s `waydroid-sync-sleep` is **deliberately excluded**: it is DESTDIR-ready
and would slot straight in, but it is only the sleep and resume legs of a feature whose other half
is unpackaged and whose timer is deliberately disabled. Shipping half a dormant feature is worse
than shipping none of it.

**The spec has never been built** — there is no `rpmbuild` or even `rpmspec` on the dev box, and
layering one onto bigtab01 costs a reboot. What *is* verified is the payload: staging all four
installers into a scratch buildroot produces 14 files, and `%files` matches that tree **exactly**,
checked by diffing the two lists rather than by reading. The `License:` tag is a placeholder marked
`FIXME` in the spec, because this repository has no LICENSE file.

## Known gaps

- **The spec is unbuilt.** `%files` is verified against a staged buildroot, and nothing else is —
  not even a syntax parse. It needs one `rpmbuild -ba` somewhere with the toolchain, and a real
  `License:`.
- **`/etc/systemd/system-sleep/` is a loaded gun.** It is empty now, and anything dropped into it
  later will be silently dead. Nothing enforces that but this note.
- **The sync feature is still half-converted.** Its sleep legs now run, but
  [17](17-hybrid-sleep.md)'s timer stays disabled, so the deferred bluetooth restore it arms finds
  no state to restore. Harmless, and it will stay that way until that feature is finished.
- **The pre leg's 1 s wait is fixed, not confirmed.** It is double the measured transition, but
  nothing checks that Android actually reached `Asleep` before the suspend proceeds. A cheap
  host-side readback does not exist; `waydroid shell` costs ~2 s and would be worse than the margin
  it buys.
- **Android's own 60 s screen timeout is still live.** The unit recovers from it on the next
  suspend/resume, but between times a kiosk left idle still goes black with no in-band way back.
  The proper fix is either a wake lock while the kiosk session runs, or `persist.waydroid.suspend`
  — both untested.
- **The lid was not retested** with the unit installed. It goes through the same
  `sleep.target`, so it should behave identically, but "should" is not "did".
