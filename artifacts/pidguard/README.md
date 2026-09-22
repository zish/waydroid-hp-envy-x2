# pidguard — keeping the container's PID namespace below the 32-bit bionic cliff

32-bit bionic packs a `pthread_mutex_t` owner thread id into 16 bits and calls
`__libc_fatal()` the moment it sees one above 65535. A Waydroid container is a
long-lived PID namespace whose counter only climbs, so after about a day of
uptime every **newly started** 32-bit process dies at birth. This image has five
of them, and two matter a great deal: the audio HAL and the camera provider,
plus `app_process32` — zygote32, and therefore every 32-bit app.

The visible result is a device stuck on the boot animation forever. Full chain
in [docs/51](../../docs/51-pid-namespace-32bit-cliff.md).

## What is here

| file | role |
|---|---|
| `waydroid-pidguard` | Caps the container's PID namespace at `pid_max=65536`. Timer-driven, reconciling. **This is the fix.** |
| `waydroid-pidguard.service` / `.timer` | Runs the above every 5 minutes. |
| `waydroid-pid-reset` | Recovery for a container *already* past the cliff, without restarting it. |
| `install.sh` | `DESTDIR`/`PREFIX`/`UNITDIR`-clean, per the repo convention. |

## Why per-namespace and not host-wide

[waydroid#2071](https://github.com/waydroid/waydroid/issues/2071) reports this same
failure (found through GitLab Runner PID churn rather than uptime) and recommends
capping **the host's** `kernel.pid_max` to 65535. That works, but it constrains the
whole machine for the container's benefit.

[Linux 6.14 made `pid_max` per-PID-namespace](https://www.phoronix.com/news/Linux-6.14-PID-Namespace)
(Brauner, merged Dec 2024). bigtab01 runs 7.1.13, so we cap **only the container**
and leave the host at 4194304. That issue's reporter proposed exactly this
("per-Waydroid PID namespace caps") and nobody implemented it.

Measured on bigtab01 — the counter primed to 65529, then processes spawned:

```
65530, 65531, 65532, 65533, 65534, 65535, 300, 301, 302, ...
```

It **wraps**. The allocator is cyclic over `[pid_min, pid_max)`, and with ~1500
tasks alive there are always free low PIDs. The cliff stops being distant and
starts being unreachable.

## Why a private procfs

The sysctl belongs to the container's PID namespace, but Waydroid's LXC config
mounts the container's `/proc` as `proc:mixed`, so `/proc/sys` is read-only from
inside — Android's own Watchdog proves it, failing to write `/proc/sysrq-trigger`
with `EROFS`. So the guard enters the PID namespace, unshares a mount namespace,
and mounts a fresh procfs there: procfs takes its PID namespace from whoever
mounts it. Nothing in the container's own view changes, and the mount is gone a
millisecond later.

## The safety interlock

On a kernel older than 6.14 `pid_max` is **global**, and the same write would
silently reconfigure the host. So the guard reads the host's value before and
after every write; if it moved, it restores it and refuses to continue rather
than leaving the machine quietly reconfigured.

## Reconciling, not event-driven

A container restart creates a fresh namespace with no cap. There is no clean
event to hook — `waydroid-container.service` goes active long before a session
creates the actual LXC container — and no hurry either, because a fresh namespace
starts at 1 and takes over a day to climb anywhere near the cliff. So the guard
polls and reconciles, the same shape as `waydroid-overlay-sync` and
`waydroid-mediad`. Five minutes against a 20-hour climb is margin to spare; the
interval is about promptness in the log, not safety.

## Usage

```sh
waydroid-pidguard --status       # report, change nothing (rc 0 capped, 2 not)
waydroid-pidguard --dry-run      # what it would change
waydroid-pidguard --verbose      # log even when nothing needed doing

waydroid-pid-reset --dry-run     # what is wedged, what would be reset
waydroid-pid-reset               # reset the counter only
waydroid-pid-reset --kill-stuck  # also signal wedged 32-bit processes
```

`bin/pid-cliff-check.sh` is the read-only diagnostic: namespace state, the
32-bit inventory, anything currently wedged, and any service init has parked.

## Recovery, if a container predates the cap

`waydroid-pid-reset` exists because the supported fix — restarting the container
— drops the cage session to the SDDM greeter and needs a human at the machine.
Resetting `ns_last_pid` does **not** revive what is already wedged: a 32-bit
process that hit the cliff does not exit, it aborts into debuggerd and hangs
there with one thread in `futex_do_wait`, and init cannot clear it either
because libprocessgroup's cgroup kill reaches nobody in this container
([docs/48](../../docs/48-battery-frozen-and-netd-stale.md), goal 7). `--kill-stuck`
signals them from the host, where the signal lands; init is their parent, finally
gets its `SIGCHLD`, and respawns them into the low PIDs the reset just freed.

**Order matters** and the script enforces it: free the low PIDs *first*, so the
respawn lands below the cliff instead of straight back above it.
