# Resume brief

Rewritten 2026-09-05 after phase 1. Read this first, then
[07-phase1-android-mesa.md](07-phase1-android-mesa.md), then [05-the-fix.md](05-the-fix.md)
(which is partly superseded — read 07 first or you will act on two corrected claims).

## One-paragraph state

Goal 1 (camera) is diagnosed down to a single function. The camera, driver, HAL, enumeration and
V4L2 streaming all work. **The upstream fix is dead for this hardware**: phase 1 cross-compiled a
probe with the NDK, ran it in the container, and measured that Android's own bundled Mesa refuses
to allocate `GBM_FORMAT_YVU420` exactly as the host's does — and `a41dbe7` deletes the 1D fallback
and depends on that allocation succeeding, so applying it would replace the black preview with an
outright allocation failure. **In exchange the real defect is now pinned and is much smaller:**
`gbm_mesa_bo_import` reconstructs the fallback buffer as `total_size × 1` with the YV12 luma
stride, a shape the allocator never used and Mesa rejects. Importing with the shape actually
allocated (4096×338 R8, stride 4096) works and maps at every geometry the code asks for. Nothing
has been built yet.

## The immediate next task

**Rebuild `libgbm_mesa_wrapper.so` with a corrected `gbm_import`, using the NDK only, and deploy
it through the vendor overlay.**

This is a new idea that phase 1 made possible, and it is *much* cheaper than the AOSP route —
if it holds, goal 1 needs no 250 GB tree at all.

The reasoning: the geometry correction can be applied inside the wrapper instead of inside the
gralloc module. `gbm_mesa_bo_import` hands `wr->import()` exactly the broken shape
(`width = total_size`, `height = 1`, `format = R8`, `stride = 1280`). That pattern is
recognisable, and `gbm_import` can rewrite it to the allocator's real shape before calling
`gbm_bo_import`:

```c
/* inside gbm_import(), before building gbm_import_fd_modifier_data */
if (drm_format == DRM_FORMAT_R8 && height == 1) {
        /* mirror gbm_mesa_bo_create's second rewrite, which the importer never applied */
        height = DIV_ROUND_UP(width, 4096);
        width  = 4096;
        stride = 4096;
}
```

Why this is attractive:

- `libgbm_mesa_wrapper.so` links only `libcutils`, `libdrm`, `libgbm_mesa`, `liblog`, `libc++` —
  **NDK-buildable**, unlike the gralloc HAL modules.
- **No ABI change.** `gbm_ops`, `alloc_args` and the `import` signature are untouched, so the
  rebuilt wrapper drops in against the shipped gralloc modules.
- **Overlay-deployable and reversible**, exactly as `external_camera_config.xml` already was:
  `/var/lib/waydroid/overlay/vendor/lib64/libgbm_mesa_wrapper.so`, delete to revert.
- Variant C in phase 1 already proved the resulting bo maps at `(total_size, 1)`, which is what
  `gbm_mesa_bo_map` will still ask for. No second change needed.

Steps:

1. Build the wrapper from `a9367e8` (the exact shipped commit) unmodified first, deploy it, and
   confirm the camera still fails *identically*. This proves the build and the overlay drop-in are
   sound before any behaviour change — do not skip it.
2. Apply the `gbm_import` rewrite, redeploy, retest with Open Camera.
3. If it works, report it upstream — the same bug will hit any GPU whose Mesa lacks YUV.

Traps for step 1, already known:

- **Build from `a9367e8`, but keep the `gbm_map` null check the shipped binary actually has.**
  The `a9367e8` source says `if (addr == NULL)` where `addr` is the `void **` parameter — a dead
  branch. The shipped binary tests the return value instead. Write `if (*addr == NULL)`, or the
  rebuild will regress: `*addr` would be left NULL rather than set to `MAP_FAILED`, which is what
  minigbm checks for.
- Headers (`gbm.h`, `drm_fourcc.h`, `log/log.h`, `cutils/properties.h`) are not in the NDK. Either
  vendor them in, or declare the handful of things used locally the way the phase 0/1 probes do.
- Link against the real `/vendor/lib64/*.so` pulled from the device; Android has no symbol
  versioning, so linking directly against those files works.

If the wrapper build turns out not to be feasible, the fallback is the AOSP route for the gralloc
modules. Disk is no longer a blocker: **`/home/coder/extra_space` on the dev box has 460+ GB free.**

## State left on bigtab01

| Item | State |
|---|---|
| `waydroid_base.prop` | original, byte-identical. Backup at `waydroid_base.prop.orig` |
| Vendor overlay | `overlay/vendor/etc/external_camera_config.xml` — 720p cap. **Not a fix**, harmless; delete to revert |
| Phase 1 probes | `gbm-android-test`, `gbm-import-android` left in `/data/local/tmp` inside the container (host path `/home/jmelanso/.local/share/waydroid/data/local/tmp/`, owner `2000:2000`). Harmless; delete anytime |
| `/tmp` on host | probe copies; cleared on reboot |
| Waydroid session | `RUNNING`, container `FROZEN` when idle — normal, not a fault |
| Toolbox container | `fedora-toolbox-44` present, still never used. Safe to delete |

Nothing destructive was done. No packages layered onto the immutable OS.

## Dev box

| | |
|---|---|
| NDK | r27c at `~/ndk-dl/android-ndk-r27c` (clang + x86_64 sysroot extracted, 1.7 GB) |
| minigbm source | `yuv` branch cloned to `/home/coder/extra_space/minigbm-yuv` |
| Big disk | `/home/coder/extra_space`, 460+ GB free — use it for any AOSP work |
| Note | no `python3`, no `rsync`, no `clang` on the dev box; `gcc`, `readelf`, `objdump`, `nm`, `unzip` are present |

## Traps already hit — do not repeat

- **`waydroid shell -- /path/to/binary` returns `Permission denied` even when the file is fine.**
  It is `lxc-attach`'s `execvp`, not permissions, and there is **no AVC** behind it. Wrap it:
  `waydroid shell -- sh -c "/path/to/binary"`. Do not go hunting SELinux for this.
- **Unbuffer stdout in any probe** (`setvbuf(stdout, NULL, _IONBF, 0)`) — a segfault otherwise
  discards everything printed into the ssh pipe.
- **A diff's context lines are not the parent file.** The `a41dbe7` diff appears to show
  `data->format` passed to `wr->import`; the parent actually passes `s_format`. Check with
  `git show <commit>^:<path>`.
- **`readelf` is not installed on bigtab01.** Pull libraries and inspect them on the dev box.
- **The vendor image is unmounted while the container is stopped.** `/vendor/...` then reads as
  missing. Verify only with the container running.
- **`/vendor/bin/hw` is mode `drwxr-x--x`.** A failed `ls` is not evidence of a missing binary.
- **`waydroid shell` needs `--`** and a shell for pipes. The trailing
  `ERROR: [Errno 13] Permission denied: 1` is cosmetic.
- **`waydroid session start` over SSH needs both** `XDG_RUNTIME_DIR=/run/user/1000` and
  `WAYLAND_DISPLAY=wayland-1`.
- **Absence of errors is not success.** Confirm positively — app running, camera client active.

## Hypotheses already disproven

| Hypothesis | Verdict |
|---|---|
| UVC metadata node needs ignoring | HAL skips `/dev/video1` unaided |
| Capture resolution too high | capped to 720p, failed identically |
| Malformed MJPEG (no Huffman tables) | captured frame is valid baseline JPEG with DHT |
| App incompatibility (`EXTERNAL` level) | Open Camera opens the device fine |
| `ro.hardware.camera=v4l2` | inert leftover, not a bug |
| Provider crash-looping | one deliberate init restart, no tombstone |
| SELinux | no AVC denials — including for the exec failure in phase 1 |
| Alternative gralloc modules | `default` breaks Android; `minigbm_gbm_mesa` identical failure |
| Buffer geometry mismatch (host Mesa) | host Mesa does not bounds-check; map succeeds |
| Imported dmabuf unmappable | imports map fine — *when the geometry is self-consistent* |
| **Mesa cannot map the R8 fallback buffer** | **wrong — it maps fine on Android's Mesa too** |
| **The upstream fix `a41dbe7` will fix this** | **wrong — it needs YUV allocation Mesa does not have** |
| **The image predates both fix commits** | **wrong — `a9367e8` is already in; only `a41dbe7` is missing** |
| **`gbm_map`'s error branch is dead, log untrustworthy** | **wrong in the shipped binary — it tests the return value and fires correctly** |
| Fixing only the import *stride* would help | no — variant B, a self-consistent 1384448×1, is still rejected |
| Multi-plane YUV import is a way around | imports (planes=3) but `gbm_bo_map` **segfaults** |

## Goals 2-4

Untouched, and per [AGENTS.md](../AGENTS.md) should not start until goal 1 is done or explicitly
parked. One incidental observation for goal 2: `vibrator.default.so` exists in the vendor image,
but `.default` HALs are stubs, so vibration will likely need real work.
