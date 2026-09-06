# 11 — Camera facing: making apps that demand a rear camera work

Written 2026-09-06, after [08-camera-fixed.md](08-camera-fixed.md) closed goal 1. This is a
*separate* camera bug from the gralloc one. Goal 1 made the camera produce frames; this made
certain apps willing to open it in the first place.

## Summary

Google Lens crashed the moment it was launched — before it ever contacted the camera service.
The cause was not a fault in the camera at all: the external camera HAL advertises
`ANDROID_LENS_FACING = EXTERNAL`, and Lens dereferences the result of a rear-camera lookup
without a null check. No rear camera meant a null, and the null became an NPE.

Patching the HAL to report `BACK` instead of `EXTERNAL` fixes the crash. Lens now opens the
camera and streams. **It still crashes later**, for an unrelated reason, and that second failure
is not worth chasing (see below). The patch is kept anyway, because it is what lets *any*
rear-camera-requiring app open the camera at all.

**One byte.** Deployed through the vendor overlay, reversible by deleting one file.

## Why Lens crashed

`ANDROID_LENS_FACING` (tag `0x80005`) has three legal values:

| Value | Meaning |
|---|---|
| 0 | `FRONT` |
| 1 | `BACK` |
| 2 | `EXTERNAL` |

`EXTERNAL` is the honest answer for a USB webcam — it means "a camera whose physical relationship
to the screen is unknown". It is also the answer almost nothing in the app ecosystem handles,
because on a phone every camera is `FRONT` or `BACK`.

Lens enumerates cameras looking for a rear one, finds none, and does not check for that:

```
java.lang.NullPointerException: Attempt to invoke virtual method
  'java.lang.Class java.lang.Object.getClass()' on a null object reference
    at com.google.android.libraries.lens.view.h.c.b.p.a(...)
```

Nothing appears in `dumpsys media.camera`'s event log for this crash, which is the tell: the app
died during *enumeration*, without ever issuing a `CONNECT`.

## The patch

The value is written in `ExternalCameraDevice::initDefaultCharsKeys` in
`/vendor/lib/camera.device@3.4-external-impl.so` (ELF32 i386, 407,412 bytes). It is a literal
immediate in a `movb`, not a table entry, so it is a single-byte change:

```
2d05d: c6 44 24 2d 02      movb $0x2,0x2d(%esp)     <-- lensFacing = EXTERNAL
2d062: 8d 44 24 2d         lea  0x2d(%esp),%eax
2d066: 6a 01               push $0x1                <-- count = 1
2d068: 50                  push %eax                <-- &lensFacing
2d069: 68 05 00 08 00      push $0x80005            <-- ANDROID_LENS_FACING
2d06f: e8 fc 30 03 00      call CameraMetadata::update@plt
```

The `push $0x80005` two instructions later is what identifies the site unambiguously — it is the
tag being written. Section headers give the vaddr→file-offset delta as `-0x1000` (`.text` at
vaddr `0x2ab90`, file offset `0x29b90`).

| | |
|---|---|
| File offset | `0x2c061` (decimal 180321) |
| Change | `02` → `01`, i.e. `EXTERNAL` → `BACK` |
| Locator bytes | `c644242d02 8d44242d 6a01 50 6805000800` |
| md5 before | `2b2b0a73e12e0083f684496f224d54b0` |
| md5 after | `add7e8d07c7d8549204e7a62c82b1e7d` |
| `cmp -l` | `180322   2   1` — exactly one byte differs |

Both variants are kept in [artifacts/camera/](../artifacts/camera/).

### Two things that matter about which file to patch

- **Only the 32-bit library exists.** There is no `/vendor/lib64/camera.device@3.4-external-impl.so`.
  The camera provider is a 32-bit process even though cameraserver and the apps are 64-bit. Unlike
  the gralloc wrapper in [docs/08](08-camera-fixed.md), this one is genuinely single-ABI — checked,
  not assumed.
- **The 3.5 and 3.6 implementations are not used and were not patched.** Both were pulled and
  searched: neither contains the tag constant `0x80005` nor the store pattern. The device runs the
  3.4 implementation.

### Deployment

```
/var/lib/waydroid/overlay/vendor/lib/camera.device@3.4-external-impl.so   root:root 0644
```

`0644` is correct here — it is a library, not a service binary. (Contrast the health HAL in
[docs/10](10-battery-fixed.md), which needed `0755`.)

A **session** restart is required, not a container restart — see the trap in
[docs/06](06-next-session.md). Confirm the live bytes with `md5sum` on the
`/var/lib/waydroid/rootfs/...` path, which reads the merged overlayfs view.

## Verification

Positive evidence, not absence of errors. `com.google.android.googlequicksearchbox` had **never**
appeared in the camera event log before the patch:

```
CONNECT device 100 client for package com.google.android.googlequicksearchbox (PID 2941)
ExtCamDevSsn@3.4: configureStreams: request stream 640x480
ExtCamDevSsn@3.4: start V4L2 streaming 640x480@30.000000fps
```

Open Camera was re-tested afterwards for regression and is unaffected — it connects, streams
1280x720@30, and renders a live preview confirmed by `screencap` of a real scene:

```
CONNECT device 100 client for package net.sourceforge.opencamera (PID 3427)
ExtCamDevSsn@3.4: configureStreams: request stream 1280x720
ExtCamDevSsn@3.4: start V4L2 streaming 1280x720@30.000000fps
```

**Test order matters.** The first Open Camera regression test looked like a regression — stuck on
its splash screen, no `CONNECT`. It was a false alarm: that session had already been poisoned by
the Lens crash (`DIED client(s) with PID 113, Binder died unexpectedly`). Re-testing on a clean
session with Open Camera launched *first* showed it working normally. **A camera client that dies
badly leaves the camera service in a state where the next client cannot connect.** Restart the
session between camera tests.

## What this did not fix

Lens now gets much further and then dies anyway, in a different place:

```
FATAL EXCEPTION: cameraThread
java.lang.NullPointerException: ... 'java.lang.Class java.lang.Object.getClass()' on a null object reference
    at com.google.android.libraries.lens.view.h.c.b.o.onCaptureCompleted(PG:21)
    at android.hardware.camera2.impl.CameraCaptureSessionImpl$1.lambda$onCaptureCompleted$4(...)
```

Same null-dereference habit, sibling class (`h.c.b.o` rather than `h.c.b.p`), but now in the
per-frame result callback. Lens is reading a **`CaptureResult`** field that the external HAL does
not populate.

**This is where to stop.** The external HAL publishes a deliberately minimal result-metadata set —
that is what `INFO_SUPPORTED_HARDWARE_LEVEL = EXTERNAL` *means*. Lens is written against a
`LIMITED`/`FULL` camera. Unlike facing, which is one constant written once at initialisation,
result metadata is produced per frame from real sensor state the webcam does not report. Each
field synthesised would only surface the next missing one. That is HAL development, not a byte
patch, and Google Lens is not a good return on it.

The patch stays regardless: it is what makes the device look like it has a rear camera, which is
the prerequisite for any scanner, document-capture or AR app, not just Lens.

## The trade-off: this machine has exactly one camera

Worth being explicit, because "set it to BACK" is not free.

The host has a **single** physical camera:

```
Bus 001 Device 004: ID 064e:c353 Suyin Corp. HP TrueVision Full HD
  /dev/video0  HP TrueVision Full HD   <- capture
  /dev/video1  HP TrueVision Full HD   <- metadata node, correctly ignored by the HAL
```

and Android sees `Number of camera devices: 1`. The Envy x2 has no rear camera. Physically, this
webcam is **user-facing** — so calling it `BACK` is a lie in the opposite direction from `EXTERNAL`.

| Setting | Rear-seeking apps | Front-seeking apps |
|---|---|---|
| `EXTERNAL` (stock) | fail | fail |
| `BACK` (deployed) | **work** | fail |
| `FRONT` | fail | work |

With one camera these are mutually exclusive, and `EXTERNAL` is the *worst* of the three because
it satisfies neither. `BACK` is therefore a strict improvement over stock, and the only question
is whether `BACK` or `FRONT` is the better single choice.

What `BACK` costs, specifically:

- **Apps that ask for a front camera find none.** Video-call apps (Meet, Zoom, Signal, WhatsApp)
  default to front. Most fall back to `getCameraIdList()[0]` and work anyway; ones that filter
  strictly on facing will report no camera. **Untested — this is the thing to check** if a
  video-call app matters.
- **No preview mirroring.** Android and most apps mirror the preview for front cameras only. On
  `BACK`, a self-view is not mirrored, so it reads as reversed. Cosmetic, but noticeable.
- **Rotation may differ.** `ANDROID_SENSOR_ORIENTATION` (tag `0xe000e`) is a separate value, but
  the framework applies different display-rotation math for front vs back. If preview comes out
  rotated in some app, this is the first suspect.

Getting *both* would need two logical cameras from one `/dev/video0` — either a `v4l2loopback`
duplicate fed from the real device, or a code cave in the HAL to register a second device with
`FRONT`. Neither is done. A far cheaper option, if it ever matters, is a host-side script that
swaps the overlay file between the `BACK` and `FRONT` variants and restarts the session; both
byte-variants are already in `artifacts/camera/`.

## Adjacent: the `Fence::waitForever` stall

Seen repeatedly during this work and **not caused by the camera** — it hit `com.sgmediapp.gcam`,
`NavigationBar0` (systemui) and `org.fossify.home` at the same time. Recording it because it costs
real time to re-diagnose and the ANR evidence rotates out.

Every affected process is stuck in the same place, in `RenderThread`:

```
__ppoll -> poll -> sync_wait -> android::Fence::waitForever
  -> android::BufferQueueProducer::queueBuffer
  -> android::Surface::queueBuffer -> ANativeWindow_queueBuffer
  -> /vendor/lib64/egl/libEGL_mesa.so (x3)
  -> eglSwapBuffersWithDamageKHR -> EglManager::swapBuffers
  -> SkiaOpenGLPipeline::swapBuffers -> CanvasContext::draw
```

That `waitForever` is the **EGL production throttle** in `BufferQueueProducer::queueBuffer`: before
queueing a new frame, the producer waits on the *previous* frame's fence, so that at most two
buffers are outstanding. It blocks only when the **consumer has not released the previous buffer**.

So this is not an app bug and not a renderer bug — it is a presentation stall downstream of every
app, which on Waydroid means the SurfaceFlinger→Wayland path. That every process stalls at once is
consistent: they share one consumer, and one stuck consumer blocks every producer behind it.

**Not root-caused.** What it is has been narrowed; *why* the release fence goes unsignalled has
not been investigated. Note it involves `libEGL_mesa.so` on the guest side, so it is plausibly
related to the same Mesa/gralloc surface as [docs/08](08-camera-fixed.md) — but that is a
hypothesis, stated as one.

Evidence preserved at `~/.local/share/waydroid/data/anr/anr_2026-09-05-17-13-50-653` on the host
(and two siblings at `17-17-39` and `17-17-41`) for as long as they survive rotation.

## Hypotheses disproven

| Hypothesis | Verdict |
|---|---|
| The app crash is ARM code failing without a native bridge | **Wrong, decisively.** No ARM code exists on the device: 50 tombstones all `ABI: 'x86_64'`; 245 dropbox entries with zero `UnsatisfiedLinkError`/`NO_MATCHING_ABIS`; `/data/app` lib dirs 46×x86_64, 1×x86, 0×arm; the crashing Lens build is `…x86_64`. libhoudini would have been pure risk for zero benefit — see the binfmt note below |
| A second, phantom camera is enumerated and breaks apps | Wrong — `dumpsys media.camera` reports `Number of camera devices: 1` |
| `external_camera_config.xml` needs its `<ignore>` entries enabled | Not needed; follows from the above. The file was read but **not** modified |
| The device is missing the `android.hardware.camera` feature flag | Wrong — `pm list features` lists it, despite no `android.hardware.camera.xml` on disk |
| USB runtime autosuspend is dropping the camera under the app | Wrong — forced `power/control` to `on` (was `auto`, device was `suspended`); Lens crashed byte-identically with no USB flap. The setting is still worth keeping for other reasons, but it fixed nothing here |
| `uvcvideo quirks = 4294967295` is an anomaly (all quirks forced on) | **Wrong — that is the default.** The parameter is documented `Forced device quirks`; `-1`/`0xFFFFFFFF` is the sentinel for "not forced, use the per-device quirks table". Nothing sets it: no `modprobe.d` entry, not on the kernel cmdline. Do not chase this |
| Lens can be fixed outright by the facing patch | Half right — it fixes enumeration, not the later `onCaptureCompleted` failure |

### The libhoudini near-miss, recorded because it was a real hazard

Installing libhoudini was considered and rejected. Beyond being unnecessary (no ARM code exists),
it carried a hazard specific to this setup: `houdini.rc` registers arm64 handlers in
**`binfmt_misc`**, and `binfmt_misc` instances are keyed per *user namespace*. Waydroid's container
is privileged — `grep -rn idmap /var/lib/waydroid/lxc/` returns nothing, so there is no
`lxc.idmap` and the container shares the **host's** global instance. Registration inside Android
would therefore have collided with the host's existing `qemu-aarch64` registration and could have
broken host podman arm64 emulation. If houdini is ever revisited: omit `houdini.rc` and set
`ro.enable.native.bridge.exec=0`.

## Revert

```bash
sudo rm /var/lib/waydroid/overlay/vendor/lib/camera.device@3.4-external-impl.so
sudo waydroid session stop && waydroid session start   # session, not container
```

To switch to `FRONT` instead, deploy the `.front` variant from `artifacts/camera/` the same way.

## Open Camera's blank "Processing settings" — a preference, not a defect

Reported as *"Open Camera crashed when I tried to access processing settings"*, later refined to
*"it froze and I tried to exit the app"*, and finally *"tapping Processing Settings results in a
grey screen"*. It was none of those things. Recording it because four plausible explanations were
wrong in sequence, and because the obvious fix would have made the system worse.

### What it actually was

Open Camera's `preference_camera_api` was set to **`preference_camera_api_old`** — the legacy
Camera1 API. Every entry on the Processing screen requires Camera2, so all of them were filtered
out. An empty full-screen `ListView` on a dark theme is a grey rectangle.

Setting the preference to `preference_camera_api_camera2` fixed it. The screen now shows *Edge mode
algorithm* and *Noise reduction algorithm*.

```bash
# app must be stopped first, or it rewrites the file on exit
sudo waydroid shell -- sh -c "am force-stop net.sourceforge.opencamera"
sudo waydroid shell -- sh -c "sed -i 's|>preference_camera_api_old<|>preference_camera_api_camera2<|' \
    /data/data/net.sourceforge.opencamera/shared_prefs/net.sourceforge.opencamera_preferences.xml"
sudo waydroid shell -- sh -c "am start -n net.sourceforge.opencamera/.MainActivity"
```

Only two entries appear, and that is correct: `android.request.availableCapabilities` is
`[BACKWARD_COMPATIBLE]` and nothing else — no `MANUAL_SENSOR`, no `RAW`, no `BURST_CAPTURE` — so
everything gated on those stays hidden. A UVC webcam genuinely cannot do them.

### Bonus: it silenced the metadata errors

`E/Camera2-Parameters: Error finding static metadata entry 'android.sensor.info.physicalSize'`
was logged five times on every camera open, alongside `android.distortionCorrection.availableModes`.
Those come from **cameraserver's Camera1→Camera2 shim**, which only runs for an app that asked for
the legacy API. On Camera2 the count is **0**.

This matters for planning: `SENSOR_INFO_PHYSICAL_SIZE` (tag `0xf0005`) is genuinely absent from
the HAL — confirmed by scanning the binary, which pushes `ACTIVE_ARRAY_SIZE`, `PIXEL_ARRAY_SIZE`,
`LENS_FACING`, `SENSOR_ORIENTATION` and `LENS_INFO_AVAILABLE_FOCAL_LENGTHS`, but never `0xf0005`.
Adding it was on the table. It turned out not to be needed: **the gap stopped mattering rather than
being patched.** Prefer that outcome where it is available.

### The fix that was considered and rejected

The hypothesis was that Open Camera hides its "Camera API" option because its `supportsCamera2()`
whitelist predates `EXTERNAL`. The HAL makes that a one-byte change, in the *same function* as the
facing patch and with the same shape:

```
0002bd3b: c6 44 24 3f 04    movb $0x4,0x3f(%esp)     <- 4 = EXTERNAL; byte at file offset 0x2bd3f
0002bd40: 8d 44 24 3f       lea  0x3f(%esp),%eax
0002bd44: 6a 01             push $0x1
0002bd46: 50                push %eax
0002bd47: 68 00 00 15 00    push $0x150000           <- ANDROID_INFO_SUPPORTED_HARDWARE_LEVEL
0002bd4d: e8 1e 34 03 00    call CameraMetadata::update@plt
```

`04` → `00` would report `LIMITED`. **Do not do this**, and the reason generalises:

`EXTERNAL` is an *exemption*: it tells the framework the camera may disappear at any moment and
need not supply the full static metadata set. `LIMITED` is a *promise* that it does. This HAL does
not publish `SENSOR_INFO_PHYSICAL_SIZE`, so claiming `LIMITED` invites apps to trust metadata that
is absent and dereference null — **precisely the failure that broke Google Lens** at the facing
stage. It would trade one empty settings screen for a new class of crash across every camera app.

The preference change was tried first because it was free and reversible, and it made the patch
unnecessary. The hypothesis behind the patch was also simply **wrong**: Open Camera connected with
`Camera API version 2` on an unmodified `EXTERNAL` HAL, so its gate never rejected `EXTERNAL` at
all. Why the option is not visible in its settings UI is still unexplained, and no longer matters.

### Hypotheses disproven, in order

| Hypothesis | Verdict |
|---|---|
| The app crashed | **Wrong** — crash buffer empty, no `FATAL`, no tombstone, no `AndroidRuntime` |
| The low-memory killer killed it | **Wrong** — not one `lmkd` line in the log |
| The app hung | **Wrong** — it logged Choreographer frames and accepted input throughout the "frozen" window; no ANR for it |
| It is the `Fence::waitForever` stall | **Wrong.** Tempting, and asserted too confidently. That stall is real and documented above, but it is not this |
| The settings *activity* never launched | **Wrong question** — recent Open Camera opens settings as a **fragment** inside `MainActivity`, so no activity launch was ever expected |
| The settings fragment was never added | **Wrong** — `MyPreferenceFragment` *and* `PreferenceSubProcessing` were both `mAdded=true mState=5` (RESUMED) |
| The fragment's view failed to render | **Wrong** — its `ListView` was `V.ED.VC..` at `0,0-1916,964`, visible and drawn, and the background painted. It simply had **zero child views** |
| Open Camera hides "Camera API" because its whitelist rejects `EXTERNAL` | **Wrong** — Camera2 engaged on an unpatched HAL |

### The lesson worth keeping

Every step of this pointed at the graphics stack or the HAL, because that is where the session's
prior bugs lived. The evidence never actually supported it: no exception, no ANR, a resumed
fragment, a visible correctly-sized view. **An empty list and a failed render look identical on
screen and completely different in `dumpsys activity top`.** Dump the view hierarchy before
theorising about rendering.
