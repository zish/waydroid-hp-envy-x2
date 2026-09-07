# Widevine L3 on Waydroid: fixing "this app is not compatible with your device"

**Status: FIXED and verified.** Waydroid's images ship no Widevine CDM at all, so every
DRM-protected streaming app rejects the device at launch. This adds Widevine **L3** through the
vendor overlay: four files and one symlink, no image modification, no `rpm-ostree` layering, no
reboot, reversible by deleting five paths.

Verify with `bin/widevine-test.sh`.

> **Netflix specifically still does not run**, for a completely separate reason this fix cannot
> address — it detects the container and terminates itself deliberately. That is
> [22-netflix-container-detection.md](22-netflix-container-detection.md). Read *this* document for
> the DRM fix, which is real and which other Widevine apps need; read *that* one for why Netflix is
> a lost cause on Waydroid.

Environment: Waydroid 1.6.3, `MAINLINE`, LineageOS 20 / Android 13 (`TQ3A.230901.001`, SDK 33),
`x86_64`, on Fedora 44 Sway Atomic. See [00-host-baseline.md](00-host-baseline.md).

## Symptom

The app installs from the Play Store without complaint, then reports the device as incompatible at
launch. This is **not** a Play Store install filter — a filter would have prevented installation.
It is a runtime rejection.

## Root cause

The vendor image contains exactly one DRM plugin, ClearKey:

```
/vendor/lib/mediadrm/libdrmclearkeyplugin.so
/vendor/lib64/mediadrm/libdrmclearkeyplugin.so
```

and `/vendor/etc/vintf/manifest/` declares exactly one DRM HAL,
`android.hardware.drm-service.clearkey.xml`. There is no Widevine CDM anywhere.

A DRM client probes the Widevine UUID `edef8ba9-79d6-4ace-a3c8-27dcd51d21ed` on startup. ClearKey
is the only factory available, it refuses that crypto scheme, and the framework gives up:

```
I DrmUtils: found IDrmFactory. Instance name:[android.hardware.drm.IDrmFactory/clearkey]
E clearkey-DrmFactory: Clearkey Drm HAL: failed to create drm plugin, invalid crypto scheme
E DrmHalAidl: uuid=[edef8ba979d64ace a3c827dcd51d21ed] Failed to make drm plugin: 6
E DrmHalHidl: uuid=[edef8ba979d64ace a3c827dcd51d21ed] No supported hal instance found
```

The absence of a CDM *is* the incompatibility. Nothing about the app needs changing.

## The fix

### Provenance of the blob

`waydroid_script` pins a prebuilt per (architecture, Android version). For `x86_64` + Android `13`:

| | |
|---|---|
| Repo | [WayDroid-ATV/vendor_google_proprietary_widevine-prebuilt](https://github.com/WayDroid-ATV/vendor_google_proprietary_widevine-prebuilt) |
| Commit | `679552343d8b2e8d7a19b6df61c7a03963d0c75b` |
| Archive md5 | `80ab79ea85c7b2556baedb371a54e01c` — **verify this on download** |
| Extracted from | ChromeOS `nissa` recovery image |
| Android fingerprint | `google/nissa/nissa_cheets:13/R130-16033.58.0/12608590:user/release-keys` |

ChromeOS `nissa` is an x86_64 board running ARCVM Android 13, which is why this is a clean match
rather than a port. Both binaries report `for Android 33`, identical to this container's
`ro.build.version.sdk`.

It is an **AIDL** DRM HAL (`android.hardware.drm.IDrmFactory/widevine`), matching the container's
existing AIDL ClearKey service. The older HIDL layout — `libwvhidl.so`, `libwvdrmengine.so`,
`android.hardware.drm@1.3-service.widevine` — that most Widevine-on-Android-x86 guides describe
does **not** apply to Android 13 here. If you are following an older guide and hunting for
`libwvhidl.so`, you are on the wrong track.

### What gets installed

Staged in `artifacts/widevine/vendor/`, deployed into `/var/lib/waydroid/overlay/vendor/`:

```
bin/hw/android.hardware.drm-service-lazy.widevine                       0755 root:root   12 KB
etc/init/android.hardware.drm-service-lazy.widevine.rc                  0644 root:root
etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml   0644 root:root
lib64/libwvaidl.so                                                      0644 root:root  2.9 MB
lib64/libprotobuf-cpp-lite.so -> libprotobuf-cpp-lite-3.9.1.so          symlink
```

### The symlink is load-bearing, not cosmetic

`libwvaidl.so` has a `NEEDED` entry for the **unversioned** soname `libprotobuf-cpp-lite.so`. On
this image that name exists only in `/system/lib64` — which a *vendor* process cannot link against,
because vendor processes resolve within `/vendor/lib64` plus the VNDK apex. `/vendor/lib64` carries
only the **versioned** `libprotobuf-cpp-lite-3.9.1.so` (496520 bytes, byte-for-byte the size of the
system copy), and `/apex/com.android.vndk.v33/lib64` has no protobuf at all.

Without the symlink the HAL fails to load with an unresolved-library error that says nothing about
DRM, which is a miserable thing to debug. `waydroid_script` patches the same gap for Android 13.

Every other dependency of both binaries resolves as shipped: `android.hardware.drm-V1-ndk.so`,
`libbase`, `liblog`, `libutils`, `libbinder_ndk`, `libc++`, `libcrypto`, `libcutils`.

### What is deliberately *not* installed

The upstream archive also carries `lib/mediadrm/libdrmclearkeyplugin.so` and
`lib64/mediadrm/libdrmclearkeyplugin.so`. `waydroid_script` copies the whole `prebuilts` tree and so
overwrites Waydroid's working ClearKey plugin with the ChromeOS build. **Skipped here**, because
that plugin is loaded by Waydroid's *own* `android.hardware.drm-service-lazy.clearkey` binary —
mixing a ChromeOS plugin into a Waydroid service is risk for no benefit. ClearKey keeps working and
keeps registering.

### SELinux is not an obstacle here

`getenforce` inside the container returns **`Disabled`**. Adding a new `/vendor/bin/hw` binary
normally needs a matching file context or init refuses to exec it; that whole class of problem does
not arise. (The *host* is SELinux Enforcing — unrelated, and untouched.)

That same property is one of the things that gives the container away to app integrity checks —
see [docs/22](22-netflix-container-detection.md).

## Deploying

Builds and downloads happen on the dev box, never on the 8 GB target. Note `rsync` is not installed
on this dev box, so `tar` over ssh:

```bash
cd artifacts/widevine
tar -cf - --owner=0 --group=0 -C vendor . \
  | ssh 10.42.0.137 'sudo tar -xvf - -C /var/lib/waydroid/overlay/vendor/'
ssh 10.42.0.137 'sudo ln -sfn libprotobuf-cpp-lite-3.9.1.so \
  /var/lib/waydroid/overlay/vendor/lib64/libprotobuf-cpp-lite.so'
ssh 10.42.0.137 'sudo systemctl restart waydroid-container'
```

The container restart is required: init parses `/vendor/etc/init/*.rc` and the VINTF manifest
fragment only at boot.

**The session does not come back by itself.** `systemctl restart waydroid-container` leaves
`Session: STOPPED`, and there is no `waydroid` systemd *user* unit on this host. Restart it as the
session user against the live compositor:

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
setsid nohup waydroid session start > /tmp/wd-session.log 2>&1 < /dev/null &
```

## Verifying

`bin/widevine-test.sh` does the whole thing. Two traps make hand-verification misleading:

**A missing `init.svc.*` property does not mean the fix failed.** The service is declared
`disabled` + `oneshot` — a *lazy* AIDL service. `init.svc.vendor.drm-widevine-hal` does not exist
until something first requests the HAL, and `service list` never shows it, because lazy services
are not registered until a client asks. This cost real time during the original session.

**`dumpsys media.drm` is not a valid probe on Android 13.** It returns `Can't find service:
media.drm`. That is not a symptom of anything.

Drive a real client and read the log instead:

```bash
sudo waydroid shell -- sh -c 'logcat -c; am start -n <drm-app>/<activity>'
sudo waydroid shell -- sh -c 'logcat -d | grep -iE "WVCdm|IDrmFactory"'
```

Success looks like:

```
I DrmUtils: found IDrmFactory. Instance name:[android.hardware.drm.IDrmFactory/widevine]
I AidlLazyServiceRegistrar: ... android.hardware.drm.IDrmFactory/widevine has clients: 1
I WVCdm-DrmFactory: [<package>] calling WVDrmFactory::createDrmPlugin(...)
D WVCdm: [cdm_engine.cpp(551):QueryStatus] security_level = L3, ...
I WVCdm: [cdm_engine.cpp(231):CloseSession] session_id = sid3
```

and afterwards `getprop` carries both services — `stopped` being correct for a lazy oneshot that
has run and exited:

```
[init.svc.vendor.drm-clearkey-service]: [stopped]
[init.svc.vendor.drm-widevine-hal]:     [stopped]
```

## Proof it works end to end

`drm-probe/` is a dependency-free Kotlin app that dumps every `MediaDrm` property for every
registered crypto scheme. It declares **no permissions on purpose**, so it sees exactly what an
ordinary app sees. `drm-probe/build.sh --install` builds it, installs it, runs it and prints the
report.

After the fix, Widevine answers everything:

| property | Widevine | ClearKey |
|---|---|---|
| vendor | `Google` | `Google` |
| version | `17.0.1@007` | `aidl-1` |
| description | `Widevine CDM` | `ClearKey CDM` |
| securityLevel | `L3` | THREW `ERROR_DRM_CANNOT_HANDLE` |
| systemId | `28926` | THREW |
| maxNumberOfSessions | `16` | THREW |
| provisioningModel | `OEMCertificate` | THREW |
| hdcpLevel / maxHdcpLevel | `Unprotected` | THREW |

That table also disposes of a red herring. The framework logs

```
E DrmHalHidl: Failed to get vendor from drm plugin: -1010
E DrmHalHidl: Failed to get description from drm plugin: -1010
```

where `-1010` is `ERROR_UNSUPPORTED`. That is the framework sweeping *both* plugins for metrics and
**ClearKey** declining. It predates the Widevine install and is not a fault.

More conclusive than any property is what appears on disk once a real client has used the CDM:

```
/data/vendor/mediadrm/IDM1013/L3/
  cert7bG-C8GiPY8bWFlg788d-w==.bin   3058 B   device certificate, obtained by provisioning
  ksid6ED875C7.lic                   6779 B   a persisted OFFLINE licence
  usgtable.bin                        497 B   usage table
```

The CDM provisioned itself against Google's server, an app requested an offline licence, received
it, and it persisted. Widevine on this device is fully functional.

### Trap: the probe's own `NotProvisionedException` is expected

```
Widevine  openSession()  FAILED -> NotProvisionedException: ERROR_DRM_NOT_PROVISIONED
ClearKey  openSession()  OK
```

This looks alarming and is not a fault. A Widevine CDM returns `NotProvisionedException` to a
client that has no provisioning for its origin; the client is then supposed to call
`getProvisionRequest()` and POST it to Google. Real apps do that; the probe deliberately does not.
ClearKey needs no provisioning, hence the contrast. The stored licence above proves sessions work.

## Limits

- **L3 is software-only**, so streaming services cap it at standard definition (~540p). HD needs
  L1, which requires a hardware TEE and a protected media path. A container on a Broadwell laptop
  has neither, and no software change can synthesise one. Hard ceiling.
- **There is no hardware video decoder at all**, and none advertises secure playback:

  ```
  video/avc   OMX.google.h264.decoder  secure=false
  video/hevc  OMX.google.hevc.decoder  secure=false
  video/vp9   OMX.google.vp9.decoder   secure=false
  video/av01  (no decoder)
  ```

  Software decode is adequate for L3 SD, but every frame is decoded on the CPU.
- **32-bit apps still get no Widevine.** The archive ships `lib64/libwvaidl.so` only. Most
  streaming apps are 64-bit, so this rarely matters.
- **PlayReady is absent** (`UnsupportedSchemeException ... NO_INIT`), as expected on Android.

## Rollback

Delete the five overlay entries and restart. No image was modified, so this is complete:

```bash
ssh 10.42.0.137 'sudo rm -f \
  /var/lib/waydroid/overlay/vendor/bin/hw/android.hardware.drm-service-lazy.widevine \
  /var/lib/waydroid/overlay/vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc \
  /var/lib/waydroid/overlay/vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml \
  /var/lib/waydroid/overlay/vendor/lib64/libwvaidl.so \
  /var/lib/waydroid/overlay/vendor/lib64/libprotobuf-cpp-lite.so'
ssh 10.42.0.137 'sudo systemctl restart waydroid-container'
```

The overlay entries otherwise survive container restarts and reboots on their own.

## Benign messages you will see and can ignore

- `E WVCdm: [initialization_data.cpp(135):SelectWidevinePssh] Unable to parse PSSH data into a
  protobuf: index = 0` — a capability probe with empty PSSH, not a playback path.
- `E WVCdm: [oemcrypto_adapter_dynamic.cpp:...] L1 not initialized. Falling back to L3` and
  `Keybox error: 25. Falling back to L3.` — correct on a device with no L1 keybox.
- `W ... Could not load liboemcrypto.so ... dlopen failed` — same thing; that library is the L1
  path and does not exist here.
- `E DrmHalHidl: Failed to find passthrough drm factories` and `hwservicemanager: Cannot find entry
  android.hardware.drm@1.0::IDrmFactory/default` — the framework checking the legacy HIDL path
  first. Present before this change too; the AIDL lookup on the next line is the one that matters.

## What this fix does and does not buy you

It **does** give the device a working, provisioned Widevine L3 CDM, which is what DRM-gated apps
check for. Apps that only need Widevine should now work, at SD.

It **does not** make Netflix run. Netflix clears the DRM stage completely — it signs in, fetches a
licence, and renders its profile picker — and then kills itself because it detects the container.
That is a separate, deliberate check:
[22-netflix-container-detection.md](22-netflix-container-detection.md).
