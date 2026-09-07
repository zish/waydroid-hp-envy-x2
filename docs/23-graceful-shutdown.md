# Shutting Android down gracefully when the host goes down

Built 2026-09-07, on request. Not part of goals 1–4; it came up on its own.

Until now, every way of stopping Waydroid killed Android outright. This adds the missing trigger so
Android runs its own shutdown sequence first — apps get `ACTION_SHUTDOWN`, PackageManager and the
settings providers flush, `sync()` happens — and then the container stops on its own.

## What was wrong

Every path that stops Waydroid converges on one line. `container_manager.stop()` calls
`helpers.lxc.stop()`, which is:

```python
def stop(args):
    command = ["lxc-stop", "-P", tools.config.defaults["lxc"], "-n", "waydroid", "-k"]
```

`-k` is *kill*: SIGKILL to every process in the container, immediately. Android is never told it is
going away. That is what happened on every host reboot.

At host shutdown it is worse than it looks. Android's processes are not in the service's cgroup —
`lxc-start` puts them in a top-level `lxc.payload.waydroid`, and the monitor in
`lxc.monitor.waydroid`:

```
$ cat /proc/219645/cgroup     # android.hardware.graphics.composer
0::/lxc.payload.waydroid
$ cat /proc/212923/cgroup     # waydroid container start
0::/system.slice/waydroid-container.service
```

So systemd's SIGTERM at shutdown never reaches Android at all. It reaches the container manager,
whose handler performs that same hard kill.

## What already existed

Waydroid handles Android shutting *itself* down. The guest asks the host over the hardware binder
(`IHardware` transaction 7), and `services/hardware_manager.py` does the host half:

```python
def shutdownRequest(reason):
    is_reboot = reason and reason.startswith("1")
    while helpers.lxc.status(args) != "STOPPED":
        ... give up after 30 tries ...
    if is_reboot:
        helpers.lxc.start(args)
    else:
        tools.actions.container_manager.stop(args)
```

So the machinery was all there. The only missing piece was a trigger from the outside.

## The trigger

`svc power shutdown` — `PowerManager.shutdown()`, the same call the power menu makes. It is present
in this image and works under `waydroid shell`:

```
$ sudo waydroid shell -- svc power
       svc power shutdown
         Perform a runtime shutdown and power off the device.
```

Run against a live session it did the whole thing, captured over `logcat`:

```
11:28:13.905 D/ShutdownThread: Notifying thread to start shutdown longPressBehavior=1
11:28:13.905 D/ShutdownThread: Attempting to use SysUI shutdown UI
11:28:13.909 I/ShutdownThread: Sending shutdown broadcast...
11:28:13.911 W/SyncManager: Writing sync state before shutdown...
11:28:13.975 I/ShutdownThread: Shutting down activity manager...
11:28:13.979 W/AppOps  : Writing app ops before shutdown...
11:28:14.095 W/BatteryStats: Writing battery stats before shutdown...
11:28:14.126 W/ProcessStatsService: Writing process stats before shutdown...
11:28:14.139 I/ShutdownThread: Shutting down package manager...
11:28:14.201 I/ShutdownThread: Radio shutdown complete.
11:28:14.703 I/ShutdownThread: Performing low-level shutdown...
```

**Note the timestamps.** The whole framework half — every flush that matters — takes **0.8 s**. The
container reached `STOPPED` 6.2 s after the trigger; the remaining ~5 s is init tearing the
container down, which needs nothing from the host. That timing is what the design below rests on.

`waydroid shell` is used rather than `lxc-attach` directly. `svc` is an `app_process` wrapper and
needs the full Android environment including the `CLASSPATH` Android generated at boot; a
hand-built `lxc-attach --set-var` environment was tried first and `svc` **failed silently**, which
is exactly the sort of shutdown command that looks installed and does nothing.

The fallback is `setprop sys.powerctl shutdown` — init's own path. It SIGTERMs every service,
`sync()`s and unmounts. Less than the framework path, far more than SIGKILL.

## Where it is hooked

Two hooks, because there are two ways the host stops Waydroid, and only one of them is systemd's.

### 1. A logind delay inhibitor — the one that matters for reboot

`waydroid-shutdown-inhibitor.service` holds a `shutdown`/`delay` lock and runs the shutdown script
when logind emits `PrepareForShutdown(true)`.

This is not decoration over `ExecStop=`. Android's shutdown needs two things the host owns: the
user's Wayland session (the composer HAL, and `ShutdownThread`'s SysUI step) and Waydroid's
hardware binder service. At host shutdown, the units holding those have **no ordering** relative to
`waydroid-container.service`:

```
$ systemctl show session-610.scope -p Before -p After
Before=
After=
```

Both merely `Conflicts=shutdown.target`, so systemd stops them in parallel and whichever wins is
luck. An inhibitor does not race: logind emits the signal and waits **before starting the
transaction**, so nothing has been stopped yet and the whole machine is still up.

The lock does not need to cover the whole shutdown — only the 0.8 s framework half. If
`InhibitDelayMaxSec` (5 s by default, unchanged here) expires first, logind proceeds and hook 2
waits for the remainder.

### 2. `ExecStop=` on `waydroid-container.service`

A drop-in adds `ExecStop=/usr/local/bin/waydroid-shutdown-android` and raises `TimeoutStopSec` to
60 s. It runs before systemd's SIGTERM reaches the container manager, so it covers `systemctl stop
waydroid-container`, shutdowns that bypass logind (`systemctl poweroff --force`), and finishing off
a shutdown the inhibitor started.

The timeout is not cosmetic: Fedora ships `TimeoutStopFailureMode=abort` for every service, so
overrunning the default 45 s would SIGABRT the container manager and dump core.

## Ruled out: an `lxc-stop` shim

The obvious way to catch *every* stop path, including the ones a user session drives (logout,
`waydroid session stop`), is to shim `lxc-stop` — it is the single choke point, and the container
manager runs it in its own process, so a `PATH` override on that one unit shadows nothing
system-wide. It was built, deployed and measured, and it **does not work**:

```
11:32:23  Stopping container
11:32:23  % lxc-stop -P /var/lib/waydroid/lxc -n waydroid -k
11:32:23  waydroid-shutdown-android: asking Android to shut down (svc power shutdown)
11:32:43  waydroid-shutdown-android: no shutdown after 20s; falling back to init (sys.powerctl)
11:32:53  waydroid-shutdown-android: still running after 30s; leaving it to the caller's hard stop
```

`waydroid session stop` went from instant to 25 s and still ended in SIGKILL. The reason is the
order inside Waydroid:

```python
def Stop(self):                       # session_manager
    do_stop(self.args, self.looper)   # session torn down FIRST
    stop_container(quit_session=False)

def stop(args, quit_session=True):    # container_manager
    services.hardware_manager.stop(args)   # hardware binder service gone
    ...
    helpers.lxc.stop(args)                 # only now does the shim get a turn
```

By the time `lxc-stop` runs, both things Android's shutdown depends on are already gone. Making the
session path graceful would mean triggering before `do_stop()`, which is inside
`/usr/lib/waydroid` — read-only on this host, and not worth an overlay for. **The shim was removed.**

That conclusion was right about the shim and wrong about the conclusion drawn from it. Triggering
before `do_stop()` does not require patching `/usr/lib/waydroid` — it requires triggering before
Waydroid is involved at all, which is what [24](24-graceful-logout.md) does from the compositor's
exit binding.

It did turn up one real bug worth recording. If Android has already exited, `lxc-stop` exits
non-zero, and `container_manager.stop()` runs it with `check=True` inside a `try` that wraps *the
rest of the teardown* — so a non-zero exit there silently skips unmounting the rootfs and tearing
down the bridge. It does not bite in practice, because `stop()` checks `status != "STOPPED"` first,
but the window exists.

## What the reboot actually showed

Verified on a real `systemctl reboot` with a live session, Android **frozen** at the time (the
normal idle state here — `suspend_action = freeze`). Both journals merged:

```
11:48:48  logind: The system will reboot now!
11:48:48  inhibitor: host is shutting down, handing over to waydroid-shutdown-android
11:48:48  shutdown-android: container is frozen, thawing it first
11:48:48  shutdown-android: asking Android to shut down (svc power shutdown)
11:48:53  logind: Delay lock is active (PID 274911/waydroid-shutdo) but inhibitor timeout is reached.
11:48:53  logind: System is rebooting.
11:48:54  systemd: Stopping session-2.scope - Session 2 of User jmelanso...     <-- the session dies HERE
11:48:54  systemd: Stopping waydroid-container.service ...
11:48:54  shutdown-android: asking Android to shut down (svc power shutdown)    <-- ExecStop takes over
11:48:55  shutdown-android: Android shut down cleanly
```

Read the fifth and seventh lines together. **The user's session scope was not stopped until 11:48:54
— five seconds after Android's shutdown began.** That is the whole point of the inhibitor, and it is
also the proof that the race was real: without the lock, `session-2.scope` and
`waydroid-container.service` stop in the same unordered batch, and Android's shutdown would have had
no protected window at all.

The handoff between the two hooks also worked as designed. logind gave up on the delay lock at 5 s
(`inhibitor timeout is reached`) while the script was still waiting for the container; systemd then
stopped the inhibitor's unit, killing that wait; and `ExecStop` picked it up one second later and
saw it through. Seven seconds from trigger to container stopped, from a frozen start.

## Known gaps

- **Logout is now covered — see [24](24-graceful-logout.md).** It triggers from in front of the
  sequence rather than behind it (the sway exit chord), which is the position the shim below could
  not reach, and it does the whole thing unprivileged. `waydroid session stop` invoked directly
  still hard-kills Android; that one remains not fixable from outside `/usr/lib/waydroid`.
- **`InhibitDelayMaxSec` is 5 s, and the reboot above did hit it.** Left alone on purpose. The
  window only has to cover the framework half, which takes 0.8 s — a 5× margin — and the measured
  reboot shows the session surviving the full five seconds while `ExecStop` finished the rest. The
  ceiling is *shared with sleep inhibitors*, and this machine's suspend path is carefully tuned
  ([docs/17](17-hybrid-sleep.md)), so raising it to buy a margin that is already 5× would trade a
  real cost for a theoretical gain. If a future shutdown ever *does* run long enough that the
  session dies mid-flush, the knob is `/etc/systemd/logind.conf.d/`, and ~20 s would let the whole
  shutdown finish inside the lock.
- **Shutdown now takes about 5 s longer when Android is running** — the lock is held until logind's
  timeout. When Waydroid is not running the script exits immediately and costs nothing.
- **`lxc.hook.post-stop = /dev/null`** makes LXC log `Script exited with status 126` and `Failed to
  run lxc.hook.post-stop` on every stop. Pre-existing, cosmetic, present in `waydroid.log` long
  before this work — not a symptom of anything here.

## Files

| where | what |
|---|---|
| `/usr/local/bin/waydroid-shutdown-android` | the shutdown itself: framework, then init, then give up. Always exits 0 |
| `/usr/local/bin/waydroid-shutdown-inhibitor` | holds the logind delay lock, runs the above on `PrepareForShutdown` |
| `/etc/systemd/system/waydroid-shutdown-inhibitor.service` | runs it, `WantedBy=multi-user.target` |
| `/etc/systemd/system/waydroid-container.service.d/graceful-shutdown.conf` | `ExecStop=` + `TimeoutStopSec=60` |

Sources in [artifacts/shutdown/](../artifacts/shutdown). No image changes, no overlay files, no
layered packages, no reboot to install.

**To undo:** `systemctl disable --now waydroid-shutdown-inhibitor`, delete the drop-in. Stock
behaviour returns exactly.

## Verifying

```bash
# the lock is armed
systemd-inhibit --list | grep Waydroid
#  Waydroid  0  root  ...  shutdown  Letting Android shut itself down  delay

# exercise it without rebooting
sudo systemctl stop waydroid-container.service
sudo journalctl -u waydroid-container.service -n 20
```

which should read:

```
Stopping waydroid-container.service - Waydroid Container...
waydroid-shutdown-android: asking Android to shut down (svc power shutdown)
waydroid-shutdown-android: Android shut down cleanly
waydroid[212923]: [11:30:54] Stopping container
waydroid-container.service: Deactivated successfully.
```

After a real reboot, the evidence is in the previous boot:

```bash
journalctl -b -1 -u waydroid-shutdown-inhibitor.service
```

`asking Android to shut down` followed by `Android shut down cleanly` means it worked. `still
running after 30s` means it did not, and the next thing to look at is whether the session died
first.

## Measured

| path | result |
|---|---|
| script by hand, session live | **6.2 s**, framework path, container `STOPPED` |
| `systemctl stop waydroid-container` | **6.5 s** total; rootfs unmounted, bridge gone, session ended |
| via the `lxc-stop` shim (removed) | 25 s, both paths timed out, ended in SIGKILL |
| **`systemctl reboot`, session live, container frozen** | **7 s**, thawed then shut down cleanly; session outlived the flush by 5 s |

No SELinux denials on any path (`ausearch -m avc`); the scripts label as `bin_t` under
`/usr/local/bin` and `waydroid shell` transitions to `waydroid_t` as it does for `ExecStart`.
