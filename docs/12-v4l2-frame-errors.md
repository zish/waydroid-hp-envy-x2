# 12 — V4L2 frame errors and spurious camera removal: ruled out, not reproduced

Written 2026-09-06. Follow-up to the loose end left in [11-camera-facing.md](11-camera-facing.md).
**No fix was made, because no fault could be reproduced.** What this doc is worth is the negative
space: it eliminates the hardware, the USB link, the kernel driver, CPU starvation and hotplug
churn, so nobody spends another session on them.

## What the error is

While Open Camera streamed 1280x720, the external camera HAL logged:

```
E/ExtCamDevSsn@3.4: dequeueV4l2FrameLocked: v4l2 buf error! buf flag 0x12040
E/ExtCamDevSsn@3.4: threadLoop: Convert V4L2 frame to YU12 failed! res 1
```

`0x12040` decodes as:

| Bit | Meaning |
|---|---|
| `0x00040` | **`V4L2_BUF_FLAG_ERROR`** |
| `0x02000` | `V4L2_BUF_FLAG_TIMESTAMP_MONOTONIC` |
| `0x10000` | `V4L2_BUF_FLAG_TSTAMP_SRC_SOE` |

Only the first matters: **the buffer holds an incomplete frame**. The other two are the normal
timestamp descriptors and appear on every good buffer too.

The reason an incomplete frame is *delivered at all* rather than discarded is uvcvideo's `nodrop`
parameter, which is `1` on this host:

```
$ cat /sys/module/uvcvideo/parameters/nodrop
1
```

`nodrop` decides who notices a damaged frame — deliver it flagged (`1`) or drop it silently (`0`).
It does not decide whether frames get damaged. The second error line is the consequence: the HAL
handed a truncated JPEG to libyuv, which refused it.

## The host's V4L2 path is clean

`bin/v4l2-stream-stats.py` streams frames and tallies per-buffer flags. Run against `/dev/video0`
with the Waydroid session **stopped**, so nothing else held the device:

| Run | Format | Frames | `ERROR` | Seq gaps | Missing EOI | Effective fps |
|---|---|---|---|---|---|---|
| A | 1280x720 MJPG | 300 | **0** | 0 | 0 | 14.7 |
| B | 640x480 MJPG | 300 | **0** | 0 | 0 | 14.7 |
| C | 1280x720 MJPG, 60 s | 900 | **0** | 0 | 0 | 14.9 |
| D | 640x480 **YUYV** (uncompressed) | 300 | **0** | 0 | n/a | 14.7 |

1,800 frames, zero errors. Every buffer came back `0x012001`
(`MAPPED|TS_MONOTONIC|SRC_SOE`) — never `0x012040`. Run D matters most: uncompressed YUYV is
~9 MB/s versus MJPG's ~5 MB/s, so it stresses the USB link hardest, and it was still clean.

**Zero sequence gaps** is the important column. It means the driver delivered every frame it
produced, consecutively — the capture side was never starved, and the numbers are not an artifact
of the Python probe being too slow to keep up.

Conclusion: **the camera, the USB 2.0 link and `uvcvideo` are healthy.** Whatever produced the
errored buffers is not on this path.

### The 15 fps is exposure, not bandwidth

Every run reports ~14.7 fps against an advertised 30. That is not a bottleneck and not a Waydroid
cost: the rate is *identical* at 640x480 MJPG, 1280x720 MJPG and uncompressed YUYV, across which
the data rate varies roughly sixfold. A bandwidth limit would scale with resolution; this does not.
It is auto-exposure doubling the frame time in low light — corroborated by the preview screencap,
which is dark and grainy. Bright the room and it should return toward 30 fps.

## Not reproducible under Waydroid either

Roughly **five minutes of confirmed streaming** across three windows — verified by an active
`CONNECT` in the camera event log and, in one case, by a `screencap` showing a live picture — with
Open Camera at 1280x720:

| Window | Conditions | `v4l2 buf error` | `YU12 failed` |
|---|---|---|---|
| 40 s | idle host | 0 | 0 |
| ~180 s | idle host | 0 | 0 |
| 90 s | **4 CPU hogs, loadavg 4.41, CPU throttled to 1.5 GHz** | 0 | 0 |

The load run was the real test of the leading hypothesis — that a saturated Core M-5Y70 delays
URB completion and costs isochronous packets. It does not, at least not at full CPU saturation.

(An earlier "load" test in this session showed loadavg 0.34 and proved nothing; the background
hogs had not actually started. Check `/proc/loadavg` *inside* the test before trusting it.)

## The second fault: the HAL removes a camera that is still there

Found while chasing the first. The camera event log shows the device being torn out from under a
streaming client:

```
21:34:32 : REMOVE device 100, reason: (Device status changed from -2 to 0)
21:34:32 : DISCONNECT device 100 client for package net.sourceforge.opencamera (PID 3552)
21:34:32 : ADD device 100, reason: (Device added)
21:35:33 : REMOVE device 100, reason: (Device status changed from 1 to 0)
21:35:33 : ADD device 100, reason: (Device added)
```

`-2` is `NOT_AVAILABLE` (open by a client), `1` is `PRESENT`, `0` is `NOT_PRESENT`. So the HAL
concluded the camera had been unplugged — once while it was actively streaming — killed the
client, and immediately re-added it.

**The hardware never moved.** `lsusb` still lists `064e:c353` throughout, `/dev/video0` still
exists, `/sys/bus/usb/devices/1-6` stays `runtime_status=active`, and there is **no USB
disconnect anywhere in `dmesg`** — the only `usb` lines are Android's unrelated `usbd` init noise.

This is arguably worse than the frame errors: it drops the camera mid-use. It happened twice in
~40 minutes and then not again in the following 20, including under full load. Cause unknown.

## Hypotheses disproven

| Hypothesis | Verdict |
|---|---|
| Bad camera, bad cable, or a flaky USB link | **Wrong** — 1,800 host frames across four format/duration combinations, zero errors, zero gaps |
| USB 2.0 bandwidth contention (the camera shares bus 001 with a full-speed Bluetooth radio) | **Wrong** — uncompressed YUYV at ~9 MB/s is clean, and the frame rate does not move with resolution |
| The camera can't sustain 30 fps, so frames arrive damaged | **Wrong** — the ~15 fps is auto-exposure, identical across all resolutions and formats; frames are complete, just fewer |
| `uvcvideo quirks = 4294967295` is forcing bad behaviour | **Wrong, and it is the default** — the parameter is `Forced device quirks`, `-1` is the "not forced" sentinel. Nothing sets it: no `modprobe.d` entry, not on the kernel cmdline |
| CPU starvation on the Core M delays URB completion | **Wrong** at full saturation — 90 s at loadavg 4.41 with the CPU throttled to 1.5 GHz produced zero errors |
| `NumVideoBuffers` is too small, so the queue underruns | **Wrong** — the config says `count="4"`, and the host probe used the same 4 buffers with zero gaps |
| Something else opening `/dev/video0` triggers the removal | **Wrong** — opening and closing the node from the host while Open Camera streamed produced no flap; a 30 s no-touch control was equally clean |
| Host uevents make Android's `ueventd` recreate the node, and the HAL's `inotify(IN_CREATE\|IN_DELETE)` watch on `/dev` reads that as a replug | **Wrong** — the container's `/dev/video0` is **inode 722, the same inode as the host's**: a bind mount, not a ueventd-created node. Deliberate `change` uevents on both the V4L2 device and the USB device changed nothing and provoked no flap |
| The udev autosuspend rule fixed it | **Not claimed.** `power/control` was already forced `on` at runtime before these errors were last seen. The rule persists a change that is correct on its own merits, not a proven fix |

## What was deliberately not changed

**`nodrop` was left at `1`.** Setting it to `0` would stop the errors being *logged* — uvcvideo
would discard damaged frames instead of handing them up flagged — while damaging exactly as many
frames as before. That is hiding a symptom, and it would also destroy the only signal that says
this is happening. If the frame errors return and prove to be cosmetic log noise rather than
visible stutter, `nodrop=0` becomes a reasonable *cosmetic* choice, but not before.

## When it happens again

Both faults are intermittent, so the useful deliverable is detection, not a fix.
**`bin/camera-watch.sh`** polls for both and prints only when something fires, capturing host-side
context at that moment — loadavg, CPU clock, USB power state, `dmesg` tail, and whether the device
is still on the bus:

```bash
scp bin/camera-watch.sh 10.42.0.137:/tmp/
ssh 10.42.0.137 '/tmp/camera-watch.sh 20'     # poll every 20s, Ctrl-C to stop
```

Leave it running during normal camera use. The next occurrence should identify the trigger, which
is the one thing this session could not.

### Where to look next

The evidence points away from the kernel and toward the HAL, so the next step is the HAL's own
view. In order of expected value:

1. **Raise the HAL's log level** so `ExternalCameraProviderImpl_2_4` reports *why* it calls
   `deviceRemoved`. The provider decides presence by `open()` + `VIDIOC_QUERYCAP`; if that probe
   ever races a client that holds the device, `EBUSY` would look identical to "unplugged". That is
   the most plausible remaining mechanism for the flap and it was never instrumented.
2. **Correlate the two faults.** A session that hits fatal V4L2 errors can tear itself down, which
   would produce a `REMOVE`. If `camera-watch.sh` ever shows frame errors immediately preceding a
   flap, they are one bug, not two.
3. Note that the earlier occurrences were on a session already poisoned by the Lens crash
   (`DIED client(s) with PID 113, Binder died unexpectedly`). Session hygiene between camera tests
   matters — see [docs/11](11-camera-facing.md).

## Postscript: the udev rule was withdrawn

The `power/control=on` rule was installed, then removed the same session. It had no demonstrated
benefit — the Lens crash reproduced identically with autosuspend off, and both device flaps
happened *while* `control` was already `on` — and pinning a USB device out of runtime suspend has a
real if small cost on a battery-powered tablet.

Removing it was also the better experiment, and it settled the question outright. With `control`
back at `auto` the device suspends after ~2 s idle, and **opening a suspended device is completely
transparent**:

```
runtime_status = suspended        <- before opening
  150 frames in 5.5s = 27.2 fps
  ERROR-flagged      : 0
  sequence gaps      : 0
  missing EOI (ffd9) : 0
runtime_status = active           <- immediately after
runtime_status = suspended        <- 10 s later, re-suspended on its own
```

Resume costs nothing measurable and corrupts nothing. **Autosuspend was never a suspect worth
having.**

### This run also confirmed the exposure explanation

The same command that gave 14.7 fps earlier gave **27.2 fps** here, with no configuration change
whatsoever — only a brighter room. Average frame size fell with it (299 KB against 371 KB), which
is the right direction: a dark frame is noisy, and noise does not compress. Both numbers move
together exactly as auto-exposure predicts, and neither moves with resolution. The camera is not
being throttled by Waydroid, USB or the driver; it is being throttled by the light in the room.

To revert the revert, the rule is preserved at
[artifacts/udev/99-uvc-no-autosuspend.rules](../artifacts/udev/99-uvc-no-autosuspend.rules).

## Correction: these are two different bugs, not one

This doc opened by treating two log lines as one phenomenon. They are not, and the distinction
matters because only one of them is reproducible:

| Line | What it is | Status |
|---|---|---|
| `dequeueV4l2FrameLocked: v4l2 buf error! buf flag 0x12040` | an **incomplete frame from the driver** | **never reproduced.** 1,800 host frames and ~5 min of Waydroid streaming, zero occurrences |
| `threadLoop: Convert V4L2 frame to YU12 failed! res 1` | a **gralloc format-conversion failure** | **reproduced**, and root-caused below |

They were seen together once and wrongly assumed to be cause and effect. The second does not need
the first: a frame can be perfectly intact and still fail to convert.

## The conversion failure: Mesa cannot allocate YCbCr_420_888

Captured from a live session:

```
[minigbm:gbm_mesa_internals.cpp(352)]: Unable to allocate 0x37393939 format, allocate as 1D buffer
[minigbm:gbm_mesa_internals.cpp(362)]: Allocate 1D buffer as 4096x38 R8 2D texture
[minigbm:gbm_mesa_internals.cpp(382)]: Allocated: 352x288, stride: 4096, map_stride: 4096
E/ExtCamDevSsn@3.4: threadLoop: Convert V4L2 frame to YU12 failed! res 1
W/Camera2Client: notifyError: Received recoverable error 3 from HAL - ignoring, requestId 10000025
```

`0x37393939` is `fourcc_code('9','9','9','7')` = **`DRM_FORMAT_FLEX_YCbCr_420_888`**, the flexible
YUV format the camera HAL asks gralloc for. Over one session:

| Measure | Count |
|---|---|
| 1D-fallback allocations | **45** |
| ...of which format `0x37393939` | **45 (all of them)** |
| Sizes seen | 1280x720 ×24, 352x288 ×7, 640x480 ×4 |
| `Convert ... to YU12 failed` | **2** |
| `v4l2 buf error` | **0** |

So **Mesa cannot allocate `YCbCr_420_888` at all** — every request without exception falls back to
a linear R8 1D buffer. This is the same fallback path as the original camera bug in
[docs/08](08-camera-fixed.md), which is worth stating plainly: **that fix is working.** The
fallback buffers now come back with `map_stride: 4096` rather than the `0` that made the map return
NULL. (The `map_stride: 0` entries still in the log are `1916x1027` display buffers — the Waydroid
window surface, allocated normally and never CPU-mapped. Different path, not a regression.)

What is left is that the fallback **usually** works and **occasionally** does not — 2 failures in
45 allocations, roughly 4%. The framework treats it as `error 3` (`ERROR_REQUEST`), logs
"recoverable ... ignoring", and drops that frame. Visible effect: an occasional dropped frame, not
a broken camera.

**This is the real remaining camera defect**, and it is a gralloc/Mesa format-support gap, not a
V4L2, USB or driver problem. It belongs with the upstream minigbm report in
[docs/09](09-upstream-report.md) rather than anywhere near `uvcvideo`.

## Suspend/resume: completely clean

The lid test, with `power/control` back at the `auto` default. `bin/suspend-probe.sh` logged from
on the host, since ssh does not survive the suspend:

```
22:46:48  baseline: control=auto status=active
22:46:57  status: active -> suspended          <- idle, autosuspended
22:47:33  status: suspended -> active          <- Open Camera opened it (CONNECT at 22:47:32)
22:47:48  status: active -> suspended          <- released at 22:47:45, re-suspended 3s later
22:48:48  status: suspended -> active          <- relaunched (CONNECT at 22:48:48)
22:54:19  *** RESUMED after ~195s asleep ***
22:54:19      on resume: control=auto status=active node=present device=present
```

Every runtime-power transition tracks camera use exactly, to the second. Across a ~195 s S3
suspend: the USB device returned at the same bus address, `/dev/video0` survived, `control=auto`
was preserved, the Waydroid session and container stayed `RUNNING`, and the camera provider was
still holding the device **mmap'd** — i.e. the streaming session persisted straight through the
suspend without the HAL noticing anything. The camera worked immediately on resume, confirmed by
the user. `/sys/power/suspend_stats/success` incremented.

The kernel log shows the camera was **fully reset** on the way back:

```
PM: suspend entry (deep)
PM: suspend devices took 0.413 seconds
usb 1-6: reset high-speed USB device number 4 using xhci_hcd   <- the camera
PM: resume devices took 0.623 seconds
Restarting tasks: Done
PM: suspend exit
```

So this was not a soft transition that the camera slept through — the USB device was reset out
from under a provider that still had buffers mapped, and the session survived it anyway.
(`dmesg -T` compresses these timestamps: the monotonic clock does not advance while suspended, so
the whole cycle appears to happen in one second. The probe log has the real wall-clock timing.)

**No `REMOVE`/`ADD` pair appears across the resume**, which is worth noting given the spurious-flap
bug above: suspend/resume is not a trigger for it.

This closes the autosuspend question completely. Runtime PM is not merely harmless here, it is
working correctly and tracking the camera precisely. The withdrawn udev rule was solving nothing.
