# Resume brief

Rewritten 2026-09-06 after goals 1, 2 and 3 were completed. Read this first, then
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

**Goal 2 (sensors) is done**, for all five: accelerometer, gyroscope, magnetometer, orientation
and rotation vector are live in Android, and Android synthesises eight more on top of them.
Waydroid's own design had the seam — `container_manager.py` starts a host daemon called
`waydroid-sensord` if one is on `PATH`, and the guest's 10 KB stub HAL returns at its first line
when it is. Upstream's daemon reads sensorfw (Sailfish's Qt/D-Bus daemon, unpackaged on Fedora), so
its libgbinder `ISensors@1.0` server was kept and the **data source replaced with a direct IIO
reader**. One binary in `/usr/local/bin`, no overlay, no image change, no layering, no reboot.
Source in [sensors/](../sensors), writeup in [docs/14](14-sensors.md), verify with
`bin/sensors-test.sh`. **Vibration is the one part of goal 2 still open**, and still blocked below
Waydroid — see the vibration section below, which is unchanged.

**Session of 2026-09-06** added a second camera fix (`LENS_FACING` `EXTERNAL`->`BACK`, so apps that
demand a rear camera will open it) and spent most of its time ruling things out — see
[11](11-camera-facing.md) and [12](12-v4l2-frame-errors.md). Net: the V4L2 frame errors were never
reproduced and the hardware is provably clean; the one real remaining camera defect is that Mesa
cannot allocate `YCbCr_420_888` at all, so ~4% of fallback allocations fail conversion. Open
Camera's blank "Processing settings" turned out to be a **preference**, not a defect. The USB
autosuspend rule was installed and then withdrawn as unnecessary. Goal 2's five sensors were then
scoped and completed in the same session; see above and [docs/14](14-sensors.md).

**GPS was asked about directly and is closed: there is no receiver in this machine.** The DSDT's
`GPS0` is an unconditional declaration in firmware shared across the Envy x2 13 family — its `_STA`
is a hardcoded `Return (0x0F)` and tests nothing. The UART0 pads were muxed to GPIO and sniffed
directly at 387 kHz; 10.5M samples across both polarities of the enable line, all high, nothing
transmitting. [docs/13](13-gps.md) has the proof and also **corrects** the earlier `_OSI` guess in
[artifacts/acpi/README.md](../artifacts/acpi/README.md) — the LPSS UARTs are off because `SMD5 == 0`
in ACPI NVS, not because of `_OSI`, so `acpi_osi=` would have been a wasted reboot. Do not re-open
this without physical evidence of a module. Probe kept as [bin/gps-probe.py](../bin/gps-probe.py).

**Session of 2026-09-06 (evening)** did two things outside the goal list, both at the owner's
request. **The power button** now suspends on a short press instead of powering the machine
off — **verified on the machine**, `PM: suspend entry (s2idle)` with a clean resume and working
wifi and bluetooth. The hold-to-shutdown stage is configured but **untested**, and two open
questions could still make it unreachable; [docs/15](15-power-button.md) states exactly what is
verified and what is not. **Waydroid's internet access** came back: an orphaned `com.android.networkstack.process`
survived a `system_server` restart and deadlocked `EthernetServiceThread` in an untimed
`awaitIpClientStart()`, so Android had no default route. The host side — bridge, dnsmasq, firewalld,
NAT, forwarding — was correct throughout and was ruled out first. `waydroid container restart`
fixed it; killing the stale process alone did not. **This will recur** on the next `system_server`
restart; [docs/16](16-waydroid-network.md) has the one-command diagnosis.

## The immediate next task

**Goal 2's sensors are done** — the scoping that used to live here is superseded by
[docs/14-sensors.md](14-sensors.md), which records what the hardware actually is (three
transducers, two firmware-fused outputs), the scale factors derived from the HID report descriptor,
the gyroscope's five-second warm-up, and the traps.

Two candidates, in the order AGENTS.md implies:

1. **Vibration** — the rest of goal 2, and the harder half. Unchanged from the previous scoping;
   read the next section. Nothing about the sensors work moves it forward, because the sensors were
   already readable from Linux and the vibrator still is not.
2. **Goal 4, removable media** — untouched, and much cheaper. Exposing the user's
   `/run/media/<username>` to the container is probably sufficient.

Goal 4 is the better next move if the aim is a working machine; vibration is the better next move
if the aim is to finish goal 2. Vibration needs the DSDT, not Waydroid.

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
| **`/etc/systemd/logind.conf.d/10-power-button.conf`** | **power button: short press suspends, long press powers off**, mode `0644`. Was previously unconfigured, i.e. a short press powered the machine off. Delete to revert. See [15](15-power-button.md) |
| **`/etc/systemd/sleep.conf.d/10-s2idle.conf`** | `MemorySleepMode=s2idle`, mode `0644` — pins suspend to s2idle instead of the `deep` default. Delete to revert |
| `/var/tmp/powerbtn-probe.py` | copy of [bin/powerbtn-probe.py](../bin/powerbtn-probe.py), for the untested button-hold question in [15](15-power-button.md). `/var/tmp` survives reboots; safe to delete |
| **`/usr/local/bin/waydroid-sensord`** | **the sensors fix**, 663 KB, mode `0755`. `/usr/local` is a symlink to `/var/usrlocal`, so no layering and no reboot. **Delete to revert** — waydroid then restores `waydroid.stub_sensors_hal=1` by itself |
| `/var/lib/waydroid/waydroid-sensord.pid` | the daemon's single-instance lock. Recreated on demand, safe to delete |
| `/etc/waydroid-sensors.conf` | **not installed.** Optional; documented sample in [artifacts/sensors/](../artifacts/sensors/) |
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
| **GPIO pin 91 (`GP91_UART0_RXD`)** | left muxed as a GPIO input by [bin/gps-probe.py](../bin/gps-probe.py) — `pinctrl-lynxpoint` does not restore the native function on release. Harmless (UART0 is disabled in firmware anyway) and **a reboot restores it**. See [13](13-gps.md) |
| GPIO pin 17 (`GP17`, GPS0 enable) | driven high during the probe, **restored to low**. Back as found |

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
| Missing | `clang` (the NDK brings its own), `rsync`, `rpm2cpio`, `cpio`, `bison`, `flex`, `bc` |
| Added 2026-09-06 | `cmake`, `libglib2.0-dev`, `pkg-config` (for `sensors/build.sh`). **`python3` is present** — the earlier note here saying otherwise was wrong |
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

- **Root is not enough for anything the container manager spawns.** `waydroid-container` runs
  confined as `system_u:system_r:waydroid_t:s0` and its children inherit that domain, so `/run`
  (`var_run_t`) is denied while `/var/lib/waydroid` (`waydroid_data_t`) works. Running the same
  binary by hand under `sudo` succeeds, because an ssh login is `unconfined_t` — so it fails
  exactly one way round and looks like a phantom. **Write to `/var/lib/waydroid`.**
- **`waydroid log` / `/var/lib/waydroid/waydroid.log` captures the stdout and stderr of anything
  waydroid spawns in the background.** That is where the SELinux failure above was finally read
  off, after a lot of guessing. Look there first when a spawned helper misbehaves.
- **`waydroid session stop` does not reliably kill background helpers.** Its cleanup is inside a
  `try:` that swallows every exception, and it runs `kill -9 $pid` with `pid` set to the *whole*
  output of `pidof` — so once two instances exist it becomes `kill -9 "A B"` and can never work
  again. Helpers should enforce single-instance themselves.
- **Processes waydroid spawns become zombies.** Its `background()` helper Popens them and never
  `wait()`s, so exited children sit in state `Z` for the life of the service. Harmless, but
  `pidof` then returns several pids. Count live ones with
  `ps -eo pid,stat,comm | awk '$3=="<comm>" && $2 !~ /Z/'`.
- **A name longer than 15 characters cannot be found by plain `pgrep`** — `/proc/PID/comm` is
  truncated. `pgrep -f` overshoots instead, matching any shell that merely mentions the name,
  including the script doing the search.
- **IIO device indices are not stable across boots.** `accel_3d` was `iio:device4` in one session
  and `iio:device0` in the next. Match on the node's `name`.

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

A fifth set — that the guest stub HAL had to be patched, that a sensors daemon would drag in
sensorfw, that the five IIO nodes are five sensors, that `in_magn_scale = 1.0` means the kernel's
unit lookup failed, and that the gyroscope is faulty — was disproven while doing goal 2; see
[14-sensors.md](14-sensors.md).

A fourth set — the LPSS UARTs being `_OSI`-gated, `GPS0._STA` meaning the receiver exists, a missing
driver, a USB or WWAN-attached GPS, and the module merely being held in reset — was disproven while
answering the GPS question; see [13-gps.md](13-gps.md).

## Goals 3-4

Goal 3 is **done** — see [docs/10](10-battery-fixed.md). Two things it deliberately left alone, both
scoped in that doc: battery *temperature* (needs an NDK rebuild of the health HAL so the board hook
reads a thermal zone instead of being stubbed out) and *system* thermals (this image ships no
thermal HAL at all — `dumpsys thermalservice` says `HAL Ready: false`). Neither is required for the
goal. Goal 3 also has one unverified behaviour: the battery sat at 100% on AC throughout, so
*tracking a changing value* was never exercised. Unplug the charger and re-run `bin/battery-test.sh`.

Goal 4 (removable media) is untouched, and is now the cheapest remaining item.

## Loose ends unrelated to the goals

Two things surfaced on 2026-09-06 that are not part of any goal but should not be lost.

### MacroDroid crash-loops on the WebView data-directory lock

`com.arlosoft.macrodroid` was respawning and dying every 4-6 seconds with:

```
FATAL EXCEPTION: main
java.lang.RuntimeException: Using WebView from more than one process at once with
the same data directory is not supported. https://crbug.com/558377 :
Current process com.arlosoft.macrodroid (pid 13026), lock owner ... (pid 2136)
```

A long-lived MacroDroid process held the WebView data-directory lock, so every process the app
started afterwards died on startup and was restarted, forever. The loop drove the 1-minute load
average from 1.35 to over 11 on a 2-core Core M and took the box into memory pressure, which is
what then killed Firefox, Netflix, NordVPN and GMS — those were casualties, not separate faults.

**It has been uninstalled**, so the loop is stopped. What is *not* known is why two MacroDroid
processes wanted WebView at once: normally the app runs a single process, and the second one
implies a separate process declared for a component (a service or a widget provider). If it goes
back on, check `dumpsys package com.arlosoft.macrodroid` for `processName=` entries that differ
from the package name before assuming it will behave.

### The launcher pins the display to portrait

Only `org.fossify.home` shows the wrong orientation; every other app is fine. It is not the
sensors — `settings get system accelerometer_rotation` returns `0`, so Android is not rotating
anything from sensor data. The launcher requests `SCREEN_ORIENTATION_PORTRAIT`, and with the
Waydroid output at `base=1916x1027` the display honours it and rotates to `cur=1027x1916`
`ROTATION_270`, which is taller than the physical screen. `dumpsys window displays` names the
culprit directly:

```
mCurrentAppOrientation=SCREEN_ORIENTATION_PORTRAIT
deepestLastOrientationSource=ActivityRecord{... org.fossify.home/.activities.MainActivity}
```

There is **no launcher setting to change** — the orientation is hardcoded in its manifest, which
`aapt2 dump xmltree` on the pulled APK shows directly, and its `Prefs.xml` has no rotation key:

```
name = "org.fossify.home.activities.MainActivity"
android:screenOrientation = 1        # 1 = portrait
```

**Fixed with a per-app compat override**, which is narrower than the display-wide
`wm set-ignore-orientation-request true` because it leaves every other app alone:

```bash
sudo waydroid shell -- sh -c 'am compat enable 265464455 org.fossify.home'  # OVERRIDE_ANY_ORIENTATION
sudo waydroid shell -- sh -c 'am compat enable 265451093 org.fossify.home'  # ..._UNDEFINED_ORIENTATION_TO_NOSENSOR
sudo waydroid shell -- sh -c 'am force-stop org.fossify.home'
```

The first gate is what makes the second apply to an app that *did* specify an orientation; without
it the `UNDEFINED_` override only touches apps that specified none. After it, `dumpsys window
displays` reports `mCurrentAppOrientation=SCREEN_ORIENTATION_NOSENSOR` with the launcher resumed,
and the display stays at `cur=1916x1027` instead of rotating to `1027x1916 ROTATION_270`. Undo with
`am compat reset <id> org.fossify.home`.

Two things not established: whether the override survives a container restart (check
`dumpsys platform_compat | grep fossify` after the next one, and move it into a startup hook if it
does not), and the launcher's grid is still the one it chose for portrait, so the icons sit in a
sparse staggered layout — the column count is a launcher setting and can be raised.
