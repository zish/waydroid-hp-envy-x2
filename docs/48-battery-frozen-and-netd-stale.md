# Two container faults: a frozen battery reading, and a netd that outlived its restart

**2026-09-18/19.** Reported as two minor annoyances — Android showing `101%` battery, and Android
showing "connected to vidiot" with no internet while the host could ping `8.8.8.8` perfectly well.
Neither turned out to be in the part of the stack it appeared to be in, and the second one shares a
root cause with goal 7.

## One-paragraph summary

Both faults are the same *shape*: something inside the container that cannot be refreshed. The
battery number was never miscalculated — it was a real host reading, latched and never replaced,
because the health HAL's periodic update is dead and the only thing that moves the value is a
`power_supply` uevent that stops arriving the moment the pack goes quiet. The Wi-Fi fault is that
`netd` **survived its own restart**: Android's init stops a service through libprocessgroup's
cgroup-based kill, Waydroid mounts the container's `/sys/fs/cgroup` read-only so those cgroups were
never created, the signal reached nobody, and init parked netd in `STOPPING` for 38 hours. The
surviving netd kept `wlan0` bound to a netId from a previous `system_server`, so every Wi-Fi
association since then failed `networkAddInterface` with `EBUSY` and Android ended up associated
with no routes and no DNS.

---

# Fault 1 — "101% full"

## The value is frozen, not wrong

The first two readings looked like a HAL that lies, which would have been a rerun of
[docs/10](10-battery-fixed.md). It is not. `getHealthInfo`, asked directly, was correct; only the
number the framework held was stale:

```
$ lshal debug android.hardware.health@2.0::IHealth/default        # 2026-09-17 21:43
level: 101 voltage: 8477            <- BatteryMonitor's cached struct, what dumpState prints
getHealthInfo -> { .batteryLevel = 100, .batteryVoltage = 8479 }  <- a fresh read, same call
```

`Health::getHealthInfo()` calls `battery_monitor_->updateValues()` — it refreshes the cache but does
**not** notify anyone. So the second `lshal debug`, two minutes later, printed `100 / 8479` from
dumpState: the cache had advanced only because *the previous probe* moved it. Nothing else was
moving it. `dumpsys battery` still read `101 / 8477` at 21:51, nine minutes after the live value had
been observed to be `100 / 8479`.

The decisive measurement came a day later, with the pack charging rather than full:

| | host `/sys/class/power_supply/BAT0` | Android `dumpsys battery` |
|---|---|---|
| 2026-09-17 21:42–21:51, `Full`, on AC | 100 %, 8479 mV | **101 %, 8477 mV**, for 9+ minutes |
| 2026-09-18 23:47, `Charging`, on AC | 65 %, 8534 mV | 65 %, 8534 mV — exact |

Two-sided, and it names the mechanism exactly: the value **tracks while it is changing** and
**freezes when it stops changing**. That is a missing periodic poll, not a bad reading.

## Where 101 came from

It is a real host reading. The ACPI battery driver computes

```
capacity = capacity_now * 100 / full_charge
```

with **no clamp to 100**, and at charge termination `capacity_now` can briefly exceed `full_charge`
(here both settle at `3473000`, the design capacity). So the host really did report 101 for a
moment. It was the last uevent before the pack went quiet, and with no periodic update there was
nothing left to ever replace it. It would have sat at 101 indefinitely.

## Why there is no periodic update

healthd has exactly two wake-ups, and on this host only one of them works.

**The wakealarm is dead.** `HealthLoop::WakeAlarmInit()` does
`timerfd_create(CLOCK_BOOTTIME_ALARM, TFD_NONBLOCK)`, which requires `CAP_WAKE_ALARM`. Waydroid's
`.rc` for this service carries **no `capabilities` line at all**:

```
service vendor.health-hal-2-0 /vendor/bin/hw/android.hardware.health@2.0-service.waydroid
    class hal
    user system
    group system
```

Upstream AOSP's has `capabilities WAKE_ALARM BLOCK_SUSPEND`. Waydroid's does not, and the running
process shows the consequence:

```
$ grep -E '^Cap|^Uid' /proc/84/status
Uid:    1000  1000  1000  1000
CapEff: 0000000000000000
```

Zero capabilities, uid 1000. The call returns `EPERM`, `wakealarm_fd_` stays `-1`, and
`healthd_mainloop` epolls with nothing periodic registered.

Upstream has no reason to notice: their `healthd_board_battery_update()` hardcodes 85 % and
charging, so on a stock Waydroid there is nothing to refresh in the first place. Fixing that in
[docs/10](10-battery-fixed.md) is what exposed this second half.

**Uevents do work.** This corrects an aside in [docs/46](46-removable-media.md): a battery is not a
net device, and *untagged* kobject uevents are broadcast to every network namespace, so the
container does see the host's `power_supply` events. That is precisely why the fault presents as
"sometimes right" rather than "obviously dead", and it is why the bug survived
`bin/battery-test.sh` — that script compares Android against the host, and while the battery is
moving they agree.

## The fix — two bytes, and Waydroid disables this twice

Same binary and same vendor-overlay route as [docs/10](10-battery-fixed.md)'s three-byte patch.
**Periodic polling is disabled in two unrelated ways, and fixing either alone changes nothing.**
That is worth stating plainly, because the first fix was deployed and verified working and the
battery still would not have polled.

**Gate one, the clock.** Exactly one `timerfd_create` call site in the binary:

```
    dbd0:  bf 09 00 00 00   mov  $0x9,%edi     ; CLOCK_BOOTTIME_ALARM  ->  $0x7, CLOCK_BOOTTIME
    dbd5:  be 00 08 00 00   mov  $0x800,%esi   ; TFD_NONBLOCK
    dbda:  e8 21 53 00 00   call 12f00 <timerfd_create@plt>
```

File offset `0xcbd1` (`.text` is VMA − 0x1000). `CLOCK_BOOTTIME` needs no capability and counts
across suspend. The timer no longer *wakes* the machine, which is wanted here rather than tolerated
— the host should not be woken up to poll a battery. The first tick after resume does the update.

**Gate two, the interval.** Found only because the first fix was verified properly rather than
assumed. `/proc/<pid>/fdinfo/` for the new timerfd said:

```
clockid: 7                 <- CLOCK_BOOTTIME, so gate one was genuinely fixed
it_value: (0, 0)
it_interval: (0, 0)        <- and the timer was never armed
```

The reason is the *other* board hook, sitting immediately before the one docs/10 patched:

```
    7720:  48 c7 07 ff ff ff ff   movq $0xffffffffffffffff,(%rdi)   ->  c3, ret
    7727:  c3                     ret
```

`healthd_board_init(struct healthd_config *config)`. That single 64-bit store covers **both**
leading `int` members — `periodic_chores_interval_fast` and `periodic_chores_interval_slow` — setting
both to `-1`, which `WakeAlarmSetInterval()` maps to a zeroed `itimerspec`, which disarms the timer.
Turning the hook into a bare `ret` (file offset `0x6720`) leaves the defaults the caller already
wrote, visible as one packed store in the inlined `InitHealthdConfig`:

```
    e31e:  48 b8 3c 00 00 00 58 02 00 00   movabs $0x2580000003c,%rax   ; 60 (fast), 600 (slow)
    e328:  48 89 04 24                     mov    %rax,(%rsp)
```

| | md5 |
|---|---|
| as shipped | `683f57b83e627b7ef3f95b49dc0cbde9` |
| docs/10 board-hook patch only | `4afd21084e721f3bee2dba77c2fbd274` |
| + wakealarm clock | `a6bc0cf3a9fb03cd0ee20ca45d3bf560` |
| + board config — deployed | `d3c88484fc3c6fa1fca7423c5a74e20c` |

Five bytes differ from shipped, at `0x6720`, `0x6730`(×3) and `0xcbd1`. Details in
[artifacts/health/README.md](../artifacts/health/README.md). Verify with
`cat /proc/<health-hal-pid>/fdinfo/<timerfd>` **from inside the container**: `clockid: 7` and
`it_interval: (60, 0)`.

Three Waydroid decisions had to be undone to get a real battery reading into Android, and each one
was invisible behind the last: the hardcoded 85 %, the unobtainable alarm clock, and the disabled
poll interval. Upstream has no reason to have noticed the latter two, because with the first one in
place there was nothing to refresh.

## Why not just add the missing `capabilities` line

It would not work on this host, and finding out why turned up something worth recording.
`/var/lib/waydroid/lxc/waydroid/config` has

```
lxc.cap.keep = audit_control sys_nice wake_alarm setpcap setgid setuid sys_ptrace sys_admin
               wake_alarm block_suspend sys_time net_admin net_raw net_bind_service kill
               dac_override dac_read_search fsetid mknod syslog chown sys_resource fowner
               ipc_lock sys_chroot
```

and the container's init comes up with `CapBnd: 000000144bac75ff`. Decoding that against the keep
list, **every** listed capability is present except one: bit 35, `CAP_WAKE_ALARM` — the only name
that appears **twice** in the list. `syslog` (34) and `block_suspend` (36), its neighbours, are both
there. `CapEff` for the same process *does* have bit 35, which is consistent with a bounding-set
drop rather than a missing privilege.

`PR_CAP_AMBIENT_RAISE` cannot raise a capability that is not in the bounding set, so init could not
have granted `WAKE_ALARM` to the service even if the `.rc` asked for it. The one-byte patch needs
neither the `.rc` change nor the bounding set, which is why it was chosen. **Why liblxc 6.0.6 drops
exactly that one entry is unresolved** and is the obvious next thing to test if this ever matters
for another capability.

---

# Fault 2 — "connected to vidiot, no internet"

## What Android thought, and what the kernel had

Android's own view was flawless. DHCP succeeded, and `ConnectivityService` held a complete set of
`LinkProperties`:

```
NetworkAgentInfo{network{101} ni{WIFI CONNECTED} ... Score(60)
  lp{{InterfaceName: wlan0  LinkAddresses: [192.168.240.112/24]  DnsAddresses: [/192.168.240.1]
      Routes: [ 192.168.240.0/24 -> 0.0.0.0 wlan0, 0.0.0.0/0 -> 192.168.240.1 wlan0 ]}}
  nc{[ Transports: WIFI Capabilities: INTERNET&NOT_METERED&... ]}          <- no VALIDATED
Active default network: 101
```

The kernel had none of it. Every per-network routing table was **empty**:

```
$ ip route show table wlan0        # table 1002 per /data/misc/net/rt_tables
$ ip route show table wlan0_local
$ ip route show table local_network
$ ip route show table all
192.168.240.0/24 dev wlan0 proto kernel scope link src 192.168.240.112   <- kernel's own, from the address
local 127.0.0.0/8 dev lo table local ...
```

The ip *rules* were all there, referencing `fwmark 0x7b` — **123**, not 101. That was the tell.

Consequences, in order: no default route, so `resNetworkQuery` returns `ENONET`
("Machine is not on the network"), so every `NetworkMonitor` probe fails with
`UnknownHostException`, so `[101 WIFI] validation failed` every ~90 s forever, so Android shows a
Wi-Fi icon with no internet. Apps see it as `UnknownHostException` too, which is why Play kept
logging `Failed to connect to server for server timestamp`.

## netd's own books

`dumpsys netd` — not logcat, which had long since rolled — holds the whole answer:

```
NetworkController
  Default network: 101
  Networks:
    51 DUMMY dummy0
    52 UNREACHABLE
    99 LOCAL
    101 PHYSICAL              <- no interface at all
    123 PHYSICAL wlan0        <- a netId ConnectivityService has never heard of
  Interface <-> last network map:
    Ifindex: 2 NetId: 123
```

and, in the same dump, the binder call log:

```
21:38:42.329 networkDestroy(100)
21:38:47.837 networkAddInterface(101, wlan0)     -> ServiceSpecificException(64, "Machine is not on the network")
21:38:47.838 networkAddRouteParcel(101, fe80::/64 ...) -> (64)
21:38:48.060 networkAddRouteParcel(101, 192.168.240.0/24 ...) -> (64)
21:38:48.060 networkAddRouteParcel(101, 0.0.0.0/0 via 192.168.240.1) -> (64)
21:38:48.517 networkCreate(NativeNetworkConfig{netId: 101, networkType: PHYSICAL, ...})
21:38:48.519 networkAddInterface(101, wlan0)     -> ServiceSpecificException(16, "Device or resource busy")
21:38:48.520 networkAddRouteParcel(101, ...)     -> ServiceSpecificException(2, "No such file or directory")
21:38:48.749 networkSetDefault(101)
```

Two separate failures, and only the second one matters. The `ENONET` burst is an ordering artefact
— `ConnectivityService` pushed the interface and routes 680 ms before it created the network — and
it is self-healing, because the `networkCreate` that follows succeeds and CS re-pushes. The fatal
one is **`EBUSY`**: `netd` refuses to move an interface that another network already owns, and
netId 123 still owned `wlan0`. With no interface in the network, the route adds then fail `ENOENT`,
and `networkSetDefault(101)` cheerfully succeeds on an empty network.

By the next day Android had cycled to netId **105**, with 123 still holding `wlan0`. It will never
recover on its own.

## Why the stale netId is still there

netIds are allocated by `ConnectivityService` starting at 100, so a netd holding 123 while CS hands
out 101 means CS restarted and netd did not. Process ages inside the container say exactly that:

```
     PID  ELAPSED     ARGS
      72  5-07:14:47  netd              <- container start
      74  5-07:09:58  zygote            (app_process32, the secondary)
     128086  10:04:47 zygote64          <- restarted ~11:47 that morning
     128093  10:04:45 system_server
```

`init.zygote64_32.rc` does carry the standard line for exactly this case:

```
service zygote /system/bin/app_process64 ... --start-system-server
    onrestart restart netd
    onrestart restart wificond
    onrestart restart audioserver
    ...
```

init issued it. It simply did not work:

```
$ getprop init.svc.netd
stopping
$ getprop init.svc_debug_pid.netd
72                       # still alive, 38 hours later
```

`Service::Stop()` kills through libprocessgroup, which signals the pids listed in the service's
`cgroup.procs`. Per [docs/43](43-app-freezer.md), Waydroid's LXC config mounts the container's
`/sys/fs/cgroup` read-only (`lxc.mount.auto = cgroup:ro sys:ro proc`), so `libprocessgroup` never
created any of those cgroups. The kill enumerates an empty (or absent) set, reports success, and
init waits for a `SIGCHLD` that will never arrive.

**This is not specific to netd.** Every service init has ever tried to restart in this container is
wedged the same way:

```
audioserver(89)  cameraserver(114)  idmap2d(115)  media(124)  mediadrm(None)  netd(72)
```

So: **no Android service in this container can be restarted**, by `restart`, by `ctl.restart`, or by
init's own crash recovery. That is the real finding here, and the Wi-Fi symptom is just the first
one that got noticed.

## The fix — `waydroid-restartd`

The proper fix is to make process-group kill work, which is the cgroup work in
[docs/43](43-app-freezer.md) (goal 7) and is not small. Until then,
[artifacts/restartd/](../artifacts/restartd) watches for services stuck in `STOPPING` whose process
is still alive and signals them, so init can reap them and complete the restart it started.

**The timing is the entire design, and getting it wrong is worse than doing nothing.** `init.rc`
has mutual `onrestart` edges — zygote's rc restarts netd, and `netd.rc` restarts zygote:

```
service netd /system/bin/netd
    onrestart restart zygote
    onrestart restart zygote_secondary
```

On a working device that does not loop, because `Service::Reap()` sets `SVC_RESTARTING` before
running the dead service's `onrestart` commands, and `Service::Restart()` is a no-op while that flag
is set:

```cpp
void Service::Restart() {
    if (flags_ & SVC_RUNNING)            StopOrReset(SVC_RESTART);
    else if (!(flags_ & SVC_RESTARTING)) Start();
}
```

So `restart netd` → netd reaped → `restart zygote` → zygote reaped → `restart netd` arrives while
netd is still inside its restart delay, does nothing, and the chain ends. **The cycle is broken by
being fast.** A watchdog with a comfortable 25-second grace would kill netd, wait, kill the zygote
netd's `onrestart` wedged, find netd already `RUNNING` again, and the two would ping-pong for ever.

Hence two speeds: a slow idle poll, because this is a laptop and the answer is almost always
"nothing is stuck", and a **cascade window** — after any kill, poll at 0.2 s and signal whatever
appears in `STOPPING` with no grace at all, which is what init itself would have done. Underneath
that, because the reasoning rests on init internals rather than on anything measured here, a
**circuit breaker**: more than 8 kills in 300 s and the daemon stands down for an hour and says so
loudly. A few extra restarts is a bad afternoon; an unbounded restart loop is a brick.

Two smaller decisions worth keeping:

- The first signal to a service is **SIGTERM**, not SIGKILL. init already believes it sent SIGTERM;
  anything still there on the next poll gets SIGKILL.
- Signals go through `lxc-attach` and `mksh`'s `kill` builtin, so the pid from
  `init.svc_debug_pid.<name>` is used **in the namespace it came from**. Translating it to a host pid
  through `/proc/*/status` `NSpid` would work too, and would be one transcription error away from
  signalling an unrelated host process.

`mediadrm` has no `init.svc_debug_pid.mediadrm` property, so the daemon reports it and leaves it
alone. That property only exists on userdebug builds; this image is
`waydroid/lineage_waydroid_x86_64 ... 13/TQ3A.230901.001 ... userdebug/test-keys`, and there is no
non-debug equivalent. Guessing a pid from an executable name would be worse than doing nothing.

---

## Traps worth remembering

- **"Connected, no internet" with perfect `LinkProperties` means look at the kernel, not at
  `ConnectivityService`.** CS reports what it *asked netd for*, not what netd did. `dumpsys
  connectivity` showed a default route that did not exist anywhere in the kernel.
- **`dumpsys netd`'s binder call log is where netd's errors live.** `ConnectivityService` logged
  nothing about three failed `networkAddRoute` calls, and logcat had rolled long before anyone
  looked. That log survived.
- **`ENONET` from `resNetworkQuery` is not a DNS fault.** It means the netId has no network in netd.
- **Two different things are called "the netId"**, and CS's and netd's can disagree indefinitely.
  `fwmark 0x7b` in `ip rule` naming a netId nothing else mentions is the cheapest tell.
- **`init.svc.<name>` is the most informative property on this host.** A service sitting in
  `stopping` is a restart that silently did not happen, and nothing else reports it — not logcat,
  not `ps`, not `dumpsys`.
- **Process ages discriminate "the framework restarted" from "everything restarted".** `ps -o ETIME`
  on netd vs zygote64 settled in one command what the logs could no longer answer.
- **A reading that is correct while it changes and wrong while it is idle is a missing poll**, not a
  bad conversion. Chasing the arithmetic would have been hours wasted.
- **Verify a fix by observing the mechanism, not by observing that the symptom is absent.** The
  wakealarm patch was deployed, the battery agreed with the host, and it would have been entirely
  reasonable to call it done — the pack was charging, so uevents were carrying the value and the
  broken poll was invisible. Reading `/proc/<pid>/fdinfo/` for the timer that had just been created
  is what exposed the second gate. `ls /proc/<pid>/fd` proves a timerfd exists; only `fdinfo` says
  whether it is armed.
- **Untagged uevents do cross into the container.** [docs/46](46-removable-media.md)'s aside that
  "netlink is netns-scoped" is true for net devices and misleading in general; a battery, and a block
  device, are broadcast to every namespace.

## Still open

- **Why `lxc.cap.keep` loses `CAP_WAKE_ALARM`** while keeping every other entry, under liblxc 6.0.6.
  Untested; it is the only duplicated name in the list.
- **The real fix for restarts** is the cgroup work in [docs/43](43-app-freezer.md). `waydroid-restartd`
  is a mitigation and is documented as one.
- **`mediadrm` has no debug pid property** while sitting in `STOPPING`. Unexplained; it may already
  have exited with init's bookkeeping left behind.
- **The host's Wi-Fi link dropped twice for ~10 minutes** during this session (`No route to host`,
  host uptime unbroken) while Android was in its failed-validation retry loop on the same radio.
  Not investigated, and a reason to be cautious about [docs/38](38-wifi-primary-radio.md)'s
  single-radio arrangement being "in service, under observation".
- **`waydroid-overlay-sync` is not installed on this host** and there is no
  `/usr/share/waydroid-overlay` payload, so `/var/lib/waydroid/overlay` is still hand-managed and a
  dropped file stays dropped. [docs/36](36-packaging.md) describes the packaged arrangement; it is
  not what is deployed. Backups now go in `/var/lib/waydroid/overlay-backups/`, deliberately outside
  the overlay — anything left inside it appears in the container as a file in `/vendor/bin/hw`.
