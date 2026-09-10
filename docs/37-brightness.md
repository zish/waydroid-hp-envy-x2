# Android controls the screen brightness

**Status: working, verified on the host.** Android's brightness now drives the real panel
backlight. The daemon is `waydroid-sensord`; the interface is
`android.hardware.light@2.0::ILight`; the target is
`/sys/class/backlight/intel_backlight`.

Two separate questions were asked. They have different answers:

| question | answer |
|---|---|
| Does the HP Envy x2 have an ambient light sensor? | **No.** Five independent checks, below. |
| Can Android adjust the screen brightness? | **Yes, now.** Manual only — no ALS means no auto-brightness. |

## There is no ambient light sensor

Not "the driver is missing" and not "it needs enabling". The hardware is absent.

| check | result |
|---|---|
| IIO devices | `magn_3d`, `incli_3d`, `dev_rotation`, `accel_3d`, `gyro_3d`. Five. No `als`. |
| ITE8350 HID report descriptor | Declares sensor types `0x73 0x76 0x83 0x86 0x8a` only. No `0x41` (Environmental: Ambient Light), no `0x04D1` (Illuminance) data field. |
| ACPI device list | No `ACPI0008`, no vendor ALS `_HID`. |
| I²C buses | Two client devices on the whole machine: `ITE8350:00` (the hub) and `SYNA7500:00` (the touchscreen). |
| `hp-wmi/als` | Reads back `EINVAL`. |

The `hp-wmi/als` one is the trap. That attribute **exists on this machine**, and
`docs/06-next-session.md` had already recorded `als` in the hp-wmi attribute list — which reads
like evidence of hardware. It is not. `hp-wmi` creates the attribute unconditionally on every HP
machine; the `EINVAL` on read is the BIOS declining the query. The attribute's presence proves
nothing and its error is the actual negative result.

The descriptor check is the strongest of the five, because the hub is where an ALS *would* hang:
it is the one component that already speaks the HID sensor usage page, and `bin/hid-decode.py`
has known the Ambient Light usage since it was written. The hub simply never declares it.

The remaining hiding place is a `_STA`-disabled DSDT node. Not checked — it needs root to read
`/sys/firmware/acpi/tables/DSDT`, and after five negatives it would only be for completeness.

**Consequence:** `config_automatic_brightness_available` can never be honestly true here. Android
agrees already — `dumpsys display` reports `mAutoBrightnessAvailable=false` and
`mUseSoftwareAutoBrightnessConfig=false`, with `mBrightnessReason=manual`. Note that the image
*does* ship `/vendor/etc/permissions/android.hardware.sensor.light.xml`, which declares the
feature; that XML is a lie inherited from the stock image and is not worth acting on.

## Why brightness was broken, and where the seam is

Waydroid ships `/vendor/bin/hw/android.hardware.light@2.0-service.waydroid`, 15 KB, built from
`hardware/waydroid/lights/service.cpp`. It registers `ILight/default` and discards every call.
The proof needs no disassembly: `strings` on it yields **no file paths at all** — only
`"Waydroid light HAL service ready."` — so there is nothing it could possibly write.

Unlike the sensors stub, it has **no property gate**. `images.py` sets
`waydroid.stub_sensors_hal=1` only when `waydroid-sensord` is absent, and nothing equivalent
exists for lights. The lights stub always runs.

The load-bearing question was whether Android 13 even *uses* `ILight` for screen brightness, since
modern Android prefers the composer. It does here, and `dumpsys display` says so outright:

```
mBacklightAdapter=BacklightAdapter [useSurfaceControl=false (force_anyway? false),
                                    backlight=com.android.server.lights.LightsService$LightImpl@...]
```

`useSurfaceControl=false` because `SurfaceControl.setDisplayBrightness` needs composer ≥ 2.3 and
Waydroid ships `android.hardware.graphics.composer@2.1-service`. So `LightsService` → JNI →
`ILight` is the live path. **This was checked before any code was written**, because if it had
come back `true` the whole approach would have been a dead end.

Two more things that had to be true, and are:

- `/dev/hwbinder` is bind-mounted into the container, so a host process can serve a guest HAL.
  Already proven by `ISensors` — see [14-sensors.md](14-sensors.md).
- SELinux inside the container is **Disabled**, so `hwservicemanager` does not label-check the
  registration. This mattered: `ISensors` working did not imply `ILight` would, because
  `hwservice_contexts` gives the two names different labels (`hal_sensors_hwservice` vs
  `hal_light_hwservice`) and the check is per-name.

## Why this lives in a binary called "sensord"

It is not tidy, and it is right. `container_manager.py` starts exactly one host daemon, gated on a
literal name:

```python
if which("waydroid-sensord"):
    ... ["waydroid-sensord", "/dev/" + args.HWBINDER_DRIVER]
```

Riding that hook buys three things a separate `waydroid-lightd` would have to earn back:

1. **No systemd unit, so no repeat of the Stage 5 trap.**
   [35-wifi-stage5.md](35-wifi-stage5.md) cost a day to the discovery that a systemd-started
   `bin_t` binary runs as `unconfined_service_t`, and `container_runtime_t` is denied
   `binder { transfer }` to it under a `dontaudit` rule — invisible in `ausearch`. Spawned from
   `container_manager.py` we inherit `waydroid_t`, which already works. `service.cpp` records the
   same lesson from the other direction for its lock file.
2. **Root, so the backlight is a plain sysfs write** rather than a logind session call.
3. **Same transport.** `ILight` is hwbinder/hidl exactly like `ISensors`, so it is one more local
   object on a connection the process already holds.

The cost is a misleading binary name. Lights are kept in their own translation units
(`Backlight.cpp`, `Lights.cpp`) so the halves stay separable if the hook ever changes.

## The wire format was disassembled, not remembered

`BnHwLight::_hidl_setLight` in the image's own `/vendor/lib64/android.hardware.light@2.0.so`
(not stripped, symbols exported):

```
Parcel::enforceInterface("android.hardware.light@2.0::ILight")
Parcel::readInt32(&type)                    <- Type is int32
Parcel::readBuffer(0x14, &handle, &ptr)     <- sizeof(LightState) == 20
...
writeToParcel(Status::ok(), reply)          <- HIDL status header
Parcel::writeInt32(status)                  <- the Status return value
```

The `0x14` is the whole point of looking. 20 bytes across five fields means all three enums
(`Flash`, `Brightness`, and `Type`) are **32-bit**, which is exactly the detail that is easy to
get wrong from memory and which would silently misalign every field after `color`:

| offset | field | type |
|---|---|---|
| 0 | `color` | `uint32_t`, `0xFFvvvvvv` |
| 4 | `flashMode` | `Flash : int32_t` |
| 8 | `flashOnMs` | `int32_t` |
| 12 | `flashOffMs` | `int32_t` |
| 16 | `brightnessMode` | `Brightness : int32_t` |

`Lights.cpp` carries a `static_assert(sizeof(LightState) == 20)` so this cannot rot quietly.
Transaction codes are `setLight = 1`, `getSupportedTypes = 2` — HIDL numbers from 1 in `.hal`
declaration order.

## The name race, and why the `interface` line had to go

Both the guest stub and our daemon register `ILight/default`, and `addService()` overwrites, so the
last registration wins. **We always lose without intervention**: `container_manager.py` starts
`waydroid-sensord` *before* `lxc-start`, so the guest stub is guaranteed to register second.

The fix is the idiom [34-wifi-second-radio.md](34-wifi-second-radio.md) paid for with `wificond`:
an overlay `.rc` that execs `/system/bin/true`, `oneshot`, `disabled`. One thing is different here
and it matters — the stock light `.rc` has a line `wificond.rc` did not:

```
interface android.hardware.light@2.0::ILight default
```

That line is precisely how init knows which service to start on demand when a client waits for a
HIDL name, and on-demand start is exactly what defeated the first `wificond` attempt. So it is
**dropped**, not kept. Three guards work together: `/system/bin/true` (a toybox symlink, verified
present) can never reach `addService()`; `oneshot` stops init respawning it on a 5 s backoff;
`disabled` keeps it out of `class hal`.

Payload: `artifacts/overlay/vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc`,
staged by `artifacts/overlay/install.sh brightness`. Stock kept alongside as `.orig`.

## The mapping

Android sends `color = 0xFF vv vv vv` with `vv` its 0..255 brightness; the standard
`(77·R + 150·G + 29·B) >> 8` reduction returns `vv` exactly for grey, which is all
`LightsService` ever sends.

Default curve is **linear in PWM duty**, deliberately. `intel_backlight` is `type raw`, so duty is
linear in luminance and perception is not — a gamma near 2.2 would track perceived brightness
better and make the bottom half of the slider more useful. Linear is the default anyway because it
is the map whose behaviour can be predicted from the numbers, and the right exponent is a matter
of taste on a specific panel. `gamma=` in `/var/lib/waydroid/backlight.conf` changes it and
**reloads live** on mtime change — which matters here, because restarting the daemon means
restarting the container, which drops the kiosk to the SDDM greeter and needs someone at the
machine.

Config lives in `/var/lib/waydroid` and not `/etc` for the SELinux reason above: `waydroid_t`
writes that directory routinely.

Two deliberate edge cases:

- **`v == 0` is passed straight through as raw 0**, blanking the panel. That is correct and it is
  an improvement: [27-android-power-button.md](27-android-power-button.md) sampled a full 40 s
  Android sleep and found `backlight=937/937` throughout — Android "asleep" today is black pixels
  at *full* backlight, because cage has no output-power IPC and nothing called logind.
- **`RestoreInitial()` on clean exit.** If the daemon dies while Android has the panel dimmed,
  nothing on the host is left that could brighten it again. Verified accidentally and then
  deliberately: killing the daemon at raw 51 put the panel back to 937.

Nothing else writes this file — confirmed, not assumed, from the docs/27 sampling above.

## Verification

Registration, after the daemon took the name:

```
DM,FC ? android.hardware.light@2.0::ILight/default    N/A   N/A
DM,FC ? android.hardware.sensors@1.0::ISensors/default N/A   N/A
```

`PID N/A` twice is the signature of a host-served HAL — the process is outside the container's PID
namespace. Before the swap that row read `85`, the guest stub.

Panel responds, and the mapping is exact:

| Android float | int sent | panel raw | expected |
|---|---|---|---|
| 0.2 | 51 | 191 | 187 |
| 0.25 | 64 | 235 | 235 |
| 0.5 | 128 | 470 | 470 |
| (dim) | 14 | 51 | 51 |

The daemon also tracks Android's **ramp animation** step by step, which is the clearest single
piece of evidence that this is a live path and not a one-shot write:

```
brightness 17/255 -> raw 62/937
brightness 16/255 -> raw 59/937
brightness 15/255 -> raw 55/937
brightness 14/255 -> raw 51/937
```

`bin/brightness-test.sh` automates this. The sensors half is unaffected — `--selftest` still
reports `SELFTEST PASSED`.

## The trap that wasted the most time here

**A run where every level reads the same low value is a dimmed display, not a broken daemon.**

Android pins the panel at `mScreenBrightnessDimConfig=0.05` — int 14, raw 51 — the moment display
policy goes to `DIM`, and ignores the brightness setting entirely while it is there. On this
machine `mUserActivityTimeoutOverrideFromWindowManager=10000` sets that timer to **10 seconds**,
overriding the 30-minute `screen_off_timeout` setting; that override is characteristic of a lock
screen being up. Injected `input keyevent`s did not reliably reset it.

Ten seconds is shorter than the test loop, because each `waydroid shell` invocation costs seconds
of its own. Measurements therefore have to set brightness and poke activity in the *same*
invocation, and `bin/brightness-test.sh` reports a dimmed measurement as **SKIPPED**, exiting 2
(inconclusive) rather than 1 (failed). It also cross-checks the last `setLight` the daemon logged
against the panel, which validates the mapping regardless of display policy.

## Android leaving is not the same as this daemon exiting

**2026-09-09, found the hard way.** Android was rebooted from inside the guest. The Waydroid
session stopped, SDDM's greeter came back — and the screen stayed black. The panel read
`brightness 0` with `bl_power 0`: powered, rendering, and completely dark. The machine was
recoverable only by ssh from another host, which is exactly the recovery a kiosk user does not
have.

`RestoreInitial()` existed and was correct. It was simply never reached.

The daemon **deliberately outlives the container**. `app_sm_presence_handler()` keeps it alive when
the guest's service manager disappears, so it can re-register when a new one appears — that is what
makes a container restart cheap. It also means stopping a Waydroid session never signals the
daemon, so the `RestoreInitial()` on the exit path in `main()`, guarded by a comment that correctly
explains why it must exist, does not run. The process was still alive as pid 137858 long after,
holding nothing but a dark panel.

Two things were wrong, and both are fixed:

- **The restore was hooked to the wrong event.** It now also runs from the service-manager-death
  branch of the presence handler, which is the event that actually occurs. The exit path is kept,
  and both now log which one fired and why.
- **The restore had no floor.** `mInitialRaw` is whatever the panel read when the daemon started,
  so a daemon that started while the screen was dark would "restore" to dark and leave the machine
  exactly as unusable as it found it. `RECOVER_FLOOR_PERCENT` (10%, ~94 raw here) is now the
  dimmest the panel may be left when Android stops owning it. This is **not** `mMinPercent`, which
  floors a non-zero request from a *live* Android and is deliberately allowed to be much dimmer:
  Android asking for 0 while it is still running is still honoured.

It also compares the target against the panel rather than against `mLastRaw`, because the recovery
case is precisely the one where something else — a rescue ssh, logind, the greeter — may have moved
it since we last wrote.

### What was considered and rejected

An `ExecStopPost=` drop-in on `waydroid-container.service`, as a safety net for a daemon that is
killed rather than signalled. It does not work for this fault, and
[`artifacts/shutdown/graceful-shutdown.conf`](../artifacts/shutdown/graceful-shutdown.conf) already
records why: session-driven stops — logout, `waydroid session stop`, Android powering itself off —
never reach that unit's `ExecStop`. It is the wrong hook, and shipping it would have looked like
cover while providing none.

**Residual risk, accepted.** If the daemon is `SIGKILL`ed after Android has dimmed the panel and
before the session ends, nothing restores it. That window is narrow — a dead daemon is not serving
`ILight`, so it cannot be what dimmed the panel except in a tight race — and every other available
hook either fires in the wrong place or runs unprivileged and cannot write sysfs.

## Still open

- ~~**Deployment is not durable yet.**~~ **Done, and it uncovered a second fault that this
  document got wrong.** The overlay `.rc` was deployed on 2026-09-09 and the container restarted,
  so the stub is neutered for good and `ILight` is ours automatically. But the hand-swap this
  entry treated as a mere deployment shortcut was **load-bearing**: a hand-started daemon runs as
  `unconfined_t`, while `container_manager.py` spawns it as `waydroid_t`, and `waydroid_t` is
  denied `write` on `sysfs_t` under a `dontaudit` rule. So the slider never worked from a
  properly-spawned daemon and could not have — every `setLight` returned `Status::UNKNOWN` from
  an `EACCES` on `open()`. Benefit 2 above ("Root, so the backlight is a plain sysfs write") is
  **false as stated**: SELinux denies the domain, not the user. Fixed with a private type for the
  one attribute plus a udev rule to apply it; see
  [42-backlight-selinux.md](42-backlight-selinux.md) and `artifacts/backlight/install.sh`.
- **The default curve is untuned.** Linear is honest, not necessarily pleasant. Try `gamma=1.8`
  or `2.2` and judge by eye; it reloads live.
- ~~**Screen-off blanking is untested.**~~ **Observed, and it bit.** Android does send 0 and the
  panel does blank, where docs/27 found it stuck at full. It was observed by blanking at Android's
  shutdown and staying that way — see the section above. Whether Android also sends 0 on an
  ordinary idle screen-off, as distinct from shutdown, is still unconfirmed.
- **Keyboard backlight: none exists.** `/sys/class/leds` holds only capslock, numlock, scrolllock,
  `hda::mute` and the two radio LEDs, so `Type::KEYBOARD` and the notification types are declined
  rather than silently accepted.
- **No ALS means no auto-brightness, permanently.** If it is ever wanted, the only real ambient
  signal on this machine is the front camera's mean luma; that would be a separate host-side
  daemon feeding a synthetic `TYPE_LIGHT` sensor, and it costs the camera and some power.
