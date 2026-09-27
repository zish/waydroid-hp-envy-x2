# Upstream report — posted 2026-09-05

Two pieces covering the camera fix from [08-camera-fixed.md](08-camera-fixed.md), both now filed.
The text of each, exactly as sent:

| | Posted | Text as sent |
|---|---|---|
| **B** | [android_external_minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) | [artifacts/upstream/minigbm-issue.md](../artifacts/upstream/minigbm-issue.md) |
| **A** | [waydroid#2339 (comment)](https://github.com/waydroid/waydroid/issues/2339#issuecomment-5554520688) | [artifacts/upstream/2339-comment.md](../artifacts/upstream/2339-comment.md) |
| **C** | [#3 (comment)](https://github.com/waydroid/android_external_minigbm/issues/3#issuecomment-5859257287) 2026-09-27 | [artifacts/upstream/minigbm-3-reply.md](../artifacts/upstream/minigbm-3-reply.md) |

A and B were posted by the user on 2026-09-05, B first so A could link to it. Verified after the fact
via the public API: the comment body carries the real issue URL, not the `<LINK TO ISSUE B>`
placeholder.

C is the 2026-09-27 reply to the first outside report of the same bug, posted from this box once
`gh auth login --web` made that possible — see
[the corroboration section](#2026-09-21-independent-corroboration-on-3-from-outside-this-project) and
[the token section](#what-this-box-can-and-cannot-do-on-github--re-measured-2026-09-27). It was
fetched back and diffed against the file: byte identical.

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

## 2026-09-21: independent corroboration on #3, from outside this project

[tomleejumah](https://github.com/waydroid/android_external_minigbm/issues/3#issuecomment-5754450757)
(`author_association: NONE` — a fellow user, **not a maintainer**) reports the identical failure and
asks for the wrapper diff, the prebuilt 32-bit `.so`, or both. Our reply is **C** in the table above —
[artifacts/upstream/minigbm-3-reply.md](../artifacts/upstream/minigbm-3-reply.md), posted
2026-09-27.

Still no maintainer engagement: issue open, unlabelled, one comment, 22 days after filing.

**Their line number corroborates the diagnosis to the line.** They cite
`gbm_mesa_wrapper.cpp:228`. Our patch's last hunk is `@@ -221,8 +282,41 @@`, eight lines of the
unpatched file starting at 221, which puts line 228 exactly on

```c
ALOGE("Failed to map the buffer at %s:%d", __FILE__, __LINE__);
```

— inside the one function the patch modifies. Their tree is byte-identical to ours in that region,
so the patch applies cleanly to it.

**What it settles, and what it does not.** Their camera source is `v4l2loopback`, a virtual device,
on different hardware; ours is a UVC webcam. Identical failure at an identical line across both
kills "it is something about the HP TrueVision webcam" for good, which is the independent
confirmation the report needed. But **both of us are on LineageOS 20 / Android 13 / SDK 33**, so this
is cross-hardware evidence, not cross-version evidence. Do not cite it as the latter.

**Why the reply sends the patch and not the binary**, which is a different argument from the one in
[54-no-vendored-binaries.md](54-no-vendored-binaries.md) and worth keeping distinct: the wrapper is
*our own* build, so distributing it breaks no policy. The reason to decline is that
[phase2/build.sh](../phase2/build.sh) pins minigbm `a9367e8` and the gralloc modules that `dlopen`
the wrapper are not rebuilt, so the `gbm_ops`/`alloc_args` ABI has to match. On a LineageOS 20 build
that differs, our prebuilt fails in a way that reads as *the fix* not working — a false negative on
the only external test this issue has. The reply offers the binary anyway if the NDK build defeats
them, with that caveat attached, and gives the two `libgbm_mesa.so` hashes to compare first.

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

**There may now be a way to settle it without paying that.** The 2026-09-21 reporter above offered
to test and report back, so the 2026-09-27 reply asks them to apply the patch and then drop just the
clamp block from the map op. If their camera still works, the clamp is confirmed unnecessary and the
diff that belongs upstream shrinks to the import fix alone — measured on somebody else's hardware,
with our working camera untouched. A negative result is equally informative: it would mean two
independent problems rather than one. Either way the answer arrives from a second machine, which is
worth more than the same answer from this one.

## What this box can and cannot do on GitHub — re-measured 2026-09-27

The original text here said there was no `gh`, no `~/.config/gh` and no remote. **All three have
since changed, and the conclusion still holds for the case that matters.** Measured rather than
assumed, because "authenticated" and "allowed to comment" are not the same thing and the
difference is the whole point:

| | |
|---|---|
| `gh` CLI | **installed**, authenticated as `zish` from `~/.config/gh/hosts.yml` |
| `origin` | **configured** — `git@zish-github:zish/waydroid-hp-envy-x2.git` |
| the repo | **public** — `raw.githubusercontent.com/zish/waydroid-hp-envy-x2/HEAD/...` returns 200 |
| the credential | a **fine-grained** PAT (no `x-oauth-scopes` header), expires 2027-09-16 |
| on `zish/waydroid-hp-envy-x2` | `{"admin":true,"push":true,...}` |
| on `waydroid/android_external_minigbm` | `{"pull":true,"push":false,"triage":false}` |

A fine-grained PAT only reaches repositories its owner granted, so `gh issue comment` on anything
under `waydroid/` failed with `GraphQL: Resource not accessible by personal access token
(addComment)`. Authenticated *reads* of upstream worked throughout — that is how the inbound comment
below was fetched and how issue state is checked.

**Resolved the same day.** `gh auth login --web` replaces the fine-grained PAT with an OAuth token
(`gho_…`) carrying `repo` scope, and the 2026-09-27 reply posted on the first attempt afterwards. So
this box can now hold upstream conversations directly; `artifacts/upstream/` remains the record of
what was said, not a staging area for hand-pasting.

**One trap, recorded because it nearly caused the wrong conclusion twice.** A repository's
`permissions` object is *collaborator* status, not comment capability:

```
$ gh api repos/waydroid/android_external_minigbm --jq '.permissions'
{"admin":false,"maintain":false,"pull":true,"push":false,"triage":false}
```

That output is **identical before and after** re-authenticating, and it reads like "you cannot write
here" in both cases. It is not the thing that gates `addComment` — commenting on a public issue needs
the token's `repo`/`public_repo` **scope**, which nobody is a collaborator to obtain. Check
`gh auth status` or the `X-Oauth-Scopes` response header, not the repo permissions, and if in doubt
just attempt the post: the refusal is explicit and harmless.

One thing genuinely improved regardless of the token: because the repo is public, a reply can
**link** the patch and the build script instead of pasting a diff into a comment body. Both were
offered that way in the 2026-09-27 reply, and all three URLs were confirmed to return 200 first.

## Checklist

- [x] Confirm the `drv_bo_import()` ordering against `drv.c` at `a9367e8`.
- [x] Post B, paste its URL into A, post A.
- [x] Record both URLs here and in [08-camera-fixed.md](08-camera-fixed.md).
- [ ] Optional: settle the map-clamp question with a clamp-free build on the device. Neither post
      asserts the clamp is needed, so this is a sharpening, not a correction. **Possibly answerable
      on the 2026-09-21 reporter's machine instead** — see the section above.
- [x] Watch for a maintainer reply. Still none after 22 days. What arrived instead was a second
      user with the same bug, which is more useful for the merge case than a maintainer ack would
      have been on its own.
- [x] Send the 2026-09-27 reply —
      [posted](https://github.com/waydroid/android_external_minigbm/issues/3#issuecomment-5859257287),
      4082 bytes, fetched back and diffed against
      [artifacts/upstream/minigbm-3-reply.md](../artifacts/upstream/minigbm-3-reply.md): byte
      identical, so what is on GitHub is exactly what this repo records.
- [ ] If they reply with their two `libgbm_mesa.so` hashes, record whether they match ours. Matching
      hashes would mean the ABI caution was unnecessary and a prebuilt could be offered freely next
      time; differing ones would justify it.
