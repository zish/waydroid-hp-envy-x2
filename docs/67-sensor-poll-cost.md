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

Now `sensor_device_retune_timer()` arms, re-arms or stops it from `activate()` and `batch()`, and
`waydroid-sensord --idle-probe` measures that it does — see below.

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

## Push mode works on every node that matters, and is still not worth adopting

Every node has `scan_elements/`, `buffer/enable`, a chardev and its own pre-assigned trigger, so
the kernel can push complete scans instead of the daemon pulling each axis.
`bin/iio-push-probe.py` measures that per node, restores everything it touches, and cross-checks
each buffered sample against an `in_*_raw` read of the same node:

| node | pushes as shipped | needs a write? | cross-check |
|---|---|---|---|
| `accel_3d` | **44.66 Hz** | no | `_raw` agrees exactly; norm 10.096 m/s² |
| `dev_rotation` | **30.99 Hz** | no | `_raw` agrees exactly; quaternion norm 1.000 |
| `gyro_3d` | **20.16 Hz** | no | norm 0.154 rad/s, machine at rest |
| `incli_3d` | 0.33 Hz | zero `in_incli_hysteresis` → **9.66 Hz** | `_raw` agrees exactly |
| `magn_3d` | 0.00 Hz | contested — see below | `_raw` agrees exactly |

The three nodes Android actually reads — `accel_3d` for the accelerometer, `dev_rotation` for
orientation and the rotation vector, `gyro_3d` for the gyroscope — all push **faster than the rate
Android asks for**, with no sysfs write of any kind. Hysteresis gates only the two nodes nothing
subscribes to, so the caveat in the previous revision of this section was the wrong way round:
push mode is not blocked on hysteresis for anything that matters.

Two nodes do not push at their advertised rate. `accel_3d` says
`in_accel_sampling_frequency = 10` and pushes at 44.66 Hz, with its own hardware timestamp
independently reporting 44.78 Hz. `incli_3d`, `gyro_3d` and `dev_rotation` all match their
advertised figure to within 2%.

**And it is still not worth adopting**, on these numbers:

- The probe spends **0.150 ms of CPU per `accel_3d` scan**, and the hub pushes 44.66 of them a
  second: 6.7 ms/s, or **0.67% of a core, for the accelerometer alone**. The whole polled daemon
  costs 0.92% of a core today for its entire subscription set.
- That 0.150 ms is Python's cost per scan, not C's, so a real implementation would be cheaper by
  an unmeasured margin. But the most it can save is the 0.92% that is there in total, and the
  work is a rewrite of the read path on a daily-driver machine.
- The push rate is not ours to choose. 44.66 Hz is three times the 15 Hz Android asked for, and
  the only lever is `in_accel_sampling_frequency` — which already says 10 and is plainly not
  governing, and which is written through the same kernel function that oopses (below).

So: proven, measured, and deliberately not adopted. `bin/iio-push-probe.py` is committed so the
decision can be re-measured rather than re-argued.

### The `-571350 m/s²` was a misparse, not a partial read

The previous revision blamed a partial-read bug. That was wrong, and the channel type says so:

    accel_3d      in_accel_x_type        = le:s16/32>>0
    magn_3d       in_magn_x_type         = le:s32/32>>0
    dev_rotation  in_rot_quaternion_type = le:s32/32X4>>0

`s16/32` is **16 real bits in a 32-bit container**, and the old probe unpacked all 32. The
impossible reading decodes cleanly once that is fixed: raw `0xFC870013`, whose low 16 bits are 19
— a real 0.19 m/s² sample — with `0xFC87` sitting above it, which is not sign extension, because
the value was negative. `magn_3d` is `s32/32`, which is exactly why its numbers looked right while
`accel_3d`'s did not. That asymmetry was the evidence, and I had read it as a buffering bug.

The IIO rule is: take `storage_bits` from the buffer, shift right by the shift, mask to
`real_bits`, and only then sign-extend. `X4` is a repeat count — one channel, four values — and
`int("32X4")` is why the old probe crashed outright on `dev_rotation`.

Partial reads are real, but only on `dev_rotation`, and only as a symptom of the next item.

### `dev_rotation` delivers 32-byte scans where the alignment rules predict 24

It declares `in_timestamp` as a channel **and** has the IIO core append its own scan timestamp, so
every scan carries the timestamp twice: quaternion at 0..15, timestamp at 16..23, the same
timestamp again at 24..31. Confirmed from a hex dump, and by the gcd of the `read()` sizes being
32 while the computed layout said 24.

Slicing 32-byte scans as 24 is what produced "41.99 Hz" — exactly 4/3 of the real 31.2 Hz — and a
quaternion norm of 170 instead of 1. This kernel (7.2.8-200.fc44) exposes no
`buffer/bytes_per_datum`, so the probe now **measures** the scan size: every `read()` returns a
whole number of scans, so the size divides their gcd, and the smallest divisor that still holds
every channel pins it down.

### Probe one node per run

`dev_rotation` measured 30.99 Hz on its own and **0.00 Hz** when probed immediately after
`accel_3d` in the same run — one scan during calibration, then nothing for six seconds. Tearing
down one node's buffer appears to stop the hub reporting on another for a while. The mechanism was
not established. A 2 s settle delay makes it less likely but is not a fix, so the probe warns on a
multi-node run and only the first node's figure should be trusted.

I first read that 0.00 Hz as the kernel oops below having wedged the node. Re-probing it alone
returned 30.99 Hz and a quaternion norm of exactly 1.000, so that was wrong too.

### `magn_3d`'s push rate is unresolved

An earlier probe measured 10.3 Hz with `in_magn_hysteresis` zeroed. Re-run today, the same
zeroing gave 0.17 Hz, and as shipped it gives 0.00–0.17 Hz whether or not the tilt-compensated
heading channel is in the scan. The discrepancy is unexplained. It was not pursued, because
settling it needs more writes through the function that oopses, and because `magn_3d` is only
subscribed in 200 ms bursts by a bot-detection SDK. Push mode on the compass should be treated as
unproven in both directions.

## Writing a hysteresis attribute can oops the kernel

Five times, working the above out:

    Oops: divide error: 0000 [#1] SMP PTI
    CPU: 0 UID: 0 PID: 19455 Comm: python3 Tainted: G I  7.2.8-200.fc44.x86_64
    RIP: 0010:convert_to_vtf_format+0x78/0xa0 [hid_sensor_iio_common]
    Call Trace:
      hid_sensor_write_raw_hyst_value+0x4b/0xe0 [hid_sensor_iio_common]
      iio_write_channel_info+0x148/0x200 [industrialio]
      kernfs_fop_write_iter / vfs_write / ksys_write

The faulting instruction is `41 f7 fe`, `idiv r14d`, with `R14 = 0`. `convert_to_vtf_format`
divides by `pow_10()` of the channel's unit exponent, and `pow_10()` is a loop multiplying a
32-bit `int` by ten — so for a large enough exponent it overflows to exactly 0 and the divide
faults. It is reachable from a root sysfs write, it kills the writing task, and the machine
otherwise survives: all five nodes still read correctly afterwards, the daemon never noticed, and
`sensors-test.sh` still passes.

On bigtab01 it is `dev_rotation`'s `in_rot_hysteresis` that does it, **including writing back the
value it already had** — which is what my restore block did, four runs in a row, each one dying
mid-restore and taking its own log with it. Two of those deaths I first wrote off as ssh dropping
on the hotspot link. Writes to `in_magn_hysteresis`, `in_anglvel_hysteresis` and
`in_incli_hysteresis` all completed normally, so it is per-channel, not hub-wide.

`bin/iio-push-probe.py` now:

- treats zeroing hysteresis as opt-in (`--zero-hysteresis`), so a default run writes no
  sensitivity value at all;
- restores only the attributes it actually changed, never one it merely read;
- keeps `("dev_rotation", "in_rot_hysteresis")` on a refusal list that no flag overrides.

`hid_sensor_write_samp_freq_value` goes through the same conversion with the *poll* interval's
unit exponent rather than the sensitivity's, so `in_*_sampling_frequency` writes are suspect by
the same argument. Untested on purpose: this is the owner's daily driver and five oopses were
enough. That also removes the only lever that could have throttled push mode's rate, which is part
of why it is not being adopted.

## Proving the idle path, without a zero-subscriber window

This is the change that was hardest to demonstrate, and it stayed "code-verified only" for a
while. An idle daemon is supposed to have no timer at all, but no idle window ever occurs on a
running system: `FaceDownDetector` and `WindowOrientationListener` hold the accelerometer for the
life of the session. Stopping them is not an option, and a session restart only produces a window
during Android's boot, before anything is watching.

The way through is that `activate()` and `batch()` are ordinary methods and need no binder at all
— the same reason `--selftest` works. `waydroid-sensord --idle-probe` constructs the real
`Sensors`, drives those methods directly, runs the real glib main loop between steps, and reports
the timer state, the number of times `PollOnce` actually ran, and the CPU each phase cost. It
registers no service and takes no lock, so it does not disturb the running daemon.

Two counters were added for it: `SensorIIO::Polls()` and `Samples()`. A CPU figure alone cannot
settle this, because 0.00% and 0.4% of a core both read as "small" — the claim is that the count
is *exactly zero*, and that needs counting.

Run on bigtab01, 4 s per phase:

| phase | timer | polls (want) | samples | CPU |
|---|---|---|---|---|
| nothing subscribed | **off** | **0** (0) | 0 | 0.2 ms = **0.00% of a core** |
| accelerometer on | 50 ms | 79 (80) | 66 | 25.3 ms = 0.63% |
| accelerometer asks 200 ms | **200 ms** | 19 (20) | 16 | 6.7 ms = 0.17% |
| magnetometer asks 66 ms too | **66 ms** | 57 (61) | 71 | 17.1 ms = 0.43% |
| magnetometer released | **200 ms** | 19 (20) | 18 | 6.0 ms = 0.15% |
| accelerometer released | **off** | **0** (0) | 0 | 0.1 ms = **0.00%** |

So: no subscribers means no timer and no polls, `batch()` re-arms the timer at the rate asked for,
and with two sensors subscribed the period follows the shorter of the two and goes back when the
faster one leaves. The probe exits non-zero if any of that stops being true.

Two details in that table are worth reading. In the second phase there are fewer samples (66) than
polls (79) — that is the repeat suppression dropping values the hub never refreshed. In the fourth
there are more samples (71) than polls (57), because one tick can produce an event for each of two
subscribed sensors.

## Measuring stability across reboots

The three claims that only time can test are that CPU stays near 0.9% of a core, that holding the
IIO descriptors open does not leak them, and that RSS does not creep. The descriptors are the one
worth watching: `DisableSensorEvents` deliberately does not close them, so they are only dropped
on the main thread on a failed read or a reprobe, and that is correct but it is also exactly the
shape of a leak.

Nothing was collecting any of it. The sampler was a `while :; do ...; sleep 600; done` started by
hand with `setsid nohup`, so after every reboot it silently gathered nothing until someone
remembered to restart it — and this machine gets rebooted often. Nine lines had accumulated in a
day.

[`artifacts/sensord-stability/`](../artifacts/sensord-stability/) replaces it with a one-shot
sampler and a systemd timer, which survives a reboot because that is what timers do. It also
records more than the original did:

| field | why |
|---|---|
| `interval=` | CPU since the previous sample. `life=` is the average since process start, which is dominated by early history and cannot show a drift |
| `fds=` | the leak check. Baseline **25** |
| `ver=` / `exe=` | a hand-built binary in `/usr/local/bin` silently shadows the packaged one, and a log spanning an upgrade is otherwise uninterpretable |
| `threads=`, `vsz=` | cheap, and a thread leak would be as quiet as a descriptor leak |

A `?` in any field means the lookup failed, usually for want of root. It does not mean zero, and
`ver=?` deliberately does not read `ver=unpackaged` — the first version of the sampler conflated
them, which would have been a lie about the host's state.

It then collected unattended, which was the whole point. **39 samples over 6.9 hours** on 1.0.3,
one process throughout (pid 1833):

| | result |
|---|---|
| descriptors | **25 in all 39 samples.** No leak |
| threads | **5 in all 39 samples.** No leak |
| RSS | 4252 KB → 4228 KB. First ten mean 4252, last ten mean **4228** — it went *down* 24 KB |
| interval CPU, n=38 | min 0.758%, p25 0.909%, **median 0.909%**, p75 0.952%, max 1.111%, mean 0.918% |

So the headline figure holds: a median of **0.909% of a core** over seven hours, against the 0.92%
measured when the work was done, with a worst observed ten-minute window of 1.111%. The lifetime
average converged to 0.915%, which is the same number from the other direction.

The descriptor column is the one that was worth waiting for. Those 25 include the held IIO
descriptors that `DisableSensorEvents` deliberately never closes, and `WindowOrientationListener`
and `FaceDownDetector` subscribe and unsubscribe across the session — so if that design leaked, it
had seven hours and every rotation of the machine in which to show it. It did not move once.

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
| IIO buffered mode is unsupported on this hub | wrong — it works on all five nodes, and the three Android reads push faster than it asks, with no sysfs write at all |
| The `accel_3d` buffered probe was broken by partial reads | wrong — it read `le:s16/32>>0` as a full 32 bits. `-571350 m/s²` was raw `0xFC870013`, a real 0.19 m/s² sample with non-sign-extension junk above it |
| Hysteresis is the gate on push mode generally | wrong — it gates only `incli_3d` and `magn_3d`, the two nodes nothing subscribes to |
| A kernel oops had wedged `dev_rotation`'s push path | wrong — probed on its own it still pushes 30.99 Hz with a quaternion norm of 1.000. Probing it second in a run is what returns nothing |
| Two probe runs died because ssh dropped on the hotspot | wrong — both were killed by a kernel divide-by-zero in `convert_to_vtf_format`, taking their buffered output with them |
| The sysfs reads are most of the daemon's CPU | wrong — they are roughly a third of it; glib dispatch and binder round trips are the rest |
| Something the user runs keeps the accelerometer subscribed | wrong — it is Android itself: `FaceDownDetector` and `WindowOrientationListener`, both uid 1000 |
| A third-party ad SDK was polling sensors in the background | wrong — a ~5 s burst at app start, then released; an integrity check. Reading one *Active sensors* snapshot instead of the `+`/`-` log is what made it look continuous |
| `rpm-ostree apply-live` failing meant the install had not happened | wrong — `/usr` was already updated; the failure is a pre-existing duplicate line in the base image's `var.conf` |

## Not done, and what is unproven

- **Stability is measured over hours, not days.** Seven hours and 39 samples show no movement in
  descriptors, threads or RSS, and a median 0.909% of a core (above). The sampler keeps running
  across reboots now, so the days accumulate on their own; what is unproven is only the long tail.
- **`magn_3d`'s push rate**, as above: 10.3 Hz once, 0.17 Hz on every re-run. Unexplained, and
  deliberately not chased through a kernel function that oopses.
- **`in_*_sampling_frequency` writes are untested.** They go through the same conversion that
  oopses on a hysteresis write, with the poll interval's unit exponent instead of the
  sensitivity's. Suspect by argument, not by measurement, and not worth a sixth oops to settle.
- **`dev_rotation` is polled at 50 ms** against a hub that pushes at 31.0 Hz. That is the
  `poll_hz` ceiling rather than a deliberate clamp, and Android can ask for faster via `batch()`
  up to that ceiling.
