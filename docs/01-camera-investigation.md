# Goal 1 — Camera in Waydroid

**Status: root cause identified. The camera is not the problem — Waydroid's gralloc is.**

Symptom: camera LED lights, Android sees the camera, the app opens it, the V4L2 stream starts —
and the preview stays **black**.

## Root cause

```
E GBM-MESA-WRAPPER: Failed to map the buffer at external/minigbm/gbm_mesa_driver/gbm_mesa_wrapper.cpp:228
E ExtCamUtils@3.4:  formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 y_str 0 c_str 0 c_step 0
E ExtCamDevSsn@3.4: threadLoop: format coversion failed!
```

The external camera HAL must write decoded frames into a graphics buffer supplied by gralloc.
The preview stream is allocated as **YV12** (`format 0x32315659`):

```
Stream[0]: Output  Dims: 1280 x 720, format 0x32315659 (YV12), usage 0x20930
Stream[1]: Output  Dims: 1280 x 720, format 0x21 (BLOB/JPEG), usage 0x20033
```

Allocation succeeds. **Mapping it for CPU access fails.** The HAL then asks for the buffer's
plane layout and gets all zeros — `y 0x0 cb 0x0 cr 0x0`, every stride `0` — which it correctly
rejects as an "unsupported flexible yuv layout". The conversion aborts, no frame is ever
delivered, and the preview stays black while the V4L2 stream keeps running (LED on).

So the fault is in **Waydroid's minigbm / gbm_mesa gralloc**, in the CPU-mapping path for
flexible YUV buffers. Everything above and below it is healthy.

## What is verified working

| Layer | State | Evidence |
|---|---|---|
| Camera hardware | working | Cheese captures normally on the host |
| `uvcvideo` driver | working | `/dev/video0`, `ID_V4L_CAPABILITIES=:capture:` |
| MJPEG stream | **valid** | frames carry `DHT`; see [Disproven](#disproven-hypotheses) |
| LXC passthrough | working | both nodes in-container as `crwxrwxrwx 1 root 39` |
| SELinux | not blocking | `ausearch -m avc -ts today` → no relevant denials |
| HAL service | running | `init.svc.vendor.camera-provider-2-7-ext` = `running` |
| HAL registration | registered | `lshal` → `...provider@2.7::ICameraProvider/external/0` |
| Camera enumeration | working | `dumpsys media.camera` → `Number of camera devices: 1` |
| Camera open | working | `Camera2ClientBase: Camera 100: Opened.` |
| V4L2 streaming | working | `start V4L2 streaming 1280x720@30.000000fps` |
| **Buffer mapping** | **BROKEN** | `GBM-MESA-WRAPPER: Failed to map the buffer` |

The camera stack is sound end to end until the very last step.

## Camera capabilities (`bin/v4l2-formats.py /dev/video0`)

```
[YUYV] YUYV 4:2:2
    176x144 320x240 352x288 640x360 640x480  @ 30,25,20,15,10,7.5,5 fps
    1280x720  @ 10 fps          1920x1080  @ 5 fps

[MJPG] Motion-JPEG (compressed)
    176x144 320x240 352x288 640x360 640x480 1280x720 1920x1080  @ 30,25,20,15,10,7.5,5 fps
```

Only MJPG reaches 30 fps above 640x480. The HAL selects MJPG — confirmed directly with
`bin/v4l2-curfmt.py`, which reports `MJPG 1280x720` while streaming.

## Gralloc experiments — both tested, neither fixes it

Since the failing component is gralloc, that is what was varied. Available modules in
`/vendor/lib64/hw/`: `gralloc.default.so`, `gralloc.gbm.so`, `gralloc.minigbm_gbm_mesa.so`.

| `ro.hardware.gralloc` | Result |
|---|---|
| `gbm` (original) | camera enumerates, opens, streams — **black preview**, map failure |
| `default` | **Android itself will not run** — see below |
| `minigbm_gbm_mesa` | **identical failure**, byte for byte |

### `default` destabilises Android

The software gralloc took the whole system down; `system_server` died repeatedly:

```
E AndroidRuntime: FATAL EXCEPTION: main
E AndroidRuntime: DeadSystemException: The system died; earlier logs will point to the root cause
   (com.android.systemui, com.android.se, com.android.networkstack.process ...)
```

Boot took ~90 s instead of ~18 s, and the camera app's activity would not even resolve. This
configuration is not usable and the run produced no valid camera evidence — the zero error count
it reported was a **false negative**, because the camera was never opened at all.

### `minigbm_gbm_mesa` reproduces the failure exactly

This run *was* valid — Open Camera running, camera client active, 18 s boot:

```
E GBM-MESA-WRAPPER: Failed to map the buffer at ...gbm_mesa_wrapper.cpp:228
E ExtCamUtils@3.4:  formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 ...
E ExtCamDevSsn@3.4: threadLoop: format coversion failed!
```

### Caveat: `ro.hardware.gralloc` is overridden at runtime

`/vendor/waydroid.prop` is the only prop file that defines `ro.hardware.gralloc`, and it holds
`gbm` — but the running system reports:

```
[ro.hardware.gralloc]: [minigbm_gbm_mesa]
```

Something in the image sets it during early init, and `ro.` properties are write-once, so that
value wins. The exact setter was not pinned down (`init.waydroid.vendor.rc` only stops
`vendor.gralloc-2-0`; the allocator rc files are the likely source).

**Consequence for the test matrix above:** the `gbm` and `minigbm_gbm_mesa` rows are very likely
*the same configuration*, so only two genuinely distinct configurations were exercised —
gbm_mesa (fails) and `default` (breaks Android). The conclusion is unchanged, because the error
is emitted by the gbm_mesa wrapper that is demonstrably in use, but the matrix should not be read
as three independent results.

The host was restored to the original `waydroid_base.prop` afterwards
(`waydroid_base.prop.orig` is the backup) and verified byte-identical.

## Where this leaves goal 1

No available configuration fixes this. The defect is in Waydroid's minigbm `gbm_mesa` wrapper,
which cannot CPU-map the flexible-YUV (YV12) buffer the external camera HAL must write into.

Remaining options, in rough order of effort:

1. **Try a different Waydroid image.** The current images are dated Apr 28 and are BlissOS-derived.
   A newer or differently-built system/vendor image may carry a fixed `gbm_mesa_wrapper`.
   Cheapest real shot, and non-destructive — images live in `/etc/waydroid-extra/images`.
2. **Report upstream** with the three-line log signature. This is a clean, specific bug:
   `gbm_mesa_wrapper.cpp:228` fails to map a YV12 buffer, producing an all-zero plane layout.
3. **Patch and rebuild** the gralloc wrapper — the definitive fix, and much the largest effort.

What is *not* worth retrying: the camera hardware, the V4L2 format, the resolution, the app, or
SELinux. All are verified working or eliminated.

## Disproven hypotheses

Kept deliberately so this ground is not re-covered.

### 1. Metadata node needs to be ignored — WRONG

Hypothesis: `/dev/video1` is the UVC metadata node and the empty `<ignore>` list in
`external_camera_config.xml` would make the HAL treat it as a camera.

The HAL already handles it unaided:

```
W CamPrvdr@2.7-external: deviceAdded device /dev/video1 does not support VIDEO_CAPTURE
```

Only one device (100) is ever enumerated. **Do not apply the `<ignore>` change.**

### 2. Resolution too high — WRONG (but change was kept)

Hypothesis: the HAL picked 1920x1080@30 and that was too much.

**Tested.** An overlay config capping resolution at 1280x720 was applied; the HAL duly switched
to `1280x720@30`, and the conversion **failed identically**. Resolution is not the variable.

> The capped config was left in place. It is harmless and still removes genuinely bogus entries —
> the stock config advertises 1600x1200 and 2592x1944, which this camera cannot produce at all.
> It is **not** a fix. Revert by deleting
> `/var/lib/waydroid/overlay/vendor/etc/external_camera_config.xml`.

### 3. MJPEG frames missing Huffman tables — WRONG

Hypothesis: the camera emits DHT-less MJPEG, which libyuv's `MJPGToI420` rejects. This is a real
failure mode for UVC webcams, so it was worth testing.

`bin/v4l2-grab.py` captured a live frame and parsed its markers:

```
ffd8 SOI → ffe0 APP0/JFIF → ffdb DQT ×2 → ffc4 DHT ×4 → ffdd DRI
     → ffe1 APP1 → ffc0 SOF0 (baseline) → ffda SOS
DHT present: YES        306,729 bytes/frame
```

Well-formed baseline JPEG with its own Huffman tables. The camera's output is fine.

### 4. `supportedHardwareLevel = EXTERNAL` rejected by the app — WRONG

Hypothesis: the device reports the restrictive `EXTERNAL` hardware level, and Google Camera
would refuse it.

Moot on two counts. The installed `com.google.android.apps.googlecamera.fishfood` has **no
launcher activity** (`cmd package resolve-activity` → `No activity found`), so it was never a
valid test. And Open Camera — which does support external cameras — opens the device
successfully and hits the same gralloc failure. The app layer is not implicated.

### 5. `ro.hardware.camera=v4l2` interfering — inert, not a bug

The property selects a legacy `camera.<hw>.so` HAL module; no such module exists in the image.
This image serves the camera through the external camera provider, which ignores the property.
Confirmed harmless — the camera enumerates and opens correctly with it set. A leftover from an
earlier attempt; worth removing for clarity, no urgency.

### 6. The provider "crash loop" — was a single deliberate restart

One `Camera provider 'external/0-0' has died` was seen. It happened **once**
(`grep -c` → `1`), produced **no tombstone**, and the host journal names the killer:
`libprocessgroup: Successfully killed process cgroup uid 1047 pid 79` — uid 1047 is
`AID_CAMERASERVER`, and `libprocessgroup` is how Android init tears down a service cgroup.
A deliberate service restart, not a crash.

## Tooling notes

`v4l-utils` is not installed and the host is rpm-ostree (layering costs a reboot), so these were
written instead — stdlib-only, direct V4L2 ioctls:

| Script | Purpose |
|---|---|
| `bin/v4l2-formats.py` | enumerate formats / resolutions / frame rates |
| `bin/v4l2-curfmt.py` | report the currently negotiated format (safe while streaming) |
| `bin/v4l2-grab.py` | capture one frame and dump its JPEG marker structure |

### `waydroid shell` quirks

Needs `--` before the command, and a shell for pipes:

```bash
sudo waydroid shell -- sh -c "dumpsys media.camera | head -30"
```

Without `--`, flags like `-l` are eaten by waydroid's own argument parser. The trailing
`ERROR: [Errno 13] Permission denied: 1` printed after each command is a cosmetic wart —
**output above it is valid**.

### Starting a session over SSH

`waydroid session start` needs both variables, or it silently defaults to `wayland-0` and fails:

```bash
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-1
setsid nohup waydroid session start >/tmp/wd.log 2>&1 </dev/null &
```

## Reference — camera components in the image

| Component | Path |
|---|---|
| Provider service | `/vendor/bin/hw/android.hardware.camera.provider@2.7-external-service` |
| init script | `/vendor/etc/init/android.hardware.camera.provider@2.7-external-service.rc` |
| Config | `/vendor/etc/external_camera_config.xml` (BlissOS-derived) |
| Impl libs | `camera.device@3.{4,5,6}-external-impl.so`, `...provider@2.{4,5,6,7}-external.so` |
| VINTF | declares `@2.7::ICameraProvider/external/0` |

Two gotchas when re-verifying: `/vendor/bin/hw` is mode `drwxr-x--x` (cannot `ls`, can `stat` by
exact name), and the vendor image is **unmounted while the container is stopped**, so every path
above reads as absent then.
