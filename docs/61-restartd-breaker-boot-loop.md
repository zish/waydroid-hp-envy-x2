# 61 — A boot loop the mitigation was built for, and the circuit breaker that stood down 11 seconds before it started

*2026-10-01. A cold boot wedged on the LineageOS animation for an hour.
[docs/48](48-battery-frozen-and-netd-stale.md)'s mechanism, [docs/48](48-battery-frozen-and-netd-stale.md)'s
mitigation installed and running, and it still happened — because **one legitimate repair cascade
costs more kills than the circuit breaker's entire budget**. Seven kills in 2.6 seconds, breaker
fires at the eighth, stands down for 3600 s, and `system_server` begins crash-looping 11 seconds
later. It crashed 212 times. Nothing else was wrong with the machine.*

## One-paragraph summary

The visible fault is the boot animation spinning forever, which is the same symptom as
[docs/51](51-pid-namespace-32bit-cliff.md) and has a different cause — and the stack trace that
looks like the explanation is the same red herring docs/51 already warned about. The real chain is
[docs/48](48-battery-frozen-and-netd-stale.md): Waydroid's LXC config mounts the container's
`/sys/fs/cgroup` read-only, so `libprocessgroup` never created the per-process cgroups, so init's
`KillProcessGroup()` signals nobody and services park in `STOPPING` forever. `waydroid-restartd`
exists precisely to signal those processes so init can reap them, it was running, and it did its
job — for seven services. Then its circuit breaker tripped, because the breaker's budget is **8
kills in 300 s** and a single zygote restart wedges **eight services at once**: init.rc's
`onrestart restart` lines all fire together. The breaker was designed to stop a ping-pong *loop*
and cannot tell one from a wide *cascade*, so it stood down with `zygote` still wedged — the one
service whose wedge is fatal — and every newly forked `system_server` then died with
`SecurityException: Unable to find app for caller`. On this host that breaker will fire on the
first cascade essentially every time, which makes the mitigation reliably absent exactly when it is
needed.

## The timeline, to the millisecond

```
15:42:48.26  waydroid-restartd started
15:42:48.56  watching for init services stuck in STOPPING (idle 10.0s, cascade 10.0s
                                                           at 0.20s, breaker 8/300s)
15:44:18.97  sent SIGTERM to idmap2d (pid 113)              <- kill 1
15:44:49.66  sent SIGTERM to zygote (pid 73)                <- kill 2
15:44:50.09  sent SIGTERM to audioserver (pid 89)            <- kill 3
15:44:50.18  sent SIGTERM to cameraserver (pid 112)          <- kill 4
15:44:50.33  sent SIGTERM to media (pid 118)                 <- kill 5
15:44:50.33  mediadrm is STOPPING but has no
             init.svc_debug_pid.mediadrm property; leaving it alone
15:44:50.38  sent SIGTERM to netd (pid 72)                   <- kill 6
15:44:51.46  sent SIGTERM to vendor.audio-hal (pid 76)       <- kill 7
15:44:51.53  sent SIGTERM to zygote (pid 4296)               <- kill 8
15:44:51.53  CIRCUIT BREAKER: 8 kills in 300s -- this looks like a restart loop,
             not a repair. Standing down for 3600s.
             Still stuck: vendor.audio-hal, zygote, zygote_secondary
15:45:02.83  *** FATAL EXCEPTION IN SYSTEM PROCESS: android.display   <- 11 s later
...          212 more, one every ~5 s, for an hour
16:45:01.87  sent SIGTERM to idmap2d (pid 113)    <- cooldown expires, resumes
```

**Seven of the eight kills land inside 1.9 seconds.** The breaker's window is 300 seconds. It was
never going to survive this.

## Why the budget is wrong, and it is the budget rather than the idea

The breaker's own rationale, from
[artifacts/restartd/waydroid-restartd](../artifacts/restartd/waydroid-restartd), is sound and worth
keeping:

> `init.rc` has mutual onrestart edges: zygote's rc carries `onrestart restart netd`, and netd's rc
> carries `onrestart restart zygote`. […] kill netd, wait 25 s, kill the zygote that netd's
> onrestart wedged, and by then netd is RUNNING again, so zygote's onrestart wedges netd, and the
> two ping-pong forever. […] A few extra restarts is a bad afternoon; an unbounded loop is a brick.

The hazard it guards against is **repetition over time** — the same two services killing each other
round after round. What actually happened is **breadth at one instant**: one zygote restart firing
`onrestart restart` on everything that depends on it. The breaker counts total kills, so it cannot
distinguish the two, and on this image a single cascade is:

```
idmap2d  zygote  audioserver  cameraserver  media  netd  vendor.audio-hal  zygote_secondary
```

which is eight names before anything has gone wrong at all. docs/48 said this list already —
"it silently wedges `audioserver`, `cameraserver`, `media`, `idmap2d` and `mediadrm` too" — so the
breadth was known and the budget was set below it anyway.

**Ordering made it worse.** The budget ran out with `zygote` and `zygote_secondary` still stuck,
which is the only part of that list that is fatal: `netd` wedged costs Wi-Fi routing (docs/48),
`audioserver` wedged costs audio, but `zygote` wedged costs **every subsequent `system_server`**.
`zygote` was signalled twice and reaped neither time; the budget was spent on services whose wedge
is survivable.

## The two red herrings, one of which this project had already written down

**Red herring 1 — the crash that looks like the cause.** `logcat -b crash` has 212 copies of:

```
E AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS: android.display
java.lang.SecurityException: Unable to find app for caller
    android.app.IApplicationThread$Stub$Proxy@3b18c88 (pid=4565)
    when getting content provider settings
  at com.android.server.display.DisplayModeDirector$DeviceConfigDisplaySettings
       .getRefreshRateInHbmHdr(DisplayModeDirector.java:2854)
  at com.android.server.display.DisplayManagerService
       .handleLogicalDisplayAddedLocked(DisplayManagerService.java:1541)
```

[docs/51](51-pid-namespace-32bit-cliff.md) flags this **exact** stack as a red herring, and it was
right to. It is a *consequence*: a freshly forked `system_server` cannot find its own app record in
an AMS whose previous instance never died, and the display thread is simply the first thread to ask
AMS a question. It was mistaken for the live cause during this session before docs/51 corrected it.

**Red herring 2 — assuming it is docs/51.** The symptom is identical to docs/51's PID cliff, and it
is not that. Three checks separate them, and all three say no:

| docs/51's signature | this incident |
|---|---|
| `Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS` every 60 s | **no Watchdog kills at all** |
| 32-bit audio HAL dead, `audioserver` never registers | `audioserver` and `android.hardware.audio.service` **alive**, 17 min old |
| container PID counter past 65535 | highest container PID **14963** |

The discriminator that is quick and decisive: `init.svc.<name>` for a handful of services.
`stopping` on several at once is docs/48/61; a Watchdog line every 60 s is docs/51.

## How to recognise this one

```bash
# the tell: several services parked, and zygote among them
waydroid shell -- sh -c 'getprop | grep "init.svc\." | grep stopping'

# two system_servers, one of them stale, is conclusive
waydroid shell -- sh -c 'ps -A -o PID,ETIME,NAME | grep system_server'

# and the mitigation saying it gave up
journalctl -u waydroid-restartd -b | grep "CIRCUIT BREAKER"
```

A stale `system_server` whose age exceeds the newest one's, plus a `CIRCUIT BREAKER` line, is this
document and nothing else.

## Recovery

A **container restart**, which is the same recovery as docs/48 and docs/51 and for the same reason —
it is the only thing that tears the namespace down from the host, where the kill does not depend on
cgroups the container never created:

```bash
sudo systemctl restart waydroid-container
```

Took 24.8 s here. It ends the cage session, so SDDM returns to the greeter and the kiosk needs a
login — there is no autologin on this host. Afterwards: `sys.boot_completed` 1, `bootanimation`
gone, exactly one `system_server`, zero fatal crashes.

**`waydroid-wifid` survives this by design** and needed no intervention, which is the Stage 5
presence-handler behaviour working:

```
Service manager /dev/binderfs/binder has died
Service manager /dev/binderfs/binder has appeared
Service manager reappeared, re-registering
```

## Verifying a boot, properly

This incident produced a wrong "it booted fine" call mid-session, and the lesson generalises:
**`Session: RUNNING` / `Container: RUNNING` and a responsive `cmd wifi status` do not mean Android
booted.** Each of the 212 crashing instances lived long enough to answer `cmd wifi`. The checks that
actually mean it:

```bash
waydroid shell -- sh -c 'getprop sys.boot_completed'        # must be 1
waydroid shell -- sh -c 'getprop init.svc.bootanim'         # must be stopped
waydroid shell -- sh -c 'ps -A -o NAME | grep -c bootanimation'   # must be 0
waydroid shell -- sh -c 'logcat -b crash -d | grep -c "FATAL EXCEPTION IN SYSTEM PROCESS"'
```

Note that `waydroid shell` appends a `Use '--details-to-stdout'` banner to **stdout**, so an exact
string comparison against `1` silently never matches. Pipe through `head -1` and strip, or compare
with a prefix test. A poll written the naive way reported "boot did not complete" for six minutes
against a machine that had booted.

## Can this be prevented?

Four things, from cheapest to most correct. **None of them are implemented as of this document.**

1. **Raise the breaker budget.** The knob already exists —
   `WAYDROID_RESTARTD_MAX_KILLS`, default 8 — so a systemd drop-in setting it to around 24 (three
   cascades) needs no code. Cheapest, and it weakens the loop protection by exactly the amount it
   raises the budget.
2. **Count cascades, not kills.** The right shape, because it matches the hazard the breaker was
   written for: kills inside one `cascade_window` are one *event*, and the budget applies to events.
   Eight separate cascades really is a ping-pong loop; one cascade of eight is a repair. Keeps the
   protection and removes the false positive.
3. **Repair `zygote` and `zygote_secondary` first** within a cascade. If the budget is going to run
   out, it should run out on services whose wedge is survivable. Today it ran out with zygote stuck.
4. **Make the kill work at all — goal 7.** Waydroid's LXC config carries
   `lxc.mount.auto = cgroup:ro sys:ro proc`; with a writable `/sys/fs/cgroup` `KillProcessGroup()`
   would signal real processes, nothing would park in `STOPPING`, and `waydroid-restartd` would have
   no reason to exist. This is the root fix and it is goal 7's existing scope. Beware that Waydroid
   **regenerates** its LXC config (see [docs/user/lxc-config.md](user/lxc-config.md)), so any change
   there needs a durable mechanism rather than an edit.

A fifth, orthogonal to all of the above: **a host-side boot watchdog** that restarts the container
when `sys.boot_completed` is still unset after a few minutes and `bootanimation` is still running.
It would not prevent the wedge, but it would turn an hour of a spinning logo into one automatic
recovery, in the same spirit as `pidguard` and `waydroid-wifi-nudge`.

## Residuals on bigtab01 after this incident

- `init.svc.idmap2d` read `stopping` again after recovery; `waydroid-restartd` signalled it at
  16:45:01 once its cooldown expired. Non-fatal — boot completed with it stuck.
- `RescueParty` logs `Disabled because of manual property`, so Android's own escalation path is off
  and cannot break a loop like this. Whether that property is ours, LineageOS's or Waydroid's was
  not established.
- `waydroid-restartd` reports `is-enabled: disabled` while being `active`, because its enable
  symlink ships inside `/usr/lib/systemd/system/multi-user.target.wants/` rather than being created
  by `systemctl enable` — deliberate, per `artifacts/restartd/install.sh`, so that the RPM needs no
  `%post` on an ostree host. Confusing to read, working as intended.
