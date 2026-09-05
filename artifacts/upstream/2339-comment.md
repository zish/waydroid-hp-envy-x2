Same failure signature here, and the trigger you identified is real — but on this hardware the
zero layout comes from one layer further down, and I don't think the attached patch will fix it.
Everything below is measured in situ rather than inferred.

**Environment:** HP Envy x2 13-j012dx, Intel Core M-5Y70 (Broadwell-Y, HD 5300), Fedora 44 Sway
Atomic, Waydroid 1.6.3 MAINLINE, Android 13 / LineageOS 20 images, Mesa 26.1.8 on both sides.
Identical `ExtCamUtils@3.4: formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0`.

### Your trigger is confirmed

Android's bundled Mesa cannot allocate *any* YUV format on this GPU. Probed inside the container
against `/vendor/lib64/libgbm_mesa.so` with a small NDK-built harness:

```
YVU420 (YV12)   supported(LINEAR)=NO   create FAILED   (all 4 flag combos + modifier path)
NV12            supported(LINEAR)=NO   create FAILED
YUYV            supported(LINEAR)=NO   create FAILED
FLEX_YCbCr_420  supported(LINEAR)=NO   create FAILED
XRGB8888        supported(LINEAR)=yes  create ok, map OK   (stride 5120)
R8              supported(LINEAR)=yes  create ok, map OK   (stride 1280)
```

Matches the host's Mesa exactly, and matches
[android_external_mesa3d#4](https://github.com/waydroid/android_external_mesa3d/issues/4) — a
Mesa-wide gap, not a Broadwell quirk.

### But that is not why the layout is zero

Because Mesa cannot allocate YV12, minigbm substitutes a linear R8 1D fallback buffer. That buffer
is fine — it creates and maps at every geometry I tried. What breaks is the **import** of it.
`gbm_mesa_bo_import()` intends to pass the buffer's byte size as the width:

```c
if (wr->get_gbm_format(s_format) == 0) {
        s_width = bo->meta.total_size;
        s_height = 1;
        s_format = DRM_FORMAT_R8;
}
```

`meta.total_size` is **0** at that moment. `drv_bo_new()` calloc's the bo, and `drv_bo_import()`
accumulates `total_size` from the per-plane sizes only *after* calling the backend's `bo_import`
hook — so the width arriving is reliably zero. Traced in the camera provider with an instrumented
wrapper while Open Camera was streaming:

```
TRACE import in : fd=14 0x1 fmt=0x20203852 stride=1280 mod=0x0     <- width=0, height=1
TRACE import out: bo=0xf790cc20                                     <- a 4096x0 bo
TRACE map out: addr=0x0 map_stride=0
Failed to map the buffer at .../gbm_mesa_wrapper.cpp:305
ExtCamUtils@3.4: formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0 y_str 0 ...
```

A zero-width image is rejected, `gbm_bo_import` returns NULL, `gbm_bo_map` on the NULL bo returns
NULL, and the HAL is handed an all-zero plane layout. That is the line you're seeing.

### Why the `lock()` fallback probably won't help

`lock()` and `lockYCbCr()` both reach the same `gbm_map()` in `libgbm_mesa_wrapper.so`. I checked
against the shipped binary that the failure branch really fires — the compiled guard tests
`gbm_bo_map`'s **return value**, not the `void **` parameter:

```
5518:  call  gbm_bo_map
5521:  mov   %rax,(%rbx)      ; *addr = ret
5524:  test  %rax,%rax
5529:  movq  $-1,(%rbx)       ; *addr = MAP_FAILED  -> ALOGE
```

So when the import has failed, plain `lock()` hands back `MAP_FAILED` and the synthesized I420
layout points at nothing. The empty layout gets traded for a bad pointer.

That said, I can only measure my own machine. If you want to check whether yours fails the same
way, `logcat | grep -i "Failed to map the buffer"` around a camera launch is the tell. If that
line is absent on your box then your import is succeeding and your case is a different one.

### What actually fixed it here

No AOSP tree. One rebuilt `libgbm_mesa_wrapper.so` per ABI, dropped into
`/var/lib/waydroid/overlay/vendor/lib{,64}/`, reverted by deleting two files. The wrapper's only
real dependency is `libgbm_mesa.so` (plus two `liblog`/`libcutils` functions, stubbed at link
time), and the `gbm_ops` / `alloc_args` / import ABI is unchanged, so the shipped gralloc modules
load it as-is. NDK r27c alone builds it.

The fix asks the dmabuf for its own size instead of trusting a field that has not been filled in
yet:

```c
if (drm_format == DRM_FORMAT_R8 && height == 1) {
        off_t size = lseek(buf_fd, 0, SEEK_END);
        if (size > 0) {
                lseek(buf_fd, 0, SEEK_SET);
                height = DIV_ROUND_UP((uint32_t)size, 4096);
                width  = 4096;    /* mirrors the allocator's 1D->2D rewrite */
                stride = 4096;
        }
}
```

Recomputing the size would have been wrong: the allocator asked for 4096x338 (1384448 bytes) and
the kernel returned **2097152** (4096x512). Only the dmabuf knows that, and `lseek(SEEK_END)`
needs no metadata to survive the trip from the 64-bit allocator to the 32-bit camera provider.

**Both ABIs matter.** Allocation happens 64-bit; the import and map that fail happen in
`android.hardware.camera.provider@2.7-external-service`, which is **32-bit**. A 64-bit-only
deployment changes nothing for the camera — that cost me a test cycle.

Result: live preview in Open Camera, `format coversion failed` and `Failed to map the buffer` both
at zero, and a `screencap` during streaming showing the actual scene.

### One more thing worth flagging

`a41dbe7` ("gbm_mesa: Fix mapping YUV") on the minigbm `yuv` branch is **not** a fix on this class
of hardware — it deletes the 1D fallback path entirely and relies on
`gbm_bo_create(GBM_FORMAT_YVU420)` succeeding. Where Mesa has no YUV allocation, `gbm_mesa_alloc`
then returns `-EINVAL` and you get an outright gralloc allocation failure instead of a black
preview. I also tried the multi-plane import direction it takes: Mesa *can* import a 3-plane
YVU420 view of the dmabuf, but mapping it segfaults. Blocked at both ends here.

Filed the underlying bug separately against `android_external_minigbm`: <LINK TO ISSUE B>
