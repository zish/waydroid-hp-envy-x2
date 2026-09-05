# Upstream report — posted 2026-09-05

Two pieces covering the camera fix from [08-camera-fixed.md](08-camera-fixed.md), both now filed.
The text of each, exactly as sent:

| | Posted | Text as sent |
|---|---|---|
| **B** | [android_external_minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) | [artifacts/upstream/minigbm-issue.md](../artifacts/upstream/minigbm-issue.md) |
| **A** | [waydroid#2339 (comment)](https://github.com/waydroid/waydroid/issues/2339#issuecomment-5554520688) | [artifacts/upstream/2339-comment.md](../artifacts/upstream/2339-comment.md) |

Both posted by the user on 2026-09-05, B first so A could link to it. Verified after the fact via
the public API: the comment body carries the real issue URL, not the `<LINK TO ISSUE B>`
placeholder.

## Why #2339 is the same bug, and where its diagnosis stops short

[waydroid#2339](https://github.com/waydroid/waydroid/issues/2339) (justinjsp, 2026-06-14, Intel UHD
620, Waydroid 1.6.2) reports our exact failure line —
`formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0`. Its diagnosis is that Mesa's
libgbm lacks NV12 support, so `lockYCbCr()` returns an empty layout; the attached (untested) patch
detects the empty layout and falls back to plain `lock()` with a synthesized I420 layout.

The trigger is right — we measured the same total absence of YUV allocation. But the layout is zero
because the **import of the R8 fallback buffer fails outright**, and `lock()` and `lockYCbCr()`
both go through the same `gbm_map()`. On a failed import that patch trades an empty layout for a
`MAP_FAILED` pointer. It also lives in the camera HAL, so it needs an AOSP build; our fix is one
`.so` per ABI in the vendor overlay.

Their post carries no `Failed to map the buffer` line, so "their deeper cause is identical" stays
an inference. Draft A asks them to grep for it rather than assuming.

## Verified against upstream source, 2026-09-05

Both drafts previously rested on a claim doc 08 asserted without a source read: that
`drv_bo_import()` populates `meta.total_size` only after calling the backend hook. Fetched
`drv.c` and `gbm_mesa_driver/gbm_mesa_internals.cpp` at `a9367e8` — the shipped commit — and it
holds exactly:

```c
struct bo *drv_bo_import(struct driver *drv, struct drv_import_fd_data *data)
{
	bo = drv_bo_new(drv, ...);                  /* calloc(1, sizeof(*bo))  -> total_size = 0 */
	ret = drv->backend->bo_import(bo, data);    /* gbm_mesa_bo_import runs HERE */
	...
	for (plane = 0; plane < bo->meta.num_planes; plane++) {
		seek_end = lseek(data->fds[plane], 0, SEEK_END);
		...
		bo->meta.total_size += bo->meta.sizes[plane];   /* only now */
	}
}
```

`drv_bo_new()` allocates with `calloc(1, sizeof(*bo))` and sets only width/height/format/use_flags/
num_planes, so `meta.total_size` is genuinely 0 when the hook runs. The measured `width=0` and the
source now agree. **Claim upgraded from inference to verified.**

Three things fell out of the read that made the drafts stronger:

1. **`drv_bo_import()` already sizes each plane with `lseek(SEEK_END)`.** Our fix is not a novel
   trick — it is the mechanism minigbm already trusts for exactly this, twenty lines below the
   hook. That is now the lead argument in draft B's fix section.
2. **The trace and the source corroborate each other.** After import, `total_size` becomes the sum
   of `seek_end - offsets[plane]`, i.e. the real dmabuf size — which is why `gbm_mesa_bo_map()`
   later asks for `2097152 x 1`, exactly the number in
   [trace-debug.log](../artifacts/phase2/trace-debug.log). The whole model is consistent end to end.
3. **Exact line numbers.** The defect is `gbm_mesa_internals.cpp:420`; the same rewrite in
   `gbm_mesa_bo_map()` is line 467. Draft B links both at `a9367e8`.

Sources are cached in the session scratchpad only, not committed — refetch with:

```bash
curl -O https://raw.githubusercontent.com/waydroid/android_external_minigbm/a9367e8/drv.c
curl -O https://raw.githubusercontent.com/waydroid/android_external_minigbm/a9367e8/gbm_mesa_driver/gbm_mesa_internals.cpp
```

## Still open: is the map clamp actually needed?

[08-camera-fixed.md](08-camera-fixed.md) says the `gbm_map()` clamp is needed because "asking Mesa
for a rectangle wider than the image fails". Phase 1's variant C measured the opposite — with a
correctly shaped bo, the wide `(s_width x 1)` map **succeeded**:

```
C  as allocated: 4096x338 R8, stride 4096
    map at s_width x 1 (gbm_mesa_bo_map) OK  map_stride=4096
```

The deployed build changes import *and* map together, so a fixed import with an unclamped map has
never run on the device. The `map out: addr=0x0` in the BEFORE trace is fully explained by the bo
being 4096x0 — a degenerate bo, not a too-wide request.

So the clamp is probably unnecessary. **Neither draft asserts it**: both present the import as the
root cause and the clamp as belt-and-braces, and draft B says outright that the map path appears to
need no change. This does not block posting; it would only sharpen the report.

Settling it means building a clamp-free 32-bit wrapper, deploying it to the overlay, and
restarting the Waydroid session — roughly the phase 2 cycle, and it briefly puts the working
camera at risk. Deferred pending a decision.

## Posting had to be done by hand

This dev box has no way to reach GitHub as the user: no `gh` CLI, no `~/.config/gh`, no
`~/.git-credentials`, no GitHub MCP tool, and this repo has no remote configured. Unauthenticated
HTTPS works — that is how the upstream sources were fetched and how the posted text was verified —
but it is read-only.

So both were pasted by hand from `artifacts/upstream/`. If more upstream traffic is expected
(maintainer replies, a PR against minigbm), installing and authenticating `gh` here would let it
be handled directly: `gh issue comment`, `gh issue view`, `gh pr create`.

## Checklist

- [x] Confirm the `drv_bo_import()` ordering against `drv.c` at `a9367e8`.
- [x] Post B, paste its URL into A, post A.
- [x] Record both URLs here and in [08-camera-fixed.md](08-camera-fixed.md).
- [ ] Optional: settle the map-clamp question with a clamp-free build on the device. Neither post
      asserts the clamp is needed, so this is a sharpening, not a correction.
- [ ] Watch for a maintainer reply. Offered in the issue: the wrapper diff
      ([phase2/0001-gbm_import-geometry.patch](../phase2/0001-gbm_import-geometry.patch)), the
      phase-1 probe sources, and the full traces — none attached yet, so they may be asked for.
