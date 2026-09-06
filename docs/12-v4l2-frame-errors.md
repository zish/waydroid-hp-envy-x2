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
