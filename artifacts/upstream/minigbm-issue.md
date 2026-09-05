**Title:** gbm_mesa_bo_import() passes width = bo->meta.total_size, which is always 0 at that point — 1D fallback buffers never import

### Summary

`gbm_mesa_bo_import()` sets `s_width = bo->meta.total_size` for formats Mesa has no GBM
equivalent for ([`gbm_mesa_driver/gbm_mesa_internals.cpp:420`][import], at `a9367e8`):

```c
uint32_t s_format = data->format;
int s_height = data->height;
int s_width = data->width;
if (wr->get_gbm_format(s_format) == 0) {
        s_width = bo->meta.total_size;
        s_height = 1;
        s_format = DRM_FORMAT_R8;
}
```

At the point the backend's `bo_import` hook runs, `meta.total_size` is **0** — `drv_bo_import()`
accumulates it only afterwards:

```c
bo = drv_bo_new(...);                       /* calloc(1, sizeof(*bo)) -> total_size = 0 */
ret = drv->backend->bo_import(bo, data);    /* <-- gbm_mesa_bo_import runs here */
...
for (plane = 0; plane < bo->meta.num_planes; plane++) {
        seek_end = lseek(data->fds[plane], 0, SEEK_END);
        ...
        bo->meta.total_size += bo->meta.sizes[plane];   /* <-- only now */
}
```

So `gbm_bo_import` is handed a zero-width image, rejects it, and returns NULL. Every consumer
that subsequently maps the bo gets NULL back.

Measured in situ, not inferred — trace from an instrumented `libgbm_mesa_wrapper.so` inside the
camera provider while streaming:

```
TRACE import in : fd=14 0x1 fmt=0x20203852 stride=1280 mod=0x0
                      ^^^ width=0, height=1
```

`0x20203852` is `DRM_FORMAT_R8`; stride 1280 is the YV12 **luma** stride, not the fallback
buffer's. The visible result is a black camera preview:

```
Failed to map the buffer at external/minigbm/gbm_mesa_driver/gbm_mesa_wrapper.cpp:228
ExtCamUtils@3.4: formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 y_str 0 c_str 0 c_step 0
ExtCamDevSsn@3.4: threadLoop: format coversion failed!
```

This half of the bug is GPU-independent — the field is unpopulated regardless of driver. It only
becomes *reachable* on a GPU whose Mesa cannot allocate YUV, which per
[android_external_mesa3d#4](https://github.com/waydroid/android_external_mesa3d/issues/4) is
currently all of them.

### Environment

| | |
|---|---|
| Host | HP Envy x2 13-j012dx, Intel Core M-5Y70 (Broadwell-Y, HD 5300) |
| OS | Fedora 44 Sway Atomic, kernel 7.1.13 |
| Waydroid | 1.6.3, MAINLINE, Android 13 / LineageOS 20 images |
| Mesa | 26.1.8, host and container |
| minigbm | `a9367e8` — identified from the two `"Failed to map the buffer"` call sites compiling to lines 183 and 228, which match `a9367e8` and no other commit on the branch |
| Camera | UVC (`HP TrueVision Full HD`), so the external camera HAL |

### Second problem in the same function

Even given the correct size, the importer never reproduces the allocator's geometry.
`gbm_mesa_bo_create()` allocates the fallback as `total_size x 1`, then rewrites it again to
`4096 x N` because drivers may not support 1D allocations. `gbm_mesa_bo_import()` reproduces
neither rewrite:

| | width | height | format | stride |
|---|---|---|---|---|
| allocator, after both rewrites | 4096 | 338 | R8 | 4096 |
| importer, as written | `total_size` | 1 | R8 | `strides[0]` = 1280 |
| importer, as measured | **0** | 1 | R8 | 1280 |

Each variant probed in its own process against the container's `libgbm_mesa.so`:

| variant | request | result |
|---|---|---|
| A — what the code asks for | 1384448x1 R8, stride 1280 | import **FAILED** |
| B — 1D but self-consistent | 1384448x1 R8, stride 1384448 | import **FAILED** |
| C — the geometry actually allocated | 4096x338 R8, stride 4096 | import **OK**, maps OK |
| D — 3-plane YVU420 view, `num_fds=3` | 1280x720 YV12 | import OK, map **SEGFAULTS** |

**B matters:** fixing only the stride is not enough. A 1-row, 1.38-million-pixel-wide image is
rejected whatever the pitch — presumably the maximum texture width (Broadwell's is 16384; that
part is inference). The shape itself has to change.

**C matters more:** with the allocation geometry the bo imports *and* maps at all three geometries
tried, including the `(total_size, 1)` that `gbm_mesa_bo_map()` asks for at
[`gbm_mesa_internals.cpp:467`][map]. So the map path appears to need no change once the import is
correct — the defect looks confined to `gbm_mesa_bo_import()`.

### Suggested fix

The allocated size is not recoverable from anything that crosses the handle: `meta.total_size` is
zero at hook time, `meta.strides[]` holds the YV12 strides, and `priv->map_stride` is
process-local. But the dmabuf knows its own size — and `drv_bo_import()` already trusts exactly
that mechanism a few lines further down, so this is the technique the code uses already rather
than a new one:

```c
if (wr->get_gbm_format(s_format) == 0) {
        off_t size = lseek(data->fds[0], 0, SEEK_END);
        lseek(data->fds[0], 0, SEEK_SET);
        s_format = DRM_FORMAT_R8;
        s_width  = GBM_MESA_1D_WIDTH;                        /* 4096, as the allocator uses */
        s_height = DIV_ROUND_UP((uint32_t)size, GBM_MESA_1D_WIDTH);
        s_stride = GBM_MESA_1D_WIDTH;
}
```

Deriving the height from `meta.total_size` instead would be wrong twice over — it is 0 here, and
even once populated it is the size the allocator *asked* for. The allocator requested
4096x338 = 1384448 bytes; the kernel returned **2097152** = 4096x512:

```
TRACE import fix: dmabuf size=2097152 -> 4096x512 stride=4096
```

Hoisting the size loop in `drv_bo_import()` above the backend hook would fix the zero but not the
rounding, and it touches every backend plus the `destroy_bo` error path. A third option —
propagating the true allocation geometry and stride through the handle metadata — is cleaner in
principle but a much larger change.

### Workaround in use

Not being able to rebuild the gralloc modules without an AOSP tree, I applied the equivalent fix
one layer out, in `gbm_mesa_wrapper.cpp`'s `gbm_import()`, keyed on the fallback's signature
(`drm_format == DRM_FORMAT_R8 && height == 1`). `libgbm_mesa_wrapper.so` builds standalone with
NDK r27c — its only real dependency is `libgbm_mesa.so`, plus two `liblog`/`libcutils` functions
that stub at link time — and the `gbm_ops` / `alloc_args` / import ABI is untouched, so the
shipped gralloc modules load it unchanged. It drops into the Waydroid vendor overlay, so it is
testable without a tree and reverts by deleting a file.

Camera preview works; `Failed to map the buffer` and `format coversion failed` are both at zero.

One trap worth recording: allocation happens 64-bit, but the import and map that fail happen in
`android.hardware.camera.provider@2.7-external-service`, which is **32-bit**. A 64-bit-only
deployment changes nothing for the camera.

Happy to send the wrapper diff, the probe sources, or the full traces if useful.

### Note on `a41dbe7`

`a41dbe7` ("gbm_mesa: Fix mapping YUV") does not fix this on hardware whose Mesa lacks YUV
allocation. It deletes the 1D fallback path and requires `gbm_bo_create(GBM_FORMAT_YVU420)` to
succeed; on failure `gbm_mesa_alloc` returns `-EINVAL`, turning a black preview into an outright
allocation failure. Variant D above also suggests the multi-plane import direction is blocked
here — Mesa imports a 3-plane YVU420 view of the dmabuf but segfaults mapping it.

Related: [waydroid/waydroid#2339](https://github.com/waydroid/waydroid/issues/2339) is the same
symptom reported from an Intel UHD 620 host.

[import]: https://github.com/waydroid/android_external_minigbm/blob/a9367e8/gbm_mesa_driver/gbm_mesa_internals.cpp#L420
[map]: https://github.com/waydroid/android_external_minigbm/blob/a9367e8/gbm_mesa_driver/gbm_mesa_internals.cpp#L467
