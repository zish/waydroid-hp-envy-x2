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
exists precisely to signal those processes so init can reap them, it was running, and its
signalling **worked** — init reaped what it signalled. It still lost, for the reason its own design
notes predicted: `netd.rc` carries `onrestart restart zygote` and zygote's rc carries
`onrestart restart netd`, so repairing one re-wedged the other. A brand-new zygote was back in
`STOPPING` **1.9 s** after its predecessor was reaped, 1.1 s after `netd` was killed. The circuit
breaker then fired at eight kills in 300 s, and **that was not obviously a false positive** — it is
what a non-converging repair looks like. The problem is what it does next: stand down for 3600 s and
leave the machine wedged with `zygote` among the still-stuck, which is the only name on that list
whose wedge is fatal. Every newly forked `system_server` then died with
`SecurityException: Unable to find app for caller`, 212 times, until a container restart — the one
repair that does work, because it does not depend on cgroups the container never created.

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

## Why it lost, and why "raise the budget" is the wrong first instinct

**Corrected after first writing this document.** The reading here was initially that the breaker
fired on mere *breadth* — one wide cascade mistaken for a loop — and that the budget was simply set
too low. The log does not support that, and the detail that settles it is which signal the second
`zygote` kill used.

Escalation in [waydroid-restartd](../artifacts/restartd/waydroid-restartd) is
`escalate = name in signalled`, and `signalled.discard(name)` runs as soon as a service leaves the
stuck set. The second `zygote` kill was logged as **SIGTERM, not SIGKILL** — so `zygote` had left
the stuck set in between. Pid 73 **was genuinely reaped**: the signalling worked, init restarted
zygote as pid 4296, and *that* new zygote was already back in `STOPPING` 1.9 seconds later.

Which is precisely this, from the daemon's own design notes:

> `init.rc` has mutual onrestart edges: zygote's rc carries `onrestart restart netd`, and netd's rc
> carries `onrestart restart zygote`. […] kill netd, wait 25 s, kill the zygote that netd's
> onrestart wedged, and by then netd is RUNNING again, so zygote's onrestart wedges netd, and the
> two ping-pong forever.

`netd` was killed at 15:44:50.38 and the new zygote was stuck by 15:44:51.53 — 1.1 s apart. The
breaker caught a repair that was **not converging**, which is what it exists for. The author's note
that "the cycle is broken by being FAST" is why cascade mode polls at 0.20 s; here fast was not
enough.

So the honest position is narrower than first written:

- **It is unknown whether a larger budget would have converged.** Three services were still stuck
  when it stopped (`vendor.audio-hal`, `zygote`, `zygote_secondary`), and nothing in the log says
  whether the next ten kills would have settled or ping-ponged indefinitely.
- **Raising `WAYDROID_RESTARTD_MAX_KILLS` is therefore a gamble, not a fix.** It may buy a longer
  kill storm, which is the outcome the author called "a brick".
- **The breadth observation still stands and still matters**: one zygote restart puts eight names
  into `STOPPING` at once, so the budget is spent in seconds and the breaker's decision rests on
  about two seconds of evidence. That is a real weakness — not because the decision was wrong, but
  because it is made too early to be informative, and because `zygote` being last in the ordering
  meant the budget went on services whose wedge is survivable.

**What is unambiguous is what happens after the breaker fires.** Standing down for 3600 s is right
for a kill storm and wrong for a wedged boot, and the daemon has no way to know the machine is now
unusable. The repair that reliably works was never attempted, because it is not something this
daemon does: a container restart.

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
| container PID counter past 65535 | `ns_last_pid` nowhere near it — see below |

The discriminator that is quick and decisive: `init.svc.<name>` for a handful of services.
`stopping` on several at once is docs/48/61; a Watchdog line every 60 s is docs/51.

## Is this the 32-bit PID cliff? No — but the two can compound

Asked directly, and worth answering in the document because anyone with this symptom will ask it.
[docs/51](51-pid-namespace-32bit-cliff.md) is a real fault with the same visible symptom, and this
is not it. But they are related more closely than "two things that both end at a boot loop", and one
of those relationships is a hazard.

**They are opposite failures of the same lifecycle.** docs/51 is a process that cannot *start* — a
newly forked 32-bit process whose tid exceeds 65535 is aborted by bionic at birth. This document is a
process that cannot be *killed* — `KillProcessGroup()` signals nobody, so init parks the service in
`STOPPING`. Android's service management needs both halves to work, and on this host each one is
broken by a different cause.

**They share a red herring**, which is why docs/51 is where a misdiagnosis lands: the
`DisplayModeDirector` / `getRefreshRateInHbmHdr` `FATAL EXCEPTION`. In docs/51 it is one crash from
the start of the episode with Watchdog doing the real killing; here it is the repeating crash itself.
Same stack, opposite role.

**And a crash loop burns PIDs toward the cliff an order of magnitude faster than normal use**, so
left alone long enough this fault grows the other one on top of itself. Measured on this host:

| | PIDs/min |
|---|---|
| idle (AGENTS.md) | 14.1 |
| real use (AGENTS.md) | ~56 |
| three hours of normal use after recovery — `ns_last_pid` 13586 | ~75 |
| **during the crash loop** — a fresh `system_server` every ~5 s | **~500 (estimated)** |

The loop figure is an estimate from one observation rather than a measurement, but the order of
magnitude is the point: at that rate the namespace counter covers 65536 in roughly two hours. **The
reason that did not turn into docs/51 as well is `pidguard`**, which caps the container's `pid_max`
at 65536 — confirmed in the container — so the counter *wraps* instead of climbing past 65535 and
the cliff is unreachable. Without that cap, a loop left overnight would have started killing 32-bit
processes at birth too, and the resulting diagnosis would have been genuinely ambiguous.

So `pidguard` earned its keep here without being implicated in the fault. The one-line check for the
cliff remains `cat /proc/sys/kernel/ns_last_pid` inside the container, not the highest running PID —
already-running processes keep their low PIDs, as AGENTS.md says.

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

Reordered after the correction above. **None of these are implemented.**

1. **Escalate to a container restart instead of standing down.** When the breaker trips *and* the
   still-stuck set contains `zygote` or `zygote_secondary`, the machine is not going to finish
   booting and no amount of signalling from inside will change that. A container restart is the
   repair that works — 24.8 s here — and the host can always do it, because it does not depend on
   the cgroups the container never created. This addresses what actually went wrong rather than
   guessing at a budget. It needs a guard of its own so it cannot loop: at most one restart per
   boot, then log and stop.
2. **A host-side boot watchdog** — the same idea with a simpler trigger and no knowledge of
   restartd's internals: if `sys.boot_completed` is still unset after a few minutes and
   `bootanimation` is still running, restart the container once. Catches wedges this document has
   not thought of, and is in the same spirit as `pidguard` and `waydroid-wifi-nudge`.
3. **Repair `zygote` and `zygote_secondary` first** within a cascade. Cheap, clearly right, and
   independent of the budget question: if the repair is going to be stopped early, the budget
   should go on the service whose wedge is fatal rather than on `cameraserver` and `media`.
4. **Make the kill work at all — goal 7.** Waydroid's LXC config carries
   `lxc.mount.auto = cgroup:ro sys:ro proc`; with a writable `/sys/fs/cgroup`,
   `KillProcessGroup()` would signal real processes, nothing would park in `STOPPING`, the mutual
   `onrestart` edges would resolve the way they do on a real device, and `waydroid-restartd` would
   have no reason to exist. The only entry that removes the cause. Beware that Waydroid
   **regenerates** its LXC config (see [docs/user/lxc-config.md](user/lxc-config.md)), so it needs
   a durable mechanism rather than an edit.

**Deliberately not recommended: raising `WAYDROID_RESTARTD_MAX_KILLS`.** The knob exists and is a
one-line drop-in, which makes it the tempting first move. But per the section above, the breaker
fired on a repair that was demonstrably re-wedging itself, so a larger budget may simply buy a
longer storm. Anyone trying it should measure whether the stuck set *shrinks* between cascades —
that is the only evidence convergence was ever possible.

**Reproducing this on purpose** is possible, and is how any of the above should be tested:
`waydroid shell -- setprop ctl.restart zygote` fires exactly the cascade that started this. It will
wedge the machine, so it wants a session nobody depends on and someone at the keyboard.

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
