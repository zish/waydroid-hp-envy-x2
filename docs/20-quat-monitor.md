# Quat Monitor: logging the hub's fusion against Android's

Built 2026-09-07. A dependency-free Kotlin app that samples the ITE8350's hardware-fused
quaternion alongside Android's software fusions at 20 Hz, writes them to disk continuously, and
lets a rotation anomaly be reported the moment it is seen.

Its purpose is to answer one question with data rather than argument: **is the hub's firmware
fusion meaningfully steadier than Android's software fusion, or should the software one be
improved?** Source in [quat-monitor/](../quat-monitor), built and installed with
`quat-monitor/build.sh --install`, data retrieved with `--pull`.

## What is logged, and why each column earns its place

| slot | sensor | inputs |
|---|---|---|
| `hw` | ITE8350 Rotation Vector (type 11) | 9-axis, **firmware** fusion, via `waydroid-sensord` |
| `sw` | GeoMag Rotation Vector (type 20, AOSP) | accel + magn, **no gyro** |
| `gm` | Game Rotation Vector (type 15, AOSP) | accel + gyro, **no magn** |

Plus the **raw accelerometer, gyroscope and magnetometer**, `|B|`, Android's magnetometer accuracy
verdict, the **age of every reading**, and both divergence angles. 30 columns, CSV, one file per
hour, gzipped on rollover, 14-day retention.

Three of those choices matter more than they look:

- **The raw inputs make the log replayable.** A log of outputs alone can show that two fusions
  disagree, but it can never test a third. With the inputs recorded, a candidate fusion can be
  written and scored offline against exactly the samples that produced a real anomaly, with no
  device round-trip per attempt. That is the difference between a monitoring tool and a
  development tool.
- **Two software fusions, split on the magnetometer.** bigtab01's magnetometer is hard-iron
  contaminated by the keyboard's attachment magnets — [docs/14](14-sensors.md) measured `|B|`
  ranging 52–134 µT against a true field near 54. `gm` ignores the magnetometer entirely, so if
  `hw` and `sw` diverge while `hw` and `gm` agree, the cause is the contaminated input rather than
  the algorithm. Without that control the two explanations are indistinguishable.
- **The age of each reading.** A sensor that has stopped publishing still answers reads with its
  last value. That is exactly how the hub failed after a bad resume
  ([docs/19](19-sensor-hub-suspend-wedge.md)), and from Android's side it is indistinguishable
  from a motionless machine. Logging age turns a stall into an obvious rising ramp instead of a
  plausible flat line.

## Interpretation traps

Read these before drawing conclusions from the data. Two of them will mislead badly.

- **`ang_hw_gm` is not an error measurement.** `GAME_ROTATION_VECTOR` deliberately has **no
  absolute heading reference** — its yaw is relative to wherever it happened to start. A constant
  offset against `hw` is therefore expected and means nothing. Only the *stability* of that
  offset is meaningful: a drifting offset means one of the two is losing heading, a constant one
  means both are tracking the same rotation. Do not read its magnitude as accuracy.
- **`ang_hw_sw` is a real disagreement.** Both `hw` and `sw` derive absolute heading from the
  magnetometer, so this one is comparable in absolute terms.
- **AOSP's own 9-axis `TYPE_ROTATION_VECTOR` is not reachable.** `dumpsys sensorservice` lists it,
  but `SensorManager.getSensorList()` returns only one sensor of that type to apps: `SensorService`
  suppresses its virtual sensor when the HAL already supplies the type. Hence GeoMag in the `sw`
  slot. The chosen bindings are written to `meta.txt` at every service start, because six months
  from now the CSV header says `hw`/`sw`/`gm` and nothing else.
- **The first seconds of any file are not trustworthy.** Before each sensor's first event the
  slot holds zeros, so `|B|` reads 0 and `m_acc` reads −1. Filter on `m_acc >= 0`.

## First results

From a 310-second sample, 6019 rows. **This is five minutes of data and proves very little** — it
is recorded here as a starting point and a demonstration that the pipeline works, not as a
finding.

Per-sample angular jitter, restricted to samples where the gyroscope reads under 1 °/s so it
measures sensor noise rather than real rotation:

| source | median | mean | p95 |
|---|---|---|---|
| `hw` | **0.0000°** | **0.0104°** | 0.0000° |
| `gm` | 0.0233° | 0.0715° | 0.1176° |
| `sw` | 0.2885° | 0.4223° | 1.3540° |

The hub's output is essentially quantisation-steady at rest; AOSP's gyro-less GeoMag fusion is
some 40× noisier by mean, which is unsurprising given it has nothing to smooth with. Divergence
ran `ang_hw_sw` median 21.8° (sd 3.2). That is a large, persistent, absolute disagreement and is
the open question this app exists to settle — whether it is heading, tilt, or a convention
difference has not been decomposed yet.

## Design

Three threads, and the separation is the point:

- **sampler** — a `HandlerThread`. Both the sensor callbacks (via the `Handler` overload of
  `registerListener`) and a 50 ms tick live here. Never touches disk.
- **writer** — owns all file I/O, fed by a **bounded queue that drops rather than blocks**.
- **main** — UI only; reads the ring, never writes it.

**Why a fixed tick rather than emitting per sensor event.** The sensors are independent and not
on a common cadence, so pairing on arrival would produce a series whose spacing is an artefact of
which sensor fired. Each callback parks its latest value and the tick samples all of them, giving
a uniform 20 Hz series — and, because ages are recorded, a stalled sensor appears as a rising ramp
rather than a plausible flat line.

**Why the queue drops.** Waydroid's `/data` is on the host's LUKS volume and a write there can
stall. If that back-pressure reached the sensor callback it would distort the very timing the log
exists to measure. Drops are counted and shown in red in the UI: a gap that is honestly reported
is worth more than a series whose timing was quietly bent by its own logger.

**Is 20 Hz reasonable to write continuously?** Yes, and it is also the hardware ceiling — every
sensor here advertises `maxRate=20.00Hz`. A row is ~250 bytes, so ~5 KB/s, ~18 MB/hour, ~60 MB/day
after gzip, against ~188 GB free. The rate was never the risk; the write pattern is. Samples are
buffered and flushed **once a second**, not per sample — 20 flushes a second would cause visible
jank and pointless flash wear for no benefit, and a crash costing at most one second of a
diagnostic log is a fair trade.

### The graph

Six stacked panels sharing one time axis — x, y, z, w, the two divergence angles, and `|B|` with a
reference line at the local 54 µT field. Pinch to zoom, drag to pan, double-tap to reset.

Each pixel column summarises the samples falling in it: a translucent band from min to max (the
raw envelope, so nothing is hidden) and a solid line through the **median** (the smoothing). This
makes the smoothing window follow the zoom for free — wide out, a column spans minutes and the
median is heavily smoothed; zoomed in, it converges on the raw data. A fixed window would be wrong
at one end or the other. Cost is O(visible samples) per *recompute*, not per frame, and the median
takes a strided subsample of at most 32 values per bucket to bound the sort.

The quaternion panels use a fixed −1.05..1.05 scale rather than autoscaling, so panels stay
comparable with each other and over time; a drifting axis would disguise exactly the slow
divergence this is meant to catch.

### Anomaly reporting

The report button also exists as a **notification action**, because anomalies are seen while using
*other* apps. Pressing it stamps the moment immediately and asks for the description afterwards —
folding the two together would smear the one number that matters. It goes straight to the service
rather than through a receiver, since Android 12+ blocks notification trampolines.

Each mark writes a row to `events.csv` and, 15 seconds later, a `capture-<id>.txt` holding logcat
from 60 s before to 15 s after, `dumpsys window`'s rotation state, and the sensor list. The window
brackets the event rather than starting at it, because whatever caused a glitch is in the log
*before* the glitch is visible.

Both `READ_LOGS` and `DUMP` are `signature|privileged|**development**`, and it is the `development`
flag that lets `pm grant` hand them to a normal app — `build.sh --install` does this. Without
`READ_LOGS` an app's logcat silently returns only its own lines, which would make every capture
look like a suspiciously quiet system. Verified: a capture contained 356 lines from **17 distinct
processes**.

## Verified on the device

- Sampling measured at **20.0 samples/sec** sustained; all 30 columns populated.
- Reading ages 23–36 ms, well inside the 50 ms tick — no sensor stalling.
- Foreground service confirmed `isForeground=true`, survives leaving the app.
- History reload at service start repopulates the graph (900 samples on first restart).
- Anomaly path end to end: mark → `events.csv` row → 47 KB capture with real multi-process logcat
  and the WindowManager rotation block.
- `--pull` retrieved 6019 rows to the dev box.

## Not done

- **Long-span browsing.** The ring holds one hour; the graph reads only the ring. Anything older
  is analysed off-device from the CSVs. A disk-backed, downsampling view is the obvious next step
  if it is ever wanted in the UI.
- **Decomposing the 21.8° divergence** into heading versus tilt. That is the actual open question.
- **The app has not run for long.** Everything above is minutes, not days.
