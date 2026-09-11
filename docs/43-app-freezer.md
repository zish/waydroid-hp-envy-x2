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

## Measured, 2026-09-10: what cached apps actually cost

Step 1 of the order of work below has now been done, and it answers the question against building
this. Measured from the host on the container's own `cpu.stat`, machine awake and idle (load
average 0.18–0.30 throughout):

| window | container CPU | share of one core |
|---|---|---|
| 120 s | 3.243 s | **2.70%** |
| 30 s (independent cross-check) | 1.010 s | 3.37% |

Per-process over the 30 s window, in `USER_HZ` units (10 ms each), read from `/proc/<pid>/stat` for
every pid in `cgroup.procs`:

```
system_server    32     ndroid.systemui  23     surfaceflinger    13
android.youtube   9     composer@2.1      9     inkedin.android    4
.gms.persistent   2     rkstack.process   2     binder:72_4        2
init              2     gle.android.gms   1     m.android.phone    1
```

**The freezer cannot touch the top four.** `system_server`, SystemUI, SurfaceFlinger and the
composer are framework, not cached apps; `.gms.persistent` and `m.android.phone` are persistent and
on the exemption list by design. Freezer-eligible work is roughly **16 of ~100 units — about 0.43%
of one core**.

Converting to power using [39-power-management.md](39-power-management.md)'s own calibration (its
sensord A/B measured 80 mW against 1.3 points of `Busy%`, which on 4 CPUs is 5.2% of one core, so
≈15 mW per 1% of one core):

| | CPU | est. power |
|---|---|---|
| freeze every eligible cached app | 0.43% of a core | **~7 mW** |
| freeze the *entire* container, all 1780 tasks | 2.70% of a core | ~40 mW |

Against a **measured 9.6 W** whole-system idle draw (1.157 A × 8.306 V, read off `BAT0` on
2026-09-10 with the charger out — the denominator docs/39 could not obtain), the per-app freezer is
worth **0.07%**. On a 45-minute runtime that is **about two seconds**. Freezing the whole container
— every process, including the framework — is worth about twelve.

Measuring the panel afterwards did not rescue the case. With the backlight dimmed the whole machine
idles at **3.44 W**, and the SoC package still sits at 0.57–0.67 W regardless of what the container
is doing ([39](39-power-management.md), "the missing denominator"). Even against that much smaller
denominator the per-app freezer is worth 0.2%, and the entire container freeze about 1%.

This is the "if it is negligible, stop here" case. The feature is not what is consuming this
machine's battery, and building it correctly will not change that. The real terms are the panel at
100%, the radios, and the pack itself; see [39](39-power-management.md) §7 and
[41](41-battery-cutoff.md).

(Task count has drifted up since this note was first written: `pids.current` now reads **1780**,
against the 1534 recorded above.)

## If it is built anyway: what is verified, and what the plan is

Deferred on 2026-09-10 in favour of the battery work above, but the feasibility questions were
settled first and are recorded so nobody re-derives them.

**Verified: the kernel supports binder freezing.** `/proc/kallsyms` carries the full Android 12+
set — `binder_ioctl_freeze`, `binder_request_freeze_notification`, `binder_add_freeze_work`,
`binder_clear_freeze_notification`. `CachedAppOptimizer.freezeBinder()` has something real to call,
so the deadlock-avoidance half of the design is present rather than missing.

**Verified: the image is already configured for it.** Nothing needs patching in the Android tree.
`/system/etc/cgroups.json` declares

```json
"Cgroups2": { "Path": "/sys/fs/cgroup", "Mode": "0775", "UID": "system", "GID": "system",
              "Controllers": [ { "Controller": "freezer", "Path": "." } ] }
```

and `/system/etc/task_profiles.json` defines the attribute and both profiles:

```json
{ "Name": "FreezerState", "Controller": "freezer", "File": "cgroup.freeze" }
{ "Name": "Frozen",   "Actions": [ { "Name": "SetAttribute",
                                     "Params": { "Name": "FreezerState", "Value": "1" } } ] }
{ "Name": "Unfrozen", "Actions": [ { "Name": "SetAttribute",
                                     "Params": { "Name": "FreezerState", "Value": "0" } } ] }
```

**Cheaper than this note originally feared: no controller delegation is needed.**
`cgroup.subtree_control` on `lxc.payload.waydroid` is *empty*, which looks like a blocker and is
not — `cgroup.freeze` is cgroup **core**, present on every cgroup regardless of which controllers
are enabled. The container needs only to `mkdir uid_N/pid_M` and write two files. Point 1 of "What
would have to change" above overstates the problem.

The stages, in order:

1. **Settle whether LXC gave the container a cgroup namespace.** This decides the entire risk
   profile and nothing should be changed before it is known. If there is one, the container's
   `/sys/fs/cgroup` root *is* `lxc.payload.waydroid`, and making it writable delegates only that
   subtree — the ordinary, safe cgroup v2 delegation pattern. If there is not, `cgroup:rw` would
   hand the container the host's whole hierarchy and `cgroup:mixed` becomes mandatory. Read-only
   check: `readlink /proc/1/ns/cgroup` against a container pid's, and `cat /proc/1/cgroup` from
   inside the container — `0::/` means namespaced, `0::/lxc.payload.waydroid` means not.
2. **Widen the mount**: `lxc.mount.auto = cgroup:ro sys:ro proc` → `cgroup:mixed:force`. The
   `lxc.container.conf(5)` page on the host is explicit that `:mixed` bind-mounts *the container's
   own* cgroup writable while remounting the parents read-only, and that `:force` is required
   precisely when cgroup namespaces are enabled, because LXC otherwise defers the mount to the
   container's init.
3. **Make it durable — and note this is a pre-existing hole, not a new one.** `set_lxc_config()`
   rebuilds `/var/lib/waydroid/lxc/waydroid/config` with a plain `cat "$snippets" > config` from
   `/usr/lib/waydroid/data/configs/config_base`. It is called from only two places —
   `tools/actions/initializer.py:163` and `tools/actions/upgrader.py:57` — so it does **not** run on
   every container start, and hand edits survive reboots. But `waydroid upgrade` erases them, and
   the `lxc.net.0.name = wlan0` rename from [34-wifi-second-radio.md](34-wifi-second-radio.md) is
   sitting in exactly that trap already: stock `config_3` still says `eth0`, and `config.pre-wlan0`
   is the fossil of the hand edit. One idempotent `ExecStartPre` reconciler in
   `artifacts/container/` would make both durable, in the same shape as `waydroid-overlay-sync`
   ([36-packaging.md](36-packaging.md)).
4. **Enable it**: `device_config put activity_manager_native_boot use_freezer true`. It is a
   `native_boot` flag, read once at boot, so it needs a container restart — which **drops the kiosk
   session to the SDDM greeter and needs someone at the machine**.
5. **Verify**: `uid_*/pid_*/cgroup.freeze` appearing at all, `CachedAppOptimizer` in logcat, and
   watch for app kills caused by binder transactions landing on frozen processes.

**The risk to watch hardest is SELinux, and it has a known shape here.** SELinux is Disabled
*inside* the container ([37-brightness.md](37-brightness.md)), but it is one kernel: the host still
labels the container's processes, and creating directories in `cgroup_t` is a host-side decision.
This project has now been bitten three times by a `dontaudit`ed denial that leaves `ausearch`
completely silent — [35](35-wifi-stage5.md), [40](40-binder-nice.md), [42](42-backlight-selinux.md).
Ask the kernel directly with `selinux.selinux_check_access()` before building anything; do not wait
for an audit record that will never be written.

## Suggested order of work

1. ~~Measure what cached Android apps actually cost while idle. If it is negligible, stop here.~~
   **Done 2026-09-10 — it is negligible.** ~7 mW out of a 9.6 W machine. See above.
2. Test the host-side whole-container freeze, short then long, and characterise the thaw. Still
   undone, and still the cheapest way to bound the idea — but the ceiling is now known to be
   ~40 mW, so this is a curiosity rather than a lead. `bin/power-ab.sh --freeze` runs it as a
   measured arm with an automatic thaw.
3. ~~Only then decide whether per-app granularity justifies widening the cgroup mount.~~
   **Decided 2026-09-10: not on battery grounds.** Build it for completeness of goal 6 if wanted,
   with eyes open about the payoff.
