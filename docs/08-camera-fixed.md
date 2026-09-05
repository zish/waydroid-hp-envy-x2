# Goal 1 complete — the camera works

The camera preview works. Built, deployed, and confirmed on bigtab01 on 2026-09-05: Open Camera
shows a live preview, `format coversion failed` and `Failed to map the buffer` are both **0**, and
a `screencap` taken while streaming shows the actual scene rather than a black frame.

No AOSP tree was needed. The whole fix is one rebuilt library per ABI, dropped in through the
vendor overlay, reversible by deleting two files.

## What was actually wrong

[Phase 1](07-phase1-android-mesa.md) established that the allocator and the importer disagree
about the fallback buffer's shape. Phase 2 built the wrapper and instrumented it, and the real
disagreement turned out to be worse than phase 1 inferred.

`gbm_mesa_bo_import()` intends to pass the buffer's byte size as the width:

```c
if (wr->get_gbm_format(s_format) == 0) {
        s_width = bo->meta.total_size;   /* <-- still 0 at this point */
        s_height = 1;
        s_format = DRM_FORMAT_R8;
}
```

But minigbm's `drv_bo_import()` calls the backend's `bo_import` hook **before** it accumulates
`meta.total_size` from the per-plane sizes. So `s_width` is not "the total size" — it is reliably
**zero**. Measured in the camera provider:

```
TRACE import in : fd=14 0x1 fmt=0x20203852 stride=1280 mod=0x0
                     ^^^ width=0, height=1
```

A zero-width image is rejected, `gbm_bo_import` returns NULL, `gbm_bo_map` is then called on a
NULL bo and returns NULL, and the camera HAL is handed the all-zero plane layout:

```
formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 y_str 0 c_str 0 c_step 0
```

> Phase 1 predicted the *shape* of this bug correctly but not its value — it assumed the width
> arriving was `total_size` (≈1384448) and that only the stride and the 1D-to-2D rewrite were
> wrong. See [the harness caveat](#the-harness-was-not-enough) for why that mattered.

## The fix

Two changes, both inside `libgbm_mesa_wrapper.so`, in
[phase2/0001-gbm_import-geometry.patch](../phase2/0001-gbm_import-geometry.patch):

**1. `gbm_import()` — size the buffer from the dmabuf itself.**

```c
if (drm_format == DRM_FORMAT_R8 && height == 1) {
        off_t size = lseek(buf_fd, 0, SEEK_END);
        if (size > 0) {
                lseek(buf_fd, 0, SEEK_SET);
                height = DIV_ROUND_UP((uint32_t)size, GBM_MESA_1D_WIDTH);
                width  = GBM_MESA_1D_WIDTH;      /* 4096 */
                stride = GBM_MESA_1D_WIDTH;
        }
}
```

`lseek(SEEK_END)` on a dma-buf fd returns its size. That is the authoritative source and it needs
no metadata to survive the trip from the 64-bit allocator to the 32-bit camera provider.

**Recomputing the size instead would have been wrong.** The allocator asked for 4096x338
(1384448 bytes); the kernel returned a buffer of **2097152** bytes — 4096x512. Only the dmabuf
knows that:

```
TRACE import fix: dmabuf size=2097152 -> 4096x512 stride=4096
```

**2. `gbm_map()` — clamp the requested rectangle to the bo.**

`gbm_mesa_bo_map()` asks for `total_size x 1` (by then `meta.total_size` *is* populated, so it is
2097152 rather than 0 — non-zero, but still a shape the bo does not have). Asking Mesa for a
rectangle wider than the image fails, so clamp to `gbm_bo_get_width/height`. Sound rather than
merely convenient: the fallback buffer is linear with map stride equal to its width, so its full
extent is exactly the flat byte range the caller means, and minigbm's plane offsets still land
where they should.

Neither change could go in `gbm_mesa_bo_map()`/`gbm_mesa_bo_import()` themselves — those live in
the gralloc modules, which are not rebuilt here.

## Why a wrapper-only rebuild was possible

| | |
|---|---|
| Dependencies | only `libgbm_mesa.so`, plus `liblog`/`libcutils` for two functions — stubbed at link time |
| ABI | `gbm_ops`, `alloc_args` and the `import` signature are untouched, so the shipped gralloc modules load it unchanged |
| Toolchain | NDK r27c alone, `x86_64-` and `i686-linux-android33` |
| Headers | Mesa's public `gbm.h`, fetched; `drm_fourcc.h` vendored as aliases of gbm.h's own fourccs |

Build with [phase2/build.sh](../phase2/build.sh). It verifies each result against the shipped
binary: the exported symbol table must be identical, and the DRM→GBM format table must match
**byte for byte** — which is what proves the vendored `drm_fourcc.h` aliases are right rather
than merely plausible.

## Both ABIs matter

This cost a wasted test cycle. The processes using the wrapper split across ABIs:

```
/system/bin/cameraserver                                            -> /vendor/lib64/...
/vendor/bin/hw/android.hardware.camera.provider@2.7-external-service -> /vendor/lib/...
/vendor/bin/hw/android.hardware.graphics.allocator@4.0-service...    -> /vendor/lib64/...
net.sourceforge.opencamera                                          -> /vendor/lib64/...
```

**Allocation happens 64-bit; the import and map that fail happen in the 32-bit camera provider.**
A 64-bit-only deployment changes nothing for the camera. Both are now deployed, since the same
defect would hit any 64-bit consumer of a fallback buffer.

## The harness was not enough

[phase2/wrapper-harness.c](../phase2/wrapper-harness.c) drives a candidate wrapper through the
gralloc call sequence in a throwaway process. It was worth writing — it proved the rebuild was
byte-faithful in behaviour before anything was installed as the system-wide gralloc backend, and
it caught nothing dangerous only because there was nothing dangerous to catch.

But it fed `gbm_import` the geometry the shipped code *intends* to pass, reconstructed by reading
the source. The real value is 0. **An earlier version of the fix passed the harness cleanly and
still failed on the device.** What resolved it was compiling in argument tracing
(`phase2/build.sh --debug`) and reading what the values actually were:
[artifacts/phase2/trace-debug.log](../artifacts/phase2/trace-debug.log).

> Reconstructing a caller's arguments from its source is a hypothesis, not an observation.
> Where a value crosses a process boundary, measure it.

## Deployed state

| Path | Contents |
|---|---|
| `/var/lib/waydroid/overlay/vendor/lib/libgbm_mesa_wrapper.so` | fixed 32-bit — **this is the one the camera needs** |
| `/var/lib/waydroid/overlay/vendor/lib64/libgbm_mesa_wrapper.so` | fixed 64-bit |
| `/var/lib/waydroid/overlay/vendor/etc/external_camera_config.xml` | pre-existing 720p cap, unrelated |

Exact bytes as deployed are kept in [artifacts/phase2/](../artifacts/phase2/). Revert by deleting
the two `.so` files and restarting the session; nothing in the images was modified.

## Reported upstream

Filed 2026-09-05. This is a real bug in `waydroid/android_external_minigbm` that will hit any GPU
whose Mesa lacks YUV allocation — which, per
[mesa3d#4](https://github.com/waydroid/android_external_mesa3d/issues/4), is all of them. The
`meta.total_size`-is-zero half is a plain bug regardless of GPU.

| | |
|---|---|
| [android_external_minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) | the defect itself, with the fix |
| [waydroid#2339 (comment)](https://github.com/waydroid/waydroid/issues/2339#issuecomment-5554520688) | same symptom reported from an Intel UHD 620 host; why the patch there will not fix it |

Text as posted, and the reasoning behind the split, are in
[09-upstream-report.md](09-upstream-report.md).

## Not yet done

- **Resolutions other than 1280x720 untested.** The overlay still caps the external camera at
  720p. The fix is resolution-independent by construction (it reads the dmabuf size), but that is
  reasoning, not measurement.
- **Stills and video capture untested.** Only the preview path was exercised.
- **Survives a host reboot?** Untested. The overlay lives in `/var`, so it should, but the
  session must be restarted for overlay changes to take effect and that has only been done by
  hand so far.
