# Android's per-app freezer, and why it does nothing here

**Status: scoped; the freezer itself is still unbuilt, but one containment fix shipped on
2026-09-12** — see *dex2oat contained, without cgroups*. Added to the goal list on 2026-09-10 at
the owner's request. Everything here is verified on the host; where something is still hypothesis
it says so.

**Read the 2026-09-12 sections before acting on the 2026-09-10 ones.** They establish that there
are two independent faults rather than one, that the second is not fixable by the mount change
proposed below, that the battery verdict survives a deliberately hostile re-measurement, and that
compaction — the other half of `CachedAppOptimizer` — is not blocked at all.

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

This is only half the story. The read-only v2 mount costs the freezer and process groups; a second,
larger fault costs Android its entire scheduling-policy layer and is **not** fixed by widening this
mount. See *there are two faults, and the mount is the smaller one*, 2026-09-12, below.

Worth noting that [17-hybrid-sleep.md](17-hybrid-sleep.md) already quotes this exact config line,
for the unrelated reason that `sys:ro` stops the container reading ACPI state. It is the same
constraint biting a second subsystem.

## What would have to change

1. **Delegate a writable cgroup subtree to the container** — `cgroup:rw` or `cgroup:mixed` in
   `lxc.mount.auto`, or an explicit delegated subtree. This is the substantive part and the risky
   one: it widens what the container can do to the host's cgroup hierarchy.
   **Superseded twice by the 2026-09-12 findings.** It is not risky — the container is already
   privileged with no idmap and `CAP_SYS_ADMIN` — and it is not sufficient, because it buys back
   only the freezer and process groups, not the scheduling layer.
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

## 2026-09-12: there are two faults, and the mount is the smaller one

Everything above treats the read-only `/sys/fs/cgroup` as *the* problem. It is one of two, and it
is the less consequential one. Both are stock upstream Waydroid; neither is anything this host did.

### Fault B: the v1 hierarchies never mounted, and never can

`/system/etc/cgroups.json` asks for four cgroup **v1** controllers — `blkio` at `/dev/blkio`,
`cpu` at `/dev/cpuctl`, `cpuset` at `/dev/cpuset`, `memory` at `/dev/memcg`. All four directories
exist inside the container, complete with the `background`, `foreground` and `top-app`
subdirectories `init.rc` creates, and every one of them is an **empty tmpfs stub**: no `tasks`
file, no `cgroup.procs`, no controller file anywhere beneath them. `/dev/stune` is there too,
equally empty, and is not even in `cgroups.json`. `/proc/mounts` inside the container has exactly
one cgroup line — the read-only v2 mount.

The reason is on the host, not in the container:

```
$ cat /proc/cgroups
#subsys_name    hierarchy   num_cgroups   enabled
cpu             0           86            1
cpuacct         0           86            1
blkio           0           86            1
memory          0           86            1
cpuset …        0           86            1        (all fourteen identical)
```

`hierarchy` is **0** for every controller. Fedora 44 is cgroup v2 unified, as every distro has
been since roughly 2021, so the v1 controllers are bound to v2 and a v1 mount of them can never
succeed. **Widening `lxc.mount.auto` does not fix this**, and no amount of delegation will.

This is not exactly a Waydroid bug. It is Waydroid shipping an AOSP image whose cgroup
configuration assumes a v1 host, onto hosts that stopped being v1 years ago. Fixing it upstream
means shipping a v2 `cgroups.json` and `task_profiles.json`. Both files live in `/system/etc`, so
locally they are overlay-able with no image change — the route every other fix here took.

### What Fault B costs, counted

`task_profiles.json` makes 45 controller references. **44 name a controller with no mount** —
`cpuset` 19, `cpu` 12, `memory` 9, `blkio` 4 — and the lone survivor is the single `freezer`
reference, which lands on the read-only v2 mount. Roughly sixty profile names are therefore
no-ops, among them `HighPerformance`, `UClampLatencySensitive`, `ProcessCapacityHigh`,
`SFMainPolicy`, `VMCompilationPerformance` and `LowIoPriority`.

The result is visible per process: `system_server`, SystemUI and a cached browser all read `0::/`,
with no differentiation whatever between the framework and a background app.

### `nice` is not quietly covering for it

The obvious hope is that `setpriority` still separates foreground from background — it is a
syscall, it needs no cgroup, and `Process.setThreadPriority` still works. Measured, it is not
covering anything. Thread-level `nice` distributions, sampled together:

```
org.mozilla.firefox   (cached,     adj 945):  51 threads @ 0,  8 @ -5,  4 @ 10,  3 @ -20
com.linkedin.android  (cached,     adj 910):  86 threads @ 0,  4 @ -10, 14 @ 10,  2 @ -20
com.android.settings  (foreground, adj   0):  26 threads @ 0,  5 @ -10,  2 @ 10,  2 @ -20
```

Cached and foreground are the same shape, and a *cached* app is holding `nice -20` threads. Those
values are what each app set for itself; AMS's backgrounding contributes nothing, because
`setProcessGroup` goes through task profiles and task profiles go through the cgroups that do not
exist. Background apps get **zero** CPU deprioritisation here, not "most of it".

### Stage 1 of the plan below is settled: the container is cgroup-namespaced

The question the plan said must be answered before anything is changed now has an answer, and it
is the favourable one:

```
host:       readlink /proc/self/ns/cgroup      -> cgroup:[4026531835]
container:  readlink /proc/<pid>/ns/cgroup     -> cgroup:[4026532767]
inside:     cat /proc/1/cgroup                 -> 0::/
```

The container has its own cgroup namespace and its `/sys/fs/cgroup` root *is*
`lxc.payload.waydroid`, so `cgroup:mixed:force` would delegate that subtree and nothing else —
the ordinary, safe v2 delegation pattern. `cgroup.controllers` on that cgroup already offers
`cpuset cpu io memory hugetlb pids rdma misc dmem`.

### And the security cost of delegating is about zero, because the container is already privileged

"This widens what the container can do to the host's cgroup hierarchy", in **What would have to
change** above, overstates it. `/var/lib/waydroid/lxc/waydroid/config` has **no `lxc.idmap`** and
keeps a long capability set:

```
lxc.cap.keep = audit_control sys_nice wake_alarm setpcap setgid setuid sys_ptrace sys_admin
               wake_alarm block_suspend sys_time net_admin net_raw net_bind_service kill
               dac_override dac_read_search fsetid mknod syslog chown sys_resource fowner
               ipc_lock sys_chroot
```

This is a privileged container running as real host root with `CAP_SYS_ADMIN`. A delegated cgroup
subtree adds essentially nothing it could not already do. The thing actually holding the line is
host SELinux — the container's processes are `container_runtime_t` — and that stays in place
whatever the mount says.

### Both faults are upstream defaults, verified

```
/usr/lib/waydroid/data/configs/config_base:10:lxc.mount.auto = cgroup:ro sys:ro proc
/var/lib/waydroid/lxc/waydroid/config:10:     lxc.mount.auto = cgroup:ro sys:ro proc
```

Byte-identical: the read-only cgroup mount is upstream's shipped default, not a local edit. Every
Waydroid user on a current distro has both faults.

## 2026-09-12: the battery case re-measured, deliberately unfavourably

The 2026-09-10 measurement was challenged on a fair point — a snapshot with a thin cached set
would understate what the freezer is worth. It was re-run with a **fatter** one (Photos, Brave,
Firefox and LinkedIn all cached), over 300 s, machine idle, load 0.08 → 0.27, nothing else
touching it:

| | |
|---|---|
| container total (`cpu.stat`, authoritative) | **4.32% of one core** |
| freezer-eligible (`adj >= 900`) | **0.887% of one core** |

Per process, the top of the table:

| process | adj | % of one core |
|---|---|---|
| `system_server` | -800 | 1.18 |
| `com.android.systemui` | -800 | 0.56 |
| **`com.google.android.apps.photos`** | **915** | **0.44** |
| `surfaceflinger` | -1000 | 0.41 |
| `composer@2.1` | -1000 | 0.30 |
| `gms.persistent` | 100 | 0.23 |
| `com.linkedin.android` | 905 | 0.15 |

Stacking the sample against the conclusion roughly **doubles** the eligible work — 0.887% against
the 0.43% recorded on 2026-09-10 — which by this note's own 15 mW-per-1%-of-a-core calibration is
**~13 mW rather than ~7 mW**. Against a measured 9.6 W that is 0.14%; against the 3.44 W
dimmed-panel floor, 0.4%. **The verdict survives a hostile sample, which is a stronger result
than the original.** The one honest argument in the table is `com.google.android.apps.photos`,
cached at adj 915 and burning 0.44% of a core doing nothing anybody asked for — and on its own
that is about 7 mW.

Two by-products worth keeping:

- **There is no `system_server` regression.** It measures 1.18% of one core, against the 1.07%
  implied by the 2026-09-10 figures. An intermediate 60 s sample appeared to show 9.16% and was
  wrong by exactly 10×: ticks are 10 ms, so over a window of *W* seconds one core is *W* × 100
  ticks and the percentage is `ticks / W`. Anyone re-deriving these numbers should check that
  divisor first.
- **Wi-Fi Stage 5 costs nothing at idle.** Inside `system_server` the top threads are
  `SensorService` (0.30% of a core), `android.ui` (0.26%) and the main thread (0.26%);
  `WifiHandlerThread` is 13 ticks over 300 s, **0.04%**.

## 2026-09-12: the real cost is performance, and it was caught in the act

46 minutes after a reboot, on AC and idle — textbook conditions for Play Store's background
dexopt job — the machine went to this, measured over 20 s:

```
system-wide:      91.6% busy across all 4 CPUs, 8.4% idle
container total:  365% of one core  (3.65 of the 4 logical CPUs)
CPU pressure:     some avg10 = 35.03%
IO  pressure:     some avg10 =  9.73%,  full avg10 = 1.27%
MemFree:          201 MB
```

with `com.android.vending:background` at 86.2% of a core at `nice=0`, `gms.persistent` at 16.5%,
`system_server` at 13.1%, and a stream of short-lived `dex2oat32` processes accounting for the
rest. dex2oat's own log line read `(threads: 4)`.

The storm itself is correct Android — every device does this, and goal 3 is what made the trigger
honest, since before [10-battery-fixed.md](10-battery-fixed.md) healthd faked "charging"
unconditionally. What is wrong is that **nothing contained it**. On a stock device `dex2oat` lives
in `/dev/cpuctl/dex2oat`, `vending:background` in the `background` cpuset, and the foreground app
in `top-app` with a `uclamp.min` floor. Here all of them are `nice=0` in `0::/`, competing on
equal terms with SurfaceFlinger.

This is the axis where the missing cgroups demonstrably cost something. Battery: no, measured
twice. Security: no, and restoring them would not cost any either. **Performance: yes, and this is
what it looks like.**

### uclamp would work here, which is unusual on x86

Worth recording because it changes whether the v2 rewrite is worth attempting. `intel_pstate` is
in **passive** mode with the **schedutil** governor, and `cpu.uclamp.min` / `cpu.uclamp.max` exist
on the container's cgroup. On the usual x86 configuration (intel_pstate active with HWP) uclamp
has no effect on frequency at all and the whole `UClampLatencySensitive` family would be pointless
to restore. Here it is not. Likewise `io.weight` is enabled on the container cgroup and **bfq** is
the scheduler on both `mmcblk0` and `sda`, and `/data` is btrfs on the LUKS device — a real SSD,
not behind the `none`-scheduled loop devices that carry `system.img` and `vendor.img`. So the
`/dev/blkio` half has a working v2 counterpart too.

### The host side of the boundary is already writable, and needs no delegation

```
/sys/fs/cgroup/lxc.payload.waydroid/cpu.weight       100
/sys/fs/cgroup/lxc.payload.waydroid/cpu.max          max 100000
/sys/fs/cgroup/lxc.payload.waydroid/io.weight        default 100
/sys/fs/cgroup/lxc.payload.waydroid/cpu.uclamp.max   max
/sys/fs/cgroup/lxc.payload.waydroid/cpuset.cpus      (empty = all)
```

Whole-container granularity, host root, one write, instantly reversible, no container change and
no restart. If the goal is ever "Waydroid must not make the host janky", it is one write away. It
does nothing for prioritisation *inside* Android, which is exactly what delegation would buy. An
A/B of `cpu.max` against a real dexopt storm was attempted on 2026-09-12 and lost its load —
dexopt finished first. Still untested.

## 2026-09-12: dex2oat contained, without cgroups — deployed

The single worst offender above has a fix that bypasses the whole cgroup problem. `installd` reads
six properties and passes them to dex2oat as `-j` and `--cpu-set`, verified against this image
rather than from memory:

```
$ strings /system/bin/installd | grep -E 'dex2oat-(threads|cpu-set)'
dalvik.vm.boot-dex2oat-cpu-set      dalvik.vm.boot-dex2oat-threads
dalvik.vm.dex2oat-cpu-set           dalvik.vm.dex2oat-threads
dalvik.vm.restore-dex2oat-cpu-set   dalvik.vm.restore-dex2oat-threads
```

**`--cpu-set` is a `sched_setaffinity()` call, not a cgroup.** That is the whole point: it is the
one containment lever that still works on a host where Android's cgroup layer is inert. All six
properties were unset, which is why the storm ran `threads: 4`.

Deployed via `artifacts/dexopt/install.sh`:

```
dalvik.vm.dex2oat-threads=2
dalvik.vm.dex2oat-cpu-set=0,2
```

`cpu0`+`cpu2` are the two threads of physical core 0 (`cpu1`+`cpu3` are core 1), so dex2oat gets
one whole physical core and the UI keeps the other one intact. Pinning to `0,1` would instead take
one thread from each core and slow everything down. `boot-` and `restore-` are deliberately left
unset — boot dexopt runs before there is any UI to protect.

These are not `ro.*` properties, so [../artifacts/build-prop/README.md](../artifacts/build-prop/README.md)'s
first trap does not apply, and no `build.prop` in the image defines them. They go in
`waydroid_base.prop`, which `make_prop()` copies verbatim into `waydroid.prop` and bind-mounts
into the container. **No container restart is needed** — `installd` reads them per invocation
rather than latching them at boot, so `install.sh` also applies them live with `setprop`.

Verified end to end by forcing a recompile:

```
I dex2oat32: … --compilation-reason=cmdline … --cpu-set=0,2 -j2
I dex2oat32: dex2oat took 2.731s (4.632s cpu) (threads: 2) …
```

**Durability trap, shared with the LXC config.** `make_base_props()` rewrites
`waydroid_base.prop` and is called from exactly two places — `initializer.py:164` and
`upgrader.py:58` — the same two that call `set_lxc_config()`. So this edit survives reboots and
container restarts and is erased by `waydroid init -f` or `waydroid upgrade`, exactly like the
`lxc.net.0.name = wlan0` rename from [34-wifi-second-radio.md](34-wifi-second-radio.md). There are
now **two** files in `/var/lib/waydroid` carrying hand edits with that profile, which strengthens
the case for the single idempotent `ExecStartPre` reconciler already proposed in step 3 below.

## 2026-09-12: compaction is not blocked, and needs no kernel patch

This note has always paired the freezer with compaction. Compaction turns out to be the half that
is nearly free, and an earlier reading of it here was wrong.

`/proc/<pid>/reclaim` **does not exist on this kernel**, and it never will: it is not upstream
Linux and never was. It began as Minchan Kim's per-process reclaim patchset, was rejected upstream,
and survives only as an `ANDROID:` out-of-tree patch in the Android common kernel trees. Patching
it into Fedora's kernel would mean carrying that patch, rebuilding the kernel, and
`rpm-ostree override replace`-ing it on an immutable host for every kernel update, with Secure Boot
signing on top.

**None of that is necessary, because upstream solved it differently and Android already uses the
upstream answer.** `process_madvise(2)` — same author — was merged in Linux **5.10** with
`MADV_PAGEOUT` / `MADV_COLD`, and AOSP's `CachedAppOptimizer` prefers it, keeping the procfs path
only as a fallback for old kernels. Four things were checked here, all positive:

| check | result |
|---|---|
| `libandroid_servers.so` strings | contains **both** `process_madvise` and `/proc/%d/reclaim` |
| bionic `libc.so` | exports `process_madvise` |
| kernel 7.1.13-200.fc44.x86_64 | `syscall(440, -1, …)` returns **EBADF**, not ENOSYS — present |
| `CAP_SYS_NICE`, which the syscall requires | `lxc.cap.keep` includes `sys_nice`, and SELinux **allows** `container_runtime_t` `capability sys_nice` |

That last row was the one worth checking rather than assuming, because
[40-binder-nice.md](40-binder-nice.md) found `waydroid_t` **denied** exactly that capability with
the denial `dontaudit`ed. `waydroid_t` is the *host daemon* domain; the container's own processes
are `container_runtime_t`, and they are allowed it.

So compaction needs **no cgroups** and **no kernel patch** — `process_madvise` takes a pidfd, not a
cgroup — and it is the half that addresses the case below, which the freezer would not.
**Tested on 2026-09-12: it works, but it is not merely one flag away.** The flag must be in effect
when the container *starts*, and it does not survive a restart, so it has to be re-applied every
time. See *compaction tested* below.

## 2026-09-12: what leaving an app open actually costs — Firefox, measured

Worth recording because it is the question users actually ask, and because the answer is not the
one this note was written to investigate.

Cached, `org.mozilla.firefox` burned **0 CPU ticks over 60 s** across all its processes. Gecko
parks its own timers when backgrounded, so the freezer would be enforcing something Firefox
already does voluntarily. What it holds is memory: **8 processes, 2000 MB resident**, spread
across the adj ladder as Android retires them independently —

```
adj=200  443MB  org.mozilla.firefox          adj=940  128MB  :utility
adj=200  265MB  :tab_…27                     adj=950  219MB  :gpu
adj=900  352MB  :tab_…16                     adj=970  496MB  :tab_…36
```

Swap absorbs it rather than lmkd killing it: `/dev/zram0` is 7.7 GB at priority 100, with a 16 GB
`/var/swapfile` behind it at priority -1. Idle pages get compressed into RAM, which is why
`MemAvailable` stayed near 5 GB with 2 GB of Firefox resident.

lmkd kills in adj order once free memory crosses `sys.lmk.minfree_levels`
(`…,55296:900,80640:950`): `adj >= 950` at ~315 MB free, `adj >= 900` at ~216 MB free. **During
the dexopt storm above, `MemFree` hit 201 MB** — under that second threshold — so Firefox's
`:tab_…36`, `:gpu` and `:utility` would have been killed right then. Coming back is a tab reload
from session store, not a crash.

**The freezer would change none of this.** A cached browser's cost here is memory, and freezing a
process does not reclaim a page. Compaction would — see above. zram is already doing much of that
job, and arguably doing it better.

## 2026-09-12, later: compaction tested — it works, with two conditions

`use_compaction` was enabled and the result measured. It works. Two things about *how* it works
matter more than the flag itself.

### A live flag flip does nothing; the container restart is the discriminator

Setting `device_config put activity_manager use_compaction true` on a running container reads back
as `true` and a `CachedAppOptimi` thread appears — but nothing is ever compacted:

```
Requested:  0 some, 4 full          Performed: 0 some, 0 full
NoPid: 0   OomAdj: 0   Time: 0   RSS: 0   Misc: 0   Unaccounted: 0
```

Requests are counted, *nothing* rejects them, and the work simply never happens, with no logcat at
all. `system_server` is not the obstacle — it holds `CAP_SYS_NICE` and `CAP_SYS_PTRACE` in its
effective set (`CapEff: 0000001002887420`), which was worth checking rather than assuming, given
[40-binder-nice.md](40-binder-nice.md).

After `systemctl restart waydroid-container.service`, the same request performs:

```
org.mozilla.firefox (adj 935)
BEFORE  RSS=303 MB  swap= 0 MB   zram=17 MB
AFTER   RSS=245 MB  swap=56 MB   zram=33 MB     -58 MB RSS for +16 MB zram
Performed: 1 -> 2,  Throttled: 37 (unchanged — nothing rejected it)
```

So the flag has to be in effect **when the container starts**, not merely set afterwards. The
restart drops the kiosk session to the SDDM greeter and needs someone at the machine.

### The flag does not survive the restart, and that is the packaging consequence

After the restart `device_config get activity_manager use_compaction` returns **`null`** and
`settings list config` has no compaction entry at all — the value written beforehand is simply
gone. This is therefore not a set-once change. It must be re-applied on **every** container start,
and because it needs `system_server` running it cannot be an `ExecStartPre` alongside the overlay
and the props: it is an `ExecStartPost` one-shot. It is the only thing in this project that has to
be applied *after* the container comes up rather than before.

### `Misc Throttled` is the disabled-flag skip

Worth recording because the counter name gives no clue. On the clean boot, before the flag was
re-applied: `Requested: 38, Performed: 1, Throttled: 37`, of which **`Misc Throttled: 36`** and
`Time Throttled: 1`. Once the flag was set, further requests performed and the Misc count stopped
rising. `Misc` here means "compaction is disabled", not "something went wrong".

## 2026-09-12: `bin/waydroid-reclaim.py`, the host-side alternative, measured

AMS compaction works but is deliberately conservative — it throttles on time, on RSS delta and on
oom_adj, which is right for a phone on battery and leaves a great deal on the table on a machine
with 8 GB and a 7.7 GB zram device. `bin/waydroid-reclaim.py` does the same thing from the host, on
demand, with no dependency on the flag, the restart, AMS plumbing, cgroups or any image change —
the same shape as `waydroid-sensord` and `waydroid-wifid`.

It walks the container's own `cgroup.procs`, filters by `oom_score_adj` (default `>= 900`, Android's
CACHED_APP floor and the same threshold `compact_throttle_min_oom_adj` uses), and calls
`process_madvise(MADV_PAGEOUT)` over each process's private writable anonymous mappings. Stdlib
only, for the same reason as `bin/v4l2-*.py`.

Measured across 61 cached processes holding 9196 MB of RSS:

```
reclaimed 736 MB of RSS for 178 MB of zram (4.1:1) -- net ~558 MB of RAM
```

corroborated independently by `free -m` — `free` 191 → 729 MB, `available` 5060 → 5599 MB, `used`
2791 → 2252 MB. Afterwards: **0 crashes, 0 ANRs**, and the container's process count went *up*
(94 → 127) rather than down, so nothing was killed.

Two honest qualifications:

- **RSS double-counts shared pages.** The ART boot image is mapped into every app, so 9196 MB is
  not 9 GB of unique memory, and the wins are lopsided: the large apps gave 50–150 MB each while
  the sixty-odd small ones gave 3–4 MB, because most of a small app's RSS is that shared image.
- **Nothing is freed outright.** Pages move to zram, so the honest figure is the pair and the
  ratio, which is what the tool reports. They fault back in on next touch. `MADV_PAGEOUT` is
  non-destructive; nothing is stopped and nothing is killed.

Which to use is a real choice rather than a redundancy. AMS compaction is automatic, throttled and
policy-driven, and needs the flag re-applied at every container start. The reclaimer is manual and
unthrottled and answers "give me half a gigabyte back, now". Running both is coherent.

## Suggested order of work

Revised 2026-09-12. The battery question is closed; what is left is a performance question and one
cheap untested lead.

1. ~~Measure what cached Android apps actually cost while idle. If it is negligible, stop here.~~
   **Done 2026-09-10, re-done against a hostile sample 2026-09-12 — it is negligible.** ~13 mW out
   of a 9.6 W machine, having doubled the cached set on purpose to try to break the conclusion.
2. ~~Contain background dexopt.~~ **Done 2026-09-12** — `artifacts/dexopt/`, two properties, no
   cgroups, no restart, verified by forcing a recompile. This addressed the one case where the
   missing cgroups measurably hurt.
3. ~~Try `use_compaction`.~~ **Done 2026-09-12 — it works.** Not one flag, though: the flag must be
   set *before* the container starts and does not survive a restart, so it needs an `ExecStartPost`
   one-shot. `bin/waydroid-reclaim.py` is the host-side alternative that needs none of that and
   recovered **~558 MB of RAM** in one run. Both are measured above.
4. **Demonstrate the jank before building the v2 rewrite.** Scroll something in Android while a
   Play Store install or dexopt pass runs, now that dex2oat is contained, and see whether what is
   left is actually bad. If it is, the project is rewriting `cgroups.json` and `task_profiles.json`
   to the v2 layout (`cpu.weight`, `cpu.uclamp.min`, `cpuset.cpus`, `io.weight`) in the overlay —
   worth attempting here specifically because schedutil and bfq mean uclamp and `io.weight` would
   really work, which is not true of most x86 hosts.
5. Test the host-side whole-container freeze, short then long, and characterise the thaw. Still
   undone; ceiling known to be ~40 mW, so a curiosity rather than a lead. `bin/power-ab.sh --freeze`
   runs it as a measured arm with an automatic thaw. The `cpu.max` A/B on the same cgroup is the
   more useful experiment and is also still undone — it lost its load on 2026-09-12 when dexopt
   finished first.
6. ~~Only then decide whether per-app granularity justifies widening the cgroup mount.~~
   **Decided 2026-09-10, unchanged 2026-09-12: not on battery grounds.** If it is built, build it
   for responsiveness, and know that the mount change alone does not deliver that.
