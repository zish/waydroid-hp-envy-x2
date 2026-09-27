@tomleejumah — that's the same bug, and your line number pins it precisely.
`gbm_mesa_wrapper.cpp:228` in an unpatched tree is the
`ALOGE("Failed to map the buffer at %s:%d", ...)` inside the wrapper's map op, which is
where this surfaces rather than where it originates: the import already returned `NULL`,
and the caller then maps a `NULL` bo.

The cause is one step earlier. `gbm_mesa_bo_import()` passes `bo->meta.total_size` as the
width, but `drv_bo_import()` fills `meta.total_size` in *after* calling the backend's
`bo_import` hook — so the width arriving at the wrapper is reliably 0. A zero-width image
is rejected outright, `gbm_bo_import()` returns `NULL`, and the map fails at your line 228.

**The diff:**
https://github.com/zish/waydroid-hp-envy-x2/blob/HEAD/phase2/0001-gbm_import-geometry.patch

It asks the dmabuf its own size with `lseek(fd, 0, SEEK_END)` and reconstructs the
`4096 x N` geometry `gbm_mesa_bo_create()` actually allocated. That isn't a novel trick —
`drv_bo_import()` already sizes each plane with `lseek(SEEK_END)` about twenty lines below
the hook. This just does it before the hook needs it.

**Building it:**
https://github.com/zish/waydroid-hp-envy-x2/blob/HEAD/phase2/build.sh builds the wrapper
with the NDK alone, no AOSP tree. Its defaults are paths on my box; override them:

```
NDK=/path/to/android-ndk-r27c MINIGBM=/path/to/minigbm OUT=/tmp/out \
    phase2/build.sh --fix --abi 32
```

`--abi 32` is the one you want. Allocation happens in the 64-bit allocator service, but the
import and map that fail happen in the 32-bit
`android.hardware.camera.provider@2.7-external-service` — so for the camera the fix has to
land in `/vendor/lib`, not `/vendor/lib64`.

**On the prebuilt `.so` — I'd rather not send it, and not for policy reasons.** The gralloc
modules that `dlopen` the wrapper are not rebuilt, so the `gbm_ops`/`alloc_args` ABI has to
match. My build pins minigbm `a9367e8` and verifies itself against the shipped binaries. If
your LineageOS 20 build differs at all, a prebuilt from here fails in a way that looks like
*the fix* not working — a false negative on the only independent test this issue has.
Building from the patch removes that ambiguity. If the NDK build gives you trouble, say so
and I'll send the binary with that caveat attached.

Worth comparing before you start — the `libgbm_mesa.so` my wrapper was built against:

```
2b8b0d322a60dd89c05d278c8583cc3e2c0496de740b237ec5f1600a830717e0  libgbm_mesa.so (32-bit)
ca64248e9daa9b30a957e0903b1d2419c388e493e40ac6b09b5c0e4c835ccaf6  libgbm_mesa.so (64-bit)
```

If yours match, we're on the same build and the ABI question is moot.

**One favour, if you're testing anyway.** The patch changes two things: the import geometry
fix, and a clamp in the map op. I think **the clamp is unnecessary.** A separate
single-process probe showed the wide `(total_size x 1)` map succeeding once the bo has the
right shape, which means the `addr=NULL` originally observed is fully explained by the
degenerate `4096x0` bo and needs no second cause. I can't settle that here cheaply — it
means deploying a clamp-free build and putting a working camera at risk.

If you apply the patch and then drop just this block from the map op:

```c
if ((uint32_t)w > bo_w || (uint32_t)h > bo_h) {
	w = (int)bo_w;
	h = (int)bo_h;
}
```

...and the camera still works, that confirms the fix is the import change alone, and the
diff that belongs upstream is meaningfully smaller. A negative result is just as useful —
it would mean there are two independent problems here, not one.

On scope, for the record: we're both on LineageOS 20 / Android 13 / SDK 33, so this isn't
cross-version evidence yet. But your setup is different hardware with a `v4l2loopback`
source rather than a UVC webcam, which makes your report the first confirmation that this
isn't specific to one machine's camera. That matters for getting it merged.

Full write-up of the diagnosis, the traces, and the phase-1 probes that narrowed it:
https://github.com/zish/waydroid-hp-envy-x2/blob/HEAD/docs/08-camera-fixed.md
