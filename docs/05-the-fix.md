# The fix — upstream already has it

> **SUPERSEDED IN PART BY [07-phase1-android-mesa.md](07-phase1-android-mesa.md).** Phase 1 measured
> Android's own Mesa and found it cannot allocate `GBM_FORMAT_YVU420` either. Because `a41dbe7`
> **deletes** the 1D fallback and depends on that allocation succeeding, applying it here would turn
> the black preview into an outright gralloc allocation failure. Two specific claims below are also
> wrong and are corrected inline. The description of what the commit *does* is still accurate.

**An upstream fix for this exact bug exists**, written by the same person who builds the Waydroid
images we are running. Our image predates or excludes it.

```
repo    https://github.com/waydroid/android_external_minigbm
branch  yuv
commit  a41dbe7  "gbm_mesa: Fix mapping YUV"   Alessandro Astone, 2025-07-20
also    a9367e8  "gbm_mesa: Fix detecting gbm_bo_map failure"
```

> **Correction (phase 1).** The image does not exclude both. `libgbm_mesa_wrapper.so` fingerprints
> to `a9367e8` exactly — the two `"Failed to map the buffer"` call sites compile to lines 183 and
> 228, matching that commit and no other. The image is the `yuv` branch tip **minus one commit**;
> only `a41dbe7` is missing.

Our image is built by `eng.aleast` — the same author.

## Root cause, stated exactly

**The shipping `gbm_mesa` wrapper only handles single-plane buffers. YUV is multi-planar.**

The old interface carries exactly one fd and one stride:

```c
struct alloc_args {
    ...
    int out_fd;              /* one fd    */
    uint32_t out_stride;     /* one stride */
};
```

and imports hardcode a single plane:

```c
struct gbm_import_fd_modifier_data data = {
    .num_fds = 1,
    .fds[0] = buf_fd,
    .strides[0] = (int)stride,
};
```

A YV12 buffer has **three** planes. Only plane 0 ever survives that path, so when the camera HAL
asks for the plane layout it gets the zeros we saw in the log:

```
formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 y_str 0 c_str 0 c_step 0
```

## What the fix changes

**1. It teaches the wrapper the format we saw in the log.** The one-line addition to the
DRM→GBM format table:

```c
+	{926497081, GBM_FORMAT_YVU420}
```

`926497081` = `0x37393939` = fourcc `"9997"` = `DRM_FORMAT_FLEX_YCbCr_420_888` — the exact value
from our failure log. Without this mapping the format is unknown, which is why minigbm fell back
to allocating a 1D R8 buffer.

**2. It makes the whole path multi-plane:**

```c
-	int out_fd;                        →   int out_fds[MAX_PLANES];
-	uint32_t out_stride;               →   uint32_t out_strides[MAX_PLANES];
-	.num_fds = 1,                      →   .num_fds = (uint32_t)num_planes,
+	args->out_fds[plane]     = gbm_bo_get_fd_for_plane(bo, plane);
+	args->out_strides[plane] = gbm_bo_get_stride_for_plane(bo, plane);
```

`gbm_import()` is also reworked to take a new `struct import_args` carrying per-plane fds and
strides instead of scalars.

**3. `a9367e8` fixes the error check** — `gbm_bo_map` returns `NULL` on failure, not `MAP_FAILED`,
so failures were silently missed and callers received a NULL pointer.

> There is still a latent bug on the `yuv` branch at `gbm_mesa_wrapper.cpp:231`:
> `if (addr == NULL)` tests the `void **` parameter, which is never NULL, instead of `*addr`.
> The error branch therefore never fires. Worth reporting upstream — it does not block us, but it
> means a future map failure would again go unlogged.
>
> **Correction (phase 1): this does not apply to the binary we are running.** Disassembly shows the
> shipped guard tests the *return value* of `gbm_bo_map` (`test %rax,%rax`), not the parameter, so it
> fires correctly. The `:228` log line is trustworthy evidence that `gbm_bo_map` returned NULL. The
> source-level bug may still be real on the `yuv` branch; it is not real in our build.

## Good news: no Mesa rebuild needed

The fix calls per-plane GBM APIs, and the Mesa already shipping in our image exports all of them.
Verified by pulling `/vendor/lib64/libgbm_mesa.so` and reading its symbols locally:

```
gbm_bo_get_fd_for_plane      present
gbm_bo_get_stride_for_plane  present
gbm_bo_get_plane_count       present
```

So only minigbm needs rebuilding, not the 41 MB `libgallium_dri.so`.

> `readelf` is **not installed on bigtab01**. Running it there returns
> `readelf: command not found`, which greps swallow into empty output that looks like "symbol
> absent". Pull libraries to a machine that has binutils and inspect them there.

## What has to be rebuilt

The fix alters `gbm_ops`, `alloc_args`, and the `import` signature — the ABI between the wrapper
and the gralloc backend. Wrapper and backend must therefore be rebuilt and deployed **as a set**.

| Soong/Make target | Lands at |
|---|---|
| `libgbm_mesa_wrapper` (`gbm_mesa_driver/Android.mk`) | `/vendor/lib64/libgbm_mesa_wrapper.so` |
| `libminigbm_gralloc_gbm_mesa` | `/vendor/lib64/libminigbm_gralloc_gbm_mesa.so` |
| `android.hardware.graphics.mapper@4.0-impl.minigbm_gbm_mesa` | `/vendor/lib64/hw/…so` |
| `gralloc.minigbm_gbm_mesa` | `/vendor/lib64/hw/gralloc.minigbm_gbm_mesa.so` |
| `android.hardware.graphics.allocator@4.0-service.minigbm_gbm_mesa` | `/vendor/bin/hw/…` |

The 32-bit `/vendor/lib/` counterparts exist too and should be replaced alongside.

`libgbm_mesa_wrapper` is gated on `BOARD_MESA3D_BUILD_LIBGBM` and links `libcutils`, `libdrm`,
`libgbm_mesa` — matching the `NEEDED` entries in the shipped binary.

## Deployment needs no image resizing

**The system and vendor images do not need to be enlarged or modified at all.** Waydroid mounts
an overlay whose lowerdir puts our directory *first*, so files there shadow the image:

```
mount -t overlay -o ...,lowerdir=/var/lib/waydroid/overlay/vendor:/var/lib/waydroid/rootfs/vendor,
      upperdir=/var/lib/waydroid/overlay_rw/vendor,...
```

Already proven in practice: `external_camera_config.xml` was overridden this way and the
container confirmed it was live. Deployment is therefore:

```bash
sudo install -D rebuilt/libgbm_mesa_wrapper.so \
    /var/lib/waydroid/overlay/vendor/lib64/libgbm_mesa_wrapper.so
# ... and the other four ...
waydroid session stop && waydroid session start
```

Revert by deleting the files. `/var` has ~197 GB free, so space is not a constraint on the target.

## Open risks

1. **Can this GPU allocate YVU420 at all?** The fix maps the format to `GBM_FORMAT_YVU420` and
   calls `gbm_bo_create` with it — but [phase 0](04-phase0-gbm-map.md) showed the *host's* Mesa
   refuses that format on this Broadwell GPU. Android's Mesa is a different build and may have
   YUV support patched in, but this is **untested and is the single biggest risk**. Cheapest check
   is an NDK-built probe run inside the container, before committing to a full build.

   > **Answered (phase 1): no.** The NDK probe ran; Android's Mesa refuses YVU420 exactly as the
   > host's does. This risk fired, and it kills the upstream fix for this hardware.
2. **Branch/version mismatch.** The repo has only `lineage-18.1` and `yuv` branches, while our
   image is Android 13 / LineageOS 20. How the `yuv` work maps onto the tree that built our image
   needs resolving once we have a checkout.

   > **Resolved (phase 1):** the image is built from `a9367e8` on the `yuv` branch itself, so there
   > is no cross-branch porting problem — but the fix on top of it is the one that cannot work here.
3. **Build environment.** These are Soong/Make targets needing AOSP-internal headers (gralloc4,
   HIDL, libhardware), so a full LineageOS/Waydroid tree is realistically required — roughly
   250 GB. An NDK-only build is plausible for the small wrapper but not for the gralloc HAL libs.

   > **Still true, but disk is no longer scarce:** `/home/coder/extra_space` on the dev box has
   > 460+ GB free. Phase 1 also shrinks the target list — the repair now needed is inside
   > `gbm_mesa_bo_import`, so only the gralloc modules need rebuilding, not the wrapper.

## Background

Mesa's GBM has no YUV support upstream and never did —
[waydroid/android_external_mesa3d#4](https://github.com/waydroid/android_external_mesa3d/issues/4)
records that it was never added because "nobody actually used that". This independently
corroborates the phase 0 measurement. minigbm exists precisely to work around that gap, and the
`yuv` branch is the effort to make that workaround handle multi-planar buffers correctly.
