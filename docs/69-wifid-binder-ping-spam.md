# The binder ping spam is waydroid-wifid waiting for a login

Observed 2026-10-16. `waydroid-ext-wifid` 1.1.1 fixes **75.4%** of it, measured — the boot-until-
first-login case. What is left is the same poll restarting after a *logout*: 19.5% from this
daemon, where the timer lives inside libgbinder rather than in our code and closing it needs a
design decision rather than a patch, and 5.1% from `waydroid-sensord`, which has the same bug on
`/dev/hwbinder`. All three are measured below; start at
[1.1.1 fixes three quarters of this](#111-fixes-three-quarters-of-this-and-the-rest-is-the-logout-path)
for what is left.

> The 1.1.1-2 package carries an earlier copy of this file, which lists the logout path as
> unverified. It was, at build time. It is not any more.

[03-binder-ping-spam.md](03-binder-ping-spam.md) decodes the same two kernel lines and is still
correct about what they mean. It pins them on a different cause — two stuck waydroid python
waiters after Android was shut down from inside the session — and that cause was real and was
cleared. This is a second, much larger source of the same message, and unlike the first one it is
not a stuck state at all: it is the normal, designed behaviour of our own daemon on a tablet that
nobody has logged into yet.

## Symptom

Two kernel lines per second, forever, whenever the host is up and Waydroid has no session:

```
binder: 1066:1066 cannot find target node
binder: 1066:1066 transaction call to 0:0 failed 253/29189/-22, code 1599098439 size 0-0 line 3253
```

| Field | Value | Meaning |
|---|---|---|
| `0:0` | target pid 0, handle 0 | binder **handle 0** — the context manager, Android's `servicemanager` |
| `code 1599098439` | `0x5F504E47` = `_PNG` | `IBinder::PING_TRANSACTION` — a liveness ping, not real work |
| `253` | — | transaction debug id; it increments by exactly 1 per second, which is how the 1 Hz rate was established without strace |
| `29189` | `0x7205` = `BR_DEAD_REPLY` | nothing is registered as context manager |
| `-22` | `-EINVAL` | — |
| `line 3253` | `binder_txn_error()` in `binder_transaction()` | kernel 7.2.10; docs/03 recorded line 3252 on an older kernel |

docs/03 recorded this at "roughly two events per second" from two processes. The rate per process
is 1 Hz and each ping costs two lines.

## Who, and why it is not a stuck state

PID 1066 was `/usr/bin/waydroid-wifid`, started by `waydroid-wifid.service` at boot. Its own
journal names the call:

```
[gbinder] /dev/binderfs/binder has no service manager
[waydroid-wifid] waiting for the container's service manager on /dev/binderfs/binder
```

That is `gbinder_servicemanager_wait(app.sm, -1)` in `wifi/service.cpp`, which libgbinder
implements as a 1 Hz PING to handle 0 until something answers. The daemon is *supposed* to sit
there — `waydroid-wifid.service` is deliberately not ordered after `waydroid-container.service`,
because the daemon must outlive the container and re-register when it comes back. The wait is the
design working. The spam is what the wait costs while Android is absent.

So the volume is a pure function of how long the tablet is powered on and logged out, and on a
kiosk tablet that is unbounded. Worst boot on record:

```
Oct 06 16:13:28  [waydroid-wifid] waiting for the container's service manager
Oct 08 21:09:57  [gbinder] Service manager /dev/binderfs/binder has appeared
```

**52 h 56 m in one wait** — 190,501 pings, which is 99.94% of that boot's 190,617
`cannot find target node` lines. The handful of other PIDs in that boot are the short-lived python
`get_service` retries docs/03 describes, 116 lines between them.

## What it costs

Measured across every boot in the journal on bigtab01:

| Measure | Value |
|---|---|
| Journal lines, all boots | 1,797,377 |
| Lines that are this spam | 526,945 |
| **Share of the journal** | **29.3%** |
| Journal on disk | 1009.4 MB, so roughly 300 MB of it |
| `binder_debug: N callbacks suppressed` events, boot -1 alone | 19 |

The last row is the part that is not merely untidy. binder's own rate limiter is dropping
messages, which means **unrelated binder diagnostics are being discarded** — on a host where
binder evidence has twice been load-bearing ([16-waydroid-network.md](16-waydroid-network.md),
[40-binder-nice.md](40-binder-nice.md)). It also rotates real history out of the journal early.

## Fixes that were rejected

- **Order the unit after `waydroid-container.service`.** Rejected by the unit's own comment, and
  it is right: it would make a container restart able to take the daemon with it, and throw away
  the presence-handler re-registration that Stage 5 exists for.
- **Back off the poll interval.** Trades the one thing this daemon cannot trade. Registering late
  is the 38-minute network deadlock in [16-waydroid-network.md](16-waydroid-network.md), because
  Android caches a failure to reach `wifinl80211`.
- **Clear `BINDER_DEBUG_FAILED_TRANSACTION` from the kernel's debug mask**
  (`/sys/module/binder/parameters/debug_mask`, `7` → `5`). This works instantly and silences both
  lines, and it is the right *stopgap* if the spam is drowning a live investigation. It is the
  wrong permanent answer: it suppresses failed-transaction reporting host-wide, which is exactly
  the class of message the rate limiter was already eating.

## The fix

Gate the binder probe on a signal that costs no binder traffic. `waydroid-container.service` owns
`id.waydro.Container` on the system bus, and `GetSession` answers an empty `a{ss}` until a session
exists:

```console
$ busctl --system call id.waydro.Container /ContainerManager \
         id.waydro.ContainerManager GetSession
a{ss} 0
```

`wifi/service.cpp` now polls that at 1 Hz and only then calls `gbinder_servicemanager_new2()` and
enters the wait. Constructing the servicemanager object is deferred too, so nothing exists that
*could* poll binder while we sit there.

The semantics are exact rather than assumed — `tools/actions/container_manager.py`:

```python
def GetSession(self):
    if not actions.initializer.is_initialized(self.args):
        raise RuntimeError("Waydroid is not initialized")
    try:
        session = self.args.session
        session["state"] = helpers.lxc.status(self.args)
        return session
    except AttributeError:
        return {}
```

Non-empty if and only if `args.session` is set, and it always carries at least `state`. An
uninitialized waydroid *raises*, which the daemon sees as "no answer" and which drives the
fallback below rather than an indefinite wait.

**The fallback.** If `GetSession` never answers at all within 60 s, the daemon gives up on the gate
and probes binder unguarded — the old behaviour. A waydroid that does not offer the method must
still get a working Wi-Fi daemon. Once it *has* answered, a later error means the container manager
went away, and servicemanager cannot appear without it, so the daemon keeps waiting rather than
falling back to pinging an empty binder.

## Why this does not delay registration

This was the one real risk, and the first version of this note got it wrong. `args.session` is
assigned **after** `helpers.lxc.start()`, not before it:

```python
helpers.lxc.start(args)
services.hardware_manager.start(args)

args.session = session
```

So the gate opens once the container has been started, not ahead of it. Measured on a real session
start, 2026-10-16 16:11:

| Time | Event |
|---|---|
| 16:11:19.632 | `Starting up container for a new session` — `do_start` begins |
| 16:11:20.543 | Android `init` sets its first property — so `lxc.start()` has launched the container and `args.session` is assigned around here |
| 16:11:21.969 | `[gbinder] Service manager /dev/binderfs/binder has appeared` |
| 16:11:21.973 | `Registered "wifinl80211"` |
| **16:11:28.683** | **`registerWificondEventCallback()` — Android's Wi-Fi framework's first call** |

Two margins matter, and both are comfortable:

- The gate opens roughly **1.4 s before** servicemanager appears, so at 1 Hz the daemon is
  normally already in `gbinder_servicemanager_wait()` by the time there is anything to find.
- Worst case the gate is detected a second late and gbinder's own 1 Hz wait adds another, putting
  registration about 1.5 s behind where it is today — against a measured **6.7 s** cushion before
  the framework asks for anything.

## Verification

- **Gate closed.** The new binary run for 30 s with no session added **0** kernel lines where the
  shipped 1.1.0 added 60, and its log stops at `no waydroid session yet; waiting for one before
  probing binder` — it never opens the binder device at all.
- **Gate open, cold.** The timing table above.
- **Gate open, warm.** `systemctl restart waydroid-wifid` against a live session on the installed
  1.1.1: **0** new kernel lines, and from opening the binder device to both names registered took
  **4 ms** (16:21:37.0237 → 16:21:37.0272). With a session already present the gate is a single
  D-Bus round trip and costs nothing measurable.
- **End to end.** Android after that restart: `Wifi is enabled`, connected to `"vidiot"`,
  `Supplicant state: COMPLETED`, RSSI -59, 144 Mbps, `wlan0` holding 192.168.240.112.
  `waydroid-wifi-nudge` reported `Wi-Fi is already enabled; nothing to do`.
- **Build.** `%check` passes 8/8 (1 skipped for a file this package's tarball correctly does not
  carry), and the packaged binary is byte-identical to the one measured on the host — the
  `--prebuilt` arm declines to strip for exactly that reason.

## Installing it on bigtab01

A `@commandline` package cannot be upgraded in place, so it is one transaction
([user/ostree.md](user/ostree.md)):

```bash
sudo rpm-ostree uninstall waydroid-ext-wifid \
     --install ./waydroid-ext-wifid-1.1.1-1.x86_64.rpm
sudo rpm-ostree apply-live --allow-replacement
```

`--apply-live` is **not** an option on `uninstall` in rpm-ostree 2026.3 — `apply-live` is its own
subcommand, and it needs `--allow-replacement` because replacing a package's files is not the
default additive case.

The second command ends in `error: Running tmpfiles for /run and /var: Running systemd worker:
exit status: 73` on this host and the package is installed anyway — `rpm -q` answers 1.1.1 and the
binary on disk matches. That is the documented `InterruptedLiveCommit` case, and the cause here is
the documented one: `/var` is owned by `jmelanso`, not `root`. A reboot clears the flag.

## 1.1.1 fixes three quarters of this, and the rest is the logout path

**Measured, not assumed.** Logging out of a live session and watching the kernel log with the
gated 1.1.1 daemon running gave **60 pings in 60 s** — the spam comes straight back. So the gate
covers the boot-before-first-login case and nothing else.

The cause is in libgbinder, and it is not reachable from our presence handler.
`gbinder_servicemanager_died()` is wired to the *remote object's* death callback and
unconditionally calls `gbinder_servicemanager_presence_check_start()`:

```c
#define PRESENSE_WAIT_MS_MIN  (100)
#define PRESENSE_WAIT_MS_MAX  (1000)
#define PRESENSE_WAIT_MS_STEP (100)
```

`gbinder_servicemanager_presense_check_timer()` calls `gbinder_remote_object_reanimate()` — which
is the PING — backing off 100 ms at a time to a 1000 ms ceiling and then returning
`G_SOURCE_CONTINUE` forever. 1 Hz, exactly as measured. Because it hangs off the death callback
rather than off the watch table, `gbinder_servicemanager_remove_handler()` does **not** stop it.
Only destroying the `GBinderServiceManager` does, in its finalizer.

Splitting every ping in the journal by whether it landed before or after the daemon's first
`waydroid-wifid ready.`, and then splitting the remainder by which PID emitted it:

| Source | Pings | Share | State |
|---|---|---|---|
| `waydroid-wifid` startup wait | 200,461 | 75.4% | **fixed in 1.1.1** |
| `waydroid-wifid` post-death poll | 51,742 | 19.5% | open — needs the decision below |
| Other processes, chiefly `waydroid-sensord` | 13,645 | 5.1% | open — see below |

### waydroid-sensord has the same bug

Caught by restarting the gated daemon at the greeter: wifid went quiet and the 1 Hz spam
*continued*, from

```
4348  root  waydroid-sensord /dev/hwbinder
```

`sensors/service.cpp` calls the identical `gbinder_servicemanager_wait(app.sm, -1)`, against
`/dev/hwbinder` and `hwservicemanager` instead of `/dev/binder`. `do_start` launches it at session
start and it outlives the session, so it polls a context manager that is gone for exactly as long
as the tablet sits logged out.

It is a smaller share only because it cannot spam the boot-until-first-login window — it does not
exist until a session has started. Per logged-out hour it costs the same as wifid did.

**But this is not the same bug, and it needs no gate.** Unlike wifid, sensord is not a boot
service that has to persist across sessions — waydroid owns its whole lifecycle. `do_start`
spawns it, and `container_manager.stop()` already tries to kill it:

```python
# Sensors
if which("waydroid-sensord"):
    command = ["pidof", "waydroid-sensord"]
    pid = tools.helpers.run.user(args, command, check=False, output_return=True).strip()
    if pid:
        command = ["kill", "-9", pid]
        tools.helpers.run.user(args, command, check=False)
```

So the intended design is already "dead when there is no session", and there is nothing for
sensord to wait quietly *for*. **The spam is that this kill is not taking effect.** Observed
2026-10-16: PID 4348 was spawned at the 16:11:19 session start, `stop()` logged
`Stopping container` at 16:32:04, and it was still polling `/dev/hwbinder` seven minutes later.

Everything else in `stop()` demonstrably ran, so it is not an exception bailing out early:

| Step | Evidence it ran |
|---|---|
| `waydroid-net.sh stop` | `waydroid0` bridge gone |
| the sensors kill | **no effect — process alive** |
| `umount_rootfs` | `/var/lib/waydroid/rootfs` unmounted |
| `del args.session` | `GetSession` returns `a{ss} 0` |

`del args.session` is the **last** statement of the `try` block and the only one in the tree, so
reaching it means the sensors block was executed. Ruled out: `which` finds
`/usr/bin/waydroid-sensord`; `pidof waydroid-sensord` returns `4348` despite `comm` being
truncated to `waydroid-sensor` at the 15-character limit (pidof falls back to cmdline);
`/usr/bin/kill` exists; `run.user` runs as root here, since it is what spawned the root-owned
process in the first place; and the process is in state `Sl`, not stuck uninterruptible in a
binder ioctl. Why a `kill -9` from root did not land is **not yet explained** and wants waydroid's
debug logging plus a reproduction.

Note the swallowed error: `except Exception as e: logging.debug(...)` means any failure inside
`stop()` is invisible at default log level, which is why this presents as spam rather than as an
error.

### The recommended shape for the rest

Do **not** simply gate `app_sm_presence_handler` the way startup was gated; it cannot stop
libgbinder's timer. Distinguish the two reasons servicemanager can die, which the current design
does not:

- **A session still exists** (`GetSession` non-empty) — the container is bouncing and Android is
  coming back. Keep exactly today's behaviour: let libgbinder poll and re-register the instant it
  reappears. The spam is bounded by the restart, a few seconds.
- **No session** (`GetSession` empty) — the user logged out and Android is not coming back on its
  own. This is the 24.5%, and it is the case the "outlive the container" design never considered.

For the second branch the cheap mechanism is to let the process exit and have systemd's existing
`Restart=always` / `RestartSec=5` bring it back behind the startup gate — it reuses the path
already verified here, and it routes through `ExecStartPost=waydroid-wifi-nudge`, which in-process
re-registration never runs. There is nothing to be late for in that branch, because there is no
Android. Tearing the services down in-process instead would preserve the letter of the design but
has to get `Wificond`/`Supplicant` destruction exactly right, and
[16-waydroid-network.md](16-waydroid-network.md) is a direct warning about what a stale binder
registration costs.

Either way this changes a documented property of `waydroid-wifid.service` — that a container
restart can never take the daemon with it — so it is a decision, not a cleanup.

## Still open

- **One hole in the startup gate.** If `do_start` raises between `helpers.lxc.start()` and
  `args.session = session`, the container is running but `GetSession` stays empty, and the daemon
  waits forever without falling back (it *has* been answered, so the 60 s escape does not apply).
  The only statement between the two is `services.hardware_manager.start(args)`. Waydroid's own
  session start has failed by then, so Android is broken with or without this daemon, but it is a
  reachable state and it is not handled.
