# Resume brief

Written 2026-09-05 to let a fresh session pick this up without the original conversation.
Read this first, then [05-the-fix.md](05-the-fix.md).

## One-paragraph state

Goal 1 (camera) is fully diagnosed. The camera hardware, driver, HAL, enumeration and V4L2
streaming all work; the preview is black because Waydroid's `gbm_mesa` gralloc wrapper handles
only **single-plane** buffers while YV12 has three, so the camera HAL receives an all-zero plane
layout. **An upstream fix exists** — `waydroid/android_external_minigbm`, branch `yuv`, commit
`a41dbe7`. Nothing has been built yet. The next decision point is a cheap risk test, described
below, before committing to a ~250 GB AOSP checkout.

## The immediate next task

**Test whether Android's bundled Mesa can allocate `GBM_FORMAT_YVU420` on this GPU.**

Why it matters: the fix maps `DRM_FORMAT_FLEX_YCbCr_420_888` to `GBM_FORMAT_YVU420` and calls
`gbm_bo_create`. [Phase 0](04-phase0-gbm-map.md) proved the *host's* Mesa 26.1.8 refuses that
format outright on this Broadwell GPU. Android ships its own Mesa (`libgallium_dri.so`, 41 MB)
which may differ — but if it refuses too, **the upstream fix will not work here** and the whole
build effort is wasted.

How: port `phase0/gbm-map-test-dl.c` to Android x86_64 with the NDK (~2 GB), push it into the
container, run it under `waydroid shell`. It is already `dlopen`-based and declares the GBM API
locally, so it should need little more than retargeting the compiler and pointing `dlopen` at
`/vendor/lib64/libgbm_mesa.so`.

Outcome decides everything:

| Android Mesa can allocate YVU420? | Then |
|---|---|
| **Yes** | The upstream fix should work. Proceed to the build. |
| **No** | The fix alone is insufficient; Mesa needs YUV support too. Much larger problem — reassess before spending disk. |

## State left on bigtab01

Re-verified on the host 2026-09-05 after a power cycle; all rows below are confirmed, not
remembered.

| Item | State |
|---|---|
| `waydroid_base.prop` | **restored to original**, verified byte-identical. Backup at `waydroid_base.prop.orig` |
| `ro.hardware.gralloc` | back to `gbm` (note: overridden to `minigbm_gbm_mesa` at runtime regardless) |
| Vendor overlay | `overlay/vendor/etc/external_camera_config.xml` — resolution capped at 720p. **Not a fix**, harmless; delete to revert |
| Waydroid session | `Session: RUNNING`, `Container: FROZEN` — freeze is the normal idle state (`suspend_action = freeze`), not a fault |
| Toolbox container | `fedora-toolbox-44` present but **never used** — the GBM probes ran natively via `dlopen`. Safe to delete (`toolbox rm fedora-toolbox-44`), or keep for an NDK build |
| `/tmp` probes | probe binaries and scripts copied there; `/tmp` clears on reboot, re-copy as needed |

Nothing destructive was done. No packages were layered onto the immutable OS.

## Traps already hit — do not repeat

- **`readelf` is not installed on bigtab01.** It returns `command not found`, which greps swallow
  into empty output that looks like "symbol absent". Pull libraries and inspect them locally.
- **The vendor image is unmounted while the container is stopped.** Every `/vendor/...` path then
  reads as missing. Verify only with the container running.
- **`/vendor/bin/hw` is mode `drwxr-x--x`.** Cannot `ls` it as a normal user, but `stat` by exact
  name works. A failed `ls` is not evidence of a missing binary.
- **`waydroid shell` needs `--`** before the command and a shell for pipes:
  `sudo waydroid shell -- sh -c "dumpsys media.camera | head"`. The trailing
  `ERROR: [Errno 13] Permission denied: 1` is cosmetic; output above it is valid.
- **`waydroid session start` over SSH needs both** `XDG_RUNTIME_DIR=/run/user/1000` and
  `WAYLAND_DISPLAY=wayland-1`, or it silently defaults to `wayland-0` and fails.
- **Absence of errors is not success.** One gralloc test reported zero failures only because the
  app never launched. Always confirm positively — app running, camera client active.

## Hypotheses already disproven

Do not re-test these; each is documented with evidence.

| Hypothesis | Verdict |
|---|---|
| UVC metadata node needs ignoring | HAL skips `/dev/video1` unaided |
| Capture resolution too high | capped to 720p, failed identically |
| Malformed MJPEG (no Huffman tables) | captured frame is valid baseline JPEG with DHT |
| App incompatibility (`EXTERNAL` level) | Open Camera opens the device fine |
| `ro.hardware.camera=v4l2` | inert leftover, not a bug |
| Provider crash-looping | one deliberate init restart, no tombstone |
| SELinux | no AVC denials |
| Alternative gralloc modules | `default` breaks Android; `minigbm_gbm_mesa` identical failure |
| Buffer geometry mismatch | Mesa does not bounds-check; map succeeds |
| Imported dmabuf unmappable | imports map fine both ways |

## Goals 2-4

Untouched, and per [AGENTS.md](../AGENTS.md) should not start until goal 1 is done or explicitly
parked. One incidental observation for goal 2: `vibrator.default.so` exists in the vendor image,
but `.default` HALs are stubs, so vibration will likely need real work.
