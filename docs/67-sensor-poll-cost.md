# What waydroid-sensord was spending its CPU on

**Status: fixed, packaged and verified on bigtab01. `1.0.3-1` measured on 2026-10-15: 1.9% of a
core down to 0.92%**, with `bin/sensors-test.sh` reporting ALL PASS end to end on three consecutive
runs and comparing four sensors rather than three.

The daemon polled every sensor at a flat 20 Hz regardless of what Android asked for, and kept
polling with nothing subscribed. Both are fixed. A third change shipped in `1.0.2` — pacing polls
from the hub's advertised `sampling_frequency` — **was wrong, and is reverted in `1.0.3`**; the
measurement that disproves it is in *The mistake* below, and it is the most useful thing in this
document.

The question that started it: the daemon shows up near the top of `top` and never leaves. Was it
being polled continuously, and could that be cheaper?

Yes to both. Just not for all the reasons the first pass claimed.

## What it cost before

Measured on pid 61313 with **only the accelerometer subscribed** (three sysfs attributes):

| thread | ticks / 10 s |
|---|---|
| `waydroid-sensor` (main) | 15 |
| `hwbinder#1` | 2 |
| `hwbinder#2` | 2 |
| **total** | **19 = 1.9% of a core** |

`utime +5, stime +15` over the same window, so **75% of it was system time** — kernel time inside
sysfs reads, which is where the hub's i2c round trips land. 102 voluntary context switches per
second, about five per 50 ms tick: one per blocking attribute read.

## Reason one: `batch()` was a no-op

`ISensors::batch(handle, samplingPeriodNs, maxReportLatencyNs)` is how Android states the rate it
wants. `service.cpp` read all three values into throwaway variables and returned `RESULT_OK`:

```c
gint32 tmp = 0;
gint64 tmp64 = 0;
gbinder_reader_read_int32(&reader, &tmp);
gbinder_reader_read_int64(&reader, &tmp64);
gbinder_reader_read_int64(&reader, &tmp64);   /* both discarded */
```

So the requested rate never reached the reader. Every client got a flat 50 ms: the framework's
66.67 ms (`SENSOR_DELAY_UI`) request was over-served by a third, and a client asking
`SENSOR_DELAY_NORMAL` (200 ms) — the common case — by four times.

## Reason two: the timer never stopped

`g_timeout_add` was called once in the `Sensors` constructor and nothing ever removed it, so the
daemon woke 20 times a second for the life of the session whether or not anything was subscribed.

## Three smaller ones

- **Each axis is its own HID round trip.** Measured: one attribute 1.15 ms of wall time, three
  attributes 3.52 ms. Reading `x`, `y`, `z` is three separate `GET_REPORT` transactions over i2c to
  assemble what the hub sends as one report.
- **`dev_rotation` was read twice.** ORIENTATION and ROTATION_VECTOR are declared against the same
  node *and the same attribute*, but `ReadSensorAt` ran per sensor, so with both enabled that was
  two round trips for one quaternion.
- **The duplicate-event guard was dead code.** `Sensors.cpp` skipped an event when
  `ts == last_TimeStamp`, but `ReadSensorAt` stamped every read with `now_boottime_ns()`, so the
  two values differed by construction and the branch was never taken.

## The mistake

`1.0.2` added a third term to the poll period: the hub's own report interval, read from
`in_<type>_sampling_frequency`. It reads 10 Hz for `accel_3d` and `magn_3d`, 20 Hz for `gyro_3d`,
31.2 Hz for `dev_rotation`. The reasoning was that polling faster than the hub publishes buys an
i2c round trip and returns the bytes you already have — so clamping to it was free.

**It is not free, and the premise is false.** Polling `in_accel_*_raw` and counting how often a
sample is byte-identical to the previous one, against an attribute that claims 10 Hz:

| poll rate | duplicates | median step | total range | still? |
|---|---|---|---|---|
| 40 Hz | **2.1%** | 2.0 LSB | 19.8 LSB | STILL |
| 20 Hz | **0.0%** | 3.0 LSB | 12.8 LSB | STILL |
| 10 Hz | 0.0% | 3.0 LSB | 11.8 LSB | STILL |

A `_raw` read issues an explicit HID `GET_REPORT` and the hub answers with a **freshly converted
sample**. It is not serving a 10 Hz pipeline, so there are no stale bytes to avoid.

The stillness columns are load-bearing. A moving accelerometer changes every sample whatever the
refresh rate, so the first version of this test proved nothing. LSB is 4 raw counts
([docs/14](14-sensors.md)), and a median step of 2–3 LSB with a total range under 20 is the
documented noise floor — the machine was sitting still, and the fresh samples are real.

So `1.0.2` did not reclaim wasted work on the accelerometer, it **under-sampled** it: 19.3 fresh
samples a second became 9.9. And feeding the same figure into the advertised `minDelay` was worse,
because it told Android that 10 Hz *was* the ceiling — so the framework stopped asking for the
66.67 ms it actually wanted and settled for 100 ms. The CPU figure improved partly because the
daemon was doing less of its job.

What the attribute really governs is the **unsolicited-report** path, which is exactly what
buffered mode showed on `magn_3d`: 10.3 Hz delivered against 10 Hz advertised. `1.0.3` still reads
and logs it for that reason, and for a future push-mode reader, but it influences no poll period.

## What changed

All in `sensors/`, keeping upstream's libgbinder server intact:

1. **Per-sensor poll deadlines.** The shared glib timer runs at the shortest interval any enabled
   sensor wants; each sensor has its own deadline.
2. **A two-term rate policy.** `RecomputeInterval` takes the slower of the configured `poll_hz`
   ceiling and Android's `batch()` request. Both terms can only slow a sensor down from the
   ceiling, so it cannot do more work than the old fixed rate did.
3. **`batch()` honoured.** `maxReportLatencyNs` is still ignored, and honestly so: the sensor list
   advertises `fifoMaxEventCount = 0`, so this HAL has promised not to batch.
4. **One read per node per tick**, shared between sensors matching on path, attributes and scale.
5. **Repeat suppression with a 1 s heartbeat.** Holding the timestamp when the values do not move
   is also what makes the existing `ts != last_TimeStamp` guard function. Worth keeping but nearly
   inert in pull mode, for the reason the table above gives: repeats are 0–2% of reads, not half.
   The heartbeat exists because these sensors are advertised `SENSOR_FLAG_CONTINUOUS_MODE` and must
   not fall silent just because the machine is sitting still.
6. **Held fds and `pread`** instead of `fopen`/`fclose` per attribute per tick.

## The numbers

Per-attribute read cost, measured with a tight loop on `accel_3d`:

| access pattern | wall | CPU |
|---|---|---|
| `open`+`read`+`close`, 1 attr | 1.164 ms | 0.097 ms |
| `open`+`read`+`close`, 3 attrs | 3.517 ms | 0.250 ms |
| held fd + `pread`, 1 attr | 1.134 ms | **0.058 ms** |
| held fds + `pread`, 3 attrs | 3.396 ms | **0.129 ms** |

Wall time is unchanged because it is the i2c round trip, not the syscall — this removes host CPU,
not hub latency.

Daemon CPU, every sample with **only the accelerometer subscribed** — which after a clean boot
means `FaceDownDetector` plus `WindowOrientationListener`, so the comparison is like for like:

| | ticks / 10 s | % of a core | accel served at | |
|---|---|---|---|---|
| before | 19 | 1.9% | 50 ms flat | Android wanted 66.67 |
| `1.0.2` | 5–6 | 0.5–0.6% | 100 ms | **overstated** — clamped, see *The mistake* |
| `1.0.3` | 9–10 | **0.92%** | 66.67 ms | what Android asked for |

**2.1x less CPU**, measured over six consecutive 10 s slices on the packaged binary after a clean
boot. The `1.0.2` figure is left in deliberately rather than deleted: it is what under-sampling
buys, and the gap between it and `1.0.3` is the cost of doing the job properly.

Two independent checks that the correction took: the advertised `maxRate` is back to `20.00Hz` from
the `10.00Hz` `1.0.2` claimed, and Android's selected period is back to `66.67 ms` from the
`100.00 ms` it had been talked down to. The log shows the policy per request —
`batch accelerometer: asked 66 ms, polling 66 ms` honoured,
`batch gyroscope: asked 5 ms, polling 50 ms` clamped to the ceiling.

The remaining 0.92% is explicable rather than mysterious: 50 ms to 66.67 ms is 0.75x the polls, and
held fds roughly halve the CPU of each one, which lands about where it lands.

## Honouring batch() broke the magnetometer check, legitimately

`bin/sensors-test.sh` compares Android's newest event against a host read and allows 5 µT. It
started failing at 5.096 µT, and the cause is worth recording because the test was not wrong
before and the daemon is not wrong now.

Android's newest event is as old as the poll period. That used to be a flat 50 ms for everything;
it is now whatever the subscriber asked for, and the only client that usually holds the
magnetometer is `com.perimeterx.mobile_sdk` — another bot-detection SDK — asking for **200 ms**.
How far the sensor itself moves over each window, 60 pairs each:

| gap | median | p90 | max | over 5 µT |
|---|---|---|---|---|
| 50 ms | 0.78 | 1.61 | **4.30 µT** | **0.0%** |
| 200 ms | 0.39 | 4.70 | **11.01 µT** | **8.3%** |

At 50 ms the magnetometer never moves 5 µT, so the tolerance was exactly calibrated to the old
behaviour. At 200 ms it exceeds it about one run in twelve. The sensor is mostly still and
occasionally steps a long way — it is the tail that breaks the check, not a drift.

The fix is to compare against a **bracket** of six host reads spanning 250 ms and accept if
Android's value matches any of them, which is what the test's own section header always claimed to
do ("bracket it with a host reading"). The 5 µT tolerance is deliberately **not** widened: the
faults this check exists to catch are nowhere near it — a wrong `in_magn_scale` is off by 1e4, and
a swapped or negated axis lands tens of µT away in a direction no recent sample matches. Asking
"is this a value the host produced in the last quarter second" tests the pipeline without encoding
one particular poll rate.

Three consecutive runs now pass, and the magnetometer is compared at all — earlier runs skipped it
with "no recent events", so this is more coverage than before, not less.

## Push mode works, and hysteresis is the gate

Every node has `scan_elements/`, `buffer/enable`, a chardev and its own pre-assigned trigger, so
the kernel can push complete scans instead of the daemon pulling each axis. Probed on `magn_3d`
because nothing was subscribed to it:

| `in_magn_hysteresis` | result |
|---|---|
| 50 µT (the default) | **2 scans in 6 s** — 0.3 Hz, effectively dead |
| 0 | **62 scans in 6.00 s = 10.3 Hz**, 60 wakeups, 0.096 ms CPU per sample |

The hub only sends an unsolicited report when the value moves past its change-sensitivity
threshold, and 50 µT is about the whole Earth field. That is why push looked broken while pull
worked.

The attraction is one report per sample instead of three `GET_REPORT` round trips, no timer,
hardware pacing, and a real hardware timestamp — `accel_3d` has `in_timestamp_en`, and a probe
confirmed it carries `CLOCK_REALTIME` nanoseconds, so `current_timestamp_clock` would need setting
to `boottime` to match what Android wants. **And the hysteresis caveat barely applies**: `gyro_3d`
and `dev_rotation` are already **0**, `accel_3d` is 0.02, and only `magn_3d` (50) and `incli_3d`
(2) are gated.

Honest accounting: in push mode the i2c work moves into the driver's context rather than vanishing,
so process CPU improves more than system-wide CPU does. The genuine system-wide win is the 3-to-1
reduction in i2c transactions per sample.

**Not implemented, and one probe is still unreliable.** A buffered read of `accel_3d` returned
plausible scan rates but physically impossible accelerations (`-571350 m/s²`), because the reader
discarded the remainder when a `read()` returned a partial scan and then stayed misaligned. The
timestamps decoded correctly, so the layout arithmetic is right; the buffering is not. No rate
figure from that probe should be trusted, and specifically it must not be read as evidence about
`accel_3d`'s push rate.

## Who actually keeps this awake

**Corrected 2026-10-14.** An earlier draft said a bundled Facebook ads SDK held the accelerometer
continuously. That was wrong, and reading the `+`/`-` registration log in `dumpsys sensorservice`
rather than a single snapshot of *Active sensors* is what showed it. The permanent subscribers are
both Android's own, exactly as [docs/14](14-sensors.md) predicted:

| subscriber | uid | sensor | pattern |
|---|---|---|---|
| `com.android.server.power.FaceDownDetector` | 1000 | accelerometer | **permanent** |
| `com.android.server.wm.WindowOrientationListener` | 1000 | accelerometer | **permanent** |
| `com.facebook.ads.redexgen.X.lp` (in `nl.ninetofive.nummi`) | 10197 | accel + gyro @ 200 ms | **~5 s burst at app start** |
| `com.google.android.location.collectionlib.SensorScanner` | 10094 | accel @ 100 ms | ~4 s burst every few minutes |
| `com.google.ccc.abuse.droidguard.events.b` | 10094 | rotation vector @ 50 ms, linear accel @ 100 ms | burst |

The Facebook SDK took the accelerometer and gyroscope for about five seconds and let go — twice
observed, `+ 16:51:13 / - 16:51:18` and `+ 23:04:56 / - 23:05:01`. That shape is a device-integrity
check rather than monitoring: a real accelerometer jitters by an LSB or two and an emulator's is
static or absent, so a few seconds of samples distinguishes them. Google's DroidGuard — the Play
Integrity attestation engine — does the same thing a few handles over, which is the clearest
evidence of what the pattern is for.

**Two consequences.** The steady-state cost is Android's, not an app's, so removing that game would
not change it. And because two framework listeners hold the accelerometer for the life of the
session, stopping the timer when idle will essentially never fire while a session is up — it earns
its place for the window between a session starting and the framework attaching, and as
correctness, not as a saving on this machine.

## Installing it, which is not one command

`rpm-ostree install ./waydroid-ext-sensord-1.0.3-1.x86_64.rpm` **fails outright** when an older
version is already a local package:

```
error: Could not depsolve transaction; 1 problem detected:
 Problem: cannot install both waydroid-ext-sensord-1.0.3-1.x86_64 from @commandline
          and waydroid-ext-sensord-1.0.2-1.x86_64 from @commandline
```

Both are `@commandline` requests and neither supersedes the other, so the replacement has to be one
transaction:

```bash
sudo rpm-ostree uninstall waydroid-ext-sensord \
     --install /tmp/waydroid-ext-sensord-1.0.3-1.x86_64.rpm
```

That form takes no `--apply-live`, so avoiding a reboot needs the standalone subcommand afterwards —
and `--allow-replacement`, because replacing a file is not the additive default:

```bash
sudo rpm-ostree apply-live --allow-replacement
```

**And that fails here, for a reason that has nothing to do with this package.** It updates `/usr`
and `/etc` and then dies running tmpfiles:

```
Updating /usr...done
Updating /etc...done
error: Running tmpfiles for /run and /var: Running systemd worker: exit status: 73
```

The cause is `/usr/lib/tmpfiles.d/var.conf:21`, a base-image file that declares `d /var/lib` a
second time. `systemd-tmpfiles` only warns and ignores the line, but it exits non-zero, and
rpm-ostree treats that as a failed transaction. The same warning is logged at **every boot** —
`22:12:34` on the boot before any of this was touched — so it is a standing Sericea quirk, not
something a package did.

The files do land (`rpm -q` reports the new version and the binary hashes correctly), but the
transaction is recorded as `InterruptedLiveCommit`, which is untidy rather than broken. **A reboot
clears it** and boots the staged deployment that already contains the package.

Finally, `sensord.mod`'s migration trap is real and bites in this exact flow: `/usr/local/bin`
precedes `/usr/bin` on `container_manager.py`'s `PATH=/usr/local/bin:/usr/bin`, so a by-hand build
left there keeps being started in preference to the package, silently. Delete it as part of
installing:

```bash
sudo rm -f /usr/local/bin/waydroid-sensord
```

Provenance is then checkable rather than assumed, which is the point of packaging it at all:

```
pid=1829  exe=/usr/bin/waydroid-sensord
md5=c8eefcdc8c104b9bfbafedabbf893ca2
rpm -qf: waydroid-ext-sensord-1.0.2-1.x86_64
```

## Gotchas

- **The daemon has moved into an RPM.** docs/14 still says `/usr/local/bin/waydroid-sensord`; it is
  now `waydroid-ext-sensord`, installed at `/usr/bin` and `/usr/sbin`, and `/usr` is read-only.
  `/usr/sbin` is not on `container_manager.py`'s PATH at all.
- **`in_*_sampling_frequency` has to be derived, not globbed.** `magn_3d` carries two of them —
  it exposes a heading field, so `in_magn_sampling_frequency` and `in_rot_sampling_frequency` sit
  side by side and only the first is the magnetometer's.
- **The runtime-PM window bounds how slowly a sensor may be polled.**
  `HID-SENSOR-200073.3.auto/power/autosuspend_delay_ms` is **3000**, and a sensor that powers down
  between polls gives a cold read — 150–300 ms, and garbage on the gyro. The advertised `maxDelay`
  of 1 s already sits inside that, and `RecomputeInterval` clamps to the same bound so the two
  cannot drift apart.
- **Closing a held fd from a binder thread is a real race.** `DisableSensorEvents` runs on an
  hwbinder thread while `PollOnce` may be inside a `pread` on those fds, and the dangerous outcome
  is not `EBADF` but a *recycled fd number*, where the read quietly succeeds against another file.
  Every path that drops fds now runs on the main thread; disable deliberately leaks three
  descriptors instead.
- **`EnableSensorEvents` publishes `enabled` last.** It is the flag `PollOnce` gates on, so every
  field that poll will read has to be in place before the gate opens.
- **Every boot renumbers the IIO nodes.** Three boots gave three different layouts, which settles
  docs/19's warning as a rule rather than an anecdote:

  | boot | device0 | device1 | device2 | device3 | device4 |
  |---|---|---|---|---|---|
  | 1 | `gyro_3d` | `accel_3d` | `incli_3d` | `dev_rotation` | `magn_3d` |
  | 2 | `magn_3d` | `dev_rotation` | `incli_3d` | `gyro_3d` | `accel_3d` |
  | 3 | `accel_3d` | `incli_3d` | `dev_rotation` | `gyro_3d` | `magn_3d` |

  The selftest passed across all three unchanged. Anything that caches an index is wrong by the
  next boot.
- **`waydroid session stop` still does not kill the daemon.** Confirmed again: the session went
  `STOPPED` with pid 1887 still in state `Sl`. It has to be killed by hand, after which it becomes
  the usual harmless zombie.
- **Stopping the session drops the kiosk to the greeter**, and with `[Autologin]` empty in
  `/etc/sddm.conf` that needs a physical login. `waydroid-cage-session` says so itself: "this
  script exits, so cage exits, so SDDM gets the greeter back."

## Hypotheses disproven along the way

| Hypothesis | Verdict |
|---|---|
| The daemon is busy because 20 Hz is simply expensive | partly — 20 Hz is more than most clients asked for, but the hardware serves it fine |
| **`in_<type>_sampling_frequency` is the rate past which a polled read returns stale bytes** | **wrong, and it shipped in 1.0.2 before being measured. It is the push rate; polled reads are answered on demand and are fresh at 20 Hz and 97.9% fresh at 40 Hz** |
| Android was asking for the rate it got | wrong — it asked for 66.67 ms and `batch()` discarded the request |
| The duplicate-timestamp guard was suppressing repeats | wrong — the timestamp was taken at read time, so it never matched. Fixing it mattered less than expected: repeats are 0–2% of reads |
| IIO buffered mode is unsupported on this hub | wrong — it works at the full 10 Hz; the change-sensitivity threshold was hiding it |
| The sysfs reads are most of the daemon's CPU | wrong — they are roughly a third of it; glib dispatch and binder round trips are the rest |
| Something the user runs keeps the accelerometer subscribed | wrong — it is Android itself: `FaceDownDetector` and `WindowOrientationListener`, both uid 1000 |
| A third-party ad SDK was polling sensors in the background | wrong — a ~5 s burst at app start, then released; an integrity check. Reading one *Active sensors* snapshot instead of the `+`/`-` log is what made it look continuous |
| `rpm-ostree apply-live` failing meant the install had not happened | wrong — `/usr` was already updated; the failure is a pre-existing duplicate line in the base image's `var.conf` |

## Not done, and what is unproven

- **The idle-timer path is not observed live.** Implemented and exercised by `--selftest`, but no
  zero-subscriber window occurs while a session is up, because two framework listeners hold the
  accelerometer. Code-verified only.
- **Buffered mode is not implemented**, and the `accel_3d` probe needs its partial-read bug fixed
  before its numbers mean anything. `magn_3d` is the only sensor where push mode has been shown to
  work at the advertised rate.
- **`dev_rotation` is polled at 50 ms** against a hub that pushes at 31.2 Hz. That is now simply
  the `poll_hz` ceiling rather than a deliberate clamp, and Android can ask for faster via
  `batch()` up to that ceiling.
- **Long-running stability is still unmeasured.** `~/sensord-stability.sh` on the host samples CPU
  and RSS every 10 minutes, but it was started with `setsid nohup` and does **not** survive a
  reboot, so it has to be relaunched to collect anything. The one sample taken before the reboot
  read RSS 4420 KB, matching docs/14's 4.4 MB — no growth, but over minutes, not days.
