# Resume brief

Rewritten 2026-09-05 after goal 1 was completed. Read this first, then
[08-camera-fixed.md](08-camera-fixed.md) for what was actually wrong and what is deployed.

## One-paragraph state

**Goal 1 (camera) is done.** Open Camera shows a live preview; `format coversion failed` and
`Failed to map the buffer` are both zero, confirmed by a `screencap` of the real scene rather than
by absence of errors alone. The bug was in Waydroid's minigbm `gbm_mesa` wrapper: for a format
Mesa cannot allocate it falls back to a linear R8 buffer, but the importer passed
`bo->meta.total_size` as the width when minigbm has not filled that in yet — so the width was
always **0**, the import failed, and the map returned NULL. Fixed by rebuilding
`libgbm_mesa_wrapper.so` with the NDK alone and deploying it through the vendor overlay for both
ABIs. **No AOSP tree was needed**, and the upstream `yuv` fix turned out to be unusable here (it
needs YUV allocation no Mesa has). **Goal 2 has not been started.**

## The immediate next task

**Goal 2: expose the accelerometer and vibration to Waydroid.** Nothing has been done on it.

What is already known, and it is not much:

- `vibrator.default.so` exists in the vendor image, but `.default` HALs are stubs, so vibration
  will likely need real work rather than configuration.
- The host is an HP Envy x2 convertible, so an accelerometer is present at the hardware level.
  Whether Linux exposes it as IIO and whether Waydroid's sensor HAL can be pointed at it is
  unexamined.

Start by finding out what the host exposes (`/sys/bus/iio/devices/`) and what the container's
sensor HAL expects. Waydroid has a `waydroid-sensord`/`libsensors` story that is worth reading up
on before touching anything.

## Camera: what is left, if you want to close it out fully

Goal 1 is complete for the stated purpose, but these were never exercised
([docs/08](08-camera-fixed.md) lists them):

- resolutions other than 1280x720 (the 720p overlay cap is still in place)
- stills and video capture — only the preview path was tested
- whether the overlay survives a host reboot (it lives in `/var`, so it should)
- ~~reporting the bug upstream~~ — done 2026-09-05:
  [minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3) plus a comment on
  [waydroid#2339](https://github.com/waydroid/waydroid/issues/2339#issuecomment-5554520688).
  Awaiting a maintainer reply; see [docs/09](09-upstream-report.md)

## State left on bigtab01

| Item | State |
|---|---|
| **`overlay/vendor/lib/libgbm_mesa_wrapper.so`** | **fixed 32-bit wrapper — this is the camera fix.** Delete to revert |
| **`overlay/vendor/lib64/libgbm_mesa_wrapper.so`** | fixed 64-bit wrapper. Delete to revert |
| `overlay/vendor/etc/external_camera_config.xml` | pre-existing 720p cap, unrelated to the fix |
| `waydroid_base.prop` | original, byte-identical. Backup at `waydroid_base.prop.orig` |
| Probes in the container | `gbm-android-test`, `gbm-import-android`, `wrapper-harness`, `wrapper-harness32` in `/data/local/tmp` (host path `/home/jmelanso/.local/share/waydroid/data/local/tmp/`, owner `2000:2000`). Harmless; delete anytime |
| `/tmp/camera-test.sh` on host | copy of `bin/camera-test.sh`; `/tmp` clears on reboot |
| Waydroid session | `RUNNING`; container `FROZEN` when idle — normal, not a fault |
| Toolbox container | `fedora-toolbox-44`, still never used. Safe to delete |

Nothing destructive was done. No packages layered onto the immutable OS. The vendor and system
images were never modified — everything is overlay files.

Exact deployed bytes are kept in [artifacts/phase2/](../artifacts/phase2/), so the fix can be
re-deployed without rebuilding.

## Dev box

| | |
|---|---|
| NDK | r27c at `~/ndk-dl/android-ndk-r27c` (clang + x86_64 **and** i686 sysroots extracted) |
| minigbm source | `yuv` branch cloned to `/home/coder/extra_space/minigbm-yuv` |
| Wrapper build tree | `/home/coder/extra_space/wrapper-build/{32,64}` |
| Big disk | `/home/coder/extra_space`, 460+ GB free |
| Note | no `python3`, no `rsync`, no `clang` on the dev box; `gcc`, `readelf`, `objdump`, `nm`, `unzip`, `curl`, `patch`, `perl` are present |

Rebuild the fix with `phase2/build.sh --abi 32 --fix` and `--abi 64 --fix`; add `--debug` for
argument tracing.

## Traps already hit — do not repeat

- **`waydroid shell -- /path/to/binary` returns `Permission denied` even when the file is fine.**
  It is `lxc-attach`'s `execvp`, not permissions, and there is **no AVC** behind it. Wrap it:
  `waydroid shell -- sh -c "/path/to/binary"`. Do not go hunting SELinux for this.
- **Check the ABI before deploying a vendor library.** The camera provider is 32-bit
  (`/vendor/lib/`) while the gralloc allocator, cameraserver and apps are 64-bit
  (`/vendor/lib64/`). A 64-bit-only deployment changed nothing and cost a full test cycle. Confirm
  with `grep libfoo /proc/<pid>/maps`.
- **Reconstructing a caller's arguments from its source is a hypothesis, not an observation.** A
  harness built on the intended values passed cleanly while the device still failed; the real
  width was 0. Where a value crosses a process boundary, compile in tracing and measure it.
- **Unbuffer stdout in any probe** (`setvbuf(stdout, NULL, _IONBF, 0)`) — a segfault otherwise
  discards everything printed into the ssh pipe.
- **Confirm your library is actually live.** `__FILE__` in the log is the giveaway: the shipped
  builds say `external/minigbm/...`, a local rebuild says its own path.
- **A diff's context lines are not the parent file.** Check with `git show <commit>^:<path>`.
- **`readelf` is not installed on bigtab01.** Pull libraries and inspect them on the dev box.
- **The vendor image is unmounted while the container is stopped.** `/vendor/...` then reads as
  missing. Verify only with the container running.
- **`/vendor/bin/hw` is mode `drwxr-x--x`.** A failed `ls` is not evidence of a missing binary.
- **`waydroid shell` needs `--`** and a shell for pipes. The trailing
  `ERROR: [Errno 13] Permission denied: 1` is cosmetic.
- **`waydroid session start` over SSH needs both** `XDG_RUNTIME_DIR=/run/user/1000` and
  `WAYLAND_DISPLAY=wayland-1`.
- **Absence of errors is not success.** `bin/camera-test.sh` now confirms positively — app pid and
  active camera client — before reporting counters.

## Hypotheses disproven along the way

| Hypothesis | Verdict |
|---|---|
| UVC metadata node needs ignoring | HAL skips `/dev/video1` unaided |
| Capture resolution too high | capped to 720p, failed identically |
| Malformed MJPEG (no Huffman tables) | captured frame is valid baseline JPEG with DHT |
| App incompatibility (`EXTERNAL` level) | Open Camera opens the device fine |
| `ro.hardware.camera=v4l2` | inert leftover, not a bug |
| Provider crash-looping | one deliberate init restart, no tombstone |
| SELinux | no AVC denials, including for the exec failure in phase 1 |
| Alternative gralloc modules | `default` breaks Android; `minigbm_gbm_mesa` identical failure |
| Mesa cannot map the R8 fallback buffer | wrong — it maps fine, once imported with a valid shape |
| The upstream fix `a41dbe7` will fix this | wrong — it needs YUV allocation no Mesa has, and it deletes the fallback the code depends on |
| The image predates both fix commits | wrong — `a9367e8` is already in; only `a41dbe7` is missing |
| `gbm_map`'s error branch is dead, log untrustworthy | wrong in the shipped binaries — they test the return value |
| Multi-plane YUV import is a way around | imports (planes=3) but `gbm_bo_map` segfaults |
| The import width is `total_size` | **wrong — it is 0**, and that was the actual bug |
| The 1D buffer is 4096x338, so the fix can recompute it | wrong — the kernel returned 4096x512; size the dmabuf with `lseek` |

## Goals 3-4

Untouched. Per [AGENTS.md](../AGENTS.md), work them in order after goal 2.
