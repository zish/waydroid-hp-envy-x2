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
   **A second half turned up on 2026-09-18, reported as "Android says 101%".** The number was never
   miscalculated: it was a real host reading, **latched and never replaced**. ACPI computes
   `capacity = capacity_now * 100 / full_charge` with **no clamp to 100**, so >100 happens at charge
   termination — and healthd had no way to ever read again. Waydroid disables the periodic battery
   poll **twice, independently**: the service's `.rc` carries no `capabilities` line, so
   `timerfd_create(CLOCK_BOOTTIME_ALARM)` fails `EPERM` against `CapEff: 0`; and the *other* board
   hook, `healthd_board_init`, writes one 64-bit `-1` over both `periodic_chores_interval_*`, which
   disarms the timer. Fixing either alone changes nothing. Uevents, contrary to
   [docs/46](docs/46-removable-media.md)'s aside, **do** reach the container — untagged uevents are
   broadcast to every netns — which is why the value is right while it moves and freezes the moment
   the pack goes quiet, and why `bin/battery-test.sh` passed throughout. Two more bytes in the same
   binary as docs/10's three, deployed the same way; five now differ from shipped. **Verify the
   mechanism, not the symptom**: `cat /proc/<health-pid>/fdinfo/<timerfd>` from *inside* the
   container must show `clockid: 7` and `it_interval: (60, 0)`. `ls /proc/<pid>/fd` proves the timer
   exists; only `fdinfo` says whether it is armed, and the first fix looked fine until that was read.
   See [docs/48-battery-frozen-and-netd-stale.md](docs/48-battery-frozen-and-netd-stale.md).
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
   **A "connected to vidiot, no internet" fault on 2026-09-18 was not in the Wi-Fi stack at all.**
   Android's `LinkProperties` were perfect — address, gateway, DNS, default route — and **every
   per-network routing table in the kernel was empty**, because `netd` **survived its own restart**
   and still owned `wlan0` under a netId from a previous `system_server`, so `networkAddInterface`
   failed `EBUSY` and the route adds `ENOENT`. `dumpsys netd`'s binder call log is the only place
   those errors are recorded; `ConnectivityService` logged nothing and logcat had rolled. The cause
   is goal 7's cgroup problem: init stops a service via libprocessgroup's `cgroup.procs`, the
   container's `/sys/fs/cgroup` is read-only so those cgroups never existed, the kill reached nobody,
   and init parked netd in `STOPPING` for 38 hours. **`init.svc.<name>` is the tell**, and **no
   Android service in this container can be restarted** — six were wedged. Mitigated by
   `artifacts/restartd/`; the real fix is goal 7. See
   [docs/48-battery-frozen-and-netd-stale.md](docs/48-battery-frozen-and-netd-stale.md).
   **Still open**: the T3U wedge has no automatic trigger (and `nmcli connection up` remains the
   mandatory discriminator before reprobing — it saved a wasted reprobe this session);
   the host's link dropped twice for ~10 minutes on 2026-09-18 while Android sat in its
   failed-validation retry loop on the same radio, uninvestigated and a caution about
   [docs/38](docs/38-wifi-primary-radio.md)'s single-radio arrangement;
   `NmBackend::forget()` is implemented but nothing calls it, so forgetting a network in Android
   leaves its PSK in NetworkManager; and signal/state fidelity in Android's UI is unreviewed.
5. **Audio — direct ALSA as a selectable backend, and eventually a DAW-grade HAL.**
   **Added 2026-09-11 at the owner's request; scoped, nothing built.** Two phases.
   **Phase 1 is a backend choice** — `--audio-backend {auto,alsa,pulse,none}`, probed before Android
   boots, so `waydroid in cage` can own a dedicated interface while every other user keeps today's
   path. That path is three shims deep: the HAL calls `snd_pcm_open(..., "pulse")`, alsa-lib
   resolves that *name* from `/vendor/usr/share/alsa/alsa.conf` (defined inline at line 662 of
   Waydroid's fork), the pulse plugin talks libpulse to the bind-mounted socket, and
   `pipewire-pulse` terminates it. **Nobody is building a native PipeWire client** — not upstream,
   not in a fork, and the reason is sound: `pipewire-pulse` already terminates the PA protocol
   natively, and that protocol is version-independent where PipeWire's is not. But **the HAL is
   already an ALSA client**, so pointing it at a real card is far smaller than a PipeWire port, and
   all three hooks exist: `/dev/snd` is simply missing from `generate_nodes_lxc_config()`; the probe
   belongs exactly where `make_prop()` already tests the host to set `waydroid.stub_sensors_hal`,
   which runs on every container start before init boots; and the device name is one
   `property_get` away in the HAL. **Sharing a card is not on the table** — every PCM on this
   machine reports `subdevices_count: 1`, dmix cannot rendezvous across the container's own IPC
   namespace, and PipeWire opens `hw:` directly — so this means *dedicating* a device, which is the
   [second-radio answer](docs/34-wifi-second-radio.md) again. Beware that **a probe run as root will
   lie**: root opens `/dev/snd/*` regardless, Android's audioserver is uid 1041 with no idmap, and
   `/dev/video0` being world-accessible is the only reason the camera works today.
   **Phase 2 is the DAW-grade HAL**, which is the real objective — the shipped one is hardcoded to
   48 kHz **stereo** out with an 85 ms buffer, **16 kHz** capture, and no `create_mmap_buffer`, so
   AAudio's low-latency path never engages. LXC adds nothing to the audio path — same kernel, same
   ALSA, same interrupt timing — so the ceiling is those 1100 lines of C, not the architecture, and
   `audio.primary.waydroid.so` is a vendor `.so` exactly like `libgbm_mesa_wrapper.so`, so the
   NDK-plus-vendor-overlay route from [docs/08](docs/08-camera-fixed.md) applies with no AOSP tree.
   **Local first, upstream if it works.** See
   [docs/44-audio-alsa-backend.md](docs/44-audio-alsa-backend.md). Nothing about audio has been
   tested on this machine at all — including whether it works today.
6. **Removable media** — let Waydroid see USB sticks, SD cards and more when inserted.
   **Deprioritised below Wi-Fi on 2026-09-07**, then **promoted ahead of goal 5 (audio) on
   2026-09-15** at the owner's request, who read the scoping note and asked to implement — so the
   list order above no longer matches the work order, and audio is parked in practice without having
   been declared parked. **Built and working the same day, hotplug included.** Verified end to end: a
   real SD card and a USB stick mount on the host and their files are readable inside Android at
   `/sdcard/Removable/<label>`, and unplugging and replugging the stick unmounts, cancels the
   notification, remounts and re-notifies with nobody touching anything. When testing by hand, give
   it a second or two — kernel enumeration plus the daemon's 0.6 s coalescing delay mean an
   immediate query looks like a failure.
   **The design is one sentence: mount the device on the host, straight into the Waydroid data
   directory.** Android reaches external storage through FUSE (`/storage/emulated/0`), whose *lower*
   directory is literally `~/.local/share/waydroid/data/media/0` on the host — so a host mount there
   propagates in by itself (`/var/home` is `shared`, the LXC config sets no propagation options) and
   FUSE serves the *content* onward, which is what crosses Android 13's per-app mount namespaces.
   **No LXC config edit, no `nsenter`, no SELinux module, and no container restart — so it never
   drops the kiosk to the greeter.** `waydroid-mediad` ([artifacts/media/](artifacts/media)) is a
   stdlib-only root daemon that takes udev block events as a wake-up and then *reconciles* desired
   mounts against actual ones, so startup, a missed event and a hotplug are one code path. The
   Android half is [media-app/](media-app), which does **no file I/O at all** — it turns the daemon's
   broadcasts into a persistent notification and hands DocumentsUI a `content://` URI on tap.
   Verify with `bin/media-test.sh`. **Ejecting** is a notification action: nothing pulls from the
   container out to the host, so the app drops a zero-byte marker named after the volume in its own
   app-private directory and the daemon polls for it, unmounts and consumes it. An ejected volume is
   remembered so the next reconcile does not helpfully remount a stick that is still plugged in. The
   daemon deliberately does **not** create that marker directory — it runs as root, and a root-owned
   `files/eject` is unwritable by the app, there being no idmap. **One trap dominates the Android half: Android 8+ silently
   refuses to deliver *implicit* broadcasts to manifest-declared receivers.** `am broadcast -a
   <action>` reports `Broadcast completed: result=0` and fires nothing, with no error in logcat or
   anywhere else; adding `-p <package>` fixes it. That plus `-f 32`
   (`FLAG_INCLUDE_STOPPED_PACKAGES`, needed because a never-launched app is in the "stopped" state)
   are both required, and each one alone looks exactly like a broken receiver.
   **Three earlier conclusions in this entry were wrong and are worth remembering as traps.**
   *gvfs is still correctly ruled out* — it never automounts without a desktop shell (there is none
   under cage) and its FUSE view has no `allow_other`, so it cannot cross into the container — but
   **the SELinux analysis was answering the wrong question**: `waydroid_t` is the domain of the *host*
   daemon from [docs/14](docs/14-sensors.md)/[40](docs/40-binder-nice.md)/[42](docs/42-backlight-selinux.md),
   while Android actually runs as **`container_runtime_t`**, which reads `dosfs_t` fine. A whole
   private-type-plus-`context=` design was scoped and never needed. **`persist.sys.fuse` is `true`**
   (predicted false) and **`vold` runs** (predicted absent — it simply has no block devices and no
   uevents, netlink being netns-scoped), so the proper Android volume route is ruled out on cost, not
   absence. Four implementation bugs are recorded in [docs/46](docs/46-removable-media.md), of which
   two generalise: **a `findmnt -o SOURCE /` guard silently protects nothing on an rpm-ostree host**
   (the answer is `overlay`, not a device), and **`/home` is a symlink to `/var/home`**, so any
   "is this mount mine?" test must use `realpath` or it will unmount its own work. Also note a
   `systemd --user` watcher **cannot** mount — it is not in a login session, so polkit falls through
   to `auth_admin` — which is why the daemon is a root system unit.
   **Tapping a notification opens the volume in a file manager — confirmed by the owner**, as is
   ejecting. Copying files onto a volume **fails in the old AOSP DocumentsUI** bundled with this
   image (its `CopyJob` throws, and the exception code is one DocumentsUI cannot even decode, so it
   presents as a silent failure) and **works in Google Files** — so use Files or Amaze for file
   operations; DocumentsUI is fine for browsing. That cost several rounds of misdiagnosis and the
   lesson is recorded in [docs/46](docs/46-removable-media.md): **when a failure is reported through
   one application, try a second application before instrumenting the stack beneath it** — three
   file managers were listed in the very first probe. Two unrelated hardware notes: the SD slot
   needs a firm reseat (a partial insertion produces no kernel event at all, which looks exactly
   like a software fault), and the card reports `FAT-fs … Volume was not properly unmounted` on
   every mount, so it wants an `fsck.vfat`.
   **The whole design assumes nothing else on the host mounts anything, which is true under cage
   and false under GNOME or KDE.** Both desktops are udisks2 clients — neither mounts anything
   itself — and GNOME automounts by default while Plasma 6 deliberately does not, so `candidates()`,
   which skips any device somebody else got to first, loses the race on one desktop and wins it on
   the other: on GNOME **nothing would reach Android at all**. Measured 2026-09-19: a desktop-style
   mount (`uid=1000`, 0755) is **readable but not writable** through MediaProvider's FUSE, and
   udisks2's owner-only iso9660 defaults (`mode=0400,dmode=0500`) are **invisible even to root
   inside the container** — the FUSE daemon is uid 10141 holding `media_rw`, and it is *its* access
   to the lower file that fails, not the caller's, which is why container-root does not bypass it.
   The way out is to stop mounting and start following: one `--rbind` of the desktop's media root
   into the data dir **joins `/run`'s peer group**, so the desktop's mounts and unmounts cross into
   the container by themselves, with no LXC change, no propagation flags and no restart — verified
   on 2026-09-20 against **real udisks2** (a loopback vfat volume, since the isohybrid stick's
   partitions cannot be opened while its whole disk is mounted), including udisks2's own unmount
   propagating cleanly out of the container even though it lists our mirror path in `MountPoints`.
   **The mirror alone is not enough, and a tmpfs stand-in hid why**: udisks2 creates
   `/run/media/<user>` as `drwxr-x---+` with `other::---`, so MediaProvider is stopped at the door
   — one `setfacl -m g:1023:x` on that directory fixes it, costs nothing and persists nowhere.
   **POSIX ACLs also retire the idmapped-mount idea**: `setfacl -R -m g:1023:rwX -m d:g:1023:rwX`
   gives Android read *and* write on ext4/btrfs/xfs and survives a remount, where idmapping fails
   `EOVERFLOW` (MediaProvider writes as uid 10141) and iso9660 refuses it outright. **FAT has no
   lever but mount options** — `chmod`, `chown`, setgid and `setfacl` all fail on it, and udisks2
   rejects a caller-supplied `gid=1023` (`OptionNotPermitted`) — but a server-side
   `/etc/udisks2/mount_options.conf` carrying `vfat_defaults=…,gid=1023,dmask=0007,fmask=0007`
   **works**, giving Android read, write *and* delete on a desktop-mounted FAT volume, at the cost
   of a host-wide policy change and a `udisks2` restart; without it Android gets those volumes
   read-only, which also works. Adding the host user to a group does not help either: MediaProvider's gids come from
   Android, never from the host's `/etc/group`. Two caveats neither fixable from our side: an open
   file inside Android makes the propagated unmount **silently skip**, so the desktop's "safely
   remove" lies; and a second bind of a volume keeps its superblock alive, which is why the mirror
   is one directory and not one bind per device. See
   [docs/49-desktop-session-media.md](docs/49-desktop-session-media.md).
   **Still open**:
   unmount-while-browsing falls back to a lazy unmount; USB optical is mostly covered (iso9660/UDF
   are handled, since the attached stick is an isohybrid image) but drive-vs-media events are a
   separate increment; MTP needs a different mechanism entirely and all four candidate packages are
   uninstalled; and there is no RPM yet, though `install.sh` is `DESTDIR`-clean.
   See [docs/46-removable-media.md](docs/46-removable-media.md).
7. **Android's per-app freezer** — make `CachedAppOptimizer`'s cgroup v2 freezer actually
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
   **This cgroup problem is already costing something, and it is not the freezer.** Because
   `libprocessgroup` never created the per-process cgroups, `KillProcessGroup()` signals nobody, so
   **no Android service in this container can ever be restarted** — not by `restart`, not by
   `ctl.restart`, not by init's own crash recovery. init parks the service in `STOPPING` and waits
   for a `SIGCHLD` that never comes. That is what broke Wi-Fi for 38 hours on 2026-09-18 (goal 4),
   and it silently wedges `audioserver`, `cameraserver`, `media`, `idmap2d` and `mediadrm` too, which
   is worth remembering the next time one of those misbehaves after a framework restart. Mitigated,
   not fixed, by `artifacts/restartd/`; this goal is the real fix. See
   [docs/48-battery-frozen-and-netd-stale.md](docs/48-battery-frozen-and-netd-stale.md).

8. **Bluetooth — managing the host's BlueZ from an Android app.** **Added 2026-09-21 at the
   owner's request; built, working and proven the same day — the owner paired a Galaxy S24 Ultra
   through the app, `bonded`, `connected`, battery reported.**
   Under cage there is no host UI at all, so pairing a headset or a keyboard means ssh-ing in and
   running `bluetoothctl`. Two pieces close that: `waydroid-btd`
   ([artifacts/bluetooth/](artifacts/bluetooth)), a root Python daemon that is a D-Bus client *and
   server* to BlueZ, and "Bluetooth" ([bt-app/](bt-app)), a dependency-free Kotlin app.
   **The first probe of the Android side was misread, and the correction is the useful part.**
   `ls /apex | grep -i bluetooth` returns nothing, which was taken to mean the image has no
   Bluetooth framework. It is a **false negative — the APEX is `com.android.btservices`**, and it
   is present, with `framework-bluetooth.jar`, `service-bluetooth.jar`, `libbluetooth_jni.so`, the
   `bt_stack.conf` set and the `com.android.bluetooth` privapp allowlist. The
   `android.hardware.bluetooth` feature is **already declared** in `handheld_core_hardware.xml`,
   and `BluetoothManagerService` has been *trying* since boot — `dumpsys bluetooth_manager` shows
   `mEnable:true` and then `Bluetooth Service not connected`. What is actually missing is
   **`Bluetooth.apk` itself** (`find` across `/system /system_ext /product /apex` for
   `*Bluetooth*apk` returns nothing) **and any vendor HAL** (`/vendor/bin/hw`, `/vendor/lib64/hw`
   both empty of it). So this is *not* the Wi-Fi Stage 0 shape where one overlay file woke a
   dormant framework: the hole is an entire privileged system APK, which means an AOSP tree —
   the one thing [docs/08](docs/08-camera-fixed.md) went to the NDK to avoid — **plus** an HCI
   transport, which still ends with the container owning `hci0`. Handing it over was rejected the
   same way [docs/28](docs/28-wifi-feasibility.md) rejected it for Wi-Fi: it is the only
   controller and the owner's keyboard is paired to it. **Grepping for the obvious word is not
   the same as looking.**
   **The transport is TCP + newline JSON on the waydroid0 bridge, not binder**, because an ordinary
   app cannot reach an arbitrary binder name: non-SDK `getService`, an overlay `service_contexts`
   edit, an `untrusted_app` `find` rule, and [docs/35](docs/35-wifi-stage5.md)'s `dontaudit`ed
   transfer trap underneath. firewalld already has `waydroid0` in the **`trusted`** zone, so no rule
   was added. TLS is available (`--tls`) and **pinned by certificate SHA-256**, not CA-validated —
   there is no name to verify on a bridge.
   **The pairing agent is what forces the shape.** A prompt is BlueZ calling *out* to an
   `org.bluez.Agent1` object, so the daemon must export one — which rules out `busctl` (it cannot
   serve an object) and rules out scraping `bluetoothctl` (it registers a competing agent).
   Capability is `KeyboardDisplay`, so modern devices get numeric comparison.
   **`Pair()` cannot be called synchronously**: it blocks until pairing completes and its agent
   callbacks arrive on the same D-Bus connection, so a blocking call deadlocks against its own
   prompt. Every device verb is async with `reply_handler`/`error_handler`.
   **The app is handed its token as a file, not a broadcast**, and that works because **SELinux is
   `Disabled` inside the container** — a root-written file in the app's private dir is simply
   readable, no labelling. A broadcast only lands if the app is running; a file survives reboots.
   **One assumption was wrong and is corrected in the docs: BlueZ is not polkit-gated.** There is no
   `org.bluez` polkit action on this host, and `bluetooth.conf` lets `context="default"` send to
   `org.bluez`, so an unprivileged caller really could pair. The daemon is root for exactly one
   reason — the profile goes into a directory owned by the app's uid, mode 0700.
   Verify with `bin/bluetooth-test.sh` — 17 pass, measured 11 devices in a 12 s scan. The agent
   needs no device to test: `org.bluez.Agent1` is an ordinary D-Bus object we export, so all five
   paths were driven directly as `bluetoothd` would, confirming `Rejected` and `Canceled` come
   back under the exact names BlueZ expects. **A trap lives in that test, not the daemon**:
   dbus-python's `SystemBus()` is a *shared singleton*, so two overlapping blocking calls on it
   produce a spurious `NoReply` that looks exactly like a daemon fault —
   `dbus.SystemBus(private=True)` for the second caller.
   The S24 came through with `legacy_pairing: false` — Secure Simple Pairing, the
   numeric-comparison flow, which is precisely what `KeyboardDisplay` was chosen for. Pairing also
   exposed a gap since fixed: a *successful* prompt left nothing in the journal, so afterwards
   there was no way to tell whether it had come from us or from a stray `bluetoothctl`; the daemon
   now logs each request and who answered it.
   **The app also replaces the stock Quick Settings tile**, added the same day at the owner's
   request. The stock `bt` tile is inert here (`dumpsys bluetooth_manager`: `state: OFF,
   address: null`), so it is a control that can only fail. The lever is one **writable secure
   setting**, `sysui_qs_tiles` — swap `bt` for `custom(lan.syshlt.bluetooth/…BtTileService)` and it
   takes effect live, with **no overlay and no container restart, so no drop to the greeter**.
   `bin/bt-tile.sh` does it with `--install`/`--remove`/`--status` and keeps an exact backup of the
   original list. Note removing `bt` hides it from the shade but not from the edit-tiles tray,
   which would need a resource overlay.
   **Two traps here.** `cmd statusbar expand-settings` **returns 1 unless the shade is collapsed
   first**, which looks like a permission failure; and `cmd statusbar click-tile` **must never be
   used on this tile** — it would toggle `hci0` off and drop the owner's keyboard and phone.
   **And one device-wide fact worth knowing before building anything else here:
   `restricted_networking_mode` is `1`**, so an app gets network *only while foreground*
   (`blocked=RESTRICTED_MODE, allowed=FOREGROUND|TOP|…`). A tile is fine because SystemUI's
   binding elevates the process state, but **a plain background service could not hold a
   connection**. A first diagnosis blamed app-standby buckets and was disproven by A/B: the tile
   connects fine in bucket 45 with no `deviceidle` whitelist, so the bucket was never the blocker.
   A second bug came out of it too — `BtClient` reported a socket *we* closed as a disconnection,
   so the tile cached "Host daemon unreachable" on every shade close and painted it on the next
   pull-down, which is the exact flash the cache exists to prevent.
   **Still open**: only the numeric-comparison flow has met real hardware (passkey-entry and PIN
   are synthetic only), and `remove`/`connect` have never run against a real bond; the controller does not survive
   s2idle ([docs/27](docs/27-android-power-button.md)) and there is no automatic recovery; whether
   A2DP audio follows through PipeWire is untested; the daemon is packaged as
   `waydroid-ext-btd` but the app is not; no BLE GATT. See
   [docs/50-bluetooth.md](docs/50-bluetooth.md).

**Screen brightness — DONE, and not on the list above.** Added at the owner's request on
2026-09-09, between Wi-Fi Stage 5 and removable media. Android's brightness slider now drives the real
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

**The container ages out — the 32-bit PID cliff. DONE, and not on the list above.** Found
2026-09-21, reported as "Waydroid seems to have restarted itself and is now stuck on the animated
boot logo." Nothing had restarted — the container and the cage session were two days old and had
never stopped, and what was restarting over and over was the Android framework *inside* a container
that never went anywhere. **32-bit bionic aborts any process whose tid exceeds 65535** (the 32-bit
`pthread_mutex_t` has 16 bits for the owner), and a Waydroid container is a long-lived PID namespace
whose counter only climbs, so past roughly a day of uptime **every newly started 32-bit process dies
at birth**. The image has five: the audio HAL, the camera provider — so **goal 1 quietly depends on
this** — `cas`, `omx`, and `app_process32`, which is zygote32 and therefore every 32-bit app. The
boot loop is downstream: with the audio HAL dead `audioserver` registers nothing, `system_server`
blocks in `AudioService`'s constructor on a binder call that never returns, Watchdog kills it after
60 s, init forks a new one with another high PID, forever. **The same root cause presents as "no
audio", "camera broken", "some apps won't launch" or "stuck on the boot logo"** depending on what
gets restarted first, so suspect it before investigating any of those on its own merits.
**Uptime past the threshold is not proof of health** — already-running processes keep their low PIDs
— it is a loaded gun; `cat /proc/sys/kernel/ns_last_pid` inside the container is the one-line check,
and the burn rate is 14.1 pids/min idle against ~56 under real use, so **1–3 days**. Two decoys:
`logcat -b crash` holds a full `FATAL EXCEPTION` that is one crash from the start of the episode and
*not* the repeating kill, because Watchdog calls `Process.killProcess()` rather than throwing; and
the aborting process **hangs rather than disappears**, since the abort lands in debuggerd, so it
looks misconfigured instead of unable to execute. Recovery is a container restart — the only thing
that gives a fresh namespace, and it drops the kiosk to the greeter. The **fix** makes the cliff
unreachable rather than distant: Linux 6.14 made `pid_max` per-PID-namespace and this host runs
7.1.x, so the container is capped at 65536 while the host stays at 4194304, and **the allocator
wraps** — measured, not assumed, with the counter primed to 65529 and PIDs running 65530…65535 then
300, 301, 302. `artifacts/pidguard/` is timer-driven and reconciling, because a container restart
makes a fresh uncapped namespace and there is no clean event to hook, and it carries a safety
interlock, since on a pre-6.14 kernel the same write would silently reconfigure the host.
**This compounds with goal 7 but is independent of it** — `waydroid-restartd` ran throughout and
could not have helped, because the respawn gets another high PID and dies the same way. Already
upstream as [waydroid#2071](https://github.com/waydroid/waydroid/issues/2071), open, recommending a
*host-wide* cap; the per-namespace one is strictly better and is what that thread asked for and
nobody built. See [docs/51-pid-namespace-32bit-cliff.md](docs/51-pid-namespace-32bit-cliff.md);
check with `bin/pid-cliff-check.sh`.

**A black screen is not a crash — the launcher was locking it.** 2026-09-21, reported as "the screen
went black and is still that way", with the caps-lock LED still toggling on the Bluetooth keyboard
and SSH working. Nothing had crashed. `dumpsys power` settles it in one field —
`mLastSleepReason=device_admin`, against a 30-minute idle timeout and a screen that had been dark
for six — and `dumpsys device_policy` names the only registered admin, Fossify Launcher's
`LockDeviceAdminReceiver`. That receiver exists for one feature, double-tap-to-lock, and a drag out
of a folder landed on the empty desktop as a double-tap. **Because `ILight` owns the real panel
here, "screen off" is literally `intel_backlight/brightness = 0`** — the panel stays powered and
displays black, which at a glance is indistinguishable from a compositor crash, a backlight
regression, or the PID cliff's boot loop with the animation off-screen. **The recovery already
existed: press the power button.** `waydroid-android-lock.service` from
[docs/27](docs/27-android-power-button.md) is ordered `Before=sleep.target` and its post leg injects
a wakeup unconditionally on every resume, so any suspend/resume cycle recovers a sleeping Android
whatever put it there; over SSH, `waydroid shell -- input keyevent KEYCODE_WAKEUP` does it directly.
**Keyboards cannot** — docs/27 measured `KEY_POWER` being dropped by the guest hwcomposer before
Android sees it — and **the caps-lock LED proves the host, not the guest**, being driven entirely
host-side. Double-tap-to-wake was scoped and is nearly free, but **only host-side**: InputReader
disables `wayland_touch` when the display group powers off, so there is no touch left inside Android
to detect, and it was judged marginal since one press of the power button already does it. The owner
disabled the gesture in Fossify's settings, which leaves the admin registered but idle; the
30-minute idle timeout still puts Android to sleep, so the recovery stays worth knowing. Also
records an AVC [docs/42](docs/42-backlight-selinux.md) did not: `systemd-backlight` runs as `init_t`
and is denied write on the backlight's private type, so it fails and retries on every brightness
change — harmless, left alone (mask the unit rather than widen the policy), and a useful side
channel for when the backlight last moved once logcat has rolled. See
[docs/52-launcher-lock-and-wake.md](docs/52-launcher-lock-and-wake.md).

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
  dim value and ignores the brightness setting entirely while display policy is DIM, and
  `bluetooth-test.sh`, which walks controller, daemon, protocol, profile delivery and app and
  reports the pairing leg as SKIPPED because it needs a human, and `bt-tile.sh`, which swaps the
  app's Quick Settings tile in for the stock Bluetooth one by editing `sysui_qs_tiles`, keeping an
  exact backup so `--remove` restores rather than reconstructs, and
  `removable-probe.sh`, which answers every open question in
  [docs/46](docs/46-removable-media.md) read-only in one run, and `media-test.sh`, which walks the
  removable-media chain from host mount to posted notification and names the link that is broken
  rather than just failing, and `pid-cliff-check.sh`, which reports how close the container's PID
  namespace is to the 32-bit bionic cliff and is a **weather report, not a health check** — crossing
  65535 breaks nothing until something restarts a 32-bit process — and `stylus-watch.py`, which
  listens to a digitizer's evdev stream and settles in seconds whether the panel's controller
  recognises a given pen at all, that being a firmware question no driver or kernel option changes, and `check-signed-commits.sh`, which is the push-time signature gate — it reads `%G?`
  rather than shelling out to `git verify-commit`, whose exit status cannot distinguish "bad
  signature" from "no signature", and it is wired both to `.git/hooks/pre-push` and to
  `lefthook.yml` so the check holds whether or not lefthook is installed
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
- `media-app/` — "Removable Media", a dependency-free Kotlin app that turns the host daemon's
  volume broadcasts into a persistent notification whose tap opens the volume in the user's file
  manager. It does **no file I/O at all** and declares no storage permission: the host mounts into
  the FUSE lower directory, `ExternalStorageProvider` indexes it, and the app only ever hands
  DocumentsUI a `content://` URI — even its status screen lists what it was *told*, never what is on
  disk. Same no-Gradle build as `sensor-app/`, except it does generate `R` (the notification needs a
  real drawable id, and `getIdentifier()` would trade a compile error for a silent runtime null)
- `bt-app/` — "Bluetooth", a dependency-free Kotlin app that manages the *host's* BlueZ through
  `waydroid-btd`. It declares only `INTERNET`: it never touches Android's Bluetooth APIs, because
  this image has none, and the radio it drives is on the other side of a socket. It holds no state
  of its own — every view is the last snapshot plus the events since, so a daemon or `bluetoothd`
  restart converges with no reconciliation code. It also ships `BtTileService`, the Quick Settings
  tile that replaces the stock Bluetooth one; the tile is bound only while the shade is open, so it
  connects per pull-down and paints from a cached state to avoid a flash of "unavailable". Same
  no-Gradle build as `sensor-app/`, and like it generates no `R` — the tile's icon and label come
  from its `<service>` element. See [docs/50-bluetooth.md](docs/50-bluetooth.md)
- `drm-probe/` — "DRM Probe", a dependency-free Kotlin app that dumps every `MediaDrm` property
  for every registered crypto scheme, plus session and decoder capability. Written to settle what
  a DRM client actually sees here instead of inferring it from Netflix's silence; it declares **no
  permissions on purpose**, so it sees what an ordinary app sees. Same no-Gradle build as
  `sensor-app/`; `drm-probe/build.sh --install` deploys, runs and prints the report. See
  [docs/21-netflix-widevine.md](docs/21-netflix-widevine.md) for the Widevine fix and
  [docs/22-netflix-container-detection.md](docs/22-netflix-container-detection.md) for why Netflix still refuses to run
- `touch-probe/` — "Touch Probe", a dependency-free Kotlin app that draws every active pointer and
  counts concurrent contacts, so "how many independent touches does Android actually receive here?"
  is measured before the `touchscreen.multitouch*` feature XML is written — the SYNA7500 reports
  `ABS_MT_SLOT` max=9 and Waydroid's hwcomposer bridge matches it, but Android declares none of the
  three features. It doubles as the stylus probe: the HUD names `TOOL_TYPE`, the stylus button bits
  and hover distance per pointer, and names the device each event arrived on (`wayland_touch`,
  `wayland_pointer`, `wayland_tablet`), so a pen is distinguishable from another finger at a glance.
  Same no-Gradle build as `sensor-app/`; `--install` deliberately does **not** pull the report,
  because the number only means something after someone has had their fingers on the glass
- `artifacts/` — configs pulled from or staged for the host, with originals kept alongside.
  Each subdirectory's `install.sh` honours `DESTDIR`/`PREFIX`/`UNITDIR`, so the same script
  is both the by-hand install and the RPM's `%install` step — one description of the layout.
  `artifacts/overlay/install.sh` holds the only written-down mapping from repo file to
  overlay path, and `artifacts/overlay-manager/` is `waydroid-overlay-sync`, and
  `artifacts/container/` holds the `waydroid-container.service` drop-ins.
  `artifacts/media/` is `waydroid-mediad`, the root daemon for goal 6 — it mounts removable
  volumes straight into the Waydroid data directory, which is the FUSE lower dir, so they surface
  at `/sdcard/Removable/<label>` with no LXC change and no container restart.
  `artifacts/restartd/` is `waydroid-restartd`, which signals Android services init has parked in
  `STOPPING` and cannot kill, because the container's read-only `/sys/fs/cgroup` means
  libprocessgroup's cgroup-based kill reaches nobody. Read its header before touching the
  intervals: the fast cascade poll is what stops the mutual `netd` ⇄ `zygote` `onrestart`
  pair from ping-ponging, and there is a circuit breaker under it for when that reasoning is wrong.
  `artifacts/bluetooth/` is `waydroid-btd`, the BlueZ daemon for goal 8 — a D-Bus client *and*
  server, because a pairing prompt is BlueZ calling out to an `org.bluez.Agent1` we export, which
  is what rules out every read-only approach.
  `artifacts/backlight/` is the SELinux half of the brightness fix — a CIL module and the
  udev rule that applies its type — kept in one directory because either half alone is inert.
  `artifacts/pidguard/` caps the container's PID namespace below the 32-bit bionic cliff, with
  `waydroid-pid-reset` for a container already past it; read its README for why the guard
  reconciles on a timer rather than hooking an event, and why it refuses to run on a pre-6.14
  kernel where `pid_max` is still global
- `packaging/` — RPM specs and build drivers. The current design is **one source package per
  modification**, generated from `packaging/mods/*.mod` by `gen-spec.sh` and built by
  `build-mod.sh` ([docs/47-package-split.md](docs/47-package-split.md)); the four hand-written
  specs and `build-rpms.sh` are the superseded layout and still the only thing the legacy path
  can build. `packaging/README.md` records what has actually been through `rpmbuild`.
  **Read it before assuming anything is packaged**: audited 2026-09-22, there are 7 `.mod`
  files against ~36 modifications, only 4 produce an *installable* package, and
  `waydroid-ext-overlay-sync` — which every overlay component hard-requires — does not exist,
  so the whole Android-side half of the project is unreachable by RPM. `waydroid-ext-camera-gbm`
  builds cleanly and cannot be installed for exactly that reason. See
  [docs/53-release-readiness.md](docs/53-release-readiness.md), which also covers the
  documentation and path audits, what genuinely cannot be applied by RPM, and the lefthook and
  GitHub Actions plan

Record what was *ruled out* and why, not just what worked. Distinguish clearly between what has
been verified on the host and what is still hypothesis.
