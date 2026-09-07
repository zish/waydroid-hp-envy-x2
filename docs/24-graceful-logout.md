# Shutting Android down gracefully when the user logs out

Built 2026-09-07, straight after [23](23-graceful-shutdown.md), which closed the host-shutdown path
and named this one as a known gap: *"Logout and `waydroid session stop` still hard-kill Android."*

It started as a question — what actually happens to a running session if you log out of sway? — and
the answer turned out to be worse than "it stops".

## What was wrong

**The container is bind-mounted onto the compositor's socket _inode_, not its path.**
`/var/lib/waydroid/lxc/waydroid/config_session`, regenerated at every session start:

```
lxc.mount.entry = /run/user/1000/wayland-1 run/xdg/wayland-0 none rbind,create=file 0 0
```

Sway unlinks `wayland-1` when it exits. A new sway creates a *new* socket at the same path, but the
container still holds the old, unlinked inode. **Logging back in does not restore Android's display**
— only `waydroid session stop && waydroid session start`, which rewrites `config_session`, does.

What happens next depends on where the session process lives, and neither branch is good:

- **Session started inside sway.** Its terminal dies with the compositor, `waydroid session start`
  takes SIGHUP, and `session_manager`'s handler runs `do_stop()` then `stop_container()` —
  `lxc-stop -k`. SIGKILL, no `ACTION_SHUTDOWN`, no flush. The same applies when the user's D-Bus
  session goes away: `handle_disconnect` calls the identical pair.
- **Session started anywhere else** — over ssh, which is how this host had been running it
  (`session-10.scope`, while sway was `session-2.scope`) — nothing signals it at all, because
  `KillUserProcesses` is at its default `no`. The container keeps running against a dead socket.
  `/vendor/etc/init/android.hardware.graphics.composer@2.1-service.rc` is `class hal animation` with
  `onrestart restart surfaceflinger` and is **not** `critical`, so init restarts the composer
  forever rather than ever giving up. Android sits there unusable and does not tear itself down.

## The constraint: no root

docs/23's `waydroid-shutdown-android` cannot be reused here. It needs root twice over — `waydroid
shell` to run `svc power shutdown`, and `lxc-info` to watch the container. At logout the actor is an
ordinary user, and requiring sudo for a logout is not a design.

So the whole path had to be rebuilt out of levers an unprivileged user already has. All four were
verified on the host as `jmelanso`:

| lever | why it is allowed without root |
|---|---|
| `waydroid status` | `GetSession` on `id.waydro.Container`. `/usr/share/dbus-1/system.d/id.waydro.Container.conf` grants `send_destination` to `context="default"` — any user may ask. This is also why `lxc-info` is not used: it answers `Insufficent privileges to control waydroid` |
| `busctl … Unfreeze` | same interface, same policy; returned rc=0 |
| `waydroid app intent` | `IPlatform` over `/dev/binder`, which is mode `crw-rw-rw-` |
| `waydroid prop set` | same binder service, transaction 2 — proved by setting and reading back a throwaway `debug.waydroid.probe` |

No sudo, no polkit, no setuid, nothing owned by root at runtime.

## The trigger, and the name that would have failed silently

`svc power shutdown` is not available without root, but the framework path it takes is: an intent to
`ShutdownActivity`. **The action name changed in Android 10**, and this is an Android 13 image:

```
$ adb shell cmd package resolve-activity -a android.intent.action.ACTION_REQUEST_SHUTDOWN
No activity found
$ adb shell cmd package resolve-activity -a com.android.internal.intent.action.REQUEST_SHUTDOWN
  name=com.android.internal.app.ShutdownActivity
  packageName=android
```

The older name is the one everything on the web still cites; it resolves to nothing here and would
have produced a wrapper that looked installed and did nothing — the same failure mode docs/23 hit
with a hand-built `lxc-attach` environment.

`ShutdownActivity` is declared `permission=android.permission.SHUTDOWN`, which an ordinary app does
not hold. It works because of *who dispatches it*: `waydroidplatform` is registered by
**system_server** (pid 311, uid `system`) — there is no separate Waydroid app process — so the caller
Android checks is the platform itself.

```bash
waydroid app intent com.android.internal.intent.action.REQUEST_SHUTDOWN ''
```

Two traps inside Waydroid's own code shape the wrapper around it:

- **`waydroid app intent` will _start_ a session if none is running.** `maybeLaunchLater()` catches
  the "no session" D-Bus exception and calls `session_manager.start()`. At logout that would boot
  Android instead of shutting it down, so the wrapper checks `waydroid status` first and does
  nothing unless a session is already RUNNING **and owned by the invoking user**.
- **`waydroid prop set` re-freezes a container it found frozen.** `prop.set()` unfreezes, sets, then
  freezes again — which would stall the shutdown it just requested. This host freezes on suspend
  (`suspend_action = freeze`), so that is a normal state to find. The wrapper thaws once up front
  with `busctl … Unfreeze` and leaves it thawed.

The fallback ladder is therefore: **framework intent → `sys.powerctl` via binder → `waydroid session
stop`**. The middle rung is init's own shutdown, and it is the one that matters when the compositor
has already gone, because unlike the framework path it needs nothing from Wayland. The last rung is
the hard kill we are trying to avoid, but leaving the container running is worse — see the socket
inode above.

## Where it is hooked

Two hooks, the same shape as docs/23, and for the same reason: only one of the ways a session ends
is under our control.

### 1. The sway exit chord — the race-free one

`/etc/sway/config.d/95-waydroid-graceful-exit.conf` rebinds `$mod+Shift+e` to run the wrapper and
*then* `swaymsg exit`. Sway's stock config ends with an include of `config.d`
([config:229](file:///home/jmelanso/.config/sway/config)), parsed **after** the exit binding earlier
in the file, and a later `bindsym` wins — so one file in `/etc` replaces the exit chord for every
user on the host without editing anybody's `~/.config/sway/config`.

This is race-free by construction: the wrapper runs to completion, with the compositor still up, and
only then does sway exit.

The binding is deliberately one physical line. Sway does support backslash continuation, but a
config file that breaks a login if it misparses is not the place to lean on it.

**`--no-warn` is load-bearing.** Sway treats overwriting a binding as a config *warning*, and every
warning is surfaced through the nag titled **"There are errors in your config file"**, raised on
every reload and every login — while the override itself works perfectly. Three things make that
nag unusually hard to trace back to this file:

- it says *errors*, but the entry is
  `Warning on line 18 (/etc/sway/config.d/95-waydroid-graceful-exit.conf) … Overwriting binding
  'Mod4+Shift+e' for device '*'`;
- the matching log line is emitted at `[INFO]`, below sway's default log level, so **nothing appears
  in the journal at all** — no `Error on line`, no trace that the reload found anything. A nag with
  no log line is the signature of this class of fault;
- `config_add_swaynag_warning()` is skipped when `config->validating` is set, so **`sway --validate`
  reports the config clean** — which clears the file for anyone who checks it that way, including
  the check recorded in "Known gaps" below.

The detail text was recovered by pointing `swaynag_command` at a wrapper that `tee`s its stdin to a
file, because sway writes the nag body into swaynag's stdin pipe and nowhere else. The decisive test
before that was cruder and worth remembering: move the drop-in out of `config.d`, reload, and see
whether the nag returns.

### 2. A systemd **user** unit — the backstop

`/usr/local/lib/systemd/user/waydroid-graceful-exit.service`, `PartOf=graphical-session.target`,
with the work in `ExecStop=`. It covers logouts that bypass the chord: sddm ending the session,
`swaymsg exit` typed by hand, the compositor crashing.

It is a backstop and not the primary trigger, because it *does* race. sway-systemd only starts
`sway-session-shutdown.target` once sway's IPC `shutdown` event has fired — which is sway already on
its way out. When it loses that race the framework rung stalls and the ladder falls through to the
init rung. Degraded, but still a real Android shutdown instead of SIGKILL.

There is no "PrepareForLogout" to inhibit; logind's delay lock, which is what made docs/23 race-free,
has no logout equivalent. Wrapping the exit action is the only place that runs *before* the
compositor starts dying.

### 3. Not sway at all — `--keep-session`

[25](25-waydroid-in-cage.md) reuses this ladder from a cage kiosk session, where the caller owns the
session manager as its own child and releases it itself. `--keep-session` skips `release_session()`
and the final `waydroid session stop` rung for that case, leaving the host-side teardown to the
caller. Neither hook above passes it, so the behaviour documented here is unchanged.

## The trigger that outlived its session

Found 2026-09-07 by the first cage login ([25](25-waydroid-in-cage.md)), which it killed. This is the
most important thing in this note, and it was invisible until something else booted Android inside the
blast radius.

Both rungs fire their trigger in the background:

```sh
"$WAYDROID" app intent com.android.internal.intent.action.REQUEST_SHUTDOWN '' >/dev/null 2>&1 &
trigger=$!
if wait_stopped "$FRAMEWORK_WAIT"; then
    log "Android shut down cleanly"
    release_session
    finish 0                      # <-- never killed $trigger
fi
kill "$trigger" 2>/dev/null        # <-- only on the failure path
```

**A trigger that cannot reach Android does not fail — it waits.** Both `waydroid app intent` and
`waydroid prop set` go through `IPlatform.get_service()`, which retries **1000 times at 1 Hz** before
giving up:

```python
    tries = 1000
    remote, status = serviceManager.get_service_sync(SERVICE_NAME)
    while(not remote):
        if tries > 0:
            logging.warning("Failed to get service {}, trying again...")
            time.sleep(1)
```

So an orphaned trigger stays armed for **about seventeen minutes**, waiting for *any* session to
register `waydroidplatform` — and delivers its shutdown to whichever one does.

The second half of the fault is that nothing checked whether there was anything to shut down. On this
image `Session: RUNNING / Container: STOPPED` is a *normal* state, not an exceptional one — it is what
every in-Android power-off leaves behind ([25](25-waydroid-in-cage.md)). Firing into it means
`wait_stopped` returns true on its first poll, so the script congratulates itself and exits while the
trigger it just launched is still looking for a target.

### What that did, on the clock

| | |
|---|---|
| 15:06:54 | Android shut down from inside. Container STOPPED, session record still held — expected |
| 15:07:49 | sway logout → the backstop runs the ladder. Sees `Session: RUNNING`, fires the intent |
| 15:07:49 | `wait_stopped` returns true **immediately** — the container was already stopped. Logs `Android shut down cleanly`, releases the session, exits. **The intent process is orphaned** |
| 15:08:33 | cage login starts a *new* container. Android boots |
| 15:08:46 | the orphan's `get_service()` finally resolves against the new `waydroidplatform` and delivers its intent |
| 15:08:46 | `init: Received sys.powerctl='shutdown,' from pid: 305 (system_server)` |
| 15:08:52 | Android is gone, 19 seconds into its life |

The intent was 57 seconds old when it landed, well inside the ~17 minute window.

### The fix, both halves

- **`finish()` kills the trigger.** Every exit path goes through it, so this covers both rungs and any
  future one. This *contains* the fault.
- **An early `container_stopped` check** short-circuits to `release_session` when Android is already
  gone, so no trigger is ever armed with nothing to shoot at. This *prevents* it.

Either alone would have stopped this particular failure; both are worth having, because they fail
differently. `Android shut down cleanly` also became `Android shut down cleanly (framework)` and is now
only reachable when the script actually caused the shutdown, rather than claiming credit for one that
had already happened — the misleading log is a large part of why this went unnoticed.

Verified against stubs: with the container already STOPPED **no trigger is fired at all**; with a
container that never stops, both rungs fire and neither leaks.

## The half nobody runs: host-side teardown

The first successful test shut Android down cleanly and then left the host half standing:

```
mounts: 5        bridge: up        sensord: running        Session: RUNNING / Container: STOPPED
```

`waydroid.log` explains it. There is no `Received transaction: 7` — the guest **never sends the
hardware-binder shutdown request** when it shuts down this way; the host just watches the binder go:

> Why it never sends it was settled later, in [25](25-waydroid-in-cage.md): the guest-side client
> landed upstream in `android_vendor_waydroid#50` on 2026-05-09 and this host's image is dated
> 2026-04-03. The host half is present; the image is five weeks too old to use it.

```
13:29:20  [gbinder] WARNING: Service manager /dev/hwbinder has died
13:29:21  % lxc-info -P /var/lib/waydroid/lxc -n waydroid -sH
13:29:21  STOPPED
```

So `hardware_manager.shutdownRequest()` — the handler docs/23 relies on — never runs, and nothing
calls `container_manager.stop()`. The rootfs stays mounted, the `waydroid0` bridge stays up, and the
session keeps holding the `id.waydro.Session` name, which would make the next `waydroid session
start` refuse with *"Session is already running"*.

`waydroid session stop` does the whole teardown, unprivileged, in **0.44 s** with the container
already stopped. The wrapper now calls it after any successful shutdown.

## Measured

| path | result |
|---|---|
| wrapper standalone, session live, compositor up | **7.07 s** to `Container: STOPPED`, framework path |
| framework half alone, from logcat | **1.45 s** (`13:29:15.132` → `13:29:16.584`) |
| with the session-release step | **7.75 s**; `Session: STOPPED`, `mounts: 0`, bridge gone |
| `waydroid session stop`, container already stopped | 0.44 s |
| `busctl … Unfreeze` against a genuinely FROZEN container | `rc=0`, `FROZEN` → `RUNNING`, unprivileged |
| session restarted afterwards | `boot_completed=1`, sensors HAL re-registered, 5 sensors |

The logcat is the same sequence docs/23 recorded for the root path, which is the point — this is not
a lesser shutdown, it is the same one reached from an unprivileged caller:

```
13:29:15.132 D/ShutdownThread: Notifying thread to start shutdown longPressBehavior=1
13:29:15.133 D/ShutdownThread: Attempting to use SysUI shutdown UI
13:29:15.139 I/ShutdownThread: Sending shutdown broadcast...
13:29:15.726 I/ShutdownThread: Shutting down activity manager...
13:29:15.981 I/ShutdownThread: Shutting down package manager...
13:29:16.078 I/ShutdownThread: Radio shutdown complete.
13:29:16.584 I/ShutdownThread: Performing low-level shutdown...
```

## Files

| where | what |
|---|---|
| `/usr/local/bin/waydroid-graceful-exit` | the ladder, plus `--exit-sway` and `--keep-session`. Always exits 0 on the shutdown path |
| `/etc/sway/config.d/95-waydroid-graceful-exit.conf` | rebinds the exit chord to run it first |
| `/usr/local/lib/systemd/user/waydroid-graceful-exit.service` | backstop, `ExecStop=`, `TimeoutStopSec=45` |
| `…/user/graphical-session.target.wants/` symlink | enables it for every user, no per-user `systemctl --user enable` |

Sources in [artifacts/graceful-exit/](../artifacts/graceful-exit); install with `sudo sh install.sh`.
No image changes, no overlay files, no layered packages, no reboot.

**To undo:** delete the four files. Stock behaviour returns exactly.

## Written to be packaged

The host paths are staging, chosen so the eventual RPM is a prefix change and nothing else.

- **`/usr/local` is a symlink to `/var/usrlocal` here.** That makes it the right place for a change
  that must not touch `/usr` on an immutable host — and exactly the wrong place for an RPM to own
  files. `install.sh` therefore substitutes `@BINDIR@` from `$PREFIX`: `PREFIX=/usr sh install.sh`
  emits the packaged layout (`/usr/bin`, `/usr/lib/systemd/user`) from the same sources. It also
  honours `DESTDIR` so it can serve as the spec's `%install` directly, skipping `restorecon` when
  staging — see the packaging section of [25](25-waydroid-in-cage.md), which audits both installers
  against Fedora and rpm-ostree rules together.
- **`/usr/local/lib/systemd/user` is in systemd's user-unit search path** (confirmed via
  `systemctl --user show -p UnitPath`), so one unit file plus one `.wants` symlink enables the
  backstop for every user on the host, with nothing written to any home directory. In an RPM these
  become `/usr/lib/systemd/user/…`, unchanged otherwise.
- **The sway drop-in wants `/etc` when staged and `/usr/share` when packaged.**
  `/usr/share/sway/config.d/` is the correct `/usr` location and the RPM must use it: the directory
  is owned by `sway-config-fedora-0.4.3-3.fc44`, which ships its own thirteen drop-ins there, so it
  is a path a package may legitimately populate. `install.sh` already takes it as a variable, so the
  spec's `%install` is exactly:

  ```
  DESTDIR=%{buildroot} PREFIX=/usr SWAY_CONFD=/usr/share/sway/config.d sh install.sh
  ```

  **The caveat is real and needs stating loudly.** The stock `/etc/sway/config` includes all three
  layers, but *this host's* `~/.config/sway/config` has that three-path line commented out
  ([config:228](file:///home/jmelanso/.config/sway/config)) and uses a two-path variant covering only
  `/etc/sway/config.d` and `~/.config/sway/config.d` ([config:229]) — because the user's home holds
  its own copies of the same thirteen `sway-config-fedora` files. A `/usr/share` drop-in is therefore
  installed correctly and **silently inert here** until that config swaps 229 back to 228. Staging to
  `/etc` sidesteps the whole question, which is why `install.sh` still defaults there.
- **No `android-tools` dependency.** adb was used heavily to *investigate* (logcat, `resolve-activity`,
  permission dumps) but nothing shipped uses it: the runtime path is `waydroid` plus `busctl`.
- **SELinux** labels came out as expected with no denials — `bin_t` for the script, `lib_t` for the
  unit, `etc_t` for the sway drop-in; `install.sh` runs `restorecon` regardless.

## Known gaps

- **The chord itself has not been exercised end to end**, because doing so logs the tester out. What
  is verified: the wrapper standalone (twice), and that the drop-in loads and reloads without raising
  the config nag.

  *Corrected 2026-09-07.* This bullet previously claimed reload had been verified clean. It had not:
  no reload was run after the drop-in was last written, and the install before it did raise the nag
  described in §1, which then sat on screen for half an hour. Two lessons, both cheap:
  `swaymsg reload` returning `"success": true` says the IPC command was accepted, **not** that the
  parse was clean — it returns that even while spawning the error nag. And `sway --validate` cannot
  see this class of fault at all. The check that actually discriminates is `pgrep swaynag` after the
  reload.
- **The backstop races the compositor** and degrades to the init rung when it loses. Accepted; there
  is no pre-logout inhibitor to take.
- **`waydroid-sensord` survives `waydroid session stop`** — seen again here: `waydroid.log` shows
  `% pidof waydroid-sensord` with no `kill -9` following, while the same `pidof` finds it fine from a
  shell. This is already a known and *already defended* failure: `sensors/service.cpp` documents both
  ways Waydroid's cleanup misses (an earlier fallible step skips the kill silently; with two
  instances `pidof` returns `"A B"`, which becomes one argv element and always fails), which is why
  the daemon takes its own exclusive `flock` and evicts a stale holder — [14](14-sensors.md). So it
  costs one stale daemon between sessions and nothing after: verified here, a single instance 19 s
  old after the restart.
- **The wrapper only ever touches a session owned by the invoking user**, since another user's
  session service lives on a bus it cannot reach. That is deliberate, not a limitation to fix.

## Verifying

```bash
# the pieces are in place
systemctl --user list-dependencies --reverse waydroid-graceful-exit.service   # graphical-session.target
grep bindsym /etc/sway/config.d/95-waydroid-graceful-exit.conf   # must carry --no-warn

# the drop-in reloads WITHOUT raising the config nag. `sway --validate` cannot
# show this and `swaymsg reload`'s own return value does not either -- see §1.
swaymsg reload && sleep 3 && { pgrep -a swaynag && echo "NAG RAISED"; } || echo "clean"

# exercise it without logging out (this DOES shut Android down)
/usr/local/bin/waydroid-graceful-exit
journalctl -t waydroid-graceful-exit -n 5
waydroid status          # Session: STOPPED
```

`asking Android to shut down (REQUEST_SHUTDOWN)` followed by `Android shut down cleanly` means the
framework path ran. `falling back to init (sys.powerctl)` means it did not, and the next thing to
check is whether the session was still alive when it fired.
