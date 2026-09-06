# Resume brief

Rewritten 2026-09-05 after goals 1 and 3 were completed. Read this first, then
[08-camera-fixed.md](08-camera-fixed.md) and [10-battery-fixed.md](10-battery-fixed.md) for what was
actually wrong in each and what is deployed. [11-camera-facing.md](11-camera-facing.md) covers a
second, separate camera fix (lens facing) plus the `Fence::waitForever` stall.
[12-camera](12-v4l2-frame-errors.md) records two intermittent camera faults that could NOT be
reproduced, and the long list of causes they rule out.

## One-paragraph state

**Goal 1 (camera) is done.** Open Camera shows a live preview; `format coversion failed` and
`Failed to map the buffer` are both zero, confirmed by a `screencap` of the real scene rather than
by absence of errors alone. The bug was in Waydroid's minigbm `gbm_mesa` wrapper: for a format
Mesa cannot allocate it falls back to a linear R8 buffer, but the importer passed
`bo->meta.total_size` as the width when minigbm has not filled that in yet — so the width was
always **0**, the import failed, and the map returned NULL. Fixed by rebuilding
`libgbm_mesa_wrapper.so` with the NDK alone and deploying it through the vendor overlay for both
ABIs. **No AOSP tree was needed**, and the upstream `yuv` fix turned out to be unusable here (it
needs YUV allocation no Mesa has).

**Goal 3 (battery) is also done**, taken out of order because it was asked for directly. Android
now reports the host's real level, voltage, charge status and AC state; the container could always
read the host's `/sys/class/power_supply`, and Waydroid's health HAL was overwriting the values with
hardcoded fakes on the one path that reaches `BatteryService`. Three-byte patch, vendor overlay,
[docs/10](10-battery-fixed.md).

**Session of 2026-09-06** added a second camera fix (`LENS_FACING` `EXTERNAL`->`BACK`, so apps that
demand a rear camera will open it) and spent most of its time ruling things out — see
[11](11-camera-facing.md) and [12](12-v4l2-frame-errors.md). Net: the V4L2 frame errors were never
reproduced and the hardware is provably clean; the one real remaining camera defect is that Mesa
cannot allocate `YCbCr_420_888` at all, so ~4% of fallback allocations fail conversion. Open
Camera's blank "Processing settings" turned out to be a **preference**, not a defect. The USB
autosuspend rule was installed and then withdrawn as unnecessary. **Goal 2 is now scoped but not
started** — read the next section, the position is better than it looks.

## The immediate next task

**Goal 2: sensors — accelerometer, tilt, compass (and vibration).** Scoped 2026-09-06 by
reconnaissance only; **no changes were made**. The position is much better than expected.

### The host already has everything, driven and working

All five sensors sit behind the ITE8350 HID sensor hub (`0018:048D:8350`) on i2c-0, exposed as IIO:

| Node | `name` | Android equivalent |
|---|---|---|
| `iio:device0` | `incli_3d` | tilt / `ORIENTATION` |
| `iio:device1` | `gyro_3d` | `GYROSCOPE` |
| `iio:device2` | `magn_3d` | `MAGNETIC_FIELD` (compass; also has `in_rot_from_north_magnetic_tilt_comp_raw`, a tilt-compensated heading) |
| `iio:device3` | `dev_rotation` | `ROTATION_VECTOR` (quaternion) |
| `iio:device4` | `accel_3d` | `ACCELEROMETER` |

Modules `hid_sensor_{accel,gyro,magn,incl,rotation}_3d` are all loaded. Every node returns live
data with a sane `_scale`, e.g. accel `scale=0.009806650` (raw is milli-g).

### The container can already read them — no plumbing needed

This is the key finding. `/dev/iio:device*` is `crw------- root root` and **not** passed into the
container, but the **sysfs interface is world-readable** (`-rw-r--r--`) and `/sys` is visible
inside. Reading from within the container works *today*, unmodified:

```
$ sudo waydroid shell -- sh -c 'for a in x y z; do cat /sys/bus/iio/devices/iio:device4/in_accel_${a}_raw; done'
0
0
1000          <- exactly 1 g on z, byte-identical to the host. Device lying flat.
```

So no `lxc.mount.entry`, no device-node work, no udev rule. **Do not start by plumbing devices in** —
that trap cost time on the camera and is not needed here.

### What is actually missing

Android reports `No Sensors on the device` (`dumpsys sensorservice`), because Waydroid ships a
**stub** sensors HAL:

```
[waydroid.stub_sensors_hal]: [1]
[init.svc.vendor.sensors-hal-1-0]: [running]
/vendor/bin/hw/android.hardware.sensors@1.0-service.waydroid   10240 bytes   <- a stub, by size alone
```

Waydroid's intended real path is a host daemon, `waydroid-sensord`, which
`tools/actions/container_manager.py:169` starts *if present*:

```python
if which("waydroid-sensord"):
    ... ["waydroid-sensord", "/dev/" + args.HWBINDER_DRIVER] ...
```

**It is not installed.** Not in `PATH`, and `rpm -ql waydroid` (1.6.3-1.fc44) ships no sensor
files at all. So the daemon half of the design is simply absent on Fedora.

### Two routes, and the second is the one this repo has already proven

1. **Get `waydroid-sensord` onto the host.** Upstream's intended design. Costs a build or a layered
   package on an immutable OS, and the guest stub must then be told not to stub
   (`waydroid.stub_sensors_hal`).
2. **Patch or replace the stub HAL in the vendor overlay**, having it read
   `/sys/bus/iio/devices/` directly — which, per the section above, already works from inside the
   container. This is *exactly* the shape of the battery fix in [docs/10](10-battery-fixed.md):
   a small Waydroid stub HAL binary in `/vendor/bin/hw/`, replaced via the vendor overlay, mode
   `0755`. The NDK toolchain and the build recipe from [docs/08](08-camera-fixed.md) are still on
   the dev box.

Start by reading the 10 KB stub with `objdump` to see what it returns for `getSensorsList()`, and
by checking whether `waydroid.stub_sensors_hal=0` changes its behaviour — that property exists for
a reason and is a one-line experiment before any building.

### Vibration — harder than the sensors, and blocked one layer lower

The vibrator **does exist in the hardware** (confirmed by the owner, 2026-09-06). But **Linux
exposes no interface to it**, which makes this a very different problem from the sensors: those are
already readable from inside the container, whereas this one has nothing to read.

Checked and found empty:

| Where a vibrator would appear | Result |
|---|---|
| force-feedback input device | **none** — no `B: FF=` line in `/proc/bus/input/devices`, and no device sets `EV` bit 21 |
| `/sys/class/leds/` | only `hda::mute`, keyboard lock LEDs and `phy0-led` |
| loaded modules | no `ff_memless`, no haptic/vibra driver |
| sysfs by name | nothing matching `*vibra*` or `*haptic*` |
| HID Haptics usage page (`05 0e`) | **absent from all three HID report descriptors** — BT keyboard, ITE8350 sensor hub, SYNA7500 touch |
| `hp-wmi` attributes | `als display dock hddtemp postcode power tablet` — no haptics |

(Beware a false lead: `05 09` appears in two descriptors and is Usage Page **Button**, not a
vibrator. A naive hex grep for it will look like a hit.)

So do **not** start this in Waydroid. Android already runs `vendor.vibrator-1-0` in the container
(visible in `dmesg`) and `vibrator.default.so` is a stub, but there is nothing underneath for it to
drive. The question to answer first is *how the firmware drives it* — most likely an ACPI method on
the ITE8350 embedded controller, which means dumping and decompiling the DSDT (`acpidump` +
`iasl -d`) and looking for a haptic/vibrate method. Only once Linux can buzz the motor does the
Waydroid half become worth doing.

One unexplained device may or may not be related: `HID-SENSOR-ff830080.1.auto`, a vendor-defined
HID sensor collection (usage page `0xff83`) with **no driver bound** — it exists as a bare
`mfd_device` with no attributes. Vendor-specific, purpose unknown, worth a look while in the DSDT.

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
| **`overlay/vendor/bin/hw/android.hardware.health@2.0-service.waydroid`** | **patched health HAL — this is the battery fix**, mode `0755`. Delete to revert |
| **`overlay/vendor/lib/libgbm_mesa_wrapper.so`** | **fixed 32-bit wrapper — this is the camera fix.** Delete to revert |
| **`overlay/vendor/lib64/libgbm_mesa_wrapper.so`** | fixed 64-bit wrapper. Delete to revert |
| **`overlay/vendor/lib/camera.device@3.4-external-impl.so`** | **facing patch, `EXTERNAL`->`BACK`**, mode `0644`. Delete to revert. See [11](11-camera-facing.md) |
| `overlay/vendor/etc/external_camera_config.xml` | pre-existing 720p cap, unrelated to the fix |
| `waydroid_base.prop` | original, byte-identical. Backup at `waydroid_base.prop.orig` |
| Probes in the container | `gbm-android-test`, `gbm-import-android`, `wrapper-harness`, `wrapper-harness32` in `/data/local/tmp` (host path `/home/jmelanso/.local/share/waydroid/data/local/tmp/`, owner `2000:2000`). Harmless; delete anytime |
| `/tmp/camera-test.sh` on host | copy of `bin/camera-test.sh`; `/tmp` clears on reboot |
| Waydroid session | `RUNNING`; container `FROZEN` when idle — normal, not a fault |
| USB autosuspend | back at the `auto` default. The udev rule that pinned it `on` was tried and **withdrawn** — see [12](12-v4l2-frame-errors.md) |
| **Open Camera `preference_camera_api`** | changed `..._old` -> `..._camera2` to populate its Processing settings screen. Original backed up beside it as `..._preferences.xml.bak-preclaude`. See [11](11-camera-facing.md) |
| Toolbox container | `fedora-toolbox-44`, still never used. Safe to delete |

Nothing destructive was done. No packages layered onto the immutable OS. The vendor and system
images were never modified — everything is overlay files.

Exact deployed bytes are kept in [artifacts/phase2/](../artifacts/phase2/), so the fix can be
re-deployed without rebuilding.

## Dev box — and where builds must happen

**Policy (set 2026-09-06): all software builds happen on the dev box, from inside the project
directory. Never on bigtab01.** The laptop has 8 GB of RAM against the dev box's 32 GB, and it is
an immutable host where every toolchain package costs a layered install and a reboot. Build here,
copy the artifact over.

`build/` in the repo is a **symlink to `/home/coder/extra_space/bigtab01-build`** and is gitignored.
The indirection is deliberate: the project lives on a filesystem that is 89% full (41 GB free),
while `extra_space` has 435 GB. So builds are reachable at a project-relative path without landing
their bytes on the small disk. Recreate it with:

```bash
mkdir -p /home/coder/extra_space/bigtab01-build && ln -s /home/coder/extra_space/bigtab01-build build
```

| Path | |
|---|---|
| `build/ndk` | NDK r27c (clang + x86_64 **and** i686 sysroots). `build/ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/clang` |
| `build/minigbm-yuv` | minigbm `yuv` branch checkout |
| `build/wrapper-build/{32,64}` | camera gralloc wrapper build tree |
| `build/sensors` | empty; for the goal 2 sensors HAL |
| `build/acpi` | empty; for DSDT/SSDT decompilation |

Rebuild the camera fix with `phase2/build.sh --abi 32 --fix` and `--abi 64 --fix`; add `--debug`
for argument tracing.

### What the dev box is, and what it can and cannot do

**Debian 13 (trixie) in a container**, 8 cores, 31 GB RAM. Kernel `6.19.14-100.fc42` belongs to the
container host, **not** to this environment — it is not the target kernel for anything.

| | |
|---|---|
| Present | `gcc`, `make`, `ld`, **binutils** (`readelf`, `objdump`, `nm`, `strings`), `curl`, `wget`, `openssl`, `xxd` |
| Missing | `clang` (the NDK brings its own), `python3`, `rsync`, `rpm2cpio`, `cpio`, `bison`, `flex`, `bc` |
| **`apt` + passwordless `sudo`** | **available** — install what you need here rather than on bigtab01 |
| `docker` | **unavailable by design.** This box *is* a Docker container and docker-in-docker is not set up, so the `/home/coder/bin/docker` shim fails with *"No suitable executable found"*. **Do not try to fix it** — plan without a container runtime |

Two consequences worth knowing before planning work:

- **Binary inspection belongs here, not on bigtab01.** binutils is already installed here, and the
  laptop has none of it. Pull the binary over and inspect it locally, as the camera work did.
- **Kernel modules are the awkward case.** A module for bigtab01 must be built against Fedora 44's
  `kernel-devel` for `7.1.13-200.fc44.x86_64`, and there is no container runtime here to get a
  Fedora userspace. **A chroot solves it, and it is verified working** (2026-09-06): `sudo chroot`
  executes into a hand-made tree in this container, and `sudo mount --bind` succeeds, so `/proc`,
  `/sys` and `/dev` can be mapped in and `dnf` will run inside the chroot.

  Bootstrap it from the **Fedora 44 Container Base** rootfs tarball off a Fedora mirror: untar its
  inner `layer.tar` and you have a working Fedora userspace with `dnf`, from which `kernel-devel`,
  `gcc` and `make` install normally. That also fixes the compiler-mismatch problem for free — the
  gcc inside the chroot is the one Fedora built the kernel with, rather than Debian's. Needs
  `apt install xz-utils` first (`xz` is missing; `tar`, `curl`, `wget`, `mount` are present).

  The cheaper alternative is `apt install rpm2cpio cpio` and extracting the `kernel-devel` RPM
  directly. That gets headers only and leaves the gcc mismatch unsolved, so prefer the chroot.
  Either way, **verify a trivial module loads before investing in a real one.** Secure Boot is off
  and `sig_enforce = N` on bigtab01, so unsigned modules will load.

  None of this is needed for goal 2's sensors HAL — the NDK is self-contained and cross-compiles
  for Android on its own, exactly as the camera fix was built. The chroot question only arises if
  the vibrator turns out to need a kernel module.

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

- **A new overlay file is invisible until the *session* restarts.** The vendor overlay is a live
  overlayfs `lowerdir`, and overlayfs does not support changing a lower dir underneath a mount.
  `waydroid container restart` is **not** enough — it leaves the mount in place. Use
  `waydroid session stop` then `waydroid session start`, and confirm with `md5sum` on
  `/var/lib/waydroid/rootfs/...` that the bytes you deployed are the bytes that are live.
- **An overlay file that is a service binary needs mode `0755`.** The existing overlay files are
  `0644`, which is fine for libraries and would silently stop a HAL from starting.

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

A second set — ARM translation, a phantom camera, USB autosuspend, the `uvcvideo quirks` value —
was disproven during the lens-facing work; see [11-camera-facing.md](11-camera-facing.md).

A third set — bad hardware, USB bandwidth, CPU starvation, buffer-queue depth and uevent-driven
node churn — was disproven while chasing the intermittent V4L2 frame errors; see
[12-v4l2-frame-errors.md](12-v4l2-frame-errors.md).

## Goals 3-4

Goal 3 is **done** — see [docs/10](10-battery-fixed.md). Two things it deliberately left alone, both
scoped in that doc: battery *temperature* (needs an NDK rebuild of the health HAL so the board hook
reads a thermal zone instead of being stubbed out) and *system* thermals (this image ships no
thermal HAL at all — `dumpsys thermalservice` says `HAL Ready: false`). Neither is required for the
goal. Goal 3 also has one unverified behaviour: the battery sat at 100% on AC throughout, so
*tracking a changing value* was never exercised. Unplug the charger and re-run `bin/battery-test.sh`.

Goal 4 is untouched.
