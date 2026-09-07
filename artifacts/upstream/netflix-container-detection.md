# Draft — community writeup: why Netflix stops working after Widevine is installed

**Not posted.** Suitable for the Waydroid issue tracker or discussions, or as a reply wherever
"Netflix opens then closes on Waydroid" comes up. Post only with the maintainer's/user's
say-so — see the repo convention for upstream reports (`artifacts/upstream/`).

The point of publishing this is to *stop* people chasing it. The usual thread on this subject
cycles through GApps, device fingerprints, `waydroid_base.prop` and reinstalls for weeks. None of
those are the cause, and this says so with measurements.

---

## Netflix on Waydroid: Widevine is fixable, the app still is not

Short version: installing Widevine genuinely fixes the "this app is not compatible with your
device" rejection, and Netflix then gets all the way to its profile picker. It still exits after
about five seconds, because it runs a root/emulator detection sweep, finds the container, and
calls `Process.killProcess()` on itself. That is not something Waydroid can fix.

Everything below is measured on: Waydroid 1.6.3 MAINLINE, LineageOS 20 / Android 13
(`TQ3A.230901.001`, SDK 33), `x86_64`, Fedora 44, HP Envy x2 (Core M-5Y70).

### 1. The compatibility message really is a missing CDM

The vendor image ships only the ClearKey plugin. A client probing the Widevine UUID
`edef8ba9-79d6-4ace-a3c8-27dcd51d21ed` gets:

```
I DrmUtils: found IDrmFactory. Instance name:[android.hardware.drm.IDrmFactory/clearkey]
E clearkey-DrmFactory: Clearkey Drm HAL: failed to create drm plugin, invalid crypto scheme
E DrmHalAidl: uuid=[edef8ba979d64ace a3c827dcd51d21ed] Failed to make drm plugin: 6
E DrmHalHidl: uuid=[edef8ba979d64ace a3c827dcd51d21ed] No supported hal instance found
```

Installing Widevine L3 clears this completely.

### 2. Two notes for anyone installing Widevine on Android 13

Worth stating because most guides predate it:

- **It is an AIDL HAL now, not HIDL.** On Android 13 the prebuilt is
  `android.hardware.drm-service-lazy.widevine` + `libwvaidl.so`, registering
  `android.hardware.drm.IDrmFactory/widevine`. If you are following an older guide and looking for
  `libwvhidl.so` / `libwvdrmengine.so` / `android.hardware.drm@1.3-service.widevine`, you are on
  the wrong track.
- **`libwvaidl.so` needs an unversioned `libprotobuf-cpp-lite.so`,** which on these images exists
  only in `/system/lib64` — unreachable from a vendor process. `/vendor/lib64` has only
  `libprotobuf-cpp-lite-3.9.1.so`. Symlink it, or the HAL fails to load with an
  unresolved-library error that mentions nothing about DRM. (`waydroid_script` does this; people
  installing by hand often miss it.)

Two further things that waste time when verifying:

- The service is `disabled` + `oneshot` — a **lazy** AIDL service. `service list` will not show it
  and `init.svc.vendor.drm-widevine-hal` will not exist until a client first asks for the HAL.
  Neither absence means the install failed.
- **`dumpsys media.drm` is not a valid probe on Android 13** — it returns
  `Can't find service: media.drm` regardless.

### 3. Widevine really does work afterwards

Not just "the plugin loads". After a real client uses it:

```
/data/vendor/mediadrm/IDM1013/L3/
  cert…​.bin          3058 B   device certificate, obtained by provisioning
  ksid6ED875C7.lic    6779 B   a persisted OFFLINE licence
  usgtable.bin         497 B   usage table
```

The CDM provisioned against Google's server and Netflix obtained and stored a real licence.
`MediaDrm` reports `vendor=Google`, `version=17.0.1@007`, `securityLevel=L3`, `systemId=28926`.

### 4. And Netflix still exits

It signs in, fetches profile avatars and promo artwork over the network, renders the profile
picker at about +4 s, and the process is gone by +5.5 s. Inside the container there is nothing:
no `am_crash`, empty crash buffer, no `data_app_crash` in dropbox, no ANR, no tombstone, and its
release build logs nothing under its own tags. Just:

```
8037  8371 I Process : Sending signal. PID: 8037 SIG: 9
```

Waydroid's Android runs under `lxc-start` in a PID namespace, but **the host can still see every
container process**, so `strace` from the host works and is how this was settled:

```bash
sudo ps -eo pid,args | grep -F com.netflix.mediaclient      # host-side pid
sudo timeout 25 strace -f -tt -s 200 \
  -e trace=openat,access,readlinkat,kill,tgkill,exit_group -p <pid> -o /tmp/nf.strace
```

In its last two seconds Netflix reads every property on the device by walking
`/dev/__properties__/u:object_r:*`, then probes (all `ENOENT`, i.e. things it hoped to find):

| probe | detects |
|---|---|
| `/sbin/su`, `/system/bin/su`, `/system/xbin/su`, `/system/bin/failsafe/su`, `/system/sd/xbin/su`, `/system/bin/.ext/su`, `/system/usr/we-need-root/su`, `/data/local/{,bin/,xbin/}su`, `/su/bin/su`, `/usr/bin/su` | root |
| `/dev/zygisk` | Magisk / Zygisk |
| `/dev/goldfish_address_space`, `/dev/goldfish_sync`, `/sys/module/goldfish_battery` | the Android emulator |
| `/dev/bstpgaipc` | BlueStacks |
| `/system/framework/windows-system_server.jar`, `/vendor/lib64/hw/{audio.primary,hwcomposer}.windows.so` | WSA |
| `/data/data/com.gbox.android/vfs_data`, `/data/data/com.clone.android.dual.space/vm` | app-cloning frameworks |
| `/system/lib64/cloud_aidl_interface-cpp.so`, `/etc/init/init.cloudservice.rc` | cloud-phone farms |
| `/etc/init.titan.sh`, `/etc/sim.prop`, `/data/downloads/.dp/apps.xml`, `/system/lib/libnb.so` | assorted emulator builds |

plus `/proc/filesystems`, `/proc/modules`, `/proc/ioports`, `/proc/self/mounts`,
`/proc/self/maps`. Then:

```
231795 02:34:36.101040 kill(8506, SIGKILL) = ?
231795 02:34:36.112268 +++ killed by SIGKILL +++
```

`8506` is its own pid inside the container namespace.

### 5. Two checks Waydroid fails structurally

Most of that list is absent, which is the good answer. Two are not, and neither looks like
something configuration can address:

- `/sys/fs/selinux/policy` → `ENOENT` (SELinux is `Disabled` inside the container; every real
  device has a loaded policy).
- `/sys/devices/system/cpu/cpu*/cpufreq/stats/time_in_state` → `ENOENT` on every CPU.
  `system_server` complains about the same absence independently.

Together with the mount table (`overlay`, `lxc`), `/proc/modules` and the property sweep, this is
a wide surface.

### 6. Things that are NOT the cause

Each of these was tested here and ruled out, so nobody needs to repeat them:

- Play Store compatibility filtering — the app was installed and Play was actively delivering
  feature splits for it.
- Missing GApps or an unregistered account — Play Services and sign-in both work.
- Memory pressure — 4.5 GB free, 24 GB swap; no lmkd activity, `am_kill` never names the process.
- A native crash, a Java exception, or an ANR — no tombstone, no `am_crash`, no `am_anr`.
- Play Integrity / SafetyNet — no attestation calls at all in the window.
- **Device fingerprint / `ro.product.*` spoofing.** Tested thoroughly: presented as a real
  x86_64 ChromeOS ARCVM device (`google/nissa/nissa_cheets:13/…:user/release-keys`), with all
  seven `build.prop` files consistent. No change; Netflix self-killed identically. Note also that
  `waydroid_base.prop` cannot change these — read-only properties cannot be re-set once a
  `build.prop` has defined them — and `ro.product.*` is derived with **odm winning** by default,
  so editing `/system/build.prop` alone does nothing. Miss one partition (`vendor_dlkm` is easy to
  overlook) and Android puts up "There's an internal problem with your device" on every boot.

### 7. Practical advice

Install Widevine — it is worth doing, and other Widevine-gated apps benefit. But for Netflix
itself on a Linux machine, use the host browser: Firefox or Chrome play it through Widevine at
720p, which is better than the ~540p that Widevine L3 inside Waydroid would have been capped at
anyway.
