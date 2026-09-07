# The sensor hub does not always survive suspend

Found and mitigated 2026-09-07, immediately after the accelerometer sign fix in
[docs/18](18-sensor-axes.md). Two presses of the power button suspended the machine twice in four
seconds, and the ITE8350 came back only half alive: the accelerometer stopped publishing while
still answering reads, so Android was fed one frozen sample forever and pinned the display to the
rotation that sample implied.

**Every app was upside down again — the exact symptom docs/18 had just fixed, from an unrelated
cause.** That is the trap worth remembering: a frozen accelerometer and a sign-inverted
accelerometer look identical from Android.

## What happened

```
21:23:05  kernel: PM: suspend entry (s2idle)     <- power button
21:23:07  kernel: PM: suspend exit
21:23:09  kernel: PM: suspend entry (s2idle)     <- power button again, 4 s later
21:23:11  kernel: PM: suspend exit
21:31:47  kernel: i2c_hid_acpi i2c-ITE8350:00: failed to set a report to device: -121
```

`-121` is `EREMOTEIO`. The freeze was **selective**, which is what made it confusing:

| node | after resume |
|---|---|
| `accel_3d` | **frozen** |
| `dev_rotation` | **frozen** |
| `incli_3d` | **frozen** |
| `gyro_3d` | live |
| `magn_3d` | live |

The accelerometer sat at exactly `x=3, y=1039, z=-54` across every sample for minutes, unchanged
by physically moving the machine.

### It is not every suspend

Nine suspend cycles happened that boot. Only the rapid pair broke it:

| cycles | outcome |
|---|---|
| 17:20, 17:21, 17:46, 18:22, 18:23 (single s2idle) | survived |
| 19:30 → 20:04 (33-minute s2idle) | logged `-121` on resume, **self-healed** — sensors verified good at 20:49 |
| 20:22 (deep) | survived |
| **21:23:05 + 21:23:09 (two s2idle, 4 s apart)** | **wedged** |

So `-121` on resume is common and usually self-healing. Do **not** reprobe reflexively on every
wake; the recovery hook below checks for staleness first. Whether every rapid double-suspend
wedges it is not established — it was observed once.

## Why nothing downstream could detect it

The reads **succeed**. They just return the same numbers forever. `waydroid-sensord` has no way to
tell a still machine from a dead hub on a single read, and Android has no way to tell a frozen
sensor from a genuinely motionless device. The only detector is time: a live accelerometer jitters
by an LSB or two even sitting on a desk, so identical readings across a 3-second window mean the
hub has stopped publishing. That is the test both recovery scripts use.

## What does not fix it

**Rewriting `in_*_sampling_frequency`.** This is the gentle, non-disruptive lever — it makes the
driver re-issue the report to the hub. It **revived `dev_rotation`** but never the accelerometer:

```
accel_3d      STILL FROZEN   3 1039 -54
dev_rotation  LIVE           -117180 0 5039060 8632810
```

It fails even when a genuinely different value is written (10 → 20 → 10, confirmed applied by
reading the attribute back), so this is not the driver skipping a no-op write. The accelerometer's
report is wedged at the hub.

## What does fix it

Reprobing the I²C HID device:

```bash
echo i2c-ITE8350:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/unbind
sleep 2
echo i2c-ITE8350:00 | sudo tee /sys/bus/i2c/drivers/i2c_hid_acpi/bind
```

**This is safe.** Only `HID-SENSOR-*` function nodes sit behind `i2c-ITE8350:00` — there are no
input devices, so the touchscreen and keyboard are unaffected. Verified with
`ls -d /sys/devices/.../i2c-ITE8350:00/0018:*/*/`, which lists seven `HID-SENSOR-*.auto` nodes and
nothing else.

## The trap the reprobe sets: renumbering

A reprobe destroys and recreates every `iio:deviceN`, and **does not necessarily hand back the
same numbers**. The first reprobe after boot moved `dev_rotation` from `device1` to `device4`
while leaving the other four in place, because the boot-time probe order and the reprobe order
differ. Subsequent reprobes are index-stable, so this bites exactly once per boot — on the first
recovery, which is the only time it matters.

`waydroid-sensord` resolved its paths once at startup and cached them. After the renumber it was
reading `in_rot_quaternion_raw` from a node that had become the gyroscope, every read failed,
`PollOnce` silently skipped the sensor, and Android kept reporting the last value it ever saw. The
only cure was restarting the daemon — and since `container_manager.py` owns its lifetime, that
meant restarting the container *and* the session, closing every running app.

**Fixed in `SensorIIO`.** The name→path scan was extracted into `ResolveNode()`, and `ReadSensor()`
now calls it again when a read fails, rate-limited to once every two seconds:

```
accelerometer    -> iio:device1 (accel_3d)
WARNING: accelerometer: node moved from /sys/bus/iio/devices/iio:device0,
         recovered without a restart
```

A stale path can never silently return the *wrong* sensor's data, because every sensor's attribute
names are unique to its type — `in_accel_*`, `in_anglvel_*`, `in_magn_*`, `in_rot_*`, `in_incli_*`.
A path pointing at the wrong node always fails to read, which is exactly what triggers
re-resolution.

Note this cannot detect the wedge itself: those reads *succeed*. It only makes the cure cheap.

## Automatic recovery

Two files, both in [artifacts/sensor-hub/](../artifacts/sensor-hub):

- **`/usr/local/bin/ite8350-resume-check`** — waits 8 s for the hub to recover unaided, tests the
  accelerometer for staleness over 3 s, and reprobes only if it is stuck. Logs to the journal
  under tag `ite8350-resume`.
- **`/etc/systemd/system/ite8350-sleep.service`** — ordered `Before=sleep.target`, so its `ExecStop`
  runs on resume, where it starts the check with `--no-block`. The check takes about 11 s, so
  running it inline would add that to every resume; this way resume is not delayed at all.
- **`/etc/systemd/system/ite8350-resume-check.service`** — wraps the script, and can be run on
  demand: `systemctl start ite8350-resume-check`.

> ### Correction, 2026-09-07: this was a `system-sleep` hook, and it never ran
>
> Until 2026-09-07 the second file was **`/etc/systemd/system-sleep/ite8350`**, on the stated
> assumption that "`/usr` is read-only on this rpm-ostree host, so the hook lives in `/etc/systemd/
> system-sleep`, which systemd searches alongside `/usr/lib/systemd/system-sleep`."
>
> **That assumption is false on this host.** systemd 259 has only one hook directory compiled in,
> `/usr/lib/systemd/system-sleep`, which is empty here and read-only. Measured: the previous boot
> had **nine suspends and zero hook runs**. Every journal appearance of `ite8350-resume-check` came
> from the manual test one second after the script was installed. So the safety net described in
> this note was never actually deployed — for its entire first day.
>
> Converted to the two units above and verified on a real suspend, where it immediately earned its
> keep: `accelerometer stale after resume -- reprobing i2c-ITE8350:00`, then `accelerometer
> recovered at /sys/bus/iio/devices/iio:device0`. **The wedge is real and it fired on the first
> cycle the check was alive for** — and again on the second, a lid close/open at 18:32. Two for
> two, which sits oddly with the "intermittent" framing above; see the note in
> [27](27-android-power-button.md) on whether that is the hub degrading or the detector
> false-positiving on a motionless machine. It also retroactively explains the loose end in
> [25](25-waydroid-in-cage.md), where the accelerometer returned bit-identical values after a
> suspend and was charitably read as a filtered sensor sitting still.
>
> Note the units are in `/etc/systemd/system`, not under `/usr/local`: `/usr/local` is
> `/var/usrlocal`, which SELinux labels `lib_t`, and `init_t` may not *start* a service whose unit
> file is `lib_t` — the first attempt failed exactly that way. Full account in
> [27](27-android-power-button.md).

Installed by [artifacts/sensor-hub/install.sh](../artifacts/sensor-hub/install.sh), which also
removes the dead hook if it finds one. No layering, no reboot.

For manual use there is [`bin/sensor-hub-reset.sh`](../bin/sensor-hub-reset.sh): `--check` reports
staleness and changes nothing, bare reprobes, `--restart` also restarts the container and session
if the indices moved (which the daemon fix now makes unnecessary).

## Verification

- **Forced renumber with the daemon running.** Unbinding `hid_sensor_accel_3d` and
  `hid_sensor_gyro_3d`, then binding them back in the opposite order, moved `accel_3d` from
  `device0` to `device1` deterministically. The daemon logged the re-resolution above, **pid
  166010 was unchanged**, and Android kept receiving live events — newest event `wall=21:48:05.541`
  against a host clock of `21:48:05`, values changing, `connections=2`. Before this change that
  renumber would have frozen the accelerometer permanently.
- **Reprobe with the daemon running**, indices unchanged: sensors recovered, no restart.
- **The hook** returns immediately and its detached check logged
  `accelerometer live after resume, nothing to do`.
- `--selftest` passed against live hardware before the new binary was installed.

## Not established

- **The hook has not been exercised against a real suspend-induced wedge.** Reproducing it needs
  the fault to recur, which took two suspends four seconds apart and has happened once. The
  staleness check and the reprobe have both been tested individually; what is untested is the
  three of them firing together on a genuine resume.
- **Whether the wedge is specific to rapid double-suspend**, or that was coincidence.
- **The root cause in the driver or firmware.** This is a mitigation, not a fix. Worth reporting
  upstream if it recurs with a reliable trigger.
