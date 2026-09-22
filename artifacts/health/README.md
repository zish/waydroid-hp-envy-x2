# Waydroid health HAL — battery fix

Both files are `/vendor/bin/hw/android.hardware.health@2.0-service.waydroid`, pulled from the
running vendor image on bigtab01 (LineageOS 20, `20.0-20260403-GAPPS-waydroid_x86_64`).

| File | md5 | |
|---|---|---|
| `…waydroid.orig` | `683f57b83e627b7ef3f95b49dc0cbde9` | as shipped |
| `…waydroid` | `d3c88484fc3c6fa1fca7423c5a74e20c` | deployed |

Five bytes differ, in three unrelated places. Earlier deployed md5s, for reference when reading
older notes: `4afd21084e721f3bee2dba77c2fbd274` (patch 1 only) and
`a6bc0cf3a9fb03cd0ee20ca45d3bf560` (patches 1 and 2).

Patches 2 and 3 are **both** required and neither works alone: 2 creates the timer, 3 arms it.

## 1 — three bytes at `0x6730`: the board hook (2026-09-05)

File offset `0x6730` is VMA `0x7730`, the start of `healthd_board_battery_update`. Turning it into
a no-op lets the real values `BatteryMonitor` read from the host's `/sys/class/power_supply` reach
Android untouched, instead of being overwritten with hardcoded fakes:

```
before: 50 66 c7      push rax / mov WORD PTR [rdi],0x101 …
after:  31 c0 c3      xor eax,eax ; ret
```

## 2 — one byte at `0xcbd1`: the wakealarm clock (2026-09-18)

File offset `0xcbd1` is VMA `0xdbd1`, the `clockid` immediate of the **only** `timerfd_create`
call site in the binary — `HealthLoop::WakeAlarmInit()`:

```
    dbd0:  bf 09 00 00 00   mov  $0x9,%edi     ; CLOCK_BOOTTIME_ALARM   ->  $0x7, CLOCK_BOOTTIME
    dbd5:  be 00 08 00 00   mov  $0x800,%esi   ; TFD_NONBLOCK
    dbda:  e8 21 53 00 00   call 12f00 <timerfd_create@plt>
```

`CLOCK_BOOTTIME_ALARM` requires `CAP_WAKE_ALARM`. This service's `.rc` carries no `capabilities`
line at all — upstream AOSP's has `capabilities WAKE_ALARM BLOCK_SUSPEND`, Waydroid's does not —
so it runs as uid 1000 with `CapEff: 0000000000000000`, the call returns `EPERM`, and healthd
registers **no periodic update**.

healthd's other wake-up, the `NETLINK_KOBJECT_UEVENT` socket, does work — a battery is not a net
device, and untagged uevents are broadcast to every network namespace, so the container does see
the host's `power_supply` events. That is why the symptom is not an obviously dead reading. It is
worse than that: the values track correctly while they are *changing*, and then freeze on the last
uevent the moment the battery goes quiet. Measured on bigtab01:

| | host | Android |
|---|---|---|
| 2026-09-17 21:42–21:51, `Full` on AC | 100 %, 8479 mV | **101 %, 8477 mV** for 9+ minutes |
| 2026-09-18 23:47, `Charging` | 65 %, 8534 mV | 65 %, 8534 mV — exact |

The reported "101 % full" was a real host reading: the ACPI battery driver computes
`capacity = capacity_now * 100 / full_charge` with **no clamp to 100**, and at charge termination
`capacity_now` can briefly exceed `full_charge`. It was the last uevent before the pack went quiet,
so it stuck — and with no periodic update there is nothing to ever replace it.

`CLOCK_BOOTTIME` needs no capability and counts across suspend. The timer no longer *wakes* the
machine — which is wanted here, not tolerated: the host should not be woken to poll a battery.
The next tick after resume does the update.

## 3 — one byte at `0x6720`: the board config (2026-09-19)

File offset `0x6720` is VMA `0x7720`, `healthd_board_init(struct healthd_config *config)` — the
other board hook, sitting immediately before `healthd_board_battery_update`:

```
    7720:  48 c7 07 ff ff ff ff   movq $0xffffffffffffffff,(%rdi)   ->  c3, ret
    7727:  c3                     ret
```

That one 64-bit store covers **both** leading `int` members of `healthd_config`,
`periodic_chores_interval_fast` and `periodic_chores_interval_slow`, setting both to `-1`.
`HealthLoop::WakeAlarmSetInterval()` maps `-1` to a zeroed `itimerspec`, which **disarms** the
timerfd. So Waydroid disables periodic battery polling twice over, in two unrelated ways, and patch
2 alone is not enough — it produces a timer that exists and never fires:

```
$ cat /proc/84/fdinfo/7          # after patch 2 only
clockid: 7                       <- CLOCK_BOOTTIME, so patch 2 worked
it_value: (0, 0)
it_interval: (0, 0)              <- but nothing is armed
```

Turning the hook into a bare `ret` leaves the defaults the caller already wrote. They are visible in
the binary as a single packed store at VMA `0xe31e`, inside the inlined `InitHealthdConfig`:

```
    e31e:  48 b8 3c 00 00 00 58 02 00 00   movabs $0x2580000003c,%rax
    e328:  48 89 04 24                     mov    %rax,(%rsp)
```

Low dword `0x3c` = 60 s (fast, on charger), high dword `0x258` = 600 s (slow, on battery) — AOSP's
`DEFAULT_PERIODIC_CHORES_INTERVAL_FAST`/`_SLOW`. The defaults are written first and the board hook
overwrote them, so removing the overwrite restores them.

Confirm it took by reading the same fdinfo: `it_interval` must be `(60, 0)`.

## Why not the `.rc` route for patch 2

Adding the missing `capabilities` line instead would not work on this host: `lxc.cap.keep` in
`/var/lib/waydroid/lxc/waydroid/config` lists `wake_alarm`, yet the container's bounding set comes
up without it (`CapBnd: 000000144bac75ff`, bit 35 clear, and every other cap in that keep list
present) — so `PR_CAP_AMBIENT_RAISE` from init would fail anyway. See
[docs/48](../../docs/48-battery-frozen-and-netd-stale.md).

## Reproduce from the original without this repo

```bash
printf '\x31\xc0\xc3' | dd of=<binary> bs=1 seek=$((0x6730)) conv=notrunc   # board hook
printf '\x07'         | dd of=<binary> bs=1 seek=$((0xcbd1)) conv=notrunc   # wakealarm clock
printf '\xc3'         | dd of=<binary> bs=1 seek=$((0x6720)) conv=notrunc   # board config
```

## Deploy

To `/var/lib/waydroid/overlay/vendor/bin/hw/` as **mode 0755**, then restart
`waydroid-container.service` and start a session — dropping the file alone is invisible, because
the overlay directory is a mounted overlayfs lowerdir.

Full reasoning in [docs/10-battery-fixed.md](../../docs/10-battery-fixed.md) for the board hook and
[docs/48-battery-frozen-and-netd-stale.md](../../docs/48-battery-frozen-and-netd-stale.md) for the
wakealarm.
