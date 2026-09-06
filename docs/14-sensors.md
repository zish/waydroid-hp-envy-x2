# Goal 2: sensors — done

Done 2026-09-06. Android now sees the accelerometer, gyroscope, magnetometer, orientation and
rotation vector, all reading live values from the ITE8350 HID sensor hub, and Android synthesises
eight more sensor types on top of them. Verified with [`bin/sensors-test.sh`](../bin/sensors-test.sh),
which compares Android's reported values against the host's IIO nodes numerically rather than
looking for an absence of errors.

Vibration is **not** part of this and remains blocked a layer lower — see
[docs/06](06-next-session.md); Linux still exposes no interface to the motor.

## One-paragraph summary

Waydroid's design already had a place for this: `container_manager.py` starts a host-side daemon
called `waydroid-sensord` if one is on `PATH`, and the guest's sensors HAL is a 10 KB stub that
takes itself out of the way when that daemon exists. Nothing had to be reverse-engineered to make
them cooperate. What was missing is that upstream's daemon
([droidian/waydroid-sensors](https://github.com/droidian/waydroid-sensors)) reads **sensorfw**,
Sailfish's Qt/D-Bus sensor daemon, which is not packaged for Fedora. So we kept upstream's
libgbinder `ISensors@1.0` server — the fiddly part, and already correct — and **replaced its data
source with a direct Linux IIO reader**. That drops Qt, D-Bus and sensorfw entirely and leaves only
glib and libgbinder, both of which bigtab01 already has because Waydroid itself depends on them.
The result is one 650 KB binary in `/usr/local/bin`, no overlay files, no image changes, no
rpm-ostree layering and no reboot.

## Why a host daemon and not a guest HAL

The images ship `/vendor/bin/hw/android.hardware.sensors@1.0-service.waydroid`. It is 10,240 bytes
and stripped, but its `main()` disassembles to exactly this:

```c
if (!property_get_bool("waydroid.stub_sensors_hal", false))
    return 0;                                   /* registers nothing */
sp<ISensors> svc = new SensorsStub();
configureRpcThreadpool(1, true);
if (svc->registerAsService("default") != OK)
    ALOGE("Cannot register Sensors HAL service.");
else {
    ALOGI("Waydroid Sensors HAL service ready.");
    joinRpcThreadpool();
}
```

and `tools/helpers/images.py:152` sets that property under one condition:

```python
if which("waydroid-sensord") is None:
    props.append("waydroid.stub_sensors_hal=1")
```

So **installing a binary named `waydroid-sensord` onto `PATH` is self-installing**: waydroid stops
writing the property into `waydroid.prop`, the guest stub then returns at its first line, and
`container_manager.py:170` starts our daemon instead. `/dev/hwbinder` is bind-mounted into the
container (`lxc/waydroid/config_nodes:14`), so host and guest share one hwbinder domain and the
guest's `hwservicemanager` sees a service registered by a host process.

Replacing the guest stub instead would have meant building against AOSP's generated HIDL headers
for `ISensors@1.0` — `hidl-gen` output that is not checked in anywhere and that the NDK does not
ship. The host-daemon route needs neither.

### What is upstream's and what is ours

| File | Origin |
|---|---|
| `hybrisbindertypes.h` | upstream, verbatim (Jolla, LGPL header) |
| `service.cpp` | upstream, plus a single-instance lock, `--selftest`, `/dev/hwbinder` default and two empty-vector fixes |
| `Sensors.cpp`, `Sensors.h` | upstream's structure, rewritten for our five sensors |
| `SensorIIO.{h,cpp}` | **ours** — replaces upstream's `SensorFW.cpp` + the whole `sensorfw-core/` tree |

A useful confirmation that upstream's wire layout is right: `hybrisbindertypes.h` asserts
`sizeof(sensor_t) == 112`, and the shipped stub's own `getSensorsList` destructor loop walks its
array with a stride of `0x70` — 112. Two independent implementations agreeing on the ABI.

## What the hardware actually is

`lsiio` shows five devices, but there are only **three transducers**. Two are computed in the hub's
firmware, and that is worth knowing because it means the expensive part of a sensors HAL — the
fusion filter — is already done for us.

| platform device | HID usage | driver | IIO node | |
|---|---|---|---|---|
| `HID-SENSOR-200073` | Motion: Accelerometer 3D | `hid_sensor_accel_3d` | `accel_3d` | physical |
| `HID-SENSOR-200076` | Motion: Gyrometer 3D | `hid_sensor_gyro_3d` | `gyro_3d` | physical |
| `HID-SENSOR-200083` | Orientation: Compass 3D | `hid_sensor_magn_3d` | `magn_3d` | physical |
| `HID-SENSOR-200086` | Orientation: Inclinometer 3D | `hid_sensor_incl_3d` | `incli_3d` | **derived** |
| `HID-SENSOR-20008a` | Orientation: Device Orientation | `hid_sensor_rotation` | `dev_rotation` | **fused** |

### Proof that `incli_3d` is derived

Its raw unit is tenths of a degree, which makes the arithmetic checkable against the other nodes:

- `in_incli_x_raw = 629` → 62.9°. From the accelerometer alone, `atan2(902, 449)` = **63.55°**.
- `in_incli_y_raw = -2` → −0.2°, and the accelerometer's X axis reads 0.108 of 9.88 m/s² — both
  are zero to within a degree.
- `in_incli_z_raw` is not from the accelerometer at all. It is the magnetometer's heading,
  mirrored. Four consecutive readings:

  | `in_rot_from_north_magnetic_tilt_comp_raw` | `in_incli_z_raw` | sum |
  |---|---|---|
  | 101.9° | 258.0° | 359.9 |
  | 102.1° | 257.8° | 359.9 |
  | 101.6° | 258.2° | 359.8 |
  | 102.1° | 257.8° | 359.9 |

  `incli_z = 360° − heading`, four times running.

### Proof that `dev_rotation` is a real fused quaternion

`in_rot_quaternion_raw × 1e-7` = `(0.3164, −0.4102, −0.6719, 0.5273)`, whose norm is **0.99892**.
Rotating world-up into the device frame with it gives `(0.007, 0.885, 0.463)`; the accelerometer's
normalised gravity vector at the same moment was `(0.011, −0.895, −0.446)` — the same axis, opposite
sign, agreeing to **1.5°**. The component order is therefore `x, y, z, w`; reading it as `w, x, y, z`
misses by 12°.

### Which is why ORIENTATION is derived from the quaternion, not from `incli_3d`

`incli_3d` does not use Android's convention, so mapping it would be guesswork. Applying Android's
own `SensorManager.getOrientation()` formula to the hub's quaternion instead is exact, and it
reproduces the hub's two *independent* firmware outputs:

| | from the quaternion | hub's own value | apart |
|---|---|---|---|
| azimuth | 102.93° | 102.0° (tilt-compensated compass heading) | 0.93° |
| pitch | −62.24° | 62.9° (inclinometer X) | 0.66° |
| roll | −0.92° | −0.2° (inclinometer Y) | 0.72° |

## Scale factors, and the one the kernel gets wrong

**`in_magn_scale` is wrong by a factor of 1e4 and must not be believed.** It reads
`1.000000000`, which would put Earth's magnetic field at 536,070 gauss.

The truth is in the HID report descriptor, decoded with the
[`bin/hid-decode.py`](../bin/hid-decode.py) written for this:

```
Motion: Accelerometer 3D      Acceleration X Axis    rid=1 size=16 unit=0x1a(G)                  expo=-3
Motion: Gyrometer 3D          Angular Velocity X     rid=2 size=32 unit=0x15(DEGREES_PER_SECOND) expo=-5
Orientation: Compass 3D       Compass Heading        rid=3 size=16 unit=0x14(DEGREES)            expo=-1
Orientation: Compass 3D       Magnetic Flux X Axis   rid=3 size=32 unit=0x1c(GAUSS)              expo=-3
Orientation: Inclinometer 3D  Inclinometer X Axis    rid=4 size=16 unit=0x14(DEGREES)            expo=-1
Orientation: Device Orient.   Quaternion             rid=5 size=32 unit=0x00(NOT_SPECIFIED)      expo=-7
Orientation: Device Orient.   Rotation Matrix        rid=5 size=16 unit=0x00(NOT_SPECIFIED)      expo=-3
```

| node | raw → SI | sysfs `_scale` |
|---|---|---|
| `accel_3d` | × 9.80665e-3 → m/s² | correct |
| `gyro_3d` | × 1.7453293e-7 → rad/s | correct |
| `magn_3d` flux | **× 1e-4 → µT** | **wrong (1.0)** |
| `magn_3d` heading | × 0.1 → degrees | wrong (1.0) |
| `incli_3d` | × 0.1 → degrees | correct, but in radians |
| `dev_rotation` | × 1e-7 → unit quaternion | correct |

### Why the kernel gets it wrong

It is *not* the `-EINVAL` path in `hid_sensor_format_scale()` that leaves the caller's `1/0`
untouched — that was the first guess and it is wrong. The lookup **succeeds**. The kernel's
`unit_conversion[]` table in `drivers/iio/common/hid-sensors/hid-sensor-attributes.c` carries
`scale_val0 = 1000` for `{HID_USAGE_SENSOR_COMPASS_3D, HID_USAGE_SENSOR_UNITS_GAUSS}`, and with the
descriptor's unit exponent of −3 that computes `1000 × 10⁻³` = **exactly 1.0**, which is what sysfs
reports. The table assumes a hub reporting in gauss; this one reports in **milligauss**. So the
physical value is `raw × 10⁻³ mG = raw × 10⁻⁶ G = raw × 10⁻⁴ µT`.

Cross-check: `|B|` then comes out at **53.5 µT**, textbook for Earth's field. Believing sysfs gives
536,070.

The accelerometer and gyroscope entries in the same table are right, which is why only the
magnetometer needed correcting: unit `0x1a` (G) × 10⁻³ → `in_accel_scale = 0.00980665`, and unit
`0x15` (deg/s) × 10⁻⁵ → `in_anglvel_scale = 1.74e-7`, both matching sysfs exactly.

## The gyroscope needs five seconds, every time it goes idle

The `hid-sensor-*` drivers power the sensor up for each `_raw` read and let runtime PM suspend it
again, so **every read after an idle gap is a cold read**. For the gyroscope that matters enormously.
Measured on a stationary machine with [`bin/iio-probe.py`](../bin/iio-probe.py):

| t after resume | \|ω\| | |
|---|---|---|
| 0.16 s | **1015 °/s** | first read: garbage |
| 0.27–0.37 s | 210 → 139 °/s | decaying |
| 0.5–3 s | ~7.6 °/s | persistent bias, mostly on Z |
| ≥ 5.5 s | 0.3–1.0 °/s | settled, 1–3 LSB |

Because the hub fuses the gyroscope into `incli_3d` and `dev_rotation`, the transient poisons those
too — which is why an early probe showed the "fused" outputs as noisy while the accelerometer
beside them was rock steady. With a 6 s warm-up the gyro's LSB quantisation (22381) reappears and
its bias falls to ~0.2 °/s.

The daemon handles this by polling continuously while a sensor is enabled — so it never goes cold
again — and by discarding events during a per-sensor warm-up window: 200 ms for the accelerometer
and magnetometer (both clean from cold), 500 ms for the quaternion (its cold read is already a
valid unit quaternion), and **5000 ms for the gyroscope**.

## Measured device characteristics

Used for the `resolution` field each sensor advertises to Android, so those are measurements rather
than guesses:

| sensor | LSB (raw) | resolution | settled noise |
|---|---|---|---|
| accelerometer | 4 | 0.0392 m/s² | ±0.16 m/s² |
| gyroscope | 22381 | 0.003906 rad/s | ±1.3 °/s p-p |
| magnetometer | 3907 | 0.3907 µT | \|B\| = 53.5-64 µT |
| rotation vector | 10 | 1e-6 | — |

`|B|` drifts between about 53 and 64 µT depending on where the machine is sitting. The upper end is
above Earth's field, which is expected rather than alarming: this is a detachable whose keyboard
attaches **magnetically**, so the dock's magnets bias the reading. It is a hardware fact, not a
scale error — the scale is fixed by the descriptor and the axes still behave.

Reading three sysfs attributes over the hub's i2c link costs **3–7 ms**, and a cold read 150–300 ms.
That is why the daemon polls at 20 Hz by default and advertises `minDelay` to match: promising a
faster rate would be a lie.

## What Android sees

```
Total 5 h/w sensors, 5 running 0 disabled clients:
0000000000) ITE8350 3-axis Accelerometer   | type: android.sensor.accelerometer(1)
0x00000001) ITE8350 3-axis Gyroscope       | type: android.sensor.gyroscope(4)
0x00000002) ITE8350 3-axis Magnetometer    | type: android.sensor.magnetic_field(2)
0x00000003) ITE8350 Orientation (from fused quaternion) | type: android.sensor.orientation(3)
0x00000004) ITE8350 Rotation Vector        | type: android.sensor.rotation_vector(11)
```

plus **eight** more that `SensorService` synthesises from them at no extra cost: Gravity, Linear
Acceleration, Game Rotation Vector, GeoMag Rotation Vector, Corrected Gyroscope, a fused Rotation
Vector, Gyroscope Bias (debug) and Orientation.

Real framework clients attach immediately — `com.android.server.wm.WindowOrientationListener` and
`com.android.server.power.FaceDownDetector` both subscribe to the accelerometer on their own.

## Verification

[`bin/sensors-test.sh`](../bin/sensors-test.sh), run on bigtab01. Latest run: **ALL PASS**.

```
### 1. is the host daemon live?
  PASS  waydroid-sensord running, pid 39335: waydroid-sensord /dev/hwbinder
  PASS  exactly one live instance
### 2. did the guest stub stand down?
  PASS  waydroid.stub_sensors_hal unset
  PASS  vendor.sensors-hal-1-0 is stopped (it exits at line 1)
### 3. what Android registered            [all five handles, right types]
### 4. daemon self-test against live hardware
    accelerometer     +0.108   -8.581   -4.629 m/s^2  |a|=9.750   OK (~1 g)
    magnetometer      +26.95   -26.95   +48.83 uT     |B|=61.94   OK (Earth field)
    rotation vector  +0.3203  -0.3984  -0.6719  +0.5352  |q|=0.99958  OK (unit)
    quat vs accel   gravity directions differ by 1.76 deg          OK
    azimuth vs hub  103.1 deg vs hub heading 103.0 deg (0.1 apart) OK
### 5. do Android's values match the host's IIO nodes?
        android [0.190 -8.650 -4.510]  host [0.108 -8.649 -4.403]  |diff| = 0.135 m/s^2
        android [0.320 -0.410 -0.670 0.530]  host [0.305 -0.410 -0.691 0.512]  angle = 0.00 deg
```

`waydroid-sensord --selftest` runs the cross-checks alone, needs no container, and is safe to run
while the real daemon is serving Android — it only reads sysfs and never touches binder.

## Sensor Info: a viewer app, and what it was for

Android only streams a sensor while something is subscribed to it, so several sensors were
registered but never actually exercised. [`sensor-app/`](../sensor-app) is a ~350-line Kotlin app
that subscribes to **every** sensor `SensorManager` reports and shows live values, which both gives
a direct read-out and closes that verification gap.

It depends on nothing but the platform — no AndroidX, no Compose, no Gradle. The UI is built
programmatically, so `sensor-app/build.sh` is four tool invocations:

```
aapt2 compile res/          -> compiled resources
aapt2 link + manifest       -> an APK with resources but no code
kotlinc src/                -> JVM .class files
d8 .class + kotlin-stdlib   -> classes.dex
zipalign, apksigner         -> a signed, installable APK
```

`--deps` fetches the SDK (platform 33, build-tools 34.0.0) and Kotlin 2.0.21 into `build/android`.
Note that Debian trixie's default JDK is 25, which Android's build-tools reject; the script pins
JDK 21.

For rotation-vector sensors it prints the quaternion *and* the azimuth/pitch/roll an app would
derive from it, which is what makes a wrong component order or a wrong world frame obvious at a
glance.

### Installing into Waydroid — three traps

- **`waydroid app install` fails silently.** No output, no non-zero exit, no installed package. Use
  `pm install` inside the container, which reports real errors.
- **The container cannot see the host's `/tmp`.** Its `/data/local/tmp` is the host's
  `~/.local/share/waydroid/data/local/tmp`, owned `2000:2000`, so the copy needs `sudo` plus a
  `chown` or `pm` cannot open the file.
- **Play Protect rejects a self-signed APK**, logging `Finsky: VerifyApps: … verdict 9`. The build
  script turns `package_verifier_enable` off for the install and restores it afterwards.

And a fourth, already in AGENTS.md but easy to forget: `waydroid shell` always exits non-zero with a
cosmetic `ERROR: [Errno 13] Permission denied: 1`, so a remote install script must **not** use
`set -e` — it silently skipped the cleanup the first time.

### An app can starve itself of the sensors it is watching

First run showed every sensor at **0.3–0.4 Hz** while `dumpsys sensorservice` showed the
accelerometer being delivered at exactly 50 ms intervals. The HAL was fine; the app was the
bottleneck. A 100 ms timer re-set the text of ~40 `TextView`s, and `setText` invalidates and
re-lays-out, which on a fanless Core M-5Y70 rendering through Waydroid consumed the whole main
looper — leaving nothing to drain the sensor event queue.

Refreshing at 3 Hz, skipping hidden cards, and not re-setting a string that has not changed took it
from 1 event/s to **179 events/s, 19.8 Hz per sensor** — the full rate the HAL advertises. Worth
remembering before blaming a HAL for a low rate seen inside an app.

## Traps hit — do not repeat

- **Root is not enough on this host.** `container_manager.py` runs confined as
  `system_u:system_r:waydroid_t:s0`, and a daemon it spawns inherits that domain. `/run` is
  `var_run_t`, so `open("/run/waydroid-sensord.pid")` fails with `EACCES` even as root, while
  `/var/lib/waydroid` is `waydroid_data_t` and works. Running the same binary by hand under `sudo`
  succeeds, because an ssh login is `unconfined_t` — so this fails exactly one way round and looks
  like a phantom. **Anything the container manager spawns must write to `/var/lib/waydroid`.**
- **Do not let a hygiene mechanism refuse to start the service.** The first version of the
  single-instance lock aborted when it could not take the lock, and the SELinux denial above then
  stopped the daemon starting at all. It now fails open.
- **`waydroid session stop` does not reliably kill `waydroid-sensord`.** Its cleanup sits inside a
  `try:` that swallows every exception (`container_manager.py:271`), and the kill is written as
  `kill -9 $pid` where `pid` is the *whole* output of `pidof` — so once two instances exist, it
  becomes `kill -9 "A B"` and can never work again. The leak is self-perpetuating. Our daemon takes
  an exclusive `flock` at startup and SIGTERMs whoever holds it.
- **Replaced instances linger as zombies.** Waydroid's `background()` helper Popens the daemon and
  never `wait()`s on it, so an exited instance stays in state `Z` for the life of the
  waydroid-container service. Harmless — a zombie polls nothing — but it means `pidof` returns
  several pids. Count live instances with
  `ps -eo pid,stat,comm | awk '$3=="waydroid-sensor" && $2 !~ /Z/'`.
- **Detecting this daemon is fiddly three ways.** `waydroid-sensord` is 16 characters, so
  `/proc/PID/comm` truncates to `waydroid-sensor` and plain `pgrep` misses it; `pgrep -f` matches
  any shell whose command line merely mentions the name, including the test script itself; and
  zombies must be excluded. All three bit this session.
- **IIO device indices are not stable across boots.** `accel_3d` was `iio:device4` in the previous
  session's notes and `iio:device0` in this one. Always match on the node's `name` attribute.
- **The first read of any HID sensor after an idle gap is slow and may be garbage** — 150–300 ms,
  and up to 1015 °/s on the gyroscope. See the warm-up section above.
- **A naive HID descriptor grep misreads the usage IDs.** Usages appear as `0x5475`, `0x4475`,
  `0x1475` and so on: the top nibble is a HID Sensor *usage modifier* (4 = Accuracy, 5 = Resolution,
  1 = Change Sensitivity), not part of the data-field id. Only modifier 0 is the field itself.

## Hypotheses disproven along the way

| Hypothesis | Verdict |
|---|---|
| The guest stub HAL must be rebuilt or patched | wrong — installing the host daemon makes it stand down by itself, no overlay needed |
| `waydroid-sensord` would need sensorfw, so this needs a layered install | wrong — only its *data source* did; the binder half has no such dependency |
| The five IIO nodes are five sensors | wrong — three transducers, two firmware-fused outputs |
| `in_magn_scale = 1.0` means the kernel's unit lookup failed | wrong — the lookup succeeds; the table entry is simply wrong for a milligauss hub |
| The gyroscope is noisy or failing | wrong — it is settling; after 5 s it sits within 1–3 LSB of zero |
| The noisy fused outputs indicate a bad fusion | wrong — they inherit the gyroscope's warm-up transient |
| `pidof waydroid-sensord` fails because of the 15-char `comm` limit | wrong — `pidof` finds it fine; the kill fails for two other reasons |
| The daemon crashed under the container manager | wrong — it exited cleanly after an SELinux `EACCES` it reported in waydroid's own log |
| The quaternion is `(w, x, y, z)` | wrong — it is `(x, y, z, w)`; the other order misses gravity by 12° |

## State left on bigtab01

| Item | State |
|---|---|
| **`/usr/local/bin/waydroid-sensord`** | **the fix.** 663 KB, mode `0755`, root:root. `/usr/local` → `/var/usrlocal`, so no rpm-ostree layering and no reboot. **Delete to revert** |
| `/var/lib/waydroid/waydroid-sensord.pid` | the single-instance lock. Recreated on demand; safe to delete |
| `waydroid.prop` | regenerated by waydroid itself without `waydroid.stub_sensors_hal=1`. Reverts on its own once the daemon is gone |
| `/etc/waydroid-sensors.conf` | **not installed.** Optional; a documented sample is in [artifacts/sensors/](../artifacts/sensors/) |
| vendor overlay | **untouched.** This goal added no overlay files at all |
| Waydroid images | untouched |
| zombie `waydroid-sensor` processes | one per session restart, until the waydroid-container service restarts. Harmless |

Reverting is deleting one file and restarting the session: waydroid then puts
`waydroid.stub_sensors_hal=1` back and the guest stub resumes reporting no sensors.

## Not done, and what is unproven

- ~~The magnetometer has not been exercised end to end through Android.~~ **Closed** — see the
  Sensor Info app below. With a subscriber attached, `bin/sensors-test.sh` compared it directly:
  Android `[28.52, -28.13, 49.62]` against the host's `[28.12, -28.12, 45.31]` µT. Four of four
  comparable sensors now pass end to end.
- **The sensor axes have not been reconciled with the display's natural orientation.** The values
  are provably correct in the *sensor's* frame, but whether that frame matches what Android expects
  for this panel is a physical question that cannot be settled remotely. It currently does not
  matter: auto-rotation is off (`accelerometer_rotation = 0`) and Waydroid renders into a fixed
  956×1027 Wayland window, so there is no panel orientation to track. It would matter for games,
  compass apps or AR. `SensorIIO` has an `axis_rotation` knob (0/90/180/270 about Z) readable from
  `/etc/waydroid-sensors.conf` so it can be corrected without a rebuild.
- **Long-running stability is unmeasured.** The daemon has been up for tens of minutes, not days.
  RSS was 4.4 MB.
- **Rates above 20 Hz are untested.** `minDelay` advertises 50 ms, derived from the 3–7 ms cost of
  a sysfs read; Android has not been asked for anything faster.
- **The hub also reports a rotation matrix** (HID usage `0x0482`, nine values, exponent −3) that
  the Linux driver does not expose at all. Not needed — the quaternion is equivalent — but it is
  there if a future need appears.
