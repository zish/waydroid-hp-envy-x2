# Goal 3: battery reporting — fixed

Done 2026-09-05. Waydroid now reports the host's real battery. Verified with
[`bin/battery-test.sh`](../bin/battery-test.sh), which compares every field against
`/sys/class/power_supply` rather than just looking for an absence of errors.

## One-paragraph summary

The host→HAL half already worked out of the box and always had. Waydroid's LXC config carries
`lxc.mount.auto = cgroup:ro sys:ro proc`, so the container sees the host's real sysfs, and the
health HAL's `BatteryMonitor` was reading `BAT0` correctly the whole time. The lie was inserted
one layer further on: Waydroid's `android.hardware.health@2.0-service.waydroid` implements the
board hook `healthd_board_battery_update()` as an unconditional overwrite of every battery field
with hardcoded values, and *that* struct — not the one the monitor filled in — is what reaches
Android's `BatteryService`. Fixed by neutralising that one function with a **three-byte** patch
and deploying the binary through the vendor overlay.

## How the two halves disagreed

| Source | level | voltage | status | AC | USB |
|---|---|---|---|---|---|
| Host `/sys/class/power_supply/BAT0` | 100 | 8440 mV | `Full` | online=1 | — |
| HAL, via `lshal debug …IHealth/default` | 100 | 8440 | FULL (5) | 1 | 0 |
| Android, via `dumpsys battery` | **85** | **3600** | **CHARGING (2)** | true | **true** |

The HAL was honest to direct callers and lied to the framework. That split is the whole tell, and
it falls straight out of `hardware/interfaces/health/2.0/default/Health.cpp`:

- `getHealthInfo()` — what `lshal debug` calls — returns `battery_monitor_`'s values untouched.
- `update()` converts those same values into a `BatteryProperties`, calls
  `healthd_board_battery_update(&props)`, and then hands the **modified** `props` to
  `healthd_mode_ops->battery_update()`, which notifies listeners. `BatteryService` is a listener.

## The board hook, disassembled

`/vendor/bin/hw/android.hardware.health@2.0-service.waydroid`, VMA `0x7730` (the binary is
stripped; this is `healthd_board_battery_update`, reached from exactly one call site at `0x8e25`,
immediately before the indirect `battery_update` call):

```asm
7730: 50                    push   rax
7731: 66 c7 07 01 01        mov    WORD PTR [rdi],0x101      ; chargerAcOnline=1, chargerUsbOnline=1
7736: c6 47 02 00           mov    BYTE PTR [rdi+0x2],0x0    ; chargerWirelessOnline=0
773a: 0f 28 05 ff c1 ff ff  movaps xmm0,[rip-0x3e01]         ; .rodata 0x3940
7741: 0f 11 47 04           movups [rdi+0x4],xmm0            ; maxCurrent=500000, maxVoltage=5000000,
                                                             ; status=2 (CHARGING), health=2 (GOOD)
7745: c6 47 14 01           mov    BYTE PTR [rdi+0x14],0x1   ; batteryPresent=true
7749: 0f 28 05 d0 c1 ff ff  movaps xmm0,[rip-0x3e30]         ; .rodata 0x3920
7750: 0f 11 47 18           movups [rdi+0x18],xmm0           ; level=85, voltage=3600, temp=350,
                                                             ; current=400000
7754: 48 b8 20 00 …09 3d 00 movabs rax,0x3d090000000020
775e: 48 89 47 28           mov    [rdi+0x28],rax            ; cycleCount=32, fullCharge=4000000
7762: c7 47 30 e0 fd 1c 00  mov    DWORD PTR [rdi+0x30],0x1cfde0  ; chargeCounter=1900000
7769: 48 83 c7 38           add    rdi,0x38
776d: 48 8d 35 5a cd ff ff  lea    rsi,[rip-0x32a6]          ; "Li-ion"
7774: e8 97 b2 00 00        call   android::String8::setTo
7779: 31 c0                 xor    eax,eax                   ; return false
777b: 59                    pop    rcx
777c: c3                    ret
```

The two `.rodata` blobs decode to the constants exactly:

```
3920  55000000 100e0000 5e010000 801a0600   85, 3600, 350, 400000
3940  20a10700 404b4c00 02000000 02000000   500000, 5000000, 2, 2
```

Every one of those matches the old `dumpsys battery` output field for field. There is **no
property check and no branch** — it fires unconditionally on every update.

### Why it exists

Most Waydroid hosts are desktops with no battery at all. Without the fake, `BatteryMonitor` finds
no supply, reports `present=false, level=0`, and Android will warn, throttle, or shut itself down
(cf. [waydroid#878](https://github.com/waydroid/waydroid/issues/878) on guest charger mode). The
hardcoded 85%-and-charging is a blunt guard against that. On a laptop it is simply wrong, and
there is no way to opt out short of changing the binary.

## The fix

Turn the hook into a no-op so the monitor's real values pass through untouched:

```
file offset 0x6730   (.text is VMA - 0x1000: VMA 0x76d0 -> file off 0x66d0)
  before: 50 66 c7      push rax / mov WORD PTR [rdi],0x101 …
  after:  31 c0 c3      xor eax,eax ; ret      -> return false, props unmodified
```

Three bytes. The rest of the function stays in place as dead code. Returning `false` is what the
original returned anyway, so the caller's `if` behaves identically.

| | md5 |
|---|---|
| original | `683f57b83e627b7ef3f95b49dc0cbde9` |
| patched | `4afd21084e721f3bee2dba77c2fbd274` |

Both are kept byte-for-byte in [artifacts/health/](../artifacts/health/).

### Deployed as

```
/var/lib/waydroid/overlay/vendor/bin/hw/android.hardware.health@2.0-service.waydroid   0755 root:root
```

Note the mode: the pre-existing overlay files are `0644`, which is fine for a library but would
leave this service unable to start. Revert by deleting that one file and restarting the session.

## Result

```
  AC powered: true          level: 100
  USB powered: false        voltage: 8440
  status: 5 (FULL)          technology: Li-ion
```

against a host reporting `capacity=100 status=Full voltage_now=8440000 AC/online=1`. `USB powered`
correctly flipped to `false` as well — the fake had claimed both AC and USB at once.

## Known-absent fields, and why they are not regressions

| Field | Value | Reason |
|---|---|---|
| `health` | 1 (UNKNOWN) | the ACPI battery exposes no `health` node for `BatteryMonitor` to read |
| `temperature` | 0 | no `temp` node either — see [the temperature question](#temperature-sensors-what-would-be-needed) |
| `Charge counter` | 0 | the host exposes `charge_now`, but `BatteryMonitor` looks for `charge_counter` |
| `Max charging current/voltage` | 0 | not exposed by the ACPI AC adapter |

`batteryFullCharge` *is* read correctly (3222000 µAh, from `charge_full`), it is just not printed
by `dumpsys battery`.

## Update latency

The container has its own network namespace, so kernel uevents on `SUBSYSTEM=power_supply` never
reach the health HAL — the instant-notification path is dead and cannot be fixed from inside.
Refreshes therefore come only from `HealthLoop`'s periodic wakealarm, which AOSP defaults to 60 s
(fast) / 600 s (slow). Android's battery reading will lag the host by up to those intervals.
`CAP_WAKE_ALARM` is in `lxc.cap.keep`, so the alarm path itself is available.

## Not yet verified

The battery was at 100% on AC for the entire session, so **tracking a changing value was never
exercised** — only that a static reading matches. Unplug the charger and re-run
`bin/battery-test.sh`: `AC powered` should go `false` and `status` to 3 (DISCHARGING) within the
wakealarm interval above.

Also untested: what Android does as a real battery approaches 0%. It will now behave like a phone,
including low-battery warnings and eventually shutdown — which is the point, but it is a behaviour
change from the permanent fake 85%.

## Temperature sensors: what would be needed

Asked during this session. There are two unrelated things called "temperature" in Android, and the
host side of both is already solved — everything remaining is inside the container.

The host exposes, and the container can already read all of it unaided:

| | |
|---|---|
| `thermal_zone0` | `acpitz`, ~36–46 °C |
| `thermal_zone1` | `acpitz`, reads 0 |
| `thermal_zone2` | `x86_pkg_temp`, ~43–60 °C |
| `hwmon3` | `coretemp` — `Package id 0`, `Core 0`, `Core 1` |
| | 7 cooling devices under `/sys/class/thermal/` |

**1. Battery temperature** (the `temperature: 0` above). `BatteryMonitor` only ever reads
`/sys/class/power_supply/<battery>/temp` or `batt_temp`. The HP's ACPI battery has neither, `/sys`
is the host's own read-only sysfs so no node can be fabricated there, and the path is not
configurable without code. The realistic route is to stop stubbing
`healthd_board_battery_update()` and instead *implement* it: read a thermal zone and convert
millidegrees to the tenths-of-a-degree Android wants (`36000 → 360`). That hook is the correct
place for exactly this — it is the board-specific override — but it needs compiled code rather
than a hex patch, so it means rebuilding the HAL with the NDK. The camera fix already established
that an NDK-only rebuild works without an AOSP tree ([docs/08](08-camera-fixed.md)).

**2. System thermals** (CPU/skin, what `dumpsys thermalservice` and thermal-aware apps use). This
image ships **no thermal HAL at all** — `lshal` lists nothing for `android.hardware.thermal`, and
the service confirms it:

```
Thermal Status: 0
Cached temperatures:
HAL Ready: false
```

Exposing host temperatures here means building an `android.hardware.thermal@2.0-service` that
enumerates `/sys/class/thermal/thermal_zone*` (and optionally the `coretemp` hwmon for per-core
detail), then adding the binary, an init `.rc`, and a VINTF manifest entry through the vendor
overlay. That is a genuine new HAL rather than a patch, and it is a bigger job than either the
camera or battery fixes.

Neither is required for goal 3, which is complete. Both are recorded here so the next session does
not have to re-derive them.

## Trap: `container restart` does not pick up a new overlay file

Worth its own heading because it cost a full cycle. The vendor overlay is mounted as
`lowerdir=/var/lib/waydroid/overlay/vendor:/var/lib/waydroid/rootfs/vendor`, and overlayfs does
not support changing a lower directory underneath a live mount. `waydroid container restart`
leaves that mount in place, so the new file stays invisible and
`md5sum /var/lib/waydroid/rootfs/vendor/bin/hw/…` still shows the original. Only
`waydroid session stop` followed by `waydroid session start` tears the mount down and rebuilds it.

Always confirm the live bytes after deploying — `bin/battery-test.sh` checks the md5 first and
refuses to report anything else if it does not match.
