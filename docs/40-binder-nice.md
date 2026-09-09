# `binder: RLIMIT_NICE not set` — a million dropped priority inheritances a boot

**Date:** 2026-09-09. **Status: fixed.** Proven on the live daemon, deployed as a
`waydroid-container.service` drop-in. Nothing was restarted; the drop-in lands at the next
container start.

Written in answer to "what are these messages and can they be turned off". They can, but the
interesting part is that the message and a real defect are the same event, so the obvious way to
turn them off — the binder debug mask — is the one option that fixes nothing.

## Summary

- The messages come from the kernel's binder driver, not from Android and not from Waydroid.
- **They are ours.** 33,977 of the 33,984 printed in one boot came from two threads of
  `waydroid-sensord`. No Android process contributes at all.
- Each message marks a binder transaction whose **priority inheritance was skipped**. The log
  line and the lost inheritance are the same event.
- Counting the rate-limiter's own suppression records, the true figure for a 6½-hour boot is
  **1,028,179 events, about 44 a second**.
- The cause is `RLIMIT_NICE = 0` (systemd's default, inherited from `waydroid-container.service`)
  combined with SELinux withholding `CAP_SYS_NICE` from `waydroid_t` — **silently**, because the
  kernel asks with the `noaudit` variant. `ausearch` is empty. This is the third time SELinux has
  quietly changed binder behaviour in this project.
- Fix is one line, `LimitNICE=40`, in a drop-in. Measured effect: **~120 messages/minute → 0**.

## The message

```
binder: 1574 RLIMIT_NICE not set
binder_user_error: 291 callbacks suppressed
```

`1574` is a thread id, not a process id.

When a binder transaction arrives, the driver applies the caller's scheduling priority to the
thread that will handle it — binder priority inheritance, which is how Android stops a background
thread from servicing a foreground request at background priority. In
`binder_do_set_priority()`, if the *receiving* task does not hold `CAP_SYS_NICE`, the driver falls
back to that task's `RLIMIT_NICE`, converted with `rlimit_to_nice(r) = 20 - r`. With
`RLIMIT_NICE = 0` this yields a floor of nice 20, one above `MAX_NICE` (19). The driver reads that
as "the limit was never set", logs the message, and **returns without applying the priority**.

So the message is not a warning that something might go wrong later. It is the record of an
inheritance that has already been dropped.

`binder_user_error()` is rate-limited, which is where the paired `callbacks suppressed` lines come
from. They matter for the arithmetic below.

## Who was producing it

Accumulated on the boot of 2026-09-09 11:06:42, between boot and 17:30 when the fix below stopped
them — 6 h 23 m:

| source | messages |
|---|---|
| tid 1574, `hwbinder#1` — thread of pid 1529 `waydroid-sensord /dev/hwbinder` | 18,030 |
| tid 2003, `hwbinder#2` — thread of the same pid 1529 | 15,947 |
| `waydroid show-full-ui` (Python, runs as the desktop user) | 2 |
| `waydroid container start` (Python, runs as root) | 1 |
| other pids, transient | 4 |

Not one Android process appears. The previous boot showed the same shape with the same daemon
under different thread ids (1529 and 1951), so this is not a one-off.

`RLIMIT_NICE not set` was the **only** kind of `binder_user_error` emitted in the whole boot, which
means every suppression record belongs to it and the counts can simply be added:

```
printed:     33,984
suppressed: 994,195
total:    1,028,179 events in 6 h 23 m  ≈ 45/s
```

That rate is consistent with [39-power-management.md](39-power-management.md)'s independent finding
that this daemon is the busiest thing on the machine.

## Why sensord and not wifid

Both daemons speak binder, both run as root with a full POSIX capability set
(`CapEff: 000001ffffffffff`), and both have `RLIMIT_NICE = 0`. Only one produces the message:

| daemon | SELinux context | `RLIMIT_NICE` | messages |
|---|---|---|---|
| `waydroid-wifid` | `system_u:unconfined_r:unconfined_t:s0` | 0 | **0** |
| `waydroid-sensord` | `system_u:system_r:waydroid_t:s0` | 0 | **33,977** |

The single variable is the SELinux domain. The kernel's capability test is
`has_capability_noaudit(task, CAP_SYS_NICE)`, which routes through the LSM, so SELinux gets a vote
even when the POSIX bits are all set. `unconfined_t` carries `capability sys_nice`; `waydroid_t`
does not, so only sensord falls through to the `RLIMIT_NICE` branch.

Because the query is the **noaudit** variant, nothing is logged — `ausearch` shows nothing to find.
That is the same trap as the `binder { transfer }` `dontaudit` in
[35-wifi-stage5.md](35-wifi-stage5.md), which cost a day, and it is now the third instance in this
project of SELinux silently altering binder:

1. `binder { call }` allowed but `binder { transfer }` denied to `unconfined_service_t` — bare
   `DeadObjectException`, `dontaudit`ed (docs/35).
2. `capability sys_nice` denied to `waydroid_t` — noaudit (this document).
3. The `ILight` name being handed back to the guest stub, which is not SELinux but has the same
   "no error anywhere" signature ([37-brightness.md](37-brightness.md)).

Worth being explicit: sensord runs as `waydroid_t` **because** `container_manager.py` starts it,
and that was the desirable property — it is exactly why the brightness work put `ILight` in this
binary rather than in a unit of its own (docs/37). The domain is not a mistake. It simply does not
carry `sys_nice`.

## What it costs

Priority inheritance into sensord's hwbinder threadpool never happens. Android's sensor and light
HAL calls are serviced at whatever priority those threads already hold, without the caller's boost.
On a 4.5 W Broadwell-Y that is not free, though it has not been measured as a latency figure here
and should not be quoted as one.

The second cost is the journal itself: a million records a boot, on an immutable host, drowning
exactly the binder diagnostics this project has repeatedly needed.

## The fix

`LimitNICE=40` gives `min_nice = 20 - 40 = -20`, so the driver stops bailing out and applies the
inherited priority normally.

Proven on the running daemon before anything was installed, with `prlimit`, no restart:

```
$ grep -i nice /proc/1529/limits          # Max nice priority   0   0
  240 messages in the preceding 2 minutes (~120/min)

$ sudo prlimit --pid 1529 --nice=40:40
$ grep -i nice /proc/1529/limits          # Max nice priority  40  40
  0 messages in the following 75 seconds
```

Daemon still healthy afterwards: same 5 threads, 6 h 31 m uptime, no errors, IIO reads live.

Confirmed durable rather than momentary: the boot's cumulative count was 33,984 at 17:32 and
still exactly 33,984 at 19:17 — 1 h 45 m of an otherwise 45/s fault producing not one further
event.

Deployed as [../artifacts/container/nice-limit.conf](../artifacts/container/nice-limit.conf),
installed by [../artifacts/container/install.sh](../artifacts/container/install.sh) to
`/etc/systemd/system/waydroid-container.service.d/`. sensord is a child of
`waydroid-container.service` (`PPid 926`, cgroup `system.slice/waydroid-container.service`), so it
inherits the limit; the container's Android processes inherit it too, which matches what stock
Android's init does anyway.

systemd applies `LimitNICE` as PID 1, before the SELinux transition, so the fix cannot be defeated
by the capability restriction it exists to route around.

One syntax trap: `man systemd.exec` specifies that a value **prefixed** with `+` or `-` is a nice
level in −20…19, while an **unprefixed** value is the raw resource limit in 0…40. `LimitNICE=40` is
therefore the raw limit and is correct; `LimitNICE=-20` would mean the same thing but reads as if
it were setting a nice value.

## Ruled out

**Granting `waydroid_t` `capability sys_nice` with a policy module.** Reaches the same end, but
requires a host policy module for something a one-line drop-in already fixes. Consistent with
docs/35 preferring `SELinuxContext=` over policy edits.

**`setrlimit()` inside sensord itself.** Self-contained in `sensors/`, but raising the *hard* limit
from 0 needs `CAP_SYS_RESOURCE`, which `waydroid_t` may also withhold. More code, more failure
modes, no advantage. Not attempted.

**Suppressing the log — `echo 6 > /sys/module/binder/parameters/debug_mask`.** The mask is `7`
(`BINDER_DEBUG_USER_ERROR | FAILED_TRANSACTION | DEAD_TRANSACTION`); clearing bit 0 stops the
message. Rejected on two grounds. It hides *every* binder user error, and this project has
repeatedly depended on those — the parcel bugs in [33-wifi-stage4.md](33-wifi-stage4.md) were found
that way. And it leaves the dropped inheritance in place; it only stops the kernel mentioning it.

## Verified vs. inferred

**Verified on the host:** the message counts and their attribution to specific tids and pids; both
daemons' SELinux contexts, capability sets and rlimits; `waydroid-container.service` having
`LimitNICE=0`; `debug_mask` being 7; `RLIMIT_NICE not set` being the sole `binder_user_error` kind
in the boot; the before/after counts across the `prlimit` change; the daemon's health after it.

**Inferred.** That SELinux specifically denies `capability sys_nice` to `waydroid_t` is not
directly confirmed — `sesearch` is not installed and layering setools onto an Atomic host costs a
reboot, and the kernel's query is unauditable by design. The evidence is the controlled comparison
above (identical rlimits, identical POSIX capabilities, different domain, opposite outcome), which
is strong but circumstantial.

The description of `binder_do_set_priority()` is from the driver's design, not from reading this
host's kernel source, which is not present on an immutable install. It is corroborated
empirically: changing that one rlimit, and nothing else, took the rate from ~120/min to zero.

## Verifying after the next container start

```sh
grep -i nice /proc/$(pidof waydroid-sensord)/limits     # expect 40  40
journalctl --since -5min | grep -c 'RLIMIT_NICE not set'   # expect 0
```

Until that restart, the running daemon can be corrected in place with the `prlimit` line above.
