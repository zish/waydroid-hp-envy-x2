# Why Netflix will not run on Waydroid — it detects the container and kills itself

**Conclusion: this is not a missing capability, and there is nothing to fix.** Netflix runs a
root/emulator detection sweep a few seconds after launch, concludes it is not on a real Android
device, and calls `Process.killProcess()` on itself. It does this *after* clearing every functional
hurdle: it signs in, provisions Widevine, fetches and persists a real offline licence, and renders
its profile picker with live artwork.

The DRM half of the problem is genuinely fixed and stays fixed — see
[21-netflix-widevine.md](21-netflix-widevine.md). That fix is what other Widevine apps need. This
document is about the wall behind it.

**If the goal is watching Netflix on a Linux laptop, use the host browser.** Firefox or Chrome play
Netflix through Widevine at 720p — better than the ~540p ceiling Widevine L3 would have imposed
inside Waydroid even if the app had run.

## The failure, as the user sees it

| t | state |
|---|---|
| +4 s | **"Choose Your Profile" fully rendered** — profiles, avatars and the rotating promo billboard all fetched from Netflix's servers |
| +5 s | the window is gone |
| ~+5.5 s | the process exits |

No crash dialog, no error message, no toast. The app simply disappears.

## The evidence

Everything inside the container is silent about this: no `am_crash`, nothing in the `crash` buffer,
no `data_app_crash` in `/data/system/dropbox`, no `am_anr`, no tombstone, and Netflix's release
build logs nothing under its own tags. The only in-container fact is:

```
8037  8371 I Process : Sending signal. PID: 8037 SIG: 9
```

`Process.killProcess(Process.myPid())` — a deliberate self-termination from one of its own threads.

So the investigation moved **outside** the container. Waydroid's Android runs under `lxc-start` in
a PID namespace, but the host still sees every container process, and `strace` is available on the
host. `bin/netflix-trace.sh` attaches to the main Netflix process from the host side and traces
`openat`/`access`/`readlinkat`/`kill` until it exits.

In its final two seconds Netflix reads **every system property** on the device by walking all of
`/dev/__properties__/u:object_r:*`, then probes a specific list of paths. All of these returned
`ENOENT` — they are things it was *looking for*:

| probe | what it detects |
|---|---|
| `/sbin/su`, `/system/bin/su`, `/system/xbin/su`, `/system/bin/failsafe/su`, `/system/sd/xbin/su`, `/system/bin/.ext/su`, `/system/usr/we-need-root/su`, `/data/local/su`, `/data/local/bin/su`, `/data/local/xbin/su`, `/su/bin/su`, `/usr/bin/su` | root |
| `/dev/zygisk` | Magisk / Zygisk |
| `/dev/goldfish_address_space`, `/dev/goldfish_sync`, `/sys/module/goldfish_battery` | the Android emulator (goldfish) |
| `/dev/bstpgaipc` | BlueStacks |
| `/system/framework/windows-system_server.jar`, `/vendor/lib64/hw/audio.primary.windows.so`, `/vendor/lib64/hw/hwcomposer.windows.so` | Windows Subsystem for Android |
| `/data/data/com.gbox.android/vfs_data`, `/data/data/com.clone.android.dual.space/vm` | app-cloning / virtualisation frameworks |
| `/system/lib64/cloud_aidl_interface-cpp.so`, `/etc/init/init.cloudservice.rc` | cloud-phone farms |
| `/etc/init.titan.sh`, `/etc/sim.prop`, `/data/downloads/.dp/apps.xml`, `/system/lib/libnb.so` | assorted emulator builds |

alongside `/proc/filesystems`, `/proc/modules`, `/proc/ioports`, `/proc/self/mounts` and
`/proc/self/maps` — the standard way to spot virtualisation from the mount table and loaded
modules. Then, immediately:

```
231795 02:34:36.101040 kill(8506, SIGKILL) = ?
231795 02:34:36.112268 +++ killed by SIGKILL +++
```

`8506` is its own pid *inside* the container namespace. This is an anti-tamper check reaching a
verdict and shutting the app down.

## Reproducing the trace

```bash
bin/netflix-trace.sh            # run on the target host, as the session user
```

The technique generalises to any container app that fails silently:

```bash
sudo ps -eo pid,args | grep -F 'com.example.app'      # the host CAN see container pids
sudo timeout 25 strace -f -tt -s 200 \
  -e trace=openat,access,readlinkat,kill,tgkill,exit_group -p <host-pid> -o /tmp/app.strace
```

Keep the syscall filter narrow. A full `-f` trace of an ART process is enormous and slows the app
enough to change its timing.

## The two checks Waydroid fails structurally

Most entries in that table are absent here — which is the *good* answer. Two are not, and both are
inherent to how Waydroid works rather than anything configuration can fix:

- **`/sys/fs/selinux/policy` → `ENOENT`.** `getenforce` inside the container returns `Disabled`.
  Every real Android device has a loaded policy. (Ironically this is the same property that makes
  installing a vendor HAL painless — see docs/21.)
- **`/sys/devices/system/cpu/cpu*/cpufreq/stats/time_in_state` → `ENOENT`** on all four CPUs. Real
  devices expose these. `system_server` complains about the same absence independently:
  `E KernelCpuSpeedReader: Failed to read cpu-freq: .../time_in_state: ENOENT`.

Add the mount table (`overlay`, `lxc`), `/proc/modules`, and the full property sweep, and the
container is not plausibly hideable from a check of this breadth. Anything that did work would be a
per-release arms race, and Netflix could still refuse server-side afterwards.

## Ruled out, with evidence

Recorded so none of this is re-derived. Every one of these was tested, not assumed.

| hypothesis | why it is wrong |
|---|---|
| Play Store compatibility filter | Netflix was already installed from `/data/app/…`, and Play was actively delivering feature splits for it during testing. Install was never blocked. |
| Missing GApps / no Google account | `com.android.vending` and `com.google.android.gms` present and working; Google's credential manager offers a saved Netflix password at sign-in. |
| Missing system feature | `pm list features` shows touchscreen, both orientations, Vulkan, `android.software.webview`. Nothing Netflix requires is absent. |
| Memory pressure | 4.5 GB available, 24 GB swap free. No `am_low_memory`, no lmkd activity. `am_kill` never names the main process — only its `:a:o.ddf` isolated helpers, reason `isolated not needed`, which is routine. |
| Native crash | No new tombstone; signal 9 is not what a segfault produces. |
| Java exception | No `am_crash` in the events buffer, empty `crash` buffer, no `data_app_crash` in dropbox. |
| ANR / watchdog | No `am_anr`, no `ANR in`, no SIGQUIT thread dump. |
| Play Integrity / SafetyNet | No DroidGuard, SafetyNet, Integrity or attestation calls anywhere in the capture window. |
| The profile tap | The first capture had an `input_interaction` 0.4 s before the kill, which looked causal. It is not: relaunching and **never touching the screen** produced the same self-kill twice. |
| Widevine being broken | The CDM is healthy and *provisioned*: `Level3 Library 28926`, OEMCrypto 17.1, and a device certificate plus a persisted offline licence on disk. See docs/21. |
| `Keybox error: 25` / `L1 not initialized` | Expected on a device with no L1 keybox. Not a fault. |
| `-1010` from `getPropertyString` | ClearKey declining properties it does not implement. Predates the Widevine install. |

## Two hypotheses that were tested and disproven

Both looked strong. Recording *why* they looked strong is the point.

### Device identity

The Widevine client identification Netflix sends to its licence server embeds, in plaintext:

```
company_name : Waydroid
model_name   : WayDroid x86_64 Device
build_info   : waydroid/lineage_waydroid_x86_64/...:13/...:userdebug/test-keys
```

`userdebug` and `test-keys` on an unknown model is exactly what a device-policy rejection would key
on, and a silent bail fits.

**Tested properly and disproven.** The device was made to present itself as the ChromeOS `nissa`
board — genuinely x86_64 so `ro.product.cpu.abilist` does not contradict the fingerprint, SDK 33
like this container, and *the same device the installed Widevine CDM came from*, so the CDM's
device certificate and build identity agree:

```
google/nissa/nissa_cheets:13/R130-16033.58.0/12608590:user/release-keys
```

Netflix self-killed exactly as before. Everything was reverted, and all four subsystems re-verified
afterwards (widevine, battery, sensors, camera — all pass). The mechanism and its traps are in
`artifacts/build-prop/`, kept because they are expensive to rediscover:

- **`waydroid_base.prop` cannot do this.** Read-only properties cannot be re-set once a
  `build.prop` has defined them. That file already sets `ro.hardware.gralloc=gbm` while the live
  value is `minigbm_gbm_mesa` — the image won.
- **`ro.product.*` is derived, and odm wins.** `ro.product.property_source_order` is unset, so init
  uses the default `odm,vendor,product,system_ext,system`. Editing `/system/build.prop` alone
  changes nothing observable. `ro.build.fingerprint` is in *no* `build.prop` — init derives it from
  brand/name/device/release/id/incremental/type/tags.
- **Miss one partition and Android accuses the device.** Leaving `vendor_dlkm` stock produced a
  system dialog on every boot: *"There's an internal problem with your device. Contact your
  manufacturer for details."* There are **seven** `build.prop` files here — enumerate them with
  `find / -xdev -name build.prop` rather than assuming. `/odm`, `/vendor_dlkm` and `/odm_dlkm` are
  the same inodes as their `/vendor/...` counterparts, so the vendor overlay reaches all three;
  `/product` and `/system_ext` are symlinks into `/system`.

### "Netflix is trying to show you an error dialog"

A stack trace appeared showing Netflix calling `displayErrorDialogIfExist` from
`ServiceAgentImpl.initCompleted`, ending in `android.view.WindowLeaked`. That reads as *Netflix has
a specific error with a message and probably an error code, and is trying to display it* — a very
promising lead.

**It was an artifact of the identity experiment's own bug.** That run had inconsistent build
fingerprints, so Android was putting up its own system dialog and disturbing the foreground. A
clean run contains neither: `grep -cE "WindowLeaked|displayErrorDialogIfExist"` → `0`. **There is
no Netflix error dialog in the normal failure.** Chasing this cost a round of screenshot sampling
at 1 s, then back-to-back, looking for a dialog that never existed.

## Traps worth knowing for any Waydroid app investigation

- **`waydroid shell` always exits non-zero**, with a cosmetic
  `ERROR: [Errno 13] Permission denied: 1`. Its exit status carries no information, so `test -e`
  and friends are useless through it — judge by output instead. (`bin/widevine-test.sh` documented
  this trap in its own header and then fell into it anyway.)
- **`/data` inside the container is `~<user>/.local/share/waydroid/data` on the host** — *not*
  `/var/lib/waydroid/data`, which does not exist. That is how to retrieve `screencap` output and
  log dumps without adb.
- **adb is unauthorised** by default; `sudo waydroid shell` is the reliable route.
- **`uiautomator dump` returns nothing here**, so it is not a route to on-screen text.
- **Netflix's process is extremely noisy.** Thousands of
  `Method exceeds compiler instruction limit: 16652 in int o.dbS.e(int)` JIT lines swamp any grep.
  Dump the whole buffer to another machine and filter there:
  ```bash
  sudo waydroid shell -- sh -c 'logcat -d > /data/local/tmp/full.log'
  ssh host 'sudo cat ~user/.local/share/waydroid/data/local/tmp/full.log' > full.log
  awk '$3=="<pid>"' full.log | grep -vE "Method exceeds compiler|JIT allocated|GC freed"
  ```
- **System dialogs never reach logcat.** Their text comes from framework resources. Take a
  `screencap`; a `grep` for the wording will always return zero and mislead you.
- **Classes are obfuscated.** `o.kNU` is the profile activity, `o.ddf` an isolated service. Useful
  for correlating lifecycle events, useless for reading intent.

## What was actually achieved

Netflix has, on this machine, everything it legitimately needs: a provisioned Widevine L3 CDM, a
successfully fetched and persisted offline licence, a working media stack, a signed-in account, and
a fully rendered profile screen. It declines anyway, by policy, because it can tell it is running
inside a container.

That is where this line of work ends. The Widevine fix stands on its own and is the durable result.
