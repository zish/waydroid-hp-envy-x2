# The accelerometer reported gravity, not acceleration

Fixed 2026-09-07. Turning auto-rotation on made nearly every app render upside down. The cause
was not the display, the panel's natural orientation, or the sensor hub's mounting: the ITE8350
reports the **gravity vector**, pointing down, where Android's accelerometer convention is
**proper acceleration**, pointing up. `waydroid-sensord` passed it through unchanged, so Android
was told the top of the screen was at the bottom.

One sign, in one function. The interesting part is why it survived four weeks of a sensors stack
that was otherwise carefully cross-checked — the daemon's own self-test had the same sign error
baked into it, so the check agreed with the bug instead of catching it.

## The symptom

`accelerometer_rotation` had just been switched from 0 to 1. With it on:

```
mSupportAutoRotation=true
mCurrentRotation=ROTATION_0
  mProposedRotation=2
  mPredictedRotation=2
mLandscapeRotation=ROTATION_0   mSeascapeRotation=ROTATION_180
mPortraitRotation=ROTATION_270  mUpsideDownRotation=ROTATION_90
```

`mProposedRotation=2` is ROTATION_180, which on this landscape panel is *seascape* — upside-down
landscape. Android's `WindowOrientationListener` reads the accelerometer and nothing else, so it
proposed a half turn while the machine sat in normal viewing pose.

### Why the launcher looked fine and everything else did not

`mLastOrientation=5` is `SCREEN_ORIENTATION_NOSENSOR`. That is the per-app compat override added
in `dadff71` to stop `org.fossify.home` pinning the display to portrait. It also, incidentally,
makes the launcher the one app on the system that *cannot* follow the sensor — so it stayed at
ROTATION_0 and looked correct while every unpinned app inverted. The launcher looking right was
a symptom of a different fix, not evidence that rotation worked.

## The measurement

Three poses, sampled straight off `/sys/bus/iio/devices/*/in_accel_*_raw` at 2.5 Hz and averaged
over the still segment of each. Against Android's axes — **+X right, +Y toward the top of the
screen, +Z out of the screen**, with a machine at rest reading +1 g along whichever axis points
at the sky:

| pose | n | hub reads (m/s²) | Android needs |
|---|---|---|---|
| flat on the desk, screen up | 38 | `+0.32, −0.04, −9.83` | `0, 0, +9.81` |
| upright, top edge up | 58 | `+0.13, −9.90, +0.06` | `0, +9.81, 0` |
| upright, right edge up | 251 | `−9.47, −0.04, −0.65` | `+9.81, 0, 0` |

Magnitudes were 9.84, 9.90 and 9.50 m/s² — all ~1 g, so the readings were never *wrong*, only
inverted. **Every axis is negated and none are swapped.**

## Why this is not a mounting rotation, and how that was nearly missed

The first two poses alone are consistent with the hub being mounted 180° about X — a real
possibility on a detachable, and the reason `SensorIIO` already carried an `axis_rotation` knob.
That reading was wrong, and the third pose is what kills it.

A transform that negates all three axes is `diag(−1, −1, −1)`, whose determinant is **−1**. That
is a reflection, and no rigid mounting of one right-handed frame inside another can produce one.
The panel frame and the hub frame are both right-handed, so they can differ only by a proper
rotation. A global negation is therefore not a frame relationship at all — it is a difference in
the sign convention of the quantity being reported.

This was almost mis-diagnosed the other way: taking poses 1 and 2 as a 180° roll about X, the
determinant argument was used to *predict* that pose 3 must read `+9.81` and to conclude the pose
had been performed mirrored. Repeating pose 3 with unambiguous instructions returned `−9.47`
again. The prediction was falsified, and the reflection was real — which meant the premise, that
this was a mounting problem, was what had to go.

**Ruled out, with the evidence:**

- **A mounting rotation of any kind.** Determinant −1; see above. `axis_rotation` cannot express
  it either, since it only rotates about Z and can never change the Z component.
- **The panel's natural orientation being wrong.** The launcher, pinned to NOSENSOR, rendered
  correctly at ROTATION_0, so ROTATION_0 *is* upright for this display.
- **A Waydroid display or `ro.sf.hwrotation` problem.** The base output is 1916×1027 and
  `mDisplayRotation=ROTATION_0` throughout; only the sensor-derived proposal was off.
- **The magnetometer and the fused quaternion.** Both verified correct, below.

## The independent witness

The hub publishes a fused quaternion (`dev_rotation`) computed in its own firmware, entirely
separately from the raw accelerometer. Rotating world-up into the device frame with it gives
`(0.007, 0.885, 0.463)`, while the raw accelerometer read `(0.011, −0.895, −0.446)` at the same
moment — **the same axis, opposite sign, agreeing to 1.5°**.

That measurement was already in [docs/14](14-sensors.md), recorded a month earlier as proof that
the quaternion component order was `x, y, z, w`. It was: the phrase "the same axis, opposite
sign" was written down, read as an expected property of the hub, and never questioned. It is in
fact the whole bug, stated plainly and filed under the wrong heading.

It also settles which of the two is wrong. A quaternion can only encode a proper rotation, so it
cannot be carrying a reflection; the quaternion is in Android's convention and the accelerometer
is not.

## Why the self-test passed anyway

`--selftest` cross-check 4 compares the quaternion's world-up against the accelerometer. It read:

```c
/* ... and should be the negative of the accelerometer's normalised reading. */
double dot = -(ux * ax + uy * ay + uz * az) / amag;
```

The check *required* the two to be anti-parallel. Written against the hardware as found, it
encoded the hub's convention as the expected one, so a correct accelerometer would have failed it
and the incorrect one passed. Every other check in the daemon is a genuine cross-check between
independent outputs; this one silently was not.

The sign is now dropped, so the check demands the two be parallel and is a real regression test
for the correction. The same trap was in `bin/sensors-test.sh`, which compared Android's value
against the raw IIO node with no sign flip — after the fix it scored a correct accelerometer as a
**19.4 m/s²** error. Both are corrected.

## The fix

`SensorIIO::GetAccelerometerEvent()` negates the vector on the way through. Nothing else changes:
the axes already line up, so `ApplyAxisRotation` stays at its default of 0°, and the quaternion,
orientation, gyroscope and magnetometer paths are untouched.

```c
double sgn = mAccelReportsGravity ? -1.0 : 1.0;
double vx = sgn * s.v[0], vy = sgn * s.v[1];
ApplyAxisRotation(vx, vy);
*z = (float)(sgn * s.v[2]);
```

`accel_reports_gravity` is a new `/etc/waydroid-sensors.conf` key, defaulting to **yes** — the
measured convention of this hub. It exists so a different hub can be settled without a rebuild,
matching how `poll_hz`, `axis_rotation`, `magn_scale` and `earth_field_ut` already work. No
config file is needed on bigtab01; the default is correct here and none exists.

Deployed by rebuilding on the dev box (`sensors/build.sh`) and installing to
`/usr/local/bin/waydroid-sensord`. No overlay files, no image changes, no layering, no reboot.
The previous binary is kept at `/var/tmp/waydroid-sensord.prev` on the host.

## Verification

Everything below is measured on the host, not inferred.

**Before installing anything** — `--selftest` needs no binder and no root, so the rebuilt binary
was run from `/tmp` against live hardware first:

```
accelerometer     -0.147   +8.993   +3.746 m/s^2  |a|=9.743  OK (~1 g)
quat vs accel   gravity directions differ by 2.94 deg        OK
azimuth vs hub  216.0 deg vs hub heading 213.2 deg  (2.8 apart)  OK
SELFTEST PASSED
```

Y and Z are positive for an upright, tilted-back machine, and check 4 passes *demanding
parallel*: the corrected accelerometer agrees with the hub's independently-fused quaternion to
2.94°. Two separate hardware outputs agreeing, not a self-consistent guess.

**After installing** — `mProposedRotation` and `mPredictedRotation` both went from `2` to `0`,
with `accelerometer_rotation` still 1. `bin/sensors-test.sh` reports ALL PASS:

```
android [-0.190 8.960 3.790]  host negated [-0.108 9.071 3.981]  |diff| = 0.236 m/s^2
PASS  accelerometer agrees (tolerance 1.0 m/s^2)
android [0.190 0.520 0.780 0.300]  host [0.160 0.520 0.797 0.258]  angle = 3.65 deg
PASS  rotation vector agrees (tolerance 20 deg)
```

**Confirmed on the machine.** The owner verified the display rotating correctly through all four
orientations, with apps upright in each — the one check that cannot be made over SSH, since
`dumpsys` reports the rotation Android *decided on*, not what is actually drawn on the panel.

**The magnetometer is not affected.** Because the daemon's self-validation turned out to be
compromised, the other sensors' conventions could not simply be assumed. Feeding the corrected
accelerometer and the *raw* magnetometer into Android's own `getRotationMatrix()` /
`getOrientation()` gives azimuth **218.7°** against the hub's independent tilt-compensated
heading of **229.8°** — 11.1° apart. A sign inversion would appear as ~180°; 11° is consistent
with the known hard-iron bias from the keyboard's attachment magnets ([docs/14](14-sensors.md)).
Azimuth is scale-invariant, so the `magn_scale` question does not enter into it.

**The gyroscope is not affected either.** Sampled `dev_rotation` and `gyro_3d` together at ~40 Hz
while the machine was rotated by hand, and compared the gyro against the rate implied by the
quaternion, `2·vec(conj(q₁)⊗q₂)/Δt`. Pooling only samples above 29°/s where a single axis carries
more than 70% of the rotation:

| axis | n | sign agrees |
|---|---|---|
| X | 66 | 75.8% |
| Y | 38 | 76.3% |
| **Z** | **153** | **96.1%** |

Z is measured directly and decisively. X and Y follow from the same determinant argument that
solved the accelerometer: a three-axis gyroscope reports in one frame with one handedness
convention, so the only physically available alternatives are *all three correct* or *all three
inverted* — a single inverted axis would make the frame a reflection. Z at 96% rules out the
global inversion, and 76% is far from both chance (50%) and inversion (~25%).

The residual noise on X and Y is explained rather than excused: the hub's quaternion fuses the
accelerometer to constrain tilt, so it is damped in pitch and roll and its derivative is a poor
instantaneous reference there. Yaw carries no such constraint and tracks the gyro closely, which
is exactly the pattern observed. A first attempt was inconclusive (mean cosine −0.017) purely
because the machine only saw 4.5°/s; the check needs a brisk sweep, above roughly 30°/s.

## Not established

- **Whether other HID sensor hubs share this convention.** The default is set from one machine.
- **Gravity and Linear Acceleration were also wrong** before this fix, since Android synthesises
  both from the accelerometer. They should now be correct, but have not been exercised directly.

## Reverting

Restore the previous binary and restart the container:

```bash
sudo install -m 0755 /var/tmp/waydroid-sensord.prev /usr/local/bin/waydroid-sensord
sudo systemctl restart waydroid-container
```

Note that restarting the container **stops the session and does not bring it back**. Restart it
as the session user:

```bash
XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus \
  nohup waydroid session start >/tmp/waydroid-session.log 2>&1 &
```

Or, without touching the binary at all, put `accel_reports_gravity = no` in
`/etc/waydroid-sensors.conf` and restart.
