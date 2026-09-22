# The 32-bit PID cliff: why a two-day-old container boot-loops on the LineageOS logo

**2026-09-21.** Reported as "Waydroid seems to have restarted itself and is now stuck on the
animated boot logo." Nothing had restarted. The container and the cage session were both two days
old and had never stopped. What had happened is that the container's PID namespace counter walked
past **65535**, and every 32-bit process in the image has been unable to start since.

## One-paragraph summary

32-bit bionic cannot represent a thread id above 65535 in `pthread_mutex_t`, and aborts the process
outright when it sees one. Waydroid's container is a long-lived PID namespace whose counter only
ever climbs, so after roughly a day of uptime every *newly started* 32-bit process dies at birth.
The image has five 32-bit binaries, and one of them is the audio HAL. With the audio HAL dead,
`audioserver` never registers its policy service; `system_server` blocks in `AudioService`'s
constructor on a binder call that will never return; Watchdog kills `system_server` after 60
seconds; init restarts zygote, which forks a new `system_server` with another high PID, and it
loops forever. `bootanimation` never receives `service.bootanim.exit`, so the logo spins.
Recovery is a container restart, which is the only thing that gives the namespace a fresh counter.
The *fix* is to cap the container's `pid_max` so the counter wraps below 65535 and the cliff
becomes unreachable — `artifacts/pidguard`, built and installed the same day.

---

## The symptom is three layers away from the cause

The visible fault is the boot animation. Two layers of misdirection sit above the real cause, and
both are worth knowing because each one looks like a complete explanation on its own.

**Layer 1 — "it restarted itself" is false.** Nothing restarted:

```
waydroid-container.service   Active: active (running) since Sat 2026-09-19 01:30:27 EDT; 2 days ago
1109897  172337  lxc-start -P /var/lib/waydroid/lxc -F -n waydroid -- /init
1109831  172337  /usr/bin/python3 /usr/bin/waydroid show-full-ui
```

Host-side everything is two days old. `waydroid status` says `Session: RUNNING / Container:
RUNNING`. What restarted is the *Android framework*, over and over, inside a container that never
went anywhere. `bootanimation` had been running 2h23m while `init` had been running 1d23h — that
gap is the whole story, and it is visible in one `ps`.

**Layer 2 — the crash buffer names the wrong crash.** `logcat -b crash` has a full
`FATAL EXCEPTION` for `system_server` at 10:22:21, a `DisplayModeDirector` /
`getRefreshRateInHbmHdr` stack failing to reach the settings provider. It is tempting and it is a
**red herring**: it is one crash from the start of the episode, and the crash buffer then shows
nothing but `DeadSystemException` from apps reacting to each subsequent death. The kill that is
actually happening every 60 seconds writes to `main`/`system`, not to `crash`, because Watchdog
does not throw — it calls `Process.killProcess()`.

**Layer 3 — the real kill.** In `logcat -b main,system`:

```
W Watchdog: *** WATCHDOG KILLING SYSTEM PROCESS: Blocked in handler on main thread (main)
W Watchdog: main annotated stack trace:
W Watchdog:     at android.media.audiopolicy.AudioProductStrategy.native_list_audio_product_strategies(Native Method)
W Watchdog:     at android.media.audiopolicy.AudioProductStrategy.initializeAudioProductStrategies(AudioProductStrategy.java:191)
W Watchdog:     at com.android.server.audio.AudioDeviceBroker.initRoutingStrategyIds(AudioDeviceBroker.java:194)
W Watchdog:     at com.android.server.audio.AudioService.<init>(AudioService.java:1006)
W Watchdog:     at com.android.server.SystemServer.startOtherServices(SystemServer.java:2135)
W Watchdog: *** GOODBYE!
```

`system_server` never finishes `startOtherServices`. It is blocked on a **binder call into
`audioserver`** that never returns, 60 seconds is up, and Watchdog shoots it. The `WAITED_HALF`
line 30 seconds earlier is the tell that it is a hang, not a crash.

A useful detail in that same block: Watchdog tries to dump the kernel via
`/proc/sysrq-trigger` and gets `EROFS (Read-only file system)`. That is LXC's `proc:mixed`, and it
is also why `/proc/sys` inside the container cannot be written from inside — which is what forces
the fix below to mount its own procfs from the host rather than just echoing into a sysctl.

## The cause

`audioserver` is up but has registered nothing. Its HAL is what is missing:

```
# ps -A -o PID,ETIME,STAT,NAME
149569    01:23:55 S  android.hardware.audio.service

# cat /proc/149569/status
Name:    android.hardwar
State:   S (sleeping)
Threads: 1

# cat /proc/149569/wchan
futex_do_wait

# service list | grep -c audio
0
```

**One thread**, asleep in a futex, for an hour and a half. It never built its binder threadpool. And
in `logcat -b crash`, under that exact pid:

```
09-21 11:21:02.862 149569 18497 F libc : Limited by the size of pthread_mutex_t, 32 bit bionic libc
                                          only accepts pid <= 65535, but current pid is 149569
```

The container's counter:

```
# cat /proc/sys/kernel/ns_last_pid
160794
```

and the binary:

```
/vendor/bin/hw/android.hardware.audio.service: ELF shared object, 32-bit LSB 386, ...
```

The message is emitted by `__libc_fatal`, which aborts. The process does not disappear, because the
abort lands in debuggerd and wedges there — which is why it presents as a *hung* process rather
than a missing one, and why `init.svc.audioserver` and friends sit in `stopping` forever.

That string lives in exactly one place, which settles the scope of the problem:

```
strings /apex/com.android.runtime/lib/bionic/libc.so   | grep -c '32 bit bionic libc only accepts'  -> 1
strings /apex/com.android.runtime/lib64/bionic/libc.so | grep -c '32 bit bionic libc only accepts'  -> 0
```

**64-bit is immune. 32-bit is not.** The 32-bit `pthread_mutex_t` has no room for a full 32-bit
owner tid — the message names `pthread_mutex_t`'s size as the constraint — so bionic refuses to run
at all above 65535 rather than corrupt a lock. The observed effect is that the process dies holding
a single thread, i.e. at its first `pthread_create`. AOSP documents the underlying constraint as a
known [32-bit ABI limitation](https://android.googlesource.com/platform/bionic/+/8b14256/docs/32-bit-abi.md):
the 32-bit `pthread_mutex_t` is 32 bits in total, leaving 16 for the owner tid. *(The exact bionic
call site was not read on this host; the bitness, the fatal message and the single-thread hang are
all measured.)*

## Blast radius: five binaries, and two of them matter a lot

```
32-bit: /vendor/bin/hw/android.hardware.audio.service
32-bit: /vendor/bin/hw/android.hardware.camera.provider@2.7-external-service
32-bit: /vendor/bin/hw/android.hardware.cas@1.2-service
32-bit: /vendor/bin/hw/android.hardware.media.omx@1.0-service
32-bit: /system/bin/app_process32
```

Two of these are load-bearing for this project:

- **the camera provider** — goal 1, "DONE". It is 32-bit. Past the cliff, a camera provider restart
  never comes back, and the camera fault would look nothing like [docs/12](12-v4l2-frame-errors.md).
- **`app_process32`** — this is `zygote_secondary`. Every 32-bit app in the image dies. In this
  episode `init.svc_debug_pid.zygote_secondary` was 157528 and it logged the same fatal at 12:21:13.

So the same root cause can present as "no audio", "camera broken", "some apps won't launch", or
"stuck on the boot logo", depending on which 32-bit thing gets restarted first after the threshold.

## Why it hides for a day and then bites

Crossing 65535 breaks nothing by itself. Processes already running keep their low PIDs and are
fine. The fault only appears when something **restarts** a 32-bit process after the threshold. This
container crossed 65535 roughly a day into its uptime and kept working; the episode began at 10:22,
about 2h23m before it was reported, when something restarted the audio HAL.

That delay is the trap. *Uptime past the threshold is not proof of health* — it is a loaded gun.

### Burn rate

Measured on this host, same day:

| Window | Rate | Time to 65535 |
|---|---|---|
| Idle, post-boot (5 min sample) | **14.1 pids/min** | ~69 h |
| Previous run, 2-day average under real app use | ~56 pids/min | ~20 h |

Boot itself burns ~1400 in the first 20 seconds and ~7000 in the first ten minutes, so an early
sample badly overestimates the steady state. The honest window is **1–3 days of container uptime**,
and it is shorter the more the machine is actually used.

`cat /proc/sys/kernel/ns_last_pid` inside the container is the one-line health check, and it is
cheap. Anything above ~60000 means the next restart of a 32-bit service will wedge.

## Interaction with goal 7

This compounds with the cgroup problem in [docs/48](48-battery-frozen-and-netd-stale.md). Once the
32-bit HALs die, init cannot clear them either — `KillProcessGroup()` signals nobody because
`libprocessgroup` never created the cgroups — so they park in `stopping`:

```
[init.svc.audioserver]:   [stopping]
[init.svc.cameraserver]:  [stopping]
[init.svc.media]:         [stopping]
[init.svc.mediadrm]:      [stopping]
[init.svc.netd]:          [stopping]
```

`waydroid-restartd` was running throughout and did not help, and could not have: it delivers the
signal init cannot, the service respawns, and the replacement gets another high PID and dies the
same way. **Fixing goal 7 would not fix this.** They are independent faults that happen to
amplify each other — goal 7 turns a recoverable service death into a permanent one, and the PID
cliff makes the respawn useless anyway.

## The fix

```
sudo systemctl restart waydroid-container.service
```

then log in again at the greeter. A container restart creates a **new PID namespace**, whose
counter starts at 1. Verified immediately after:

| | before | after |
|---|---|---|
| `ns_last_pid` | 160794 | 1448 |
| `android.hardware.audio.service` pid | 149569 (hung, 1 thread) | 79 (running) |
| `service list \| grep -c audio` | 0 | 3 |
| `service.bootanim.exit` | 0 | 1 |
| `init.svc.audioserver` | stopping | running |
| `init.svc.cameraserver` / `netd` / `zygote_secondary` | stopping | running |
| `system_server` | killed every ~60 s | stable, pid 311 |
| `WATCHDOG KILLING` count since restart | — | **0** |

`system_server` was watched for 3m13s, well past the 60 s Watchdog window, and `bootanimation`
exited on its own.

The cost is the one [AGENTS.md](../AGENTS.md) always warns about: restarting the container service
**drops the kiosk session back to the SDDM greeter**, so it needs someone at the machine.

## The permanent fix: cap the namespace instead of restarting it

Restarting is the *recovery*. The *fix* is to make the counter unable to reach the cliff at all.

[Linux 6.14 made `kernel.pid_max` per-PID-namespace](https://www.phoronix.com/news/Linux-6.14-PID-Namespace)
(Brauner, merged December 2024). bigtab01 runs **7.1.13**, so the container's namespace can be
capped at `pid_max=65536` — highest PID 65535, exactly bionic's limit — while the host stays at
4194304. Verified on the live container:

```
ns pid_max read      = 4194304
ns pid_max WRITE ok  = 65536
host pid_max AFTER   = 4194304      <- untouched
```

**The allocator wraps.** This was the one load-bearing assumption, and it was measured rather than
assumed. With `pid_max=65536`, the counter primed to 65529 and fourteen processes spawned:

```
65530, 65531, 65532, 65533, 65534, 65535, 300, 301, 302, 303, 304, 305, 306, 307
```

`alloc_pid` is cyclic over `[pid_min, pid_max)`, and with ~1500 tasks alive there are always free
low PIDs. So the cliff is not delayed, it is **unreachable**.

### Why a private procfs is needed to write it

The sysctl belongs to the container's PID namespace, but `/proc/sys` is read-only from inside —
LXC's `proc:mixed`, the same thing that made Watchdog's `/proc/sysrq-trigger` write fail `EROFS`
above. So: enter the PID namespace, unshare a mount namespace, mount a fresh procfs there. procfs
takes its PID namespace from whoever mounts it, and that one is ours and writable. The container's
own view never changes.

```sh
nsenter -t <container-init> -p -- unshare -m --propagation private -- \
  sh -c "mount -t proc proc /run/x && echo 65536 > /run/x/sys/kernel/pid_max; umount /run/x"
```

Two traps in that line. `nsenter` **forks by default** when entering a PID namespace — there is no
`--fork` option, only `--no-fork`, and passing `--fork` fails outright. And the target must be the
container's **init**, which is the child of `lxc-start`, not `lxc-start` itself; `lxc-start` lives
in the host's PID namespace, so aiming at it silently does nothing useful.

### What was built

[`artifacts/pidguard/`](../artifacts/pidguard) — see its
[README](../artifacts/pidguard/README.md).

| | |
|---|---|
| `waydroid-pidguard` | Applies the cap. Timer-driven and **reconciling**, because a container restart makes a fresh uncapped namespace and there is no clean event to hook — `waydroid-container.service` goes active long before a session creates the actual LXC container. Five minutes against a 20-hour climb is margin to spare. |
| `waydroid-pid-reset` | Recovery for a container already past the cliff, without dropping the session. |
| `bin/pid-cliff-check.sh` | Read-only diagnostic: namespace state, 32-bit inventory, anything wedged, anything init has parked. |

The guard carries a **safety interlock**: on a pre-6.14 kernel `pid_max` is global and the same
write would quietly reconfigure the host, so it reads the host's value before and after, restores
it if it moved, and refuses to run.

Installed and verified on bigtab01 on 2026-09-21, including the step that
[docs/35](35-wifi-stage5.md) teaches to distrust — **run under systemd, not by hand**, since those
are different SELinux domains. `Result=success`, the cap applied, zero AVCs. The timer is enabled
and firing every five minutes.

`waydroid-pid-reset` was exercised only in `--dry-run`; `--kill-stuck` has **not** been run against
a genuinely wedged container, because none has existed since the restart.

## Upstream

**This is already reported: [waydroid#2071](https://github.com/waydroid/waydroid/issues/2071)**,
filed 2025-09-30, still open, no fix merged. Same mechanism, reached from the other direction —
the reporter's host ran GitLab Runner, whose process churn pushed the container's PIDs past 65535
in hours rather than days. Their recommended workaround is a host-wide
`kernel.pid_max=65535`.

**There is no patch of ours to push.** The constraint is AOSP's, not Waydroid's: the 32-bit
`pthread_mutex_t` is 32 bits total with 16 for the owner tid, and bionic documents it as a
[known 32-bit ABI limitation](https://android.googlesource.com/platform/bionic/+/8b14256/docs/32-bit-abi.md).
Nobody is going to widen it.

**What is worth contributing** is the per-namespace cap. #2071's reporter lists "per-Waydroid PID
namespace caps" as a suggested fix and nobody implemented it — reasonably, since per-namespace
`pid_max` was barely out when the issue was filed. `artifacts/pidguard` is a working
implementation with the wrap behaviour measured, and it is strictly better than the host-wide cap
that thread currently recommends.

**No effect on our existing upstream reports.**
[minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) and the
[#2339 comment](https://github.com/waydroid/waydroid/issues/2339) concern `drv_bo_import()` leaving
`meta.total_size` unset so `gbm_map()` returns NULL — a buffer-import path with no connection to
PID allocation. One caveat is worth carrying, though: the camera provider is **one of the five
32-bit binaries**, so anyone reproducing that camera work on a long-lived container could see the
camera fail for this entirely unrelated reason. The two look different — past the cliff there is no
camera provider *at all*, where the minigbm bug gives a running provider and a broken buffer — but
it is a confounder worth naming before someone spends a day on it.

## Ruled out

- **Restarting the session instead of the container.** The PID namespace belongs to the container,
  not the session. A session restart reuses it and changes nothing.
- **Restarting the wedged services** (`restartd`, `ctl.restart`, init's own recovery). The
  replacement process gets the next PID, which is also above 65535. This is not a goal 7 problem
  wearing a hat, and fixing goal 7 would not fix it.
- **Capping the host's `kernel.pid_max`** — upstream's recommendation, and it does work. Superseded
  here by the per-namespace cap, which achieves the same thing without constraining the host. Keep
  it in mind as the fallback on a kernel older than 6.14; the guard detects that case and says so.
- **Anything in the audio stack.** Goal 5 ([docs/44](44-audio-alsa-backend.md)) is untouched by
  this. The audio HAL here is not misconfigured, it is unable to execute.
- **`--fork` on `nsenter`.** Not an option; it forks by default. Cost a round trip, and the failure
  was quiet enough that a probe appeared to succeed while having written nothing — the first run of
  this investigation "confirmed" per-namespace `pid_max` without ever performing the write.

## Open

- **`--kill-stuck` is unexercised** against a genuinely wedged container. Its reset half is
  measured (`ns_last_pid` 13316 → 301, next PIDs 302/303/304); the kill half is reasoned from
  docs/48 and untested. The next occurrence is the chance to test it — and with the cap installed
  there may never be one, which is a good problem.
- **There is still no notification path** for any warning the guard might want to raise; see
  [docs/41](41-battery-cutoff.md), `dunst` fails on every session start. The guard logs to the
  journal and nothing reads the journal.
- **Packaged as `waydroid-ext-pidguard`** on 2026-09-22 — `packaging/mods/pidguard.mod`, a full
  `rpmbuild -ba`. The Linux 6.14 requirement is deliberately *not* a `Requires:` on the kernel:
  an rpm-ostree host composes against whatever kernel its image carries, so that would make the
  package uninstallable rather than inert, and the guard already fails safe at runtime by
  restoring the host's `pid_max` and refusing to continue.
- **What restarted the audio HAL at 10:22** was never determined. The `DisplayModeDirector` crash
  in the crash buffer at 10:22:21 is the earliest event in the episode, but whether it is cause or
  consequence is unresolved. With the cap in place the question is now academic.
- **The burn rate was measured on an idle machine** (14.1 pids/min) and inferred for a busy one
  (~56 pids/min, from the 2-day average). Neither number matters any more for safety, but they are
  the basis for the "1–3 days" figure quoted above.
