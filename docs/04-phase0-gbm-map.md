# Phase 0 — can Mesa map the camera's buffer?

Goal: decide whether the camera failure is *"Mesa cannot map YUV"* (fix belongs in minigbm) or
*"the wrapper calls Mesa wrong"* (smaller, contained fix), before committing to a build
environment.

**Outcome: partly answered, with one caveat that matters.** Read the caveat before acting on any
of this.

## What was run

Three programs, all in `phase0/`, all stdlib + `dlopen` only — no `gbm.h`, no toolbox container,
no packages layered onto the immutable host:

| Program | Question |
|---|---|
| `gbm-map-test-dl.c` | can Mesa create/map YUV vs RGB buffers? |
| `gbm-fallback-test.c` | does minigbm's R8 "1D fallback" geometry map? |
| `gbm-import-test.c` | can an imported (dmabuf) buffer be mapped? |

A toolbox container was created but deliberately **not** used: it would install its own
`mesa-libgbm-devel`, testing a Mesa that is not the one in play. `dlopen`ing the host's real
`libgbm.so.1` is both faster and more faithful.

## Result 1 — host Mesa cannot allocate YUV at all

```
=== YVU420 (YV12)   supported(LINEAR)=NO ===     create FAILED  (all four flag combos)
=== NV12            supported(LINEAR)=NO ===     create FAILED
=== YUYV            supported(LINEAR)=NO ===     create FAILED
=== XRGB8888        supported(LINEAR)=yes ===    create ok, map OK  (stride 5120)
=== R8              supported(LINEAR)=yes ===    create ok, map OK  (stride 1280)
```

Not merely unmappable — **unallocatable**. `gbm_device_is_format_supported` says no, and
`gbm_bo_create` fails for every usage-flag combination.

## Result 2 — this explains minigbm's fallback

The mystery format in the failure log decodes cleanly:

```
0x37393939  =  fourcc "9997"  =  DRM_FORMAT_FLEX_YCbCr_420_888
```

So the log is coherent — minigbm asks Mesa for flexible YUV, Mesa refuses, and minigbm falls back
to a linear buffer:

```
Unable to allocate 0x37393939 format, allocate as 1D buffer
Allocate 1D buffer as 4096x338 R8 2D texture
Allocated: 1280x720, stride: 4096, map_stride: 4096
```

The arithmetic checks out: 4096 x 338 = 1,384,448 bytes, and a 1280x720 YV12 frame needs
1280 x 720 x 3/2 = 1,382,400. The fallback buffer is correctly sized.

## Results 3 and 4 — two more hypotheses killed

**Geometry mismatch — WRONG.** The buffer physically exists as 4096x338 but the wrapper maps it
with the logical dims 1280x720 (720 > 338). Mesa does not bounds-check this; it succeeds:

```
map full allocated extent   (4096 x 338) : OK  map_stride=4096
map logical dims            (1280 x 720) : OK  map_stride=1280
```

**Imported dmabuf — WRONG.** The original log shows allocation in pid 83 (gralloc allocator) and
the map failure in pid 79 (camera provider), so the buffer crosses a process boundary. But
importing and mapping works, via both import paths:

```
[imported via GBM_BO_IMPORT_FD]           map allocated extent: OK   map logical dims: OK
[imported via GBM_BO_IMPORT_FD_MODIFIER]  map allocated extent: OK   map logical dims: OK
```

> The `fork()`-based cross-process check in `gbm-import-test.c` produced no output. Mesa/DRM
> contexts generally do not survive `fork()`, so that is a flaw in the test, not a result. A real
> cross-process test needs `SCM_RIGHTS` fd passing or a re-exec. **Do not read it as a finding.**

## The caveat — this tested the wrong Mesa

Everything above ran against the **host's** Mesa:

```
host:    mesa-libgbm-26.1.8-1.fc44.x86_64
```

But the Waydroid image ships **its own complete Mesa**:

```
/vendor/lib64/libgallium_dri.so     41,479,872 bytes
/vendor/lib64/libgbm_mesa.so            13,752 bytes   (thin gbm shim over it)
/vendor/lib64/egl/libEGL_mesa.so, libGLESv2_mesa.so, ...
```

41 MB is a full Gallium driver, not a shim. **The `gbm_bo_map` that actually fails runs against
Android's bundled Mesa, not the host's.** So these results are indicative, not conclusive.

What still transfers: the "cannot allocate FLEX_YCbCr_420_888, fall back to R8" behaviour was
logged *by the Android side*, so Android's Mesa also refuses YUV allocation. Consistent with
Result 1. What does **not** transfer: whether Android's Mesa can map the R8 fallback buffer —
untested, and that is precisely the failing step.

## Where this leaves the diagnosis

Confirmed: the camera HAL needs a CPU-mappable YUV buffer; no Mesa involved will allocate YUV, so
minigbm substitutes a linear R8 buffer; mapping that buffer fails inside the camera HAL process.

Not yet explained: **why** that map fails, given that the equivalent operation succeeds on host
Mesa in every configuration tested — same format, same geometry, same import paths.

## Next steps, cheapest first

1. **Read the source (no build needed).** `gbm_mesa_wrapper.cpp:228` and
   `gbm_mesa_internals.cpp:352-382` are named in the logs. Waydroid's minigbm fork is a small
   repo; reading the failing function may explain it outright — for instance if the wrapper maps
   with the *logical* format rather than the R8 the buffer was really allocated as.
2. **Test against Android's Mesa.** Build the same probe with the NDK for Android x86_64, push it
   into the container, run under `waydroid shell`. NDK is ~2 GB — fits current free space, no
   need for the 250 GB AOSP tree.
3. **Check upstream.** Waydroid's issue tracker may already have this; worth ten minutes before
   writing a patch.

## Reusable tooling

All three probes take the DRM node as `argv[1]` and need only `gcc ... -ldl`. They were built on
the dev box (glibc 2.41) and run unmodified on the host (Fedora 44) — no cross-compilation, no
packages installed anywhere.
