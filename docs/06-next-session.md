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
`bin/sensors-test.sh`. **One follow-up landed 2026-09-07**: with auto-rotation switched on, every
app that follows the sensor rendered upside down, because the hub reports the gravity vector where
Android's convention is proper acceleration. One negation in `GetAccelerometerEvent`, plus the
repair of two cross-checks that had been ratifying the bug; [docs/18](18-sensor-axes.md).
**Vibration is the one part of goal 2 still open**, and still blocked below
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

**Session of 2026-09-06 (late)** measured what the machine actually draws and built a periodic
wake timer for Waydroid; both are in [docs/17](17-hybrid-sleep.md). Headline: **screen-off awake is
2.14 W (~12 h)** against **s2idle ~0.6 W (~43 h)** — a ratio of only ~3.5x, not the 10x assumed, so
the timer earns its place for multi-day standby rather than daily use. The **S3 comparison is the
open thread**: the kernel's own default was `deep`, s2idle at 0.6 W is high for standby, but S3
resume throws `xhci_hcd ... xHC error in resume, Reinit` where s2idle resumes clean. Re-add one
config file and run one command to finish it; docs/17 has both. **Bluetooth as a wake source** also
looks achievable and untested — `1-4/power/wakeup` exists, so the hardware is capable.

**Session of 2026-09-07** answered a design question instead of fixing anything: can Android's own
Wi-Fi settings drive NetworkManager, and would handing Android the radio directly be easier? The
images were inspected with `debugfs` straight off the read-only `.img` files — no mount, no sudo,
no container running — a technique worth reusing for any "what is in this image" question. Result:
the **entire Wi-Fi framework is present and dormant** (`com.android.wifi` APEX, `wificond`, the
libs), and what is missing is the feature XML, a supplicant binary, and any vendor Wi-Fi HAL. The
vendor VINTF manifest contains no Wi-Fi entry at all, which is precisely the precondition for
`WifiNative`'s no-vendor-HAL path. Direct hardware access was **rejected**: `wlp1s0` is this
machine's only network interface, so moving `phy0` into the container drops SSH with no way back
short of the physical console, and it saves almost none of the work because the supplicant is
missing either way. The design that survived is the [docs/14](14-sensors.md) pattern — a host
daemon serving the supplicant interface over libgbinder, behind a **pluggable backend** so
NetworkManager is one implementation among several. `/dev/binder` turns out to be bind-mounted from
the host alongside `/dev/hwbinder`, so the AIDL side is reachable from a host daemon too. Wi-Fi is
now goal 4; removable media is goal 5. [28](28-wifi-feasibility.md), [29](29-wifi-plan.md).

**Session of 2026-09-08 built the first half of it.** `waydroid-wifid` — a host daemon in `wifi/` —
now serves Android's `wifinl80211` over libgbinder on `/dev/binder`, replacing the container's own
wificond entirely, and the Wi-Fi framework brings a client interface up and keeps it up against it:
`Successfully setup Iface:{Name=wlan0,...}`, `entering ScanOnlyModeState`. Stage 1's blocker
evaporated exactly as Path U predicted, because nothing in this design talks to nl80211 and `wlan0`
only has to be a netdev. The NetworkManager backend behind the pluggable contract already reads the
host's real access points (`waydroid-wifid --scan`), and as of Stage 3 they arrive **inside**
Android with the right names, signal strengths and security flags. What is still missing is the
supplicant, without which the master toggle cannot stay on — and therefore the Settings picker,
which needs the toggle, even though the scan data behind it is now real.
[31](31-wifi-stage2.md), [32](32-wifi-stage3.md); verify with `bin/wifi-test.sh`.

## Parked, and worth revisiting

Side-quests from the 2026-09-06 sessions, none of them on the AGENTS.md goal list. Each is
scoped and cheap to resume; none is blocking.

### Bluetooth as a wake source — **deferred at the owner's request, 2026-09-06**

The wish is to wake the laptop with the HP bluetooth keyboard. The hardware looks capable and
nothing has been tried yet:

```
0000:00:14.0 (xHCI PCIe)  = enabled     <- already a wake source
usb1         (root hub)   = disabled
1-4          (bluetooth)  = disabled    <- Intel 8087:0a2a
```

Corroborated 2026-09-07 by watching a real suspend rather than reading sysfs: `bluetoothd:
Controller resume with wake event 0x0`, and the keyboard's HID device is **destroyed and recreated**
across the cycle (`input: HP Wireless … Keyboard as …/input34`, new input numbers). So today the
keyboard is fully down in s2idle and costs nothing — which is also why it cannot wake the machine.
See [27](27-android-power-button.md).

`1-4/power/wakeup` **existing at all** is the signal — the kernel only creates that attribute for
devices advertising USB remote wakeup. Two writes test it:

```bash
echo enabled | sudo tee /sys/bus/usb/devices/1-4/power/wakeup /sys/bus/usb/devices/usb1/power/wakeup
```

**Decide the conflict first, because it is a choice and not an addition.** An rfkill-blocked
controller cannot wake anything, so bluetooth-as-wake-source and the "bluetooth off during sync
windows" behaviour built into `waydroid-sync` are mutually exclusive. And enabling remote wake on
a radio is a common source of spurious wakeups, so the standby figure in
[docs/17](17-hybrid-sleep.md) would need re-measuring afterwards. Also note the controller is
**USB**, and S3 resume throws `xhci_hcd ... xHC error in resume, Reinit` where s2idle does not —
so this is probably an s2idle feature, which is a point for s2idle in the comparison below.

### S3 versus s2idle standby power

The substantive open measurement. Scoped, smoke-tested and deferred — one config file plus one
command, both in [docs/17](17-hybrid-sleep.md). Genuinely undecided: the kernel's own default here
was `deep` and the measured s2idle 0.6 W is high for standby, but S3 resume reinitialises the USB
controller where s2idle resumes clean.

### The `waydroid-sync` cycle has never actually run

Both guards were exercised and correctly refused to act, which is the safe half. The half where it
thaws Android, refreezes it and re-suspends the machine is **unproven**, which is why the timer is
installed but disabled. Test it on battery, screen locked, with the machine genuinely asleep.

### Power button long-press

Configured as `poweroff`, **never tested**, and possibly unreachable — see
[docs/15](15-power-button.md). [bin/powerbtn-probe.py](../bin/powerbtn-probe.py) settles the first
of the two open questions; `HandlePowerKeyLongPress=lock` settles the second without risking a
firmware power cut.

### Display upside-down after a resume — unexplained

Happened once, 2026-09-06, and corrected without intervention. sway reported `transform: normal`
throughout and the kernel logged nothing about panel orientation. **A `transform 180` was tried
and was wrong** — it put waybar at the bottom and inverted it, which is what 180 does to an
already-correct display. If it recurs, capture `swaymsg -t get_outputs` *at that moment*; `grim`
is useless here because it captures the compositor framebuffer, which looks correct whatever the
panel is doing.

## The immediate next task

### Build the RPMs — 2026-09-22, and this supersedes everything below in this section

The next session's job is packaging, not hardware. The rest of this section is the accreted
record of the Wi-Fi stages and is still accurate as history; it is no longer the next task.

A release-readiness audit ran on 2026-09-22 and is in
[docs/53-release-readiness.md](53-release-readiness.md). Read it before starting — it measured
things the design documents get wrong, and two of its findings change where to begin:

- **`waydroid-ext-overlay-sync` has no `.mod` and is the keystone.** Every overlay component
  hard-requires it. `waydroid-ext-camera-gbm` *builds* and **cannot be installed**, because its
  only dependency is a package that does not exist; `waydroid-ext-camera` requires two more that
  do not exist either. Write this one first and two already-built packages become installable.
- **`wifid`'s `%build` calls `wifi/build.sh --rpm`, a flag the script does not have.** Its
  argument parser exits 2 on anything it does not recognise, so the generated spec fails before
  reaching the two reasons `packaging/README.md` does record. Implementing `--rpm` — a native
  build against Fedora's `libgbinder-devel` rather than the `--deps` path that copies `.so`
  files off bigtab01 — and giving `artifacts/wifi/install.sh` the component argument
  `artifacts/overlay/install.sh` already has are what unblock a full `-ba`.

Of ~36 modifications named in [docs/47](47-package-split.md), **7 have a `.mod` and 4 produce an
installable package**. The order that gets the most working soonest is: `overlay-sync`, then the
remaining overlay components (`camera-hal`, `battery`, `wifi-framework`, `wifi-hostd`,
`brightness-overlay`, `widevine`), then `sensord` — which `backlight` already needs and which
also carries `ILight`, so brightness stays broken without it.

Everything builds on the dev box; `rpm` 4.20.1 and `rpmlint` 2.7.0 are installed there. Drive it
with `packaging/build-mod.sh --lint <name>`.

### Also on the list, not yet started

- **Move the APKs into their own GitHub repositories**, one per app, each with its own CI/CD.
  Requested 2026-09-22. Six directories, a completely separate toolchain and distribution
  channel from the host packaging, and a signing problem that has to be fixed *during* the move:
  every APK build script generates a throwaway debug keystore if none exists. Detail and the
  open question about the three diagnostic probes are in
  [docs/53](53-release-readiness.md).
- **Write `BUILDING.md`.** Neither compiled daemon can currently be built by anyone who cannot
  ssh to bigtab01.
- **Enforcement is already in place for signed commits** — `bin/check-signed-commits.sh`, wired
  to `.git/hooks/pre-push` and to [lefthook.yml](../lefthook.yml). All 94 commits on master
  already pass. Note `lefthook install` replaces the native shim with lefthook's dispatcher.


**Goal 2's sensors are done** — the scoping that used to live here is superseded by
[docs/14-sensors.md](14-sensors.md), which records what the hardware actually is (three
transducers, two firmware-fused outputs), the scale factors derived from the HID report descriptor,
the gyroscope's five-second warm-up, and the traps.

**Stage 0 landed on 2026-09-07 and succeeded** — one overlay file
(`/system/etc/permissions/android.hardware.wifi.xml`) brought Android's whole Wi-Fi framework up:
`WifiService` runs, `wificond` starts by itself, Settings tries to enable Wi-Fi, and the *only*
failure left is `wificond: Can't get wlan0 index: No such device`. It also retired the plan's
biggest risk a stage early — `HalDeviceManager` reports `mWifi: null` and the framework carried on
regardless, so **the no-vendor-HAL path works**. **Next is Stage 1: produce a `wlan0` in the
container** via `virt_wifi`. Evidence in `artifacts/wifi/stage0/`.

**Stage 1 was attempted the same day and is blocked, informatively.** `virt_wifi` creates
`wlan0@eth0` in the container fine, but it registers the **netdev in the container's netns while
leaving its wiphy in the host's**, and `iw phy set netns` is refused with `-EOPNOTSUPP` because
stock `virt_wifi` never sets `WIPHY_FLAG_NETNS_OK`. wificond therefore reports `No wiphy is found`.
Container networking was unaffected throughout. This forces a fork — patch `virt_wifi` (~2 lines,
but an out-of-tree module on a host that updates kernels often) versus replace `wificond` in
userspace (no kernel work, and the wiphy stops mattering at all). **That decision is the next
thing to make**; the table is at the end of the Stage 1 section in
[docs/29-wifi-plan.md](29-wifi-plan.md). Evidence in `artifacts/wifi/stage1/`.

**The fork was decided: Path U — no kernel work.** The offline extraction that follows from it is
done and is in [docs/30-wifi-aidl-surface.md](30-wifi-aidl-surface.md): both HIDL *and* AIDL
supplicant paths ship in this image, selection is by VINTF declaration, the AIDL is version 1, and
**both halves of the shim are AIDL on `/dev/binder`** — one dialect, no `hwservicemanager`. Watch
the jarjar trap recorded there. Path U also kills the prebuilt-supplicant shortcut, because a stock
`wpa_supplicant` needs a real phy; the next milestone was Stage 2, a `waydroid-wifid` skeleton
that registers `wifinl80211`.

**The AIDL surface is now pinned and cross-checked** — [docs/30](30-wifi-aidl-surface.md).
`IWificond`'s 18 transaction codes were read out of this image's own `framework.jar` bytecode and
match AOSP `android-13.0.0_r75` exactly, so upstream `.aidl` can be used directly; only 13 of the 18
are ever called. The supplicant side is **203 method slots** across six interfaces (not the ~80 first
estimated), with `ISupplicantStaNetwork` alone at 93. Sources fetch as two subdirectory tarballs from
android.googlesource.com — no repo clone. The supplicant got the same cross-check on
2026-09-08: **147 proxy methods match AOSP exactly** across `ISupplicant`, `ISupplicantStaIface` and
`ISupplicantStaNetwork`, and the highest code in each equals the AIDL method count, so nothing is
renumbered. The two **callback** interfaces remain unverified — the framework holds their `Stub`,
not a `Proxy`, so there is nothing to read; that is deliberately deferred to runtime in Stage 4.

**Stage 2 landed on 2026-09-08 and works** — [docs/31-wifi-stage2.md](31-wifi-stage2.md).
`waydroid-wifid` is a host daemon (`wifi/` in the repo) that registers `wifinl80211` on
`/dev/binder` and serves `IWificond`, `IClientInterface` and `IWifiScannerImpl` over libgbinder,
behind the pluggable `WifiBackend` contract with NetworkManager as the first backend. Android now
logs `Successfully setup Iface:{Name=wlan0,...}` and `entering ScanOnlyModeState` — the exact
inverse of Stage 1's failure. Verify with `bin/wifi-test.sh`; evidence in `artifacts/wifi/stage2/`.

**One correction the plan needed: the Wi-Fi master toggle does not turn on yet, and could not
have.** `ROLE_CLIENT_PRIMARY` runs `startSupplicant()` *before* it reaches wificond, so a
wificond-only shim tops out at scan-only mode. The toggle is Stage 4's, with the supplicant.

**Stage 3 landed the same day** — [docs/32-wifi-stage3.md](32-wifi-stage3.md). The
`NativeScanResult` layout came out of this image's `framework.jar` with the same bytecode technique
[docs/30](30-wifi-aidl-surface.md) used for the transaction codes, and Android now lists the host's
real access points: `cmd wifi list-scan-results` shows SSIDs, RSSI and flags like
`[RSN-SAE-CCMP][ESS][MFPR][MFPC]`, all of it from NetworkManager.

Two findings from that stage are worth carrying forward, because both would cost a session to
rediscover:

- **Android derives security by parsing beacon information elements; there is no security field.**
  A host backend has no beacon, so the IEs are synthesised in `wifi/NativeScanResult.cpp` from what
  NM reports. Emit nothing the host did not actually say — that is why `WifiStandard` reads
  "unknown" rather than a plausible guess.
- **`tsf` is load-bearing and fails silently.** `WificondScannerImpl` drops every result older than
  the scan it asked for, so a zero timestamp, or announcing completion before the host has really
  scanned, produces an empty list with nothing in the log. `WifiBackend::onScanComplete()` exists
  for this.

**The next milestone is Stage 4: the supplicant**, and with it the master toggle and any actual
connection. It is `ISupplicant` / `ISupplicantStaIface` / `ISupplicantStaNetwork` plus two callbacks
at AIDL v1, declared through a VINTF fragment in the vendor overlay so `isDeclared()` picks the AIDL
path — the same mechanism the widevine fix uses. The callback transaction codes cannot be read
statically and must be settled at runtime, exactly as `IScanEvent`'s were in Stage 2. `wlan0` also
has to start carrying traffic; plan that cutover rather than stumbling into it, since it costs the
container its network for a window.

Four things to know before touching it:

- **The daemon must run in `unconfined_t`, and this is not a preference.** systemd runs a `bin_t`
  binary as `unconfined_service_t`, and the host policy allows `binder { call }` to that domain while
  **denying `binder { transfer }`** from `container_runtime_t`. Calls carrying no binder succeed and
  every callback-passing call fails with a bare `DeadObjectException`; the rule is `dontaudit`ed, so
  `ausearch` is clean and the obvious first move gives the wrong answer. `SELinuxContext=` in
  `waydroid-wifid.service` handles it. **`bin/wifi-test.sh` checks this first** — see
  [35](35-wifi-stage5.md).

- **An overlay file is not deployed until the container *service* restarts.**
  `waydroid container restart` does nothing for it — see [32](32-wifi-stage3.md). This already bit a
  Stage 0 file that had not been in effect for a day without anyone noticing. Verify from inside the
  container, not by listing the overlay directory.

- **`wlan0` is the container's uplink now**, renamed by `lxc.net.0.name = wlan0` in
  `/var/lib/waydroid/lxc/waydroid/config`. There is no `eth0` at all, which kills the
  Ethernet-outscores-Wi-Fi trap for good and retires `bin/wifi-wlan0.sh`. See
  [34](34-wifi-second-radio.md). ~~`wlan0` is not needed for scanning~~ — true of scan-only mode and
  no longer the point.

- **`waydroid-wifid` autostarts from `waydroid-wifid.service`** and survives a reboot, verified end
  to end. It is pinned to the T3U by **factory MAC** in `/etc/waydroid-wifid.conf`, not by
  `wlp0s20u1`, which encodes a USB port. Install or update with `wifi/build.sh --install --unit`.

- **Restarting the daemon leaves Android's Wi-Fi switched off**, and the cause is AOSP's own quota:
  `SelfRecovery` allows 2 restarts an hour and one daemon restart delivers 2–3 binder deaths, so the
  first spends the budget and the rest land on `Disabling wifi`. `waydroid-wifi-nudge` re-enables it
  from `ExecStartPost`, respecting `Settings.Global wifi_on`. The old
  `set-scan-always-available disabled/enabled` dance is **obsolete** — it was compensating for the
  SELinux denial above, not for anything about registration.

- **Stock wificond can never take the name.** `artifacts/overlay/system/etc/init/wificond.rc` is
  deployed and points the service at `/system/bin/true` with `oneshot`, so it execs and exits;
  `getprop init.svc.wificond` is empty across a full boot. Marking it `disabled` alone was **not**
  enough — something asks init to start it on the connectivity-mode path. See
  [34](34-wifi-second-radio.md).

The other two candidates, both still open:

1. **Vibration** — the rest of goal 2, and the harder half. Unchanged from the previous scoping;
   read the next section. Nothing about the sensors work moves it forward, because the sensors were
   already readable from Linux and the vibrator still is not. It needs the DSDT, not Waydroid.
2. **Goal 5, removable media** — untouched, and still the cheapest thing on the list. Exposing the
   user's `/run/media/<username>` to the container is probably sufficient.

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
| **`/usr/local/bin/waydroid-sync`**, **`waydroid-bt-restore`** | periodic sync-window scripts, mode `0755`. See [17](17-hybrid-sleep.md). Delete to revert |
| `/etc/systemd/system-sleep/50-waydroid-sync` | **REMOVED 2026-09-07** — it had never run. systemd 259 scans only `/usr/lib/systemd/system-sleep`, empty and read-only here; measured, 9 suspends in one boot and 0 hook runs, and `/run/waydroid-sync.cycle` had never existed. Replaced by `waydroid-sync-sleep.service` below. `/etc/systemd/system-sleep/` is now **empty and must stay that way** — anything put there is silently dead. See [27](27-android-power-button.md) |
| **`/etc/systemd/system/waydroid-sync.{timer,service}`** | installed but the timer is **DISABLED**. Its guards were verified to refuse action, but the path where it *acts* has never run. Enable with `sudo systemctl enable --now waydroid-sync.timer` once tested |
| `/etc/systemd/sleep.conf.d/20-s3-test.conf` | **not installed** — the S3 comparison was cancelled and the file removed, so the host is back on validated s2idle. Source in [artifacts/power/](../artifacts/power/) |
| `/var/tmp/power-*.sh`, `/var/tmp/power-measure.log` | measurement harness and the raw session log. `/var/tmp` survives reboots; safe to delete |
| sway output `eDP-1` transform | **back at `normal`, as found.** After a resume the display was reported upside-down; a `transform 180` was tried and was **wrong** — it put waybar at the bottom and inverted it, which is what 180 does to an already-correct display. Reverted. Cause never established, and sway reported `normal` throughout. Note `grim` cannot diagnose this: it captures the compositor framebuffer, so it looks correct whatever the panel is doing |
| **`/etc/systemd/logind.conf.d/10-power-button.conf`** | **power button: short press suspends, long press powers off**, mode `0644`. Was previously unconfigured, i.e. a short press powered the machine off. Delete to revert. See [15](15-power-button.md) |
| **`/etc/systemd/sleep.conf.d/10-s2idle.conf`** | `MemorySleepMode=s2idle`, mode `0644` — pins suspend to s2idle instead of the `deep` default. Delete to revert |
| **`/usr/local/bin/waydroid-android-key`** | **injects a key into Android from the host**, mode `0755`. Writes an `input_event` into the guest's `/dev/input/wl_keyboard_events` FIFO, reached via `/proc/<container pid>/root`. See [27](27-android-power-button.md) |
| **`/usr/local/bin/waydroid-android-lock`** | the `pre`/`post` policy: sleep + arm the keyguard, then wake. Drive **this**, not the unit, to test by hand, mode `0755` |
| **`/etc/systemd/system/waydroid-android-lock.service`** | **enabled** via a `sleep.target.wants/` symlink. `Before=sleep.target` so the pre leg runs ahead of the `user.slice` freeze. Delete both to revert. **Not** a `system-sleep` hook, and [27](27-android-power-button.md) explains at length why it cannot be. Note the unit is in `/etc`, **not** under `/usr/local`: `/usr/local` is `/var/usrlocal`, which SELinux labels `lib_t`, and `init_t` may not *start* a `lib_t` service — measured, it fails with `avc: denied { start } … tclass=service` |
| **`/usr/local/bin/ite8350-resume-check`** + **`/etc/systemd/system/ite8350-{sleep,resume-check}.service`** | **docs/19's sensor-hub safety net, finally actually running.** Was a `/etc/systemd/system-sleep/` hook that had never fired once; converted to units 2026-09-07 and it caught a real stale accelerometer on its first working resume. See [19](19-sensor-hub-suspend-wedge.md), [27](27-android-power-button.md) |
| **`/usr/local/bin/waydroid-sync-sleep`** + **`/etc/systemd/system/waydroid-sync-sleep.service`** | the sync feature's sleep/resume legs, converted from the dead `50-waydroid-sync` hook. Runs now (`/run/waydroid-sync.cycle` finally exists), but the feature as a whole stays dormant while `waydroid-sync.timer` is disabled |
| Android `screen_off_timeout` | **raised 60 s → 30 min 2026-09-07** (`settings put system screen_off_timeout 1800000`). Android-wide, so it affects sway sessions too. Belt and braces only: the timeout has never actually been observed to fire — `system_server` holds a `SCREEN_BRIGHT_WAKE_LOCK 'UndimDetectorWakeLock'`, and a deliberate 15 s timeout with 50 s idle did not sleep it. See [27](27-android-power-button.md) |
| Android keyguard | **enabled and secured 2026-09-07** — `locksettings set-disabled false`, `lock_screen_lock_after_timeout=0`, and a PIN set by the owner: `KeyguardServiceDelegate secure=true`, unlock confirmed under cage. **Lost credential: stop the session and delete `~/.local/share/waydroid/data/system/locksettings.db`** (host-visible, owned by the session user, no root). `locksettings` cannot do it — with a credential set every subcommand needs `--old <CREDENTIAL>` |
| **`/usr/local/bin/waydroid-shutdown-android`**, **`waydroid-shutdown-inhibitor`** | **graceful Android shutdown when the host goes down**, mode `0755`. See [23](23-graceful-shutdown.md) |
| **`/etc/systemd/system/waydroid-shutdown-inhibitor.service`** | **enabled**. Holds a logind `shutdown`/`delay` lock and runs the shutdown on `PrepareForShutdown`. `systemctl disable --now` to revert |
| **`waydroid-container.service.d/graceful-shutdown.conf`** | `ExecStop=` + `TimeoutStopSec=60`, mode `0644`. Delete to revert |
| **`/usr/local/bin/waydroid-graceful-exit`** | **graceful Android shutdown at logout, unprivileged**, mode `0755`. See [24](24-graceful-logout.md) |
| **`/etc/sway/config.d/95-waydroid-graceful-exit.conf`** | rebinds `$mod+Shift+e` to shut Android down before `swaymsg exit`, mode `0644`. Loaded for every user; delete to revert |
| **`/usr/local/lib/systemd/user/waydroid-graceful-exit.service`** | backstop for logouts that bypass the chord, plus a `graphical-session.target.wants/` symlink that enables it for every user. Delete both to revert |
| **`/usr/local/bin/waydroid-cage-session`** | **Waydroid as a kiosk session under cage**, mode `0755`. Entry check, shutdown watchdog, exit paths. See [25](25-waydroid-in-cage.md) |
| **`/var/tmp/waydroid-install/`** | staged sources for the two installers above (`cage`, `graceful-exit`). `/var/tmp` survives reboots; safe to delete |
| **`/etc/wayland-sessions/waydroid-cage.desktop`** | the SDDM session entry, `cage -s -- …/waydroid-cage-session`, mode `0644`. Pre-existing file; restore the one-line `Exec=cage -- waydroid show-full-ui` to revert |
| `/var/tmp/powerbtn-probe.py` | copy of [bin/powerbtn-probe.py](../bin/powerbtn-probe.py), for the untested button-hold question in [15](15-power-button.md). `/var/tmp` survives reboots; safe to delete |
| **`overlay/system/etc/permissions/android.hardware.wifi.xml`** | **Wi-Fi Stage 0** — the one file that brings Android's whole Wi-Fi framework out of dormancy, mode `0644`. Delete to revert. See [29](29-wifi-plan.md) |
| **`/usr/local/bin/waydroid-wifid`** | **the host-side wificond + supplicant replacement**, mode `0755`. Started by `waydroid-wifid.service`, not by hand. Delete to revert. See [31](31-wifi-stage2.md), [34](34-wifi-second-radio.md), [35](35-wifi-stage5.md) |
| **`/etc/systemd/system/waydroid-wifid.service`** | **enabled.** Runs the daemon from boot, from `/dev/binderfs/binder` so it does not depend on the container. Carries `SELinuxContext=system_u:unconfined_r:unconfined_t:s0`, **without which every callback-passing binder call fails silently** — see [35](35-wifi-stage5.md). `systemctl disable --now` to revert |
| **`/etc/waydroid-wifid.conf`** | the daemon's arguments. Pins the radio by **factory MAC** (`34:E8:94:F8:61:70`, the T3U), not by `wlp0s20u1`, which encodes a USB port and renames if the adapter moves |
| **`/usr/local/bin/waydroid-wifi-nudge`** | re-enables Android's Wi-Fi after a daemon restart, run as `ExecStartPost`. Works around AOSP's `SelfRecovery` quota (2/hour, and one restart spends 2–3). Respects `Settings.Global wifi_on`. See [35](35-wifi-stage5.md) |
| **`/usr/local/bin/waydroid-wifi-sync`** + **`waydroid-wifi-sync.{service,timer}`** | **timer enabled.** Imports opted-in NetworkManager profiles into Android's saved networks, and deletes the NM profile when the network is forgotten in Android. Also triggered by the daemon when Android enables Wi-Fi. See [36](36-wifi-credential-sync.md) |
| **`/etc/waydroid-wifi-share.conf`** | the **opt-in allow-list**, mode `0600`, and the audit trail for which passphrases have been copied into Android's *cleartext* `WifiConfigStore.xml`. Currently: `vidiot	nodelete`. Empty it to stop sharing |
| `wlan0` in the container | **the container's uplink**, renamed by `lxc.net.0.name = wlan0` in `/var/lib/waydroid/lxc/waydroid/config` (backup at `config.pre-wlan0`). There is no `eth0`. ~~a dummy netdev from `bin/wifi-wlan0.sh`~~ — that script is retired |
| stock `wificond` | **can never start.** `artifacts/overlay/system/etc/init/wificond.rc` is deployed and points it at `/system/bin/true` with `oneshot`; `getprop init.svc.wificond` is empty across a full boot. Marking it `disabled` alone was not enough |
| `/var/lib/waydroid/waydroid-wifid.pid` | the wifi daemon's single-instance lock. Recreated on demand, safe to delete |
| `/var/lib/waydroid/waydroid-wifi-sync.state` | which networks the sync has confirmed present in Android. **Deleting it is safe** — it only ever licenses a deletion, so losing it makes the next run more conservative, not less |
| `vidiot (Waydroid)` NM profile | the daemon's projection of an Android-driven connection: pinned to `wlp0s20u1`, `never-default`, `route-metric 1000`, UUID derived from the SSID. Recreated on the next connect if deleted. **Not** the host's own `vidiot` profile |
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
| **`/var/lib/waydroid/waydroid_base.prop`** | **two dex2oat properties added 2026-09-12** — `dalvik.vm.dex2oat-threads=2`, `dalvik.vm.dex2oat-cpu-set=0,2`, pinning background dexopt to one physical core so it stops saturating the machine. Stock file kept at `waydroid_base.prop.pre-dexopt`. Survives reboots and container restarts; **erased by `waydroid init -f` or `waydroid upgrade`** — re-run `artifacts/dexopt/install.sh`. See [43](43-app-freezer.md) |
| `/usr/local/share/waydroid-dexopt/dexopt.prop` | payload for the above, mode `0644`. Staged by the same installer so it doubles as the RPM's `%install` step |
| `use_compaction=true` (Android `device_config`) | **set, working, and ephemeral.** Enables `CachedAppOptimizer`'s compaction half. Verified to reclaim memory only when the flag is in effect *at container start*, and it is **lost on every container restart** — `device_config get` reads `null` afterwards. Nothing re-applies it yet; see `packaging/README.md`'s planned `ExecStartPost` one-shot |

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

- **A frozen accelerometer is indistinguishable from the sign-convention bug.** The ITE8350 does
  not always survive s2idle: it keeps *answering* reads while returning the same numbers forever,
  so Android pins the display to whatever rotation the stale sample implies and every app comes up
  rotated — the exact symptom [docs/18](18-sensor-axes.md) fixed, from an unrelated cause. Check
  staleness with `bin/sensor-hub-reset.sh --check` before re-opening that. Recovery is a driver
  reprobe, now automatic on resume; see [docs/19](19-sensor-hub-suspend-wedge.md).
- **A hub reprobe renumbers the `iio:deviceN` nodes** — but only the first time after a boot,
  because the boot-time and reprobe probe orders differ. That is also the only time it matters.
  `waydroid-sensord` now re-resolves by name when a read fails, so it no longer costs a container
  and session restart.
- **A cross-check is only independent if it was not written against the broken behaviour.**
  `waydroid-sensord --selftest` compared the hub's fused quaternion against its accelerometer and
  *required them anti-parallel* — which is what the hardware reported. So it ratified the
  accelerometer's inverted sign instead of catching it, and `bin/sensors-test.sh` compared
  Android's value against the raw IIO node with exactly the same blind spot. Both passed for a
  month. A check derived from observed behaviour rather than from the spec tests self-consistency,
  not correctness. See [docs/18](18-sensor-axes.md).
- **`systemctl restart waydroid-container` stops the session and does not bring it back.**
  `waydroid status` sits at `Session: STOPPED` indefinitely. Restart it as the session user:
  `XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus nohup waydroid session start &`
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
| Upside-down apps are a sensor *mounting* rotation | wrong — all three axes negated is a reflection (det −1), which no rigid mount can produce; it is a sign convention |
| `axis_rotation` can correct the upside-down apps | wrong — it only rotates about Z and can never change the Z component |
| The panel's natural orientation is wrong | wrong — the `NOSENSOR`-pinned launcher renders correctly at `ROTATION_0` |
| The magnetometer shares the accelerometer's inverted sign | wrong — `getRotationMatrix` azimuth lands 11° from the hub's own heading, not 180° |
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

## Goals 3-7

Goal 3 is **done** — see [docs/10](10-battery-fixed.md). Two things it deliberately left alone, both
scoped in that doc: battery *temperature* (needs an NDK rebuild of the health HAL so the board hook
reads a thermal zone instead of being stubbed out) and *system* thermals (this image ships no
thermal HAL at all — `dumpsys thermalservice` says `HAL Ready: false`). Neither is required for the
goal. Goal 3 also has one unverified behaviour: the battery sat at 100% on AC throughout, so
*tracking a changing value* was never exercised. Unplug the charger and re-run `bin/battery-test.sh`.

Goal 4 is now **Wi-Fi** — scoped 2026-09-07, nothing built; see
[28-wifi-feasibility.md](28-wifi-feasibility.md) and [29-wifi-plan.md](29-wifi-plan.md). Removable
media is now goal 6. It is untouched and remains the cheapest remaining item, but the owner
deprioritised it below Wi-Fi.

Goal 5 is **audio**, added 2026-09-11; scoped, nothing built. See
[44-audio-alsa-backend.md](44-audio-alsa-backend.md). Phase 1 is a `--audio-backend
{auto,alsa,pulse,none}` CLI option probed before Android boots; phase 2 is a DAW-grade HAL. Three
things to know before touching it. Nobody is building a native PipeWire client for Waydroid and
there is a good reason not to, but the HAL is **already an ALSA client** — it opens the alsa-lib
name `"pulse"`, which is just a config alias — so redirecting it is small. Sharing a card with the
host is not possible (one substream per PCM here, dmix cannot cross the container's IPC namespace,
PipeWire opens `hw:` directly), so this means dedicating a device, exactly like the second radio in
[34](34-wifi-second-radio.md). And an availability probe run as root will lie, because root opens
`/dev/snd/*` regardless while Android's audioserver is uid 1041 — `/dev/video0` being
world-accessible is the only reason the camera works today. Nothing about audio has ever been
tested on this machine, including whether it works at all right now.

Goal 7 is **Android's per-app freezer**, added 2026-09-10. See
[43-app-freezer.md](43-app-freezer.md), which was substantially rewritten on 2026-09-12. The
freezer itself is still unbuilt and the battery case against it is now measured twice; two
*adjacent* things were built instead, and both work.

Four things to know before touching it.

**There are two faults, not one.** The read-only `/sys/fs/cgroup` costs the freezer and process
groups. Separately, the four cgroup **v1** controllers Android asks for — `/dev/cpuctl`,
`/dev/cpuset`, `/dev/blkio`, `/dev/memcg` — never mounted and never can, because this host is
cgroup v2 unified (`/proc/cgroups` shows hierarchy `0` for all fourteen). Those directories exist
inside the container as empty tmpfs stubs. **Widening `lxc.mount.auto` does not fix that one**, and
it is the larger of the two: 44 of the 45 controller references in `task_profiles.json` are dead,
so Android's entire scheduling-policy layer is inert and `nice` is not covering for it.

**The cost is performance, not battery.** Freezer-eligible work re-measured against a deliberately
fatter cached set is 0.887% of a core, about 13 mW of a 9.6 W machine. What it does cost showed up
on its own: Play Store's post-reboot dexopt took the machine to 91.6% busy with CPU pressure at
`some avg10=35%`, uncontained, because the `dex2oat` cgroup does not exist. That is fixed —
`artifacts/dexopt/` pins dex2oat with `--cpu-set`, which is `sched_setaffinity` and needs no cgroup.

**Compaction — the other half of `CachedAppOptimizer` — works, and is worth more than the freezer.**
It needs no cgroups and no kernel patch: `/proc/<pid>/reclaim` is an out-of-tree Android patch this
kernel will never have, but upstream's `process_madvise(2)` is present and is what Android 13
actually uses. `use_compaction=true` must be in effect **when the container starts** and **does not
survive a restart**, so it needs re-applying every time. `bin/waydroid-reclaim.py` does the same job
from the host with none of those conditions and recovered **~558 MB of RAM** in one measured run.

**And the old warning still stands:** logcat's `<pkg> is exempt from freezer` lines are exemption
bookkeeping that runs with the freezer disabled — they look like proof it works and are not.

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
anything from sensor data.

> **Premise superseded, 2026-09-07.** Auto-rotation has since been turned on
> (`accelerometer_rotation = 1`), and a real sensor bug was waiting behind it: the accelerometer's
> sign convention was inverted, so every app that follows the sensor came up upside down — while
> the launcher, pinned to `NOSENSOR` by the very override below, kept looking correct and
> disguised it. Fixed in [docs/18](18-sensor-axes.md). The launcher diagnosis below is unaffected;
> only the "auto-rotation is off, so it cannot be the sensors" reasoning has expired. The launcher requests `SCREEN_ORIENTATION_PORTRAIT`, and with the
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

**The override does survive a container restart** — established 2026-09-07 after a
`systemctl restart waydroid-container` for the sensors fix. Both change IDs came back with their
package overrides intact, so no startup hook is needed:

```
ChangeId(265464455; name=OVERRIDE_ANY_ORIENTATION; packageOverrides={org.fossify.home=true} ...)
ChangeId(265451093; name=OVERRIDE_UNDEFINED_ORIENTATION_TO_NOSENSOR; packageOverrides={org.fossify.home=true} ...)
```

Still open: the launcher's grid is the one it chose for portrait, so the icons sit in a
sparse staggered layout — the column count is a launcher setting and can be raised.
