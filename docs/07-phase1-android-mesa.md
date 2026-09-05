# Phase 1 — testing Android's own Mesa, and what it changes

Phase 0 measured the **host's** Mesa and flagged the result as indicative only, because the
`gbm_bo_map` that actually fails runs against the 41 MB Mesa bundled inside the Waydroid image.
[06-next-session.md](06-next-session.md) set one question as the gate before spending ~250 GB on
an AOSP tree:

> **Can Android's bundled Mesa allocate `GBM_FORMAT_YVU420` on this GPU?**

## Answer: no — and that alone rules out the upstream fix

Two probes were cross-compiled for Android x86_64 with NDK r27c and run inside the container
against `/vendor/lib64/libgbm_mesa.so` (GBM backend `drm`). Sources and captured output:

| | |
|---|---|
| `phase1/gbm-android-test.c` | can Android's Mesa create/map YUV? → [output](../artifacts/phase1/gbm-android-test.out) |
| `phase1/gbm-import-android.c` | which *import* geometries work? → [output](../artifacts/phase1/gbm-import-android.out) |
| `phase1/build.sh` | NDK build, `x86_64-linux-android33` |

```
=== YVU420 (YV12)   supported(LINEAR)=NO ===   create FAILED  (all 4 flag combos + modifier path)
=== NV12            supported(LINEAR)=NO ===   create FAILED
=== YUYV            supported(LINEAR)=NO ===   create FAILED
=== FLEX_YCbCr_420  supported(LINEAR)=NO ===   create FAILED
=== XRGB8888        supported(LINEAR)=yes ===  create ok, map OK   (stride 5120)
=== R8              supported(LINEAR)=yes ===  create ok, map OK   (stride 1280)
```

Identical to the host's Mesa 26.1.8. This is a Mesa-wide gap, not a Broadwell quirk — consistent
with [android_external_mesa3d#4](https://github.com/waydroid/android_external_mesa3d/issues/4).

Per the decision table in the resume brief this is the **No** branch. Reading the upstream commit
shows *why* it is fatal rather than merely unhelpful: `a41dbe7` **deletes the 1D fallback path
entirely** — the `if (alloc_args.drm_format == 0) { … allocate as R8 1D buffer … }` block — and
relies on `gbm_bo_create(GBM_FORMAT_YVU420)` succeeding. On failure `gbm_mesa_alloc` returns
`-EINVAL` and `gbm_mesa_bo_create` propagates it.

> Applying the upstream fix here would replace a black preview with an outright gralloc
> **allocation failure**. It is a regression on this hardware, not a fix.

## Phase 0's open question, answered: the fallback buffer maps fine

Phase 0 could not test whether Android's Mesa maps the R8 buffer minigbm actually substitutes.
It does — at both geometries, exactly as the host's Mesa did:

```
=== R8 1D fallback, exactly as minigbm allocates it today ===
  create 4096x338 R8 ok
    as allocated extent:           map(4096x338) OK  map_stride=4096
    as logical camera dims:        map(1280x720) OK  map_stride=4096
```

So "Mesa cannot map the fallback buffer" is **wrong**. The buffer is fine. Something else breaks.

## What actually breaks: the importer invents a geometry the allocator never used

### Pinning the shipped source first

`artifacts/lib/libgbm_mesa_wrapper.so` contains exactly two `"Failed to map the buffer at %s:%d"`
call sites, and the line numbers are compiled in as immediates:

```
51e1:  41 b8 b7 00 00 00     mov $0xb7,%r8d      → line 183
554a:  41 b8 e4 00 00 00     mov $0xe4,%r8d      → line 228
```

Lines 183 and 228 match commit **`a9367e8`** exactly, and no other commit on the branch:

| commit | ALOGE lines |
|---|---|
| `34d259c` | 178, 222 |
| `d293a61` | 183, 227 |
| **`a9367e8`** | **183, 228** ← shipped |
| `a41dbe7` | 188, 233 |

The binary also contains `waydroid.modifiers.`, `gbm_bo_create_with_modifiers2` and
`gbm_device_get_format_modifier_plane_count`, confirming `d293a61` and `34d259c` are in.

> **This corrects [05-the-fix.md](05-the-fix.md).** The image does *not* predate both fix commits.
> It already contains `a9367e8` ("Fix detecting gbm_bo_map failure"). It is built from the commit
> immediately before `a41dbe7` — the `yuv` branch tip minus one. Only the YUV commit is missing.

> **Also corrects doc 05's "latent bug" note.** Doc 05 warned that `if (addr == NULL)` tests the
> `void **` parameter, so the error branch never fires and the log cannot be trusted. In the
> shipped binary it *does* fire — the compiled guard tests the **return value**:
> ```
> 5518:  call  gbm_bo_map
> 5521:  mov   %rax,(%rbx)      ; *addr = ret
> 5524:  test  %rax,%rax        ; ← the return value, not the parameter
> 5527:  jne   5557
> 5529:  movq  $-1,(%rbx)       ; *addr = MAP_FAILED
>        …ALOGE line 228
> ```
> So `gbm_bo_map()` genuinely returned NULL in the camera provider. The log line is trustworthy.

### The disagreement

Allocation and import compute *different* shapes for the same buffer:

| | width | height | format | stride |
|---|---|---|---|---|
| **allocator** (`gbm_mesa_bo_create`, after both rewrites) | 4096 | 338 | R8 | 4096 |
| **importer** (`gbm_mesa_bo_import`) | `total_size` ≈ 1384448 | 1 | R8 | `strides[0]` = **1280** |

The importer takes `s_width = bo->meta.total_size; s_height = 1; s_format = DRM_FORMAT_R8` but
passes `data->strides[0]`, which is the **YV12 luma stride**, 1280 — describing a 1384448-pixel-wide
image with a 1280-byte pitch. It never reproduces the allocator's second rewrite to 4096×338.

### Measured, inside the container

Each variant ran in its own process, so a crash could not truncate the rest:

| variant | request | result |
|---|---|---|
| **A** — what the shipped code asks for | 1384448×1 R8, stride 1280 | **import FAILED** |
| **A'** — same, unaligned `total_size` | 1382400×1 R8, stride 1280 | **import FAILED** |
| **B** — 1D but self-consistent | 1384448×1 R8, stride 1384448 | **import FAILED** |
| **C** — the geometry actually allocated | 4096×338 R8, stride 4096 | **import OK**, maps OK |
| **D** — 3-plane YVU420 view, `num_fds=3` | 1280×720 YV12 | import OK (planes=3), **map SEGFAULTS** |
| **D'** — 3-plane YVU420, `num_fds=1` | 1280×720 YV12 | import FAILED |

This is the root cause, measured rather than inferred:

```
gbm_bo_import(1384448 x 1, R8, stride 1280)  →  NULL
  → gbm_bo_map(NULL, …)                      →  NULL
    → "Failed to map the buffer at …gbm_mesa_wrapper.cpp:228"
      → gralloc hands the camera HAL a null base
        → "formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0"
```

**B failing matters.** Fixing only the stride is not enough — a 1-row, 1.38-million-pixel-wide
image is rejected regardless. (Likely the GPU's maximum texture width; Broadwell's is 16384.
Inference, not measured.) The shape itself has to change.

**C succeeding matters more.** The bo imported with the allocation geometry maps at *all three*
geometries, including the `(total_size, 1)` that `gbm_mesa_bo_map` asks for:

```
  C  as allocated: 4096x338 R8, stride 4096
      import OK  planes=1 stride=4096
      map at import dims               OK  map_stride=4096
      map at camera dims 1280x720      OK  map_stride=4096
      map at s_width x 1 (gbm_mesa_bo_map) OK  map_stride=4096
```

So `gbm_mesa_bo_map`'s own `s_width/s_height` rewrite is harmless once the import is right.
**The defect is confined to `gbm_mesa_bo_import`.**

**D is the one to not get excited about.** Mesa *can* import a 3-plane YVU420 view of a dmabuf
even though it cannot allocate one — but mapping it segfaults. The multi-plane direction the
upstream fix takes is blocked at both ends on this platform.

## Where this leaves goal 1

The upstream fix is out. In exchange, the defect is now pinned to one function, and repairing it
needs **no Mesa YUV support at all** — the 1D fallback stays, it just has to be imported with the
shape it was allocated with.

Sketch, in `gbm_mesa_bo_import`, replacing the `s_width/s_height` rewrite:

```c
if (wr->get_gbm_format(s_format) == 0) {
        s_format = DRM_FORMAT_R8;
        s_width  = 4096;                                     /* mirror the allocator's */
        s_height = DIV_ROUND_UP(bo->meta.total_size, 4096);   /* second rewrite         */
        s_stride = 4096;
}
```

`total_size` travels in the buffer handle, and `DIV_ROUND_UP` gives 338 for both 1382400 and
1384448, so the reconstruction is robust to the alignment question.

**Open design point, honestly unresolved:** the allocator's real stride (4096) is not carried
across the handle — `bo->meta.strides[]` holds the YV12 strides and `priv->map_stride` is
process-local. The sketch assumes a 4096-wide linear R8 allocation always gets stride 4096, which
held in every measurement here but is an assumption. The alternative is to propagate the true
allocation stride in the handle metadata, which is a larger change.

Scope of the rebuild also shrinks: `gbm_mesa_bo_import` lives in `gbm_mesa_internals.cpp`, so only
the **minigbm gralloc modules** need rebuilding. `libgbm_mesa_wrapper.so` is untouched and the
`gbm_ops`/`alloc_args` ABI is unchanged — unlike the upstream fix, which changes both.

## Still true, still the blocker

This is a **hypothesis with strong evidence, not a verified fix.** It has not been compiled or
run. Building any of it still needs a Soong/AOSP environment. Disk is no longer the constraint:
`/home/coder/extra_space` on the dev box has 460+ GB free.

## Reusable tooling

Both probes are stdlib + `dlopen` only, take the DRM node as `argv[1]`, and
`gbm-import-android` takes a variant id as `argv[2]` (`A A2 B C D D2`) so each runs isolated.
Build with `phase1/build.sh` (set `NDK=` if not at `~/ndk-dl/android-ndk-r27c`).

Deploy: copy to `/home/jmelanso/.local/share/waydroid/data/local/tmp/` on the host (that directory
*is* `/data/local/tmp` inside the container), owner `2000:2000`, mode `0755`.

## Traps hit in phase 1

- **`waydroid shell -- /path/to/binary` fails with `Permission denied`** even for a perfectly
  executable file. It is `lxc-attach`'s `execvp`, not a permission problem — and there is no AVC
  denial behind it. Wrap it: `waydroid shell -- sh -c "/path/to/binary"`.
- **stdout is block-buffered into the ssh pipe.** A segfaulting probe loses everything it printed.
  `setvbuf(stdout, NULL, _IONBF, 0)` first thing in `main`.
- **Reading a diff's context lines is not reading the parent file.** The `a41dbe7` diff appears to
  show `data->format` being passed to `wr->import`; the parent file actually passes `s_format`.
  Confirm with `git show <commit>^:<path>` before building an argument on it.
