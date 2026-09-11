# Power management: what Android expects, what this machine does, and what is worth building

**Date:** 2026-09-09. **Status: investigation only. Nothing on the host was changed.** One
reversible experiment was run (a 15 s `SIGSTOP` of `waydroid-sensord`); the daemon was resumed and
verified healthy. All figures below are measured on bigtab01 unless explicitly marked as an
estimate.

Written in answer to four questions: how normal Android handles ACPI and power management, what
would make this machine lighter on battery, whether Waydroid could own CPU/disk/memory/peripheral
power management, and whether `waydroid-sensord` already carries ACPI or power data.

## Summary

- **`waydroid-sensord` carries no power or ACPI data.** It serves `ISensors@1.0` and
  `ILight@2.0` and nothing else. Battery reaches Android by an unrelated route — the guest health
  HAL reads the host's own read-only sysfs directly ([10-battery-fixed.md](10-battery-fixed.md)).
- **Android has no concept of ACPI.** It is an ARM/device-tree stack; on x86 the kernel consumes
  ACPI and republishes it as sysfs, and Android only ever sees cpufreq/thermal/power_supply
  through HALs.
- **Waydroid's Power HAL is a stub** — 10,576 bytes containing no `/sys`, `cpufreq` or `governor`
  strings at all. Every `powerHint()` and `setInteractive()` Android sends is discarded. This is
  the same shape as the light HAL stub that [37-brightness.md](37-brightness.md) replaced, and it
  is the one piece worth building.
- **Android's own suspend machinery is structurally inert here.** `/sys/power/wake_lock` does not
  exist on this kernel and `/sys` is read-only in the container.
- **The SoC is not the problem.** Package power idles at **0.47–0.55 W** against a 4.5 W TDP.
- **Our sensor daemon is the top interrupt source on the machine** — 674 I²C interrupts/s,
  measured at **~80 mW** of package power. Real, worth fixing, but second-order.
- **The panel is the dominant consumer by a wide margin, and it sits at 100%.** Originally an
  estimate; **measured on 2026-09-10** at roughly 3.4 W (dim) to 9.6 W (full) of whole-system draw,
  against a SoC package that never leaves 0.57–0.67 W. See "the missing denominator" in section 3.

## 1. Android's power model, and where ACPI fits

ACPI does not appear anywhere in Android's design. Android targets ARM SoCs described by device
tree: DVFS is cpufreq, idle is PSCI, rails are regulators, and there is no firmware bytecode
interpreter in the stack. On the x86 Android forks (Android-x86, the old Intel phones) ACPI is
handled by the Linux kernel exactly as on any Linux machine, and the Android userspace above it
sees only the sysfs the kernel publishes. So the honest answer to "how does Android handle ACPI"
is that it doesn't — Linux does, and a HAL translates.

What Android does own is four layers. Their state on this host:

| Layer | Role | On bigtab01 |
|---|---|---|
| Kernel wakelocks + opportunistic suspend | `/sys/power/wake_lock`; the device suspends whenever *no* wakelock is held, rather than on an idle timer. The single largest difference from desktop Linux | **Unavailable.** `/sys/power/wake_lock` does not exist — Fedora does not build `CONFIG_PM_WAKELOCKS` — and `/sys` is `sys:ro` in the container regardless |
| `android.system.suspend@1.0-service` | Holds `/sys/power/wakeup_count`, writes `mem` to `/sys/power/state` | Running, and its own error strings name exactly those two paths. Both unwritable here. It is inert |
| `android.hardware.power@1.0::IPower` | `setInteractive()`, `powerHint(INTERACTION/LAUNCH/LOW_POWER/SUSTAINED_PERFORMANCE)`, `setFeature()`. Where a vendor writes cpufreq knobs, touch boost, cluster caps | **A stub.** See section 4 |
| `android.hardware.thermal` | Feeds `ThermalService`; drives app-visible throttling | **Absent.** `dumpsys thermalservice` → `HAL Ready: false`, `Thermal Status: 0`, with 4 status listeners registered and receiving nothing |
| Framework: Doze, App Standby, JobScheduler batching, Battery Saver | Pure Java, needs no HAL | Present and configured (`inactive_to=30m`, `light_idle_to=5m`, Battery Saver OFF), but rarely triggers — see section 5 |

**The structural constraint.** The container is a namespace, not a machine. Android inside
Waydroid cannot suspend the host, set a governor, or touch runtime PM, because every one of those
lives behind a read-only `/sys`. Every real power action has to happen host-side. That is the same
seam sensors, Wi-Fi and the backlight already sit on, and it means the question is never "can
Android do power management" but "can Android's *intent* reach a host-side policy engine".

## 2. `waydroid-sensord` and power data: it carries none

The daemon registers two names on the hwbinder connection:

```
android.hardware.sensors@1.0::ISensors     (service.cpp, DEFAULT_IFACE)
android.hardware.light@2.0::ILight         (Lights.cpp, added by 37-brightness.md)
```

Grepping the source for `power|acpi|thermal|governor|cpufreq` returns only comments and the
`sensor_t.power` field — the milliamp figure in a sensor descriptor, which is a constant `0.5f`.

Battery data reaches Android without any daemon at all. `lxc.mount.auto = cgroup:ro sys:ro proc`
gives the container the host's real sysfs, the guest health HAL's `BatteryMonitor` reads
`/sys/class/power_supply/BAT0` correctly, and the only thing that ever needed fixing was
`healthd_board_battery_update()` overwriting those reads with fakes
([10-battery-fixed.md](10-battery-fixed.md)).

Confirmed live during this investigation: host `BAT0` reads `Full/100%/AC online=1`, Android
`dumpsys power` reads `mIsPowered=true mBatteryLevel=96`. The lag is expected — the container's
network namespace never receives `SUBSYSTEM=power_supply` uevents, so refreshes come only from
`HealthLoop`'s 60 s wakealarm (docs/10, "Update latency").

## 3. Measured: what this machine is doing

### Package power

`turbostat`, `cpupower` and `x86_energy_perf_policy` are installed on the host. `powertop` is not.

```
Busy%   Bzy_MHz  PkgTmp  PkgWatt  CorWatt  GFXWatt
 2.62      1147      38     0.54     0.08     0.00
 2.83      1083      37     0.54     0.08     0.00
 2.97      1155      38     0.56     0.09     0.00
 2.63      1074      38     0.51     0.06     0.00
```

RAPL agrees independently: 5,606,248 µJ over 10 s = **560 mW**. Against a 4.5 W TDP the SoC is
close to its floor, and `GFXWatt` is 0.00 with a Waydroid session composited and displayed.

**Trap worth naming:** reading `/proc/cpuinfo` or `scaling_cur_freq` showed 2593 MHz on three of
four cores at load 0.25, which looks like a runaway. It is observer effect — those reads IPI the
target CPU. `turbostat`'s `Bzy_MHz` shows the true figure, ~1100 MHz. Do not diagnose from
`/proc/cpuinfo`.

### Interrupts

The LPSS I²C controllers are the top interrupt source on the machine, ahead of the local timer:

```
IRQ  7   9,546,687   INT3432:00, INT3433:00   LPSS I2C
LOC      8,347,560   Local timer interrupts
CAL      1,252,370   Function call interrupts
IRQ 42     438,152   ahci
IRQ 49     220,468   i915
IRQ 39     179,423   ITE8350:00               the sensor hub's own line
IRQ 53     165,407   iwlwifi
```

That is `waydroid-sensord`. [`SensorIIO.cpp:139`](../sensors/SensorIIO.cpp#L139) hardcodes
`mPollIntervalMs = 50`, and [`PollOnce()`](../sensors/SensorIIO.cpp#L489) sysfs-reads every
enabled sensor's `_raw` channels on each pass — 20 Hz × ~16 channels ≈ 320 HID-over-I²C
`GET_REPORT`s a second, each costing several controller interrupts. The hub's *own* interrupt line
fires only 10/s, which is the tell: the traffic is host-initiated polling, not the device pushing.
The daemon does 99 voluntary context switches/s and had burned 6m17s of CPU in 7 h.

### The A/B experiment

**Method.** `waydroid-sensord` is **not a systemd unit.** It is a child of
`/usr/bin/waydroid container start` (pid 926), started by `container_manager.py` because its
literal binary name is on `PATH`, and it runs as `system_u:system_r:waydroid_t:s0`. Killing it
would leave it dead until the next container restart — which drops the kiosk session to the SDDM
greeter and needs someone at the machine — and relaunching it by hand from a shell would give it
the wrong SELinux context. So the daemon was `SIGSTOP`ped for ~15 s and `SIGCONT`ed, which stops
the polling without disturbing anything else. `ISensors::poll` is a blocking call by design, so a
stalled reply is indistinguishable from a quiet sensor.

| | Busy% | Bzy_MHz | PkgWatt | LPSS-I²C |
|---|---|---|---|---|
| sensord running (7 samples) | 2.93 | ~1120 | **0.553** | 674/s |
| sensord stopped (3 samples) | 1.63 | ~1210 | **0.473** | 37/s |
| delta | −1.3 pts | — | **−80 mW** | **−637/s** |

After `SIGCONT`: state `S`, IRQ rate back to 663/s, `ILight` still registered, the full sensor list
intact in `dumpsys sensorservice`. No damage.

**Caveat:** three samples over ~15 s in the stopped arm. This is an order of magnitude, not a
precise figure. The interrupt delta is unambiguous; the 80 mW is ±20 mW at best.

**Interpretation.** 80 mW is a 17% increase on an idle package — but the package is only half a
watt. As a fraction of *system* draw (estimated 4–8 W with the panel lit) it is 1–2%, or roughly
3–7 minutes off a 24.05 Wh battery. It is worth fixing because it is a defect in code we shipped
and 637 interrupts/s is ugly, **not** because it is the battery win.

### What could not be measured

**Total system draw, which is the denominator for everything above.** The battery was `Full` on AC
for the whole session, so `current_now` reads 0 and RAPL only covers the SoC package — the panel,
the backlight inverter, the SSD and the radios are all off-package and invisible to it. Getting
that number requires unplugging the charger and reading `power_now`/`current_now` from
`/sys/class/power_supply/BAT0`. Until then, every claim about the panel's share is an estimate.

**S0ix residency.** There is no `/sys/kernel/debug/pmc_core` — the `intel_pmc_core` driver starts
at Skylake and this is Broadwell-Y. So whether `s2idle` reaches a genuinely low-power state on this
platform cannot be observed at all. `mem_sleep` reads `[s2idle] deep`, so S3 is available and an
A/B is cheap; `artifacts/power/20-s3-test.conf` is already staged for it.
[17-hybrid-sleep.md](17-hybrid-sleep.md) bounded the s2idle draw only loosely, and this is the
missing half of that comparison.

### Measured 2026-09-10: the missing denominator, and what it cost to get

The charger was pulled and `bin/power-ab.sh` walked a set of arms, changing one thing at a time.
This supplies the number the section above could not obtain — and it overturns this note's own
estimate of where the power goes.

| backlight | `sys_W` (whole machine) | `pkg_W` (RAPL, SoC only) | off-package |
|---|---|---|---|
| 937 = 100% | **9.61** (and 6.96–7.11 on later idle reads) | 0.634 | ~9.0 |
| 468 = 50% | **~5.0** | 0.661 | ~4.4 |
| 93 = 10% | **~3.44** | 0.644 | ~2.8 |
| 51 = Android's dim value | **3.44–4.03** | 0.669 | ~2.8–3.4 |

**The panel is not "almost certainly" the dominant consumer — it is measured, and it is most of the
machine.** The SoC package never leaves 0.57–0.67 W under any condition tested. Everything else
moves between roughly 2.8 W and 9.0 W, and the only variable being changed was the backlight. The
range across the backlight's travel is on the order of **3.5–6 W**, against a package that does not
move at all.

That reconciles the observed runtime. Using [41-battery-cutoff.md](41-battery-cutoff.md)'s finding
that this 2014 pack delivers about a quarter of its claimed 23 Wh — call it ~5.8 Wh real:

| condition | draw | predicted runtime |
|---|---|---|
| backlight 100% | 9.6 W | **~36 min** |
| backlight 50% | 5.0 W | ~69 min |
| backlight 10% | 3.4 W | ~101 min |

The reported "about 45 minutes" is the first row. Turning the backlight down is worth roughly
**doubling** it, and it is free.

#### The instrument is worse than the machine, and that has to be said

Two runs were needed, and the first was junk. Its arms were 30 s settle + 90 s sample, and it
produced results that contradicted themselves — backlight 50% appearing to draw *less* than
backlight 10%, and an arm at full brightness reading 4.6 W below the baseline at that same
brightness. The cause was not the machine.

**`BAT0`'s `current_now` is heavily filtered.** `battery.cache_time` is 1000 ms, so the kernel is
not caching — the filtering is the EC's own. In the second run it held **one identical value
(3.444 W) for 20 straight minutes**, across three genuinely different machine configurations:
sensord running, sensord `SIGSTOP`ped, and Wi-Fi switched from CAM to power-save. An initial probe
that saw it change at exactly t=1 and t=61 in 120 one-second samples suggested a clean 60 s refresh;
that was over-generalised from one observation and the 300 s arms disprove it.

The consequences for any future measurement here:

- **Do not ask this pack to resolve anything below ~1 W.** The `sensord-stopped` and
  `wifi-powersave` arms are not weak results, they are *no* result — the gauge did not move.
- **For on-package terms, use RAPL instead.** It resolved what the pack could not: `pkg_W` fell to
  **0.567 W** with `waydroid-sensord` stopped against 0.64–0.67 W otherwise — an ~80–100 mW effect,
  independently reproducing the 80 mW this note measured by a different method in section 3.
- **RAPL is blind to the panel, the radios and the SSD**, which is precisely the 2.8–9.0 W term. The
  two instruments are complementary and neither alone answers the question.
- **Android moved the panel mid-run.** The moment nobody was touching the machine, its dim policy
  drove the backlight from 937 to 51 ([42-backlight-selinux.md](42-backlight-selinux.md)), so the
  second run's `baseline` arm is at bl=51, not bl=937. `bin/power-ab.sh` now samples backlight and
  DPMS at every point and flags an arm whose panel moved, rather than averaging through it.

Residual scatter is real and unexplained: bl=51 read 4.03 W while bl=93 read 3.44 W, which is the
wrong way round, and bl=937 read 9.61 W once and 6.96–7.11 W later. Treat every figure above as
±0.6 W and as an ordering, not a calibration. The ordering is not in doubt; the third decimal is
meaningless.

## 4. The Power HAL is a stub — evidence

`/vendor/bin/hw/android.hardware.power@1.0-service.waydroid`, 10,576 bytes. Its complete set of
printable strings is the linker path, libc/liblog/libhidlbase/libutils/libcutils, and the mangled
`IPower` vtable symbols:

```
_ZN7android8hardware5power4V1_06IPower17registerAsServiceE...
_ZN7android8hardware5power4V1_06IPower14interfaceChainE...
_ZN7android8hardware5power4V1_06IPower4pingEv
...
```

Grepping the same binary for `sys/|cpu|freq|governor|hint|boost` returns **nothing**. It registers
the interface and discards every call. For scale, the light HAL stub that
[37-brightness.md](37-brightness.md) replaced is 15,000 bytes and had the same property — "it
contains no file path strings at all".

## 5. Android's framework PM is present but rarely fires

```
mWakefulness=Awake
mHoldingDisplaySuspendBlocker=true
Wake Locks: size=0
Battery Saver is currently: OFF
```

`deviceidle` is fully configured (`inactive_to=30m`, `idle_after_inactive_to=30m`,
`light_idle_to=5m`, `motion_inactive_to=10m`). But
[27-android-power-button.md](27-android-power-button.md) already established that `system_server`
holds a `SCREEN_BRIGHT_WAKE_LOCK 'UndimDetectorWakeLock'` and that the screen-off timeout has never
been observed to fire, even with a deliberate 15 s timeout and 50 s of idle. `screen_off_timeout`
was subsequently raised to 30 min (docs/06). So the display stays lit and Doze never gets its
chance. Also note `motion_inactive_to=10m` — Doze uses the *significant motion* sensor to decide
the device has been set down, and that sensor is one our daemon does not synthesise.

## 6. Host-side settings, as found

| Setting | Value | Note |
|---|---|---|
| Backlight | **937 / 937 (100%)** | Now genuinely driven by Android's slider (docs/37). Estimated 1.5–3 W between min and max on a panel this size — unverified, see above |
| cpufreq | `intel_cpufreq` (intel_pstate **passive**) + `schedutil` | `min_perf_pct=19`, `no_turbo=0`, `turbo_pct=60`, 22 P-states |
| EPB | 6 (`normal`), set by `tuned` profile `balanced` | Broadwell-Y has no HWP, so there is no `energy_performance_preference` node — EPB via `x86_energy_perf_policy` is the only knob of this kind |
| cpuidle | `intel_idle` + `menu`; C10 measured at **53%** residency on cpu0 over a live 10 s window | |
| PCIe ASPM | `[default]` | `powersave` available, untried |
| SATA LPM | `med_power_with_dipm` | already correct |
| Wi-Fi power save | **off** | `/etc/modprobe.d/intel_wireless.conf`: `iwlmvm power_scheme=1` (CAM — continuously awake) and `iwlwifi power_save=0`. **This file is not in this repo** — it is pre-existing host config, not something the Wi-Fi work added. It may have been set for association stability, so treat it as load-bearing until proven otherwise |
| Swap | zram0 7.7 G zstd (291 MB in → 60 MB compressed) + 16 G `/var/swapfile` at lower priority | Healthy. Disk interrupts measured **0/s** |
| Sleep | `mem_sleep = [s2idle] deep`; 1 successful suspend, 0 failed, in 7 h | |
| USB autosuspend | YubiKey pinned `on`; camera `suspended`; hub `auto` | Camera correctly asleep |
| Daemons | `thermald` active, `tuned` active (`balanced`), `upower` active. No TLP, no power-profiles-daemon | |

## 7. What is worth building, and how hard

Framing first, because the question invites a wrong answer: **Android should not and cannot manage
CPU, disk or peripheral power here.** Those are host kernel policy and stay there. What is worth
building is a path for Android's *intent* — "the user is interacting", "battery saver is on", "I am
thermally limited" — to reach a host-side policy engine.

| Part | Where | Difficulty | Payoff |
|---|---|---|---|
| **Fix our own polling.** Honour the rate Android asks for via `batch()` instead of a fixed 50 ms; `dumpsys sensorservice` already shows `minRate=1.00Hz maxRate=20.00Hz`, so Android can and does ask for less. Longer term, IIO triggered buffers so the hub pushes at its own rate and the CPU wakes once per batch | `sensors/SensorIIO.cpp`, host-only, no overlay, no reboot | **Low** for rate-limiting; **medium** for triggered buffers | Removes ~637 wakeups/s and ~80 mW. Best effort-to-win ratio, and it is a defect we introduced |
| **Host knobs**: `tuned-adm profile powersave`, EPB via `x86_energy_perf_policy`, ASPM `powersave`, Wi-Fi PS on | Host config, `artifacts/power/` | **Trivial** each, but each needs an A/B on battery, and the Wi-Fi one carries association risk | Modest, additive |
| **Power HAL.** Serve `android.hardware.power@1.0::IPower` as a third name on the hwbinder connection `waydroid-sensord` already holds. Map `setInteractive(false)` → EPB/tuned powersave; `LOW_POWER` (Battery Saver) → `tuned-adm profile powersave`; `INTERACTION`/`LAUNCH` → transient `min_perf_pct` bump; `SUSTAINED_PERFORMANCE` → `no_turbo=1` | `sensors/`, plus an overlay `.rc` to stand the stub down | **Low–medium.** Four HIDL methods, smaller than `Lights.cpp`. Belongs in sensord because `container_manager.py` gates on that literal binary name — which also buys `waydroid_t` instead of the `unconfined_service_t` that cost Wi-Fi Stage 5 a day ([35](35-wifi-stage5.md)) | Android's Battery Saver and interactivity finally do something. This is the piece that answers "can Waydroid handle CPU power management" |
| **Thermal HAL.** `android.hardware.thermal@2.0-service` over `/sys/class/thermal` (zones read 40 °C / 45 °C live) | New guest binary + `.rc` + VINTF via overlay | **Medium.** A genuine new HAL, scoped already in [10-battery-fixed.md](10-battery-fixed.md) | Apps self-throttle; 4 already-registered listeners start receiving |
| **Battery temperature.** Implement `healthd_board_battery_update()` properly instead of the 3-byte no-op | NDK rebuild of the health HAL | **Low–medium**, scoped in docs/10 | Closes a known-absent field |
| **Real Doze / suspend integration.** Android decides to sleep → host freezes the container *and* enters s2idle or S3 → RTC or input wakes both | `hardware_manager.py` behaviour + host units | **Medium–high**, and half-built already in [17-hybrid-sleep.md](17-hybrid-sleep.md). Blocked from the clean direction by the missing `wake_lock` and by `suspend_action` having no "do nothing" value | Largest theoretical win, least certain |

None of this belongs ahead of the outstanding Wi-Fi Stage 5 items in the goal order, with the
arguable exception of the sensord polling rate — that is a defect in shipped code rather than new
scope.

## 8. Ruled out, and traps

- **`waydroid-sensord` is not a power daemon and adding power data to it is not "already done".**
  It is, however, the right *place* for a Power HAL, for the naming and SELinux reasons above.
- **The CPU is not the battery problem.** 0.47–0.55 W package at idle. Do not spend effort on
  governors before measuring the panel.
- **`/proc/cpuinfo` and `scaling_cur_freq` lie about frequency** under observation. Use
  `turbostat --show Bzy_MHz`.
- **`strings` is not installed on the host.** Use `tr -c '[:print:]' '\n' < file | grep`.
- **RAPL (`/sys/class/powercap/intel-rapl:0/energy_uj`) is root-only** and covers the SoC package
  only — it cannot see the panel, SSD or radios.
- **There is no S0ix residency counter on Broadwell.** `pmc_core` starts at Skylake. Whether
  s2idle is deep here is unmeasurable directly; only a battery-draw A/B against `deep` can answer
  it.
- **`kill -0 <pid>` from an unprivileged shell returns failure for a root-owned process** — it is
  EPERM, not "process gone". It briefly looked like the SIGSTOP had killed the daemon. Check
  `ps`/`/proc/<pid>/stat` instead.
