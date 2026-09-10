# Android's per-app freezer, and why it does nothing here

**Status: scoped, nothing built.** Added to the goal list on 2026-09-10 at the owner's request.
Everything below is verified on the host; none of it is a plan that has been tried.

## What the feature is

Android's production mechanism for stopping cached apps burning CPU is the **cgroup v2 freezer**,
driven by `CachedAppOptimizer` in `system_server`. It writes `cgroup.freeze` for each cached app's
own cgroup, and pairs with memory compaction through `/proc/<pid>/reclaim`.

This is worth stating because the obvious guess is wrong: **Android does not use CRIU**, and never
has for the app lifecycle. Android's architectural answer to "freeze an app" is the activity
lifecycle — apps are designed to be killed outright and rebuilt from `onSaveInstanceState`, so the
platform gets resume-where-you-left-off without ever checkpointing a process.

## Current state on bigtab01, measured

Both halves of `CachedAppOptimizer` are off:

```
use_freezer=false
use_compaction=false
```

and `device_config get activity_manager_native_boot use_freezer` returns `null` (unset).

The framework's freezer *bookkeeping* is nonetheless running — logcat is full of lines like

```
I ActivityManager: com.android.vending is exempt from freezer
```

which is a trap in miniature: it looks like the freezer is working. It is not. Those lines are
`ActivityManagerService` maintaining its exemption list, which it does whether or not anything is
ever actually frozen.

## Why it cannot simply be switched on

`CachedAppOptimizer` needs to create and write per-app freezer cgroups. It cannot, and the reason
is one line in Waydroid's own LXC config:

```
lxc.mount.auto = cgroup:ro sys:ro proc
```

`/sys/fs/cgroup` is mounted **read-only** inside the container — confirmed from the live mount
flags, not inferred from the config:

```
none on /sys/fs/cgroup type cgroup2 (ro,seclabel,nosuid,nodev,noexec,relatime,...)
```

The consequence is visible: `/sys/fs/cgroup/uid_0` does not exist, and no `uid_*` cgroup exists at
all, because `libprocessgroup` was never able to create one. So flipping `use_freezer` alone would
change nothing — the writes underneath it would fail.

Worth noting that [17-hybrid-sleep.md](17-hybrid-sleep.md) already quotes this exact config line,
for the unrelated reason that `sys:ro` stops the container reading ACPI state. It is the same
constraint biting a second subsystem.

## What would have to change

1. **Delegate a writable cgroup subtree to the container** — `cgroup:rw` or `cgroup:mixed` in
   `lxc.mount.auto`, or an explicit delegated subtree. This is the substantive part and the risky
   one: it widens what the container can do to the host's cgroup hierarchy.
2. **Enable the feature** — `device_config put activity_manager_native_boot use_freezer true`.
3. **Get `libprocessgroup` to build the `uid_N/pid_M` hierarchy** it expects. Whether it does this
   correctly against a delegated subtree in a container is **unknown and untested**.
4. **SELinux.** Untested. Note that SELinux inside the container is Disabled
   ([37-brightness.md](37-brightness.md)), so the exposure is on the host side, where the mount
   originates.

## Risks and open questions, none of them answered

- **Does it actually help?** Unmeasured. The benefit is CPU not burned by cached apps while the
  machine is awake but idle. Nobody has measured what that costs today, so the win is currently a
  presumption. **Measure first.**
- **Thaw behaviour.** `CLOCK_MONOTONIC` keeps advancing while a task is frozen, so on thaw an app
  sees a time jump. Android's own freezer handles this deliberately (`freeze_debounce_timeout` is
  600000 ms in the settings above, and there is an exemption list). A hand-rolled equivalent would
  not.
- **Does widening the cgroup mount break anything else?** Unknown.
- **Is per-app granularity what is actually wanted**, versus the whole-container freeze below?

## Ruled out: CRIU

Not viable, and not marginally so. `criu` 4.2.1 *is* installed on the host, but:

```
$ strings /usr/bin/criu | grep -c binder
0
```

No binder support and no plugin directory at all. Every Android process holds binder fds to
`servicemanager` and `system_server`; the container additionally holds GPU/dmabuf fds, live DRM
context from the composer, a Wayland socket to `cage`, and the two host daemons on `/dev/hwbinder`.
Checkpointing state that lives behind a kernel driver CRIU has never heard of is not a tuning
problem.

## The cheaper thing that already works

The same kernel feature is available **right now** at container granularity, from the host:

```
/sys/fs/cgroup/lxc.payload.waydroid/cgroup.freeze     # "0" = thawed
```

Root on the host can write `1` to it. Scope, measured:

| file | value | meaning |
|---|---|---|
| `cgroup.procs` | 81 | processes (thread-group leaders) |
| `pids.current` | **1534** | tasks — the freezer's real unit; Android is very thread-heavy |
| `cgroup.events` | `populated 1 frozen 0` | `frozen` flips to 1 when every task has stopped |

It is hierarchical, though that is moot here: the only child cgroup, `.lxc`, holds 0 processes.

Three properties that matter:

- The write is one atomic request but **not instantaneous** — tasks freeze at their next safe
  stopping point, and one blocked in uninterruptible sleep delays it. Poll `cgroup.events`'
  `frozen` field rather than sleeping a fixed interval.
- It is a **scheduling** freeze, not a checkpoint. Memory, fds, sockets and binder state stay
  exactly as they are, which is precisely why it sidesteps every CRIU blocker.
- It is not a kill-shield: `SIGKILL` still reaches frozen tasks, so the OOM killer can too.

**This is untested here** and the long-freeze case is the one to prove: 1534 threads all observe
the same `CLOCK_MONOTONIC` jump on thaw, so watchdogs, ANRs and a thundering herd of expired
alarms are the expected failure mode. Seconds should be clean; minutes need evidence.

Note it buys nothing for **suspend** — [17-hybrid-sleep.md](17-hybrid-sleep.md) established that
s2idle already freezes all userspace including the container. The value is the awake-but-idle case.

## Suggested order of work

1. Measure what cached Android apps actually cost while idle. If it is negligible, stop here.
2. Test the host-side whole-container freeze, short then long, and characterise the thaw.
3. Only then decide whether per-app granularity justifies widening the cgroup mount.
