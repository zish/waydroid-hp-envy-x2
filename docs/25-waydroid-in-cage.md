# Running Waydroid as a kiosk session under cage

Built 2026-09-07, after [23](23-graceful-shutdown.md) and [24](24-graceful-logout.md), which closed
the host-shutdown and sway-logout paths. The goal here is different: not Waydroid *in* a desktop,
but Waydroid *as* the desktop — pick "Waydroid in Cage" at the SDDM greeter, get Android full-screen,
power Android off from inside, and land back on the greeter with the machine ready to do it again.

Cage is already installed on the host, and a session entry already existed:

```ini
Exec=cage -- waydroid show-full-ui
```

That line is wrong in three ways, and none of them are bugs — they are consequences of how Waydroid
splits itself in two. This note is mostly about that split.

## What the container service actually is

`waydroid-container.service` is thin — `ExecStart=/usr/bin/waydroid container start`,
`BusName=id.waydro.Container`, an `ExecStartPre` that symlinks the binderfs nodes into `/dev`, plus
the `graceful-shutdown.conf` drop-in from [23](23-graceful-shutdown.md).

`waydroid container start` is **a root daemon running a GLib main loop that owns
`id.waydro.Container` on the system bus.** At startup it does nothing else; no container exists until
somebody asks. It exports `/ContainerManager` with `Start`, `Stop`, `Freeze`, `Unfreeze` and
`GetSession`. It is the privileged half of Waydroid, and every method on it is reachable by an
unprivileged caller — `id.waydro.Container.conf` grants `send_destination` to `context="default"`.

`Start(session)` is where the root work happens, in `do_start`:

- probes the binder and ashmem drivers and chmods the binder nodes — **once per daemon lifetime**
  (`prepare_drivers_once`), not once per session
- `waydroid-net.sh start` — the `waydroid0` bridge, NAT, dnsmasq
- launches `waydroid-sensord` if it is on `PATH` — our daemon from [14](14-sensors.md)
- chmods the device nodes Android needs: `/dev/dri/renderD*`, `/dev/video*`, `/dev/dma_heap/*`,
  `/dev/fb*`, `/dev/sw_sync`
- generates `lxc/waydroid/config_session` — the per-session bind mounts: **the caller's Wayland
  socket** → `/run/xdg/wayland-0`, the pulse socket, and `~/.local/share/waydroid/data` → `/data`
- mounts the rootfs (system.img + vendor.img + the overlays in `/var/lib/waydroid/overlay`) and
  writes the prop file
- `lxc-start`
- starts the `IHardware` binder service (`waydroidhardware`, on `/dev/binder`) so the guest can call
  back out

Two properties of it decide everything below:

1. **It tracks exactly one session**, in `args.session`. `do_start` raises `Already tracking a
   session` if one is already registered.
2. **`Stop` does not exit the daemon.** The main loop quits only on SIGINT/SIGTERM. Container start
   and stop are method calls on a daemon that outlives them both, so **a session ending never
   requires restarting the unit** — and restarting it is the heavier hammer, since it re-probes
   drivers.

The other half, `waydroid session start`, runs as the user, owns `id.waydro.Session` on the *user*
bus, runs the user/clipboard/notification services, and blocks in its own main loop after calling
`Container.Start`. Its signal handlers are the seam this work uses:

| signal | handler |
|---|---|
| SIGTERM / SIGINT / SIGHUP | `do_stop()` then `stop_container(quit_session=False)` — tear the session down *and* tell the container to stop |
| SIGUSR1 | `do_stop()` only — the container saying "I already stopped, you can go" |

## The finding: this image is five weeks too old to tell the host it shut down

[24](24-graceful-logout.md) recorded the symptom — a clean in-Android shutdown leaves the host half
standing, and `waydroid.log` shows no `Received transaction: 7`, just the hwbinder service manager
dying. The cause is neither a race nor a design gap. **It is version skew between the host tooling
and the Android images, and upstream already fixed it.**

The host implements `IHardware` transaction 7, `shutdownRequest`, and
`hardware_manager.shutdownRequest()` does the whole teardown. The guest-side client is
`lineageos.waydroid.Hardware`, in `/system/framework/org.lineageos.platform.jar`. Its method set,
read out of the dex:

```
enableBluetooth, enableNFC, reboot, suspend, upgrade, upgrade2
```

No shutdown method. `shutdownRequest` appears zero times in any framework jar in the image, and a
census of the whole log agrees: 26 × `Received transaction: 3` (suspend), never a 7.

Both halves were added upstream on the same day, **2026-05-09**:

| | |
|---|---|
| [waydroid#2305](https://github.com/waydroid/waydroid/pull/2305) | the host half — `TRANSACTION_shutdownRequest = 7` and the handler. Merged; it is in the 1.6.3 on this host, which is why the host side is already there |
| [android_vendor_waydroid#50](https://github.com/waydroid/android_vendor_waydroid/pull/50) | the guest half — `IHardware.shutdownRequest()` in `Hardware.java`, the AIDL method, and a shutdown-intent `BroadcastReceiver` in `WayDroidService` |

This host's image predates the second one:

```
ro.build.date=Fri Apr  3 11:36:24 CEST 2026
ro.build.date.utc=1775208984
```

**2026-04-03 — five weeks before the guest patch merged.** The vendor PR even describes the exact
method set observed above: when `shutdownRequest()` is unavailable it "will fallback to the existing
`IHardware.reboot()` call", *for reboot only*. That is precisely why transaction 4 is present and 7
is not, and why **Android's "Restart" works end to end here while "Power off" goes unannounced** —
an asymmetry the wrapper has to allow for either way.

### What that means for this design

**Updating the system image is the real fix**, and it demotes the watchdog to a fallback rather than
the mechanism. With a post-2026-05-09 image, `shutdownRequest` fires, the daemon runs
`container_manager.stop()` and SIGUSR1s the session process, `waydroid show-full-ui` exits on its
own, and cage exits with it. The wrapper stays correct in that world: its loop checks the child
before it checks the container, so an already-exited session manager just ends the loop with no
teardown of its own.

That upgrade is not a `waydroid upgrade` away, though. `images_path` is `/etc/waydroid-extra/images`,
which is in `preinstalled_images_paths`, so the upgrader refuses by design. The images are also owned
by no RPM — they were placed by hand — so replacing them is a manual swap, not a package update.
**Untested, and worth doing before trusting the kiosk to a long-lived session.**

Until then the watchdog is load-bearing, and it stays useful afterwards as the backstop for the case
upstream still does not cover: a container that stops without anybody being told, for any reason
other than Android's own shutdown path.

## What "ready for the next login" means

Four conditions must hold before a new login can start a session:

| # | condition | if violated |
|---|---|---|
| 1 | the daemon is not tracking a session (`args.session` cleared) | `Already tracking a session` |
| 2 | `id.waydro.Session` is unowned on the user bus | `Session is already running` |
| 3 | rootfs unmounted, `waydroid0` down | flaky rather than fatal; `do_start` would re-mount |
| 4 | `config_session` regenerated against the **new** Wayland socket | Android can never connect |

Condition 4 is the one that rules out the tempting optimisation. `generate_session_lxc_config` binds
the socket by **inode**, and cage unlinks its socket when it exits. Keeping the container alive
across logins would leave it holding a dead inode, and a new cage at the same path does not restore
it — Android would crash-loop the composer forever, because
`android.hardware.graphics.composer@2.1-service.rc` is `class hal animation` with `onrestart restart
surfaceflinger` and is not `critical`. **A fresh session start per login is mandatory, not tidiness.**

All four are satisfied by one successful `waydroid session stop` — 0.44 s with the container already
stopped, measured in [24](24-graceful-logout.md). **No reboot, and no `systemctl restart
waydroid-container`, is ever required.**

There is exactly one command that manufactures a wedge instead of clearing one: `sudo waydroid
container stop` does **not** go over D-Bus. `tools/__init__.py` calls `container_manager.stop()`
directly, in the CLI's own process, whose `args` has no `session` attribute — so it tears down the
container, network and mounts while leaving the daemon still tracking the session, and it cannot stop
the daemon's hardware-manager thread either (`args.hardwareLoop` lives in the other process). It
produces `Session: RUNNING / Container: STOPPED` — the identical signature to an in-Android
power-off, from an unrelated cause. Use `waydroid session stop`.

## Why `cage -- waydroid show-full-ui` does not work

**Cage exits when its child exits.** That is the whole session model, and it is a good fit — it means
the session's lifetime is one process's lifetime. It also means the child has to be chosen carefully.

1. **`waydroid show-full-ui` only blocks when no session is running.** `maybeLaunchLater` catches the
   "no session" D-Bus error and calls `session_manager.start(background=False)`, which holds the
   session main loop and calls `justShow` from the unlocked callback — exactly what a kiosk wants.
   But if a session *is* already registered it fires the intent and returns, cage exits, and the user
   lands back on the greeter. A stale session has to be cleared first, not inherited.
2. **Android's power-off never ends the session** — the missing transaction 7 above. The session
   manager blocks forever against a dead container, and cage never exits. That is a black screen, not
   a logout. Something has to notice.
3. **Cage has no sway-systemd equivalent.** `rpm -ql cage` is `/usr/bin/cage` and a man page: no
   units, no desktop file, no `graphical-session.target` integration. So the
   `waydroid-graceful-exit.service` backstop from [24](24-graceful-logout.md), which is
   `PartOf=graphical-session.target`, **never starts under cage** and its `ExecStop` never runs. That
   safety net has to be replaced.

## The wrapper

`waydroid-cage-session` is cage's child and does the three jobs above. It is unprivileged throughout,
for the same reasons and by the same means as [24](24-graceful-logout.md).

```ini
Exec=cage -s -- /usr/local/bin/waydroid-cage-session
```

`-s` allows VT switching, kept deliberately: on a machine whose only session is a kiosk, a way out
that does not involve the kiosk is worth having.

**On entry** it requires `WAYLAND_DISPLAY`, then asks the *bus* whether anything owns
`id.waydro.Container` (`NameHasOwner`) before asking the *daemon* anything. Inferring "no service"
from a failed `GetSession` would have been one call fewer and is about to become wrong:
[waydroid#2389](https://github.com/waydroid/waydroid/pull/2389), open, adds a caller check to
`GetSession` that denies a non-root caller whenever no session is tracked — exactly the state a
kiosk login starts in. A session belonging to another uid is left alone and the session gives up; one
belonging to this user
is stale by definition (condition 4) and is cleared with the full `waydroid-graceful-exit` ladder,
which can cost ~20 s because the framework rung cannot work without the compositor that session was
bound to.

**The watchdog** polls `GetSession` and latches. `busctl` rather than `waydroid status`: measured on
this host, **9 ms against 220 ms**, because the latter starts a Python interpreter to make the same
D-Bus call. At a 2 s poll for the life of a session, on a Core M with 8 GB, that difference is worth
parsing a busctl line for.

- Before Android is up, an empty session means "still booting", not "gone" — `args.session` is the
  *last* statement of `do_start`, after `lxc.start`, so a session that is visible at all has a
  started container. The watchdog latches on first sight of `RUNNING`/`FROZEN` and only then arms.
- `FROZEN` is not an exit. This host runs `suspend_action = freeze`.
- `STOPPED` must be seen **three polls running** before it counts. Android's own "Restart" is
  transaction 4, and `hardware_manager.reboot()` calls `lxc-stop` then `lxc-start` with no wait
  between them, so the container is briefly STOPPED during a reboot. Without the confirmation count,
  rebooting Android would log the user out. It costs ~6 s on a real shutdown.

**On Android's power-off** the watchdog SIGTERMs the session manager. Its handler runs `do_stop()`
and then `Container.Stop(False)`, which is the host-side half nothing else performs; the container is
already STOPPED so the daemon skips `lxc-stop` and goes straight to unmounting the rootfs, tearing
down the bridge and clearing `args.session`. The child exits, so the wrapper exits, so cage exits, so
SDDM gets the greeter back. That is the whole intended path, and it involves no signals from outside
and therefore no race.

**On SIGTERM** — SDDM ending the session, or systemd stopping the scope — there is a race, and it is
the same one [24](24-graceful-logout.md) accepted for its backstop: the signal goes to the whole
cgroup, so the session manager gets it at the same instant, and its handler reaches `lxc-stop -k`.

What can be done is to stop the racer. **SIGSTOP is not catchable**, so the wrapper freezes the
session manager first, which keeps GLib from dispatching the SIGTERM it has already queued, and that
buys the ladder its window. Afterwards the child is resumed and terminated normally, and its own
handler performs the host-side teardown. This is why `--keep-session` was added to
`waydroid-graceful-exit`: under cage the session manager is our own child and will release itself, so
the ladder must shut Android down and then keep its hands off. It is a bias, not a fix — if the
child's handler dispatches first, the result is today's SIGKILL.

**A last resort** runs on every exit path: if the daemon is still tracking a session, the wrapper
clears it with `Stop(false)` over busctl rather than `waydroid session stop`. With the session
manager already gone, that command falls back to `Stop(true)`, which makes the daemon
`os.kill(session["pid"], SIGUSR1)` — a pid recorded at `Start`, never rechecked, and SIGUSR1's
default disposition is *terminate*. There is no session left to notify, so it does not ask.

**An anti-bounce guard** pauses before returning to the greeter if the session lasted less than 15 s.
A kiosk session that fails instantly is a relogin loop, and with SDDM autologin it is a spin.

## Verified, and not

Verified on the host:

- the guest's `IHardware` method set, read out of `org.lineageos.platform.jar`; the transaction
  census over `waydroid.log`
- `GetSession` reachable unprivileged, its output format, and the 9 ms vs 220 ms cost
- the field parser, against real `busctl` output in all four states (live, `a{ss} 0`, no daemon,
  STOPPED)
- cage's option set and that its package ships no systemd integration
- SDDM's `SessionDir` already includes `/etc/wayland-sessions`, via
  `/etc/sddm.conf.d/wayland-paths.conf`

The wrapper's state machine was then exercised against stub `busctl`, `waydroid` and
`waydroid-graceful-exit` binaries, replaying scripted `GetSession` sequences, so every branch has
been run even though the session has not:

| scenario | result |
|---|---|
| boots, runs, Android powers off | latches on `RUNNING`, three confirming `STOPPED` polls, SIGTERM to the session manager, `Stop(false)`, exit 0 |
| **Android reboot blip** — two `STOPPED` polls then `RUNNING` | session survives, counter resets; ends only on a later run of three |
| container service not answering | exits 1 having touched nothing |
| stale session at entry, cleared by the ladder | ladder called, re-check clean, normal session follows |
| Android never boots | gives up at the boot deadline and ends the session |
| SIGTERM mid-session | `SIGSTOP` child → `waydroid-graceful-exit --keep-session` → `SIGCONT`+`SIGTERM` → `Stop(false)` |
| **#2389 semantics** — `GetSession` denied until a session exists | treated as "still booting", session starts normally |

The boot-timeout case is the one the harness earned its keep on. It originally fell out of the loop
without signalling the child, so `reap_child` waited its full timeout and then **SIGKILLed the
session manager** — skipping `do_stop()` and `Container.Stop()` entirely, which is exactly the wedge
this script exists to prevent, reached from its own error path. The SIGTERM was hoisted out of the
shutdown branch to cover every exit from the loop.

**Verified since**: two real logins on 2026-09-07, written up below. The first failed and is the more
instructive of the two — the lifecycle worked and Android was killed by an unrelated bug it exposed.
The second booted to a working full-screen Android and stayed up.

## The first cage login, 2026-09-07

It failed, and it failed in a way worth the whole exercise: **the session machinery worked and the
thing it was managing was shot from off-stage.**

| | |
|---|---|
| 15:08:33 | `starting Waydroid on wayland-0` — bridge up, rootfs mounted, `lxc-start` |
| 15:08:34 | sensors HAL registered, 5 sensors, a stale `waydroid-sensord` evicted by its own flock |
| 15:08:35 | `Android is up (container: RUNNING)`; LineageOS boot animation on screen |
| 15:08:46 | `init: Received sys.powerctl='shutdown,' from pid: 305 (system_server)` |
| 15:08:52 | container STOPPED. Black screen |
| 15:08:57 | watchdog confirms the stop over three polls, SIGTERMs the session manager |
| 15:09:17 | session manager still hadn't responded; SIGKILL, then the host teardown |
| 15:09:17 | back at SDDM, `Session: STOPPED`, `waydroid-container.service` still `active` |

**Android did not crash — it was told to shut down**, by an orphaned trigger the *previous* logout left
behind. That is [24](24-graceful-logout.md)'s bug, written up there in full: a backgrounded
`waydroid app intent` that `finish 0` never killed, kept alive by `IPlatform.get_service()`'s 1000
retries at 1 Hz, which found the new session's `waydroidplatform` 57 seconds later and delivered a
shutdown meant for a container that had already been gone for a minute. Nothing to do with cage, and
nothing to do with the wrapper.

### What the wrapper got right

Everything it is for. It detected a container that stopped without anyone being told — the case that
does not exist upstream for this image — confirmed it over three polls rather than reacting to a blip,
ran the teardown, and handed the greeter back with the host clean. `waydroid-container.service` stayed
`active` from before the sway session until after the cage one: **the systemd service never needed
restarting**, which is the question this whole thread started with, now answered from a live run
rather than from the code.

### What the wrapper got wrong

**SIGTERM to the session manager did nothing, for twenty seconds.** The log shows
`Failed to get service waydroidplatform, trying again...` once a second from 15:08:52 to 15:09:16,
straight through the SIGTERM at 15:08:57, until the grace period expired and it was SIGKILLed.

The cause is the same `get_service()` retry loop, seen from the other side. `waydroid show-full-ui`
runs `justShow()` from `user_manager`'s unlocked callback, and that call **blocks the GLib main loop** —
which is the only thing that dispatches the handler `GLib.unix_signal_add` registered for SIGTERM. The
signal was queued and never delivered. A session manager in that state is not slow, it is wedged, and
waiting longer cannot help.

Fixed by treating the grace period as a probe rather than a delay: it drops from 20 s to **6 s**, and
when it expires the wrapper performs the host-side teardown *itself* (`Stop(false)` over busctl) before
resorting to SIGKILL. Killing first would have skipped `Container.Stop()` and wedged the next login —
the exact failure this script exists to prevent, reached from its own cleanup path. Re-tested against a
stub child that ignores SIGTERM: 44 s becomes 10 s, and the teardown happens either way.

## The second cage login: it works

15:23 the same day, with both fixes deployed.

```
15:23:20.798  waydroid-cage-session: starting Waydroid on wayland-0
15:23:22.824  waydroid-cage-session: Android is up (container: RUNNING)
```

and a minute later:

| check | result |
|---|---|
| `sys.boot_completed` | `1` |
| `waydroid.active_apps` | `Waydroid` — the full UI, so `justShow()` ran and returned |
| container | `RUNNING`, stable across a 30 s watch |
| `Received sys.powerctl` since login | **0** |

That last row is the one that matters: the shutdown that killed the first attempt came from an
orphaned trigger, and with [24](24-graceful-logout.md)'s fix in place nothing asked Android to go.
`waydroid show-full-ui` stayed in its main loop, so the wrapper's watchdog had nothing to do — which
is exactly the healthy case.

Note also that `justShow()` **returned** this time. On the first attempt it was still retrying
`get_service()` when the container died, which is what made the session manager deaf to SIGTERM. Once
Android is actually alive that call completes in the normal way and the main loop is responsive again.
The 6 s grace period is therefore the abnormal path, not the usual one.

### A false alarm worth recording

Between the two attempts SDDM reported "login failed" three times. It was not the session:

```
pam_unix(sddm:auth): authentication failure; ... user=jmelanso
sddm[1075]: Authentication error: SDDM::Auth::ERROR_AUTHENTICATION "Authentication failure"
```

That is password verification failing before SDDM ever reaches `Starting Wayland user session`, and no
`waydroid-cage-session` entry exists for those attempts. Worth knowing because the obvious suspicion —
"the kiosk session is broken" — is checkable in one line: if the journal has no
`sddm-helper: Starting Wayland user session`, the session was never launched and the problem is
upstream of everything in this note.

Input and rendering work: Google Maps was driven interactively and reported as **"super-responsive"**.
That is a subjective report rather than a measurement, but it is worth recording, because it is not
the expected direction for a Core M-5Y70 — a kiosk compositor with one fullscreen surface, no
decorations and no other clients is doing strictly less work per frame than sway was, and the
[08](08-camera-fixed.md) gbm path means those frames are real dmabufs rather than copies.

### Suspend/resume passes, and the freeze gap is narrower than it looked

Tested at 15:31 by pressing the power button. The whole cycle:

```
15:31:21  systemd-logind: Power key pressed short.
15:31:22  systemd-sleep: Performing sleep operation 'suspend'...
15:31:22  kernel: PM: suspend entry (s2idle)
15:32:30  kernel: PM: suspend exit
```

Afterwards: `Session: RUNNING`, `Container: RUNNING`, `sys.boot_completed=1`, `cage` and
`waydroid-cage-session` both still the same processes, and the watchdog never fired — no new journal
line at all, because there was nothing abnormal to notice. Android was reported back "almost
immediately" with a responsive UI.

**The key finding is what did *not* happen.** No new `Received transaction: 3` — the last one predates
this session by two hours. The power key is consumed by **logind**, which suspends the host; it never
reaches Android, so Android never asks the host to freeze the container, so
`container_manager.freeze()` never runs and there is nothing to thaw. The container simply suspends
along with the machine, like every other process.

The **lid** was tested separately at 15:36 and behaves identically:

```
15:36:11.71  systemd-logind: Lid closed.
15:36:12.13  kernel: PM: suspend entry (s2idle)
15:38:09.98  systemd-logind: Lid opened.
15:38:10.08  kernel: PM: suspend exit          <-- 92 ms
```

118 seconds asleep, resume in under a tenth of a second, Android back on screen "almost immediately"
and responsive. Again no `transaction 3`, and `cage` plus `waydroid-cage-session` came through as the
same processes — by then ~15 minutes old and spanning two suspends. The wrapper's journal has no entry
for either cycle, which is the correct output: nothing abnormal happened, so the watchdog said nothing.

That re-scopes the gap below. It is **not** "suspend strands the cage kiosk" — the ordinary lid/power
path is clean, because logind consumes both keys and Android is never consulted. It is specifically
Android's *own* display timeout requesting a freeze that has no counterpart thaw, and that path is
still untriggered here.

The sensor hub also survived: `waydroid-sensord` was servicing enable/disable calls from Android 52
seconds after the first resume, and the gyroscope returns live, changing values after the second
(`-179048, -67143, -44762` → `-111905, -44762, -223811` → …). One clean cycle does not disprove
[19](19-sensor-hub-suspend-wedge.md)'s wedge, which is intermittent by nature; the reprobe hook is
installed at `/etc/systemd/system-sleep/ite8350` and remains the safety net.

One loose end, recorded rather than resolved: the **accelerometer** returned bit-identical values
(`x=11 y=-878 z=-468`) across four reads three seconds apart, and the same triple five minutes and a
suspend earlier. On a machine sitting still that is plausible for a filtered HID sensor, and the
gyroscope sharing the same hub is demonstrably live — a hub-level wedge would freeze both. But
docs/19's failure mode *is* "reads keep returning a frozen value", so identical-to-the-digit deserves
a note. The cheap disambiguation is to move the machine and read again, or simply to rotate it and see
whether Android follows.

### Still unknown

The session starts, runs, shows the full UI, takes input, and survives host suspend. What has **not**
been exercised: Android's own display-timeout freeze, long-run stability, and a clean Android
power-off returning to the greeter. The first attempt did exercise that teardown path, but from a
container that had been killed rather than one shutting down on request.

One unexplained observation, recorded rather than diagnosed: cage logged
`[ERROR] [backend/drm/atomic.c:82] connector eDP-1: Atomic commit failed: Device or resource busy`
repeatedly between 15:08:43 and 15:08:51, and then stopped. The boot animation displayed, so it was
not fatal, and the timing overlaps the greeter handing over the DRM device. Not investigated.

## Known gaps

- **An Android-initiated freeze would strand the kiosk** — but the ordinary suspend path does not,
  see above. The power button and lid go through logind and suspend the whole host, which the
  container rides out with no freeze involved. The risk is narrower: if Android's *own* display
  timeout fires transaction 3, the host freezes the container and nothing thaws it, because upstream's
  thaw comes from `maybeLaunchLater` — the user relaunching Waydroid, which under cage there is no way
  to do. `persist.waydroid.suspend` (alongside `mWaydroidSuspendDefault` in the guest framework) is
  unset here and is the obvious knob; still **untested**, and now known to be less urgent than it
  looked.
- **The SIGTERM race is a bias, not a fix.** See above.
- **A wedged session manager cannot be stopped politely**, only worked around — the wrapper tears the
  host side down itself and then SIGKILLs. That leaves Android without its own shutdown on that path,
  which is acceptable only because it is already gone by the time it happens.
- **`graphical-session.target` is not started under cage**, so anything else on the host relying on
  it is inert in this session too. Only Waydroid's own backstop was audited.
- **The anti-bounce guard hides a persistent failure behind a 5 s pause.** If Waydroid is broken, the
  greeter will still be reachable, but the reason is only in the journal
  (`journalctl -t waydroid-cage-session`).

## Packaging: Fedora and rpm-ostree

The host paths are staging, and the installers are written so the eventual RPM is an environment
change and nothing else. Both `artifacts/cage/install.sh` and
`artifacts/graceful-exit/install.sh` honour `DESTDIR`, so each doubles as the spec's `%install`:

```
DESTDIR=%{buildroot} PREFIX=/usr SESSIONDIR=/usr/share/wayland-sessions sh artifacts/cage/install.sh
DESTDIR=%{buildroot} PREFIX=/usr SWAY_CONFD=/usr/share/sway/config.d sh artifacts/graceful-exit/install.sh
```

Which produces, verified by staging into a scratch buildroot:

```
-rwxr-xr-x /usr/bin/waydroid-cage-session
-rwxr-xr-x /usr/bin/waydroid-graceful-exit
-rw-r--r-- /usr/lib/systemd/user/waydroid-graceful-exit.service
lrwxrwxrwx /usr/lib/systemd/user/graphical-session.target.wants/waydroid-graceful-exit.service
-rw-r--r-- /usr/share/wayland-sessions/waydroid-cage.desktop
-rw-r--r-- /usr/share/sway/config.d/95-waydroid-graceful-exit.conf
```

Nothing in `/etc`, nothing in `/var`, nothing in `/usr/local`, and `@BINDIR@` substituted to
`/usr/bin` in every file that embeds a path — the session entry's `Exec=`, the unit's `ExecStop=`,
the sway drop-in's `bindsym`, and **the wrapper's own `GRACEFUL_EXIT=`**. That last one is not
hypothetical: the first cut of `artifacts/cage/install.sh` installed the wrapper raw, and the
deployed copy went out with a literal `@BINDIR@` in it. It failed quietly, the way this kind of
thing does — `[ -x "$GRACEFUL_EXIT" ]` is simply false, so the logout path would have logged
"missing; Android will be killed, not shut down" and done exactly that. It was caught by
checksumming the installed files against the sources rather than by reading the installer, which is
why that check is worth running after every deploy. Both installers now pass every file through the
substitution.

The host facts that dictate that layout, all checked here:

| fact | consequence |
|---|---|
| `/usr/local` is a symlink to `../var/usrlocal` | an RPM must never own anything under it — which is exactly what makes it the right place for the *manual* install on an immutable host, and the wrong place for a package. Hence `$PREFIX` |
| `/usr/share/wayland-sessions` is owned by `filesystem-3.18-52.fc44` | the package installs into it without owning the directory |
| SDDM's compiled-in `SessionDir` already includes `/usr/share/wayland-sessions` | the `/etc/sddm.conf.d/wayland-paths.conf` drop-in this host uses is a local convenience, **not** a packaging dependency. The `/etc/wayland-sessions` default here exists only because that drop-in adds it |
| `/usr/lib/systemd/user` is in the user unit search path | the `graphical-session.target.wants` symlink can ship as a packaged file, enabling the unit for every user with **no scriptlet** and nothing written to any home directory |
| `/usr/share/sway/config.d` is owned by `sway-config-fedora` | only relevant to [24](24-graceful-logout.md)'s sway hook; a package shipping there must `Requires: sway-config-fedora` rather than own the directory. The cage session ships no sway content at all |
| this host's `~/.config/sway/config` includes only `/etc/sway/config.d` and `~/.config/sway/config.d` | the packaged `/usr/share` drop-in installs correctly and is then **silently inert** here, because the three-path include line is commented out in favour of a two-path one. Not a packaging bug — the stock `/etc/sway/config` does include `/usr/share` — but it means "the RPM installed" is not the same as "the exit chord is live". See [24](24-graceful-logout.md) |

And the rpm-ostree rules that shaped the installers:

- **No package content under `/var`.** Satisfied by `PREFIX=/usr`; the `/usr/local` default would violate
  it, which is the whole reason the substitution exists.
- **No filesystem-mutating scriptlets.** SELinux labels come from the compose, not from a `%post`, so
  `restorecon` is skipped whenever `DESTDIR` is set. The manual install still runs it, because there it
  is correct — labels came out `bin_t` for the scripts and `etc_t` for the session entry, no denials.
- **`%install` must stage into a buildroot**, which is what the `DESTDIR` support is for. Both
  installers also suppress their "installed, now do X" epilogue when staging.
- **Unit enablement without a scriptlet**, via the packaged `.wants` symlink rather than
  `%systemd_user_post`.

Runtime dependencies are `waydroid`, `cage`, `systemd` (for `busctl`), `coreutils` and `gawk`;
`logger` (util-linux) is used if present and skipped if not. Nothing needs `android-tools`.

**Not yet done:** no spec file is written, and none of this has been built as an RPM — the layout is
verified, the packaging is not.

## Files

| where | what |
|---|---|
| `@BINDIR@/waydroid-cage-session` | the wrapper: entry check, watchdog, exit paths |
| `/etc/wayland-sessions/waydroid-cage.desktop` | the SDDM session entry, `cage -s -- …` |
| `@BINDIR@/waydroid-graceful-exit` | gains `--keep-session`; otherwise unchanged from [24](24-graceful-logout.md) |

Sources in [artifacts/cage/](../artifacts/cage); install with `sudo sh install.sh`. No image changes,
no overlay files, no layered packages, no reboot. **To undo:** delete the wrapper and restore the
original one-line `Exec=` in the desktop file.

## Verifying

```bash
# the pieces are in place
ls -l /usr/local/bin/waydroid-cage-session
grep Exec /etc/wayland-sessions/waydroid-cage.desktop
/usr/local/bin/waydroid-graceful-exit --help | grep keep-session

# what the watchdog sees, live
busctl --system call id.waydro.Container /ContainerManager \
    id.waydro.ContainerManager GetSession

# after a session, the whole story is in the journal
journalctl -t waydroid-cage-session -t waydroid-graceful-exit -b
```

`Android is up` … `Android has shut down; releasing the session` … `session ended after Ns` is the
intended path. `clearing a stale Waydroid session from an earlier login` at the *start* of a session
means the previous logout did not finish — the reason will be in the previous boot's journal.
