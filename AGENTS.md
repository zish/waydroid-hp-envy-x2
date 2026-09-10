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
  **Dropping the file is not enough, and `waydroid container restart` will not pick it up.** The
  overlay is an overlayfs mount whose lowerdir is that directory, created once by
  `waydroid-container.service`; adding a file to a mounted lowerdir is undefined behaviour and here
  it is simply invisible. Deploying means `sudo systemctl restart waydroid-container.service` and
  then starting a session again — which **drops the kiosk session back to the SDDM greeter**, so it
  needs someone at the machine. Always confirm a file is in effect by reading it from *inside* the
  container, never by `ls`-ing the overlay directory. See
  [docs/32-wifi-stage3.md](docs/32-wifi-stage3.md); this bit a Stage 0 file that had silently not
  been in effect for a day. Overlay content is now packaged rather than hand-copied:
  `waydroid-overlay-sync` reconciles `/var/lib/waydroid/overlay` from payload in
  `/usr/share/waydroid-overlay` before the container starts, so a wiped overlay repairs
  itself and `waydroid-overlay-sync --verify` answers whether the live overlay still matches
  ([docs/36-packaging.md](docs/36-packaging.md)).

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
   A third SELinux-shaped trap lived here too: the daemon was losing **every** binder priority
   inheritance — about a million a boot, each logged as `binder: <tid> RLIMIT_NICE not set` —
   because `waydroid_t` is not allowed `capability sys_nice` and the kernel asks with the
   *noaudit* variant, so `ausearch` shows nothing. Fixed by giving the container a real
   `RLIMIT_NICE` through a `waydroid-container.service` drop-in rather than a policy module. See
   [docs/40-binder-nice.md](docs/40-binder-nice.md).
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
   Separately, and not about Android: do not trust a battery percentage on this machine. The
   pack's gauge is uncalibrated and reads high — it hard-cut at roughly 18% on 2026-09-09, with no
   shutdown and no suspend — and `dunst` fails on every session start, so the host has **no**
   working notification path for a low-battery warning or anything else. See
   [docs/41-battery-cutoff.md](docs/41-battery-cutoff.md).
4. **Wi-Fi — Android's Wi-Fi settings driving NetworkManager.** **In progress: Stages 0 and 2–5
   largely done; some Stage 5 polish outstanding.** The whole Android Wi-Fi framework was already present and dormant in
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
   [docs/31-wifi-stage2.md](docs/31-wifi-stage2.md).
   **Stage 3 is done**: the host's real access points now arrive inside Android with the right
   names, signal strengths and security flags — `cmd wifi list-scan-results` reads straight out of
   NetworkManager. The `NativeScanResult` layout was disassembled from this image's `framework.jar`;
   the beacon information elements Android parses security out of have to be **synthesised**,
   because NM keeps the conclusions and discards the beacon; and `tsf` is load-bearing, since
   results older than the scan Android asked for are dropped without a word. See
   [docs/32-wifi-stage3.md](docs/32-wifi-stage3.md); verify both stages with `bin/wifi-test.sh`.
   **Stage 4 is done**: Android drives a real access point end to end and has **validated internet**
   over a Wi-Fi network it controls itself. A second radio — a TP-Link Archer T3U on
   `rtw88_8822bu` — was added so Android can never strand the host, which also falsifies
   [docs/28](docs/28-wifi-feasibility.md)'s premise that `wlp1s0` is the only interface. The
   supplicant shim is in [wifi/Supplicant.cpp](wifi/Supplicant.cpp); the control plane goes through
   NetworkManager to the T3U while the data plane still goes over `waydroid0`.
   Three bugs of ours were found and fixed on the way, the worst of which —
   `getConnectionCapabilities` writing a parcelable without `readTypedObject()`'s non-null marker —
   **killed `system_server` on every successful association**, which is why nothing could have
   worked before. What finally produced a routable network was the uplink rename
   (`lxc.net.0.name = wlan0`) that [docs/29](docs/29-wifi-plan.md) had always prescribed and
   [docs/33](docs/33-wifi-stage4.md) had deferred; it also retires `bin/wifi-wlan0.sh`
   and kills the Ethernet-outscores-Wi-Fi trap for good. The wificond name race is now closed
   durably by an overlay `.rc` that execs `/system/bin/true`. See
   [docs/34-wifi-second-radio.md](docs/34-wifi-second-radio.md).
   **Stage 5 is largely done** — `waydroid-wifid.service` runs the daemon from boot, and a reboot
   was watched end to end: the daemon came up before the container, waited for its servicemanager,
   registered both names, and Android reached `ROLE_CLIENT_PRIMARY` with validated internet with
   nobody touching anything. Two findings dominate.
   **The daemon only ever worked because it was started by hand.** systemd runs a `bin_t` binary as
   `unconfined_service_t`, and the host policy allows `binder { call }` to that domain but **denies
   `binder { transfer }`** from `container_runtime_t`. Calls carrying no binder succeed while every
   callback-passing call fails with a bare `DeadObjectException`, and the rule is `dontaudit`ed, so
   `ausearch` shows nothing. Fixed with `SELinuxContext=` in the unit — a policy module was rejected
   as the weaker option, since it would grant that transfer to every unconfined service on the host.
   **Android showed no networks because of a channel list, not a timestamp.** `WificondScannerImpl`
   has *two* filters incrementing one counter — a `tsf` check and a `containsChannel()` check — so
   "Filtering out N" is ambiguous, and the channel lists come from our own `getAvailable*Channels`,
   which was the one handler that logged nothing. It does now. Two real `tsf` bugs were fixed on the
   way (NM truncates `LastSeen` to whole seconds; a scan is a sweep, not an instant).
   Android also does not restart Wi-Fi after the daemon restarts, and the cause is AOSP's own quota:
   `SelfRecovery` allows 2 restarts an hour and one daemon restart delivers 2–3 binder deaths, so
   the first spends the budget. `waydroid-wifi-nudge` re-enables it, respecting `wifi_on`.
   The radio is now pinned by **factory MAC**, not by `wlp0s20u1`, which is a USB-topology name.
   See [docs/35-wifi-stage5.md](docs/35-wifi-stage5.md).
   **Still open**: the T3U wedge has no automatic trigger (and `nmcli connection up` remains the
   mandatory discriminator before reprobing — it saved a wasted reprobe this session);
   `NmBackend::forget()` is implemented but nothing calls it, so forgetting a network in Android
   leaves its PSK in NetworkManager; and signal/state fidelity in Android's UI is unreviewed.
5. **Removable media** — let Waydroid see USB sticks and MicroSD cards when inserted.
   Exposing the user's `/run/media/<username>` directory is probably sufficient. **Deprioritised
   below Wi-Fi on 2026-09-07** at the owner's request.
6. **Android's per-app freezer** — make `CachedAppOptimizer`'s cgroup v2 freezer actually
   work, so cached apps stop burning CPU while the machine is awake but idle. **Added 2026-09-10
   at the owner's request; scoped, nothing built.** Android does **not** use CRIU for this and
   never has — CRIU is ruled out here anyway, since `strings /usr/bin/criu | grep -c binder`
   returns **0** and every Android process is full of binder fds. The feature is off
   (`use_freezer=false`, `use_compaction=false`) and **cannot simply be switched on**: Waydroid's
   own LXC config mounts the container's `/sys/fs/cgroup` read-only
   (`lxc.mount.auto = cgroup:ro sys:ro proc`, the same line [docs/17](docs/17-hybrid-sleep.md)
   quotes for ACPI), so `libprocessgroup` never created any `uid_*` cgroup and the writes beneath
   the flag would fail. Beware a convincing red herring: logcat is full of
   `ActivityManager: <pkg> is exempt from freezer`, which is exemption bookkeeping that runs
   whether or not anything is ever frozen. A cheaper thing already works and should be tried
   first — the host can freeze the **whole container** via
   `/sys/fs/cgroup/lxc.payload.waydroid/cgroup.freeze` (81 processes, **1534 tasks**), untested,
   with the `CLOCK_MONOTONIC` jump on thaw as the expected failure mode. Measure whether idle apps
   cost anything before building any of it. See [docs/43-app-freezer.md](docs/43-app-freezer.md).

**Screen brightness — DONE, and not on the list above.** Added at the owner's request on
2026-09-09, between Wi-Fi Stage 5 and goal 5. Android's brightness slider now drives the real
panel backlight. The machine has **no ambient light sensor** — the ITE8350 declares only five
sensor types and there is no `ACPI0008` and no ALS on either i2c bus — so *auto*-brightness can
never work here and Android already knows it (`mAutoBrightnessAvailable=false`). Manual control
was broken because Waydroid's shipped light HAL is a 15 KB stub that registers `ILight` and
discards every call; it contains no file path strings at all. `waydroid-sensord` now serves
`android.hardware.light@2.0::ILight` as a second name on the hwbinder connection it already
holds — it lives there because `container_manager.py` gates its one host daemon on that literal
binary name, which also means it inherits `waydroid_t` instead of the `unconfined_service_t` that
cost Wi-Fi Stage 5 a day. Android 13 reaches `ILight` rather than the composer here
(`useSurfaceControl=false`, because Waydroid ships composer 2.1), which was verified before any
code was written. See [docs/37-brightness.md](docs/37-brightness.md); verify with
`bin/brightness-test.sh`. **It is durable now, and making it durable is what exposed a second
fault.** The overlay `.rc` was deployed on 2026-09-09, which retired the hand-swap — and the
hand-swap turned out to be load-bearing. A hand-started daemon is `unconfined_t`;
`container_manager.py` spawns it as `waydroid_t`, and `waydroid_t` is denied `write` on `sysfs_t`,
so every `setLight` returned `Status::UNKNOWN` from an `EACCES` and the slider moved nothing.
Being root does not help — SELinux denies the domain, not the user, which falsifies `Backlight.h`'s
premise. The denial is `dontaudit`ed, so `ausearch` was silent, exactly as in
[docs/40](docs/40-binder-nice.md) and [docs/35](docs/35-wifi-stage5.md); the way out is to ask the
kernel with `selinux.selinux_check_access()` rather than wait for an audit record that will never
come. Fixed with a private type on the one sysfs attribute plus a udev rule to reapply it each
boot, since sysfs labels do not persist — `artifacts/backlight/install.sh`, written in CIL so it
needs no `selinux-policy-devel` and no reboot. See
[docs/42-backlight-selinux.md](docs/42-backlight-selinux.md). **Verified end to end by a reboot on 2026-09-10**: udev
labelled the attribute on the real boot path, `container_manager.py` respawned the daemon as
`waydroid_t`, there were zero `EACCES` lines against 697 before, and the full 0.2/0.5/0.8/1.0 sweep
passed within 4 raw units. Note `runcon` cannot stand in for that reboot — `waydroid_t` is denied
`entrypoint` on `bin_t`, so the daemon *inherits* the domain from `container_manager.py` rather
than transitioning into it. Two things found while verifying: `bin/brightness-test.sh`'s
user-activity poke **does not work** (injected keyevents and taps leave
`mLastUserActivityTime` frozen, and `svc power stayon` loses to WindowManager's 10 s override), so
a full-range run needs a human touching the machine throughout; and Android's dim policy now
drives the *physical* panel, so the whole display dims 10 s after the last touch of Android even
when someone is using the host.

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
  in the container's network namespace, and `wifi-test.sh`), and `brightness-test.sh`, which
  reports a dimmed display as SKIPPED rather than failing, because Android pins the panel at its
  dim value and ignores the brightness setting entirely while display policy is DIM
- `sensors/` — source for `waydroid-sensord`, the host-side sensors daemon (goal 2). Build with
  `sensors/build.sh`; see the header comment for why it is a host daemon and not a guest HAL.
  It also serves `android.hardware.light@2.0::ILight` from `Lights.cpp` and `Backlight.cpp`, so
  Android's brightness reaches `/sys/class/backlight` — in this binary because its *name* is the
  install hook; build.sh's header explains the trade
- `wifi/` — source for `waydroid-wifid`, the host-side wificond replacement (goal 4). Same shape as
  `sensors/`. `WifiBackend.h` is the pluggable seam: everything above it speaks AIDL to Android,
  everything below it speaks to whatever owns the radio on the host, and `NmBackend` is the first
  implementation. `NativeScanResult.cpp` is the awkward corner — it marshals a custom parcelable
  whose layout exists only as bytecode, and synthesises the 802.11 beacon elements Android insists
  on parsing its security out of. Build with `wifi/build.sh`; `--unit` also installs the
  systemd unit, the `waydroid-wifi-nudge` restart workaround and the `waydroid-wifi-sync`
  credential reconciler, all of which live in `artifacts/wifi/`
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
- `artifacts/` — configs pulled from or staged for the host, with originals kept alongside.
  Each subdirectory's `install.sh` honours `DESTDIR`/`PREFIX`/`UNITDIR`, so the same script
  is both the by-hand install and the RPM's `%install` step — one description of the layout.
  `artifacts/overlay/install.sh` holds the only written-down mapping from repo file to
  overlay path, and `artifacts/overlay-manager/` is `waydroid-overlay-sync`, and
  `artifacts/container/` holds the `waydroid-container.service` drop-ins.
  `artifacts/backlight/` is the SELinux half of the brightness fix — a CIL module and the
  udev rule that applies its type — kept in one directory because either half alone is inert
- `packaging/` — RPM specs and `build-rpms.sh`. Four source packages: the noarch
  `waydroid-bigtab01`, the two compiled daemons, and `waydroid-overlay`, whose subpackages
  stage overlay payload into `/usr` and let `waydroid-overlay-sync` deploy it to `/var`
  before the container starts. `packaging/README.md` records what has actually been built;
  the design is [docs/36-packaging.md](docs/36-packaging.md)

Record what was *ruled out* and why, not just what worked. Distinguish clearly between what has
been verified on the host and what is still hypothesis.
