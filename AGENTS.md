# bigtab01 — Waydroid hardware enablement

## Scope

**Primary track:** an HP Envy x2 running Linux with Waydroid, worked toward usable Android
hardware support. This is the project.

**Secondary track: parked.** A native AOSP install was considered and set aside — AOSP needs
the same hardware drivers, which originate on the Linux side, so it makes the goals below
harder rather than easier while discarding a mature userspace. Revisit only if the Waydroid
track hits a hard wall.

## The host

| | |
|---|---|
| Name | `bigtab01.home.syshlt.lan` — currently **not resolvable** |
| Address | `10.42.0.137` — reach it by IP |
| Access | `ssh 10.42.0.137` (key-based, user `jmelanso`, no password required) |
| Hardware | HP Envy x2 13-j012dx, Intel Core M-5Y70 (Broadwell-Y), 8 GB RAM |
| OS | Fedora 44 **Sway Atomic** (rpm-ostree, immutable), kernel 7.1.x, SELinux Enforcing |
| Waydroid | 1.6.3, MAINLINE, images in `/etc/waydroid-extra/images` |

Full detail in [docs/00-host-baseline.md](docs/00-host-baseline.md).

### After a reboot

The host needs two manual steps at the console before it is reachable: the **LUKS passphrase**
for `/var/home`, and **starting `sshd`**, which does not auto-start. Expect several minutes of
`Connection refused` after a reboot; that is normal, not a fault.

### Running commands on the host

Plain `ssh` and `rsync` work normally. There was a period where non-PTY sessions hung; a
`sshd` restart fixed it ([docs/02-ssh-access.md](docs/02-ssh-access.md)). If it recurs, use
`bin/rsh`, which forces a PTY as a workaround.

Inside Android, `waydroid shell` needs `--` and a shell for pipes:

```bash
sudo waydroid shell -- sh -c "dumpsys media.camera | head -30"
```

It prints a cosmetic `ERROR: [Errno 13] Permission denied: 1` after each command; output above
that line is still valid.

### Two constraints worth remembering

- **The OS is immutable.** `/usr` is read-only; packages need `rpm-ostree install` plus a
  reboot. Prefer changes that land in `/etc` or `/var`.
- **Waydroid has overlays enabled** (`mount_overlays = True`). Override files inside the
  Android images by dropping them in `/var/lib/waydroid/overlay/{system,vendor}/` instead of
  modifying the read-only images. Reversible by deleting one file — always prefer this.

### Where builds happen

**All software builds run on the dev box, from inside the project directory — never on bigtab01.**
The laptop has 8 GB of RAM against the dev box's 32 GB, and it is an immutable host where every
toolchain package costs a layered install and a reboot. Build here, copy the artifact across.
`build/` in the repo is a gitignored symlink onto the big disk; see
[docs/06-next-session.md](docs/06-next-session.md) for the layout and for what this box can and
cannot do (no working container runtime; `apt` and `sudo` available).

### sudo

Password auth for `sudo` is temporarily disabled, so sudo commands will run unprompted.
**Always confirm with me before running anything under sudo.**

## Goals, in priority order

1. **Camera** — **DONE.** Live preview works. Waydroid's minigbm `gbm_mesa` wrapper imported
   the camera's fallback buffer with a width of 0 (minigbm fills `meta.total_size` in only after
   calling the backend's `bo_import` hook), so the map returned NULL and the HAL got an all-zero
   plane layout. Fixed by rebuilding `libgbm_mesa_wrapper.so` with the NDK — no AOSP tree — and
   dropping it into the vendor overlay for **both** ABIs. See
   [docs/08-camera-fixed.md](docs/08-camera-fixed.md); the investigation is in
   [docs/01](docs/01-camera-investigation.md), [04](docs/04-phase0-gbm-map.md) and
   [07](docs/07-phase1-android-mesa.md). Reported upstream as
   [minigbm#3](https://github.com/waydroid/android_external_minigbm/issues/3), cross-linked from
   [waydroid#2339](https://github.com/waydroid/waydroid/issues/2339) — see
   [docs/09-upstream-report.md](docs/09-upstream-report.md).
   A separate camera fix — reporting `LENS_FACING_BACK` instead of `EXTERNAL`, so apps that
   require a rear camera will open it — is in [docs/11-camera-facing.md](docs/11-camera-facing.md).
   Two intermittent camera faults remain unreproduced and unexplained — errored V4L2 buffers and
   spurious device removal; [docs/12-v4l2-frame-errors.md](docs/12-v4l2-frame-errors.md) rules out
   the hardware, USB, the driver and CPU load, and ships `bin/camera-watch.sh` to catch the next one.
2. **Sensors** — **DONE for all five.** Android now reports the accelerometer, gyroscope,
   magnetometer, orientation and rotation vector, reading live values from the ITE8350 HID sensor
   hub, and synthesises eight more sensor types on top of them (Gravity, Linear Acceleration, Game
   and GeoMag Rotation Vector, …). Waydroid's own design had the seam: `container_manager.py`
   starts a host daemon named `waydroid-sensord` if one is on `PATH`, and the guest's stub HAL
   stands down by itself when it is. Upstream's daemon reads sensorfw, which Fedora does not
   package, so its libgbinder `ISensors@1.0` server was kept and its **data source replaced with a
   direct IIO reader**. One binary in `/usr/local/bin`, no overlay files, no image changes, no
   layering, no reboot. See [docs/14-sensors.md](docs/14-sensors.md); verify with
   `bin/sensors-test.sh`.
   Turning **auto-rotation** on then exposed a sign bug: the hub reports the gravity vector where
   Android's convention is proper acceleration, so every app that follows the sensor rendered
   upside down. One negation in `GetAccelerometerEvent`, deployed by rebuilding the daemon. See
   [docs/18-sensor-axes.md](docs/18-sensor-axes.md), which also records why the daemon's own
   self-test had been ratifying the bug rather than catching it.
   Separately, the hub does **not** reliably survive s2idle: it can keep answering reads with a
   frozen value, which looks identical to that sign bug. Recovery is a driver reprobe, now
   automatic on resume via a `systemd-sleep` hook, and the daemon re-resolves its IIO nodes by
   name so the reprobe costs nothing. See
   [docs/19-sensor-hub-suspend-wedge.md](docs/19-sensor-hub-suspend-wedge.md).
   **Vibration is the remaining part and is blocked a layer lower** — the motor exists but Linux
   exposes no interface to it at all, so that part starts with the DSDT, not with Waydroid.
3. **Power** — **DONE.** Battery level, voltage, charge status and AC adapter state now come from
   the host. The container could always read the host's `/sys/class/power_supply` and the health HAL
   read it correctly; Waydroid's `healthd_board_battery_update()` then overwrote every field with
   hardcoded fakes (85%, charging) on the one path that reaches Android's `BatteryService`. Fixed
   with a three-byte patch to that hook, deployed via the vendor overlay. See
   [docs/10-battery-fixed.md](docs/10-battery-fixed.md); verify with `bin/battery-test.sh`.
   Temperature is still unreported — that needs an NDK rebuild of the HAL (battery temp) or a new
   thermal HAL (system temps); both are scoped in docs/10.
4. **Wi-Fi — Android's Wi-Fi settings driving NetworkManager.** **In progress: Stages 0 and 2
   done, 3–5 outstanding.** The whole Android Wi-Fi framework was already present and dormant in
   the image (`com.android.wifi` APEX, `wificond`); what was missing was the feature XML, a
   supplicant, and any vendor HAL. Direct hardware access was considered and **rejected**: `wlp1s0`
   is this machine's only network interface, so handing `phy0` to the container costs the host its
   network while saving almost none of the software work. The design is a host daemon over
   libgbinder — the [docs/14](docs/14-sensors.md) pattern — behind a **pluggable host backend**, so
   NetworkManager is one implementation among several and others can add iwd or connman. Findings
   in [docs/28-wifi-feasibility.md](docs/28-wifi-feasibility.md), plan in
   [docs/29-wifi-plan.md](docs/29-wifi-plan.md), wire format pinned against this image in
   [docs/30-wifi-aidl-surface.md](docs/30-wifi-aidl-surface.md).
   **Stage 0** (one overlay file) woke the framework up and proved the no-vendor-HAL path works.
   **Stage 1** — a real nl80211 phy via `virt_wifi` — is blocked and was routed around: the module
   namespaces its netdev but pins its wiphy to `init_net`, so the fork was decided in favour of
   replacing `wificond` in userspace rather than patching the kernel.
   **Stage 2 is done**: `waydroid-wifid` (source in [wifi/](wifi)) registers `wifinl80211` on
   `/dev/binder` and serves `IWificond`, `IClientInterface` and `IWifiScannerImpl`, and Android now
   brings a client interface up and keeps it in `ScanOnlyModeState` against it. See
   [docs/31-wifi-stage2.md](docs/31-wifi-stage2.md); verify with `bin/wifi-test.sh`.
   **Next is Stage 3**, and it is one job — the `NativeScanResult` parcelable layout. The host half
   already works (`waydroid-wifid --scan` lists the real access points). The Wi-Fi **master toggle
   still does not stay on**, and cannot until Stage 4's supplicant: `ROLE_CLIENT_PRIMARY` calls
   `startSupplicant()` before it ever reaches wificond.
5. **Removable media** — let Waydroid see USB sticks and MicroSD cards when inserted.
   Exposing the user's `/run/media/<username>` directory is probably sufficient. **Deprioritised
   below Wi-Fi on 2026-09-07** at the owner's request.

Work the list in order. Don't start a later item until the one before it is either done or
explicitly parked.

## Picking this up again

Start with [docs/06-next-session.md](docs/06-next-session.md) — current state, the immediate next
task, traps already hit, and hypotheses already disproven.

## Repository conventions

This repo is the record of the work. It should contain detailed documentation and artifacts
produced during troubleshooting and configuration — findings, configs, scripts, captured logs,
and the reasoning behind each change.

- `docs/` — numbered investigation notes, one per topic
- `bin/` — helper scripts for working with the host, incl. stdlib-only V4L2 probes
  (`v4l2-formats.py`, `v4l2-curfmt.py`, `v4l2-grab.py`) written because `v4l-utils` is not
  installed and layering a package on an Atomic host costs a reboot, plus the sensor tools
  (`iio-probe.py`, `hid-decode.py`, `sensors-test.sh`, `sensor-hub-reset.sh`) and
  `powerbtn-probe.py`, which measures
  whether the power button reports a *held* press at all, and `netflix-trace.sh`, which straces a
  container app **from the host** — the trick that settled the Netflix question when every
  in-container avenue had run out, plus the Wi-Fi pair (`wifi-wlan0.sh`, which puts a netdev
  in the container's network namespace, and `wifi-test.sh`)
- `sensors/` — source for `waydroid-sensord`, the host-side sensors daemon (goal 2). Build with
  `sensors/build.sh`; see the header comment for why it is a host daemon and not a guest HAL
- `wifi/` — source for `waydroid-wifid`, the host-side wificond replacement (goal 4). Same shape as
  `sensors/`. `WifiBackend.h` is the pluggable seam: everything above it speaks AIDL to Android,
  everything below it speaks to whatever owns the radio on the host, and `NmBackend` is the first
  implementation. Build with `wifi/build.sh`
- `sensor-app/` — "Sensor Info", a dependency-free Kotlin app that displays every sensor live,
  with an attitude panel above it: a compass dial and a software-rendered 3-D view of the
  machine's orientation. Built without Gradle (`aapt2` + `kotlinc` + `d8` + `apksigner`);
  `sensor-app/build.sh --install` puts it on the device
- `quat-monitor/` — "Quat Monitor", a dependency-free Kotlin app that logs the ITE8350's
  hardware-fused quaternion against Android's software fusions at 20 Hz, continuously, so the
  question "is the hardware meaningfully steadier, or should the software fusion be improved?"
  can be settled from data. Logs the raw accel/gyro/magn too, which is what makes the data
  *replayable* — a candidate fusion can be scored offline without a device round-trip. Same
  no-Gradle build as `sensor-app/`; `--install` deploys and grants, `--pull` retrieves the CSVs.
  See [docs/20-quat-monitor.md](docs/20-quat-monitor.md), and read its "interpretation traps"
  before drawing conclusions from the data
- `drm-probe/` — "DRM Probe", a dependency-free Kotlin app that dumps every `MediaDrm` property
  for every registered crypto scheme, plus session and decoder capability. Written to settle what
  a DRM client actually sees here instead of inferring it from Netflix's silence; it declares **no
  permissions on purpose**, so it sees what an ordinary app sees. Same no-Gradle build as
  `sensor-app/`; `drm-probe/build.sh --install` deploys, runs and prints the report. See
  [docs/21-netflix-widevine.md](docs/21-netflix-widevine.md) for the Widevine fix and
  [docs/22-netflix-container-detection.md](docs/22-netflix-container-detection.md) for why Netflix still refuses to run
- `artifacts/` — configs pulled from or staged for the host, with originals kept alongside

Record what was *ruled out* and why, not just what worked. Distinguish clearly between what has
been verified on the host and what is still hypothesis.
