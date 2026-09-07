# Widevine L3 CDM — vendor overlay payload

Staged tree for `/var/lib/waydroid/overlay/vendor/`. Fixes Netflix reporting the device as
incompatible; full write-up in [../../docs/21-netflix-widevine.md](../../docs/21-netflix-widevine.md).

## Provenance

Not built here — a redistributed Google prebuilt, pinned by `waydroid_script` for
(`x86_64`, Android `13`):

| | |
|---|---|
| Repo | `WayDroid-ATV/vendor_google_proprietary_widevine-prebuilt` |
| Commit | `679552343d8b2e8d7a19b6df61c7a03963d0c75b` |
| Archive md5 | `80ab79ea85c7b2556baedb371a54e01c` — verified on download |
| Extracted from | ChromeOS `nissa` recovery image |
| Android fingerprint | `google/nissa/nissa_cheets:13/R130-16033.58.0/12608590:user/release-keys` |

ChromeOS `nissa` is x86_64 running ARCVM Android 13. Both binaries report `for Android 33`,
matching this container's `ro.build.version.sdk` exactly. AIDL HAL, not the older HIDL layout.

Re-fetch with:

```bash
curl -sSL -o widevine.zip \
  https://github.com/WayDroid-ATV/vendor_google_proprietary_widevine-prebuilt/archive/679552343d8b2e8d7a19b6df61c7a03963d0c75b.zip
md5sum widevine.zip   # expect 80ab79ea85c7b2556baedb371a54e01c
```

## Contents

```
vendor/bin/hw/android.hardware.drm-service-lazy.widevine   0755   lazy AIDL HAL service
vendor/etc/init/…widevine.rc                               0644   init service definition
vendor/etc/vintf/manifest/manifest_…widevine.xml           0644   declares IDrmFactory/widevine
vendor/lib64/libwvaidl.so                                  0644   the CDM itself (2.9 MB)
```

Plus one symlink created on the host, **not** stored here (git would flatten it into a file):

```
vendor/lib64/libprotobuf-cpp-lite.so -> libprotobuf-cpp-lite-3.9.1.so
```

That symlink is required, not cosmetic — `libwvaidl.so` needs the unversioned soname and a vendor
process cannot reach `/system/lib64`. Create it explicitly when deploying.

## Deliberately omitted from upstream

The archive also contains `lib/mediadrm/libdrmclearkeyplugin.so` and
`lib64/mediadrm/libdrmclearkeyplugin.so`. `waydroid_script` copies the whole tree and so
overwrites Waydroid's working ClearKey plugin with the ChromeOS build. Not staged here: that
plugin is loaded by Waydroid's own ClearKey service binary, and Netflix needs Widevine, not
ClearKey. No benefit, real risk.

## Deploy

`rsync` is not installed on the dev box:

```bash
cd artifacts/widevine
tar -cf - --owner=0 --group=0 -C vendor . \
  | ssh 10.42.0.137 'sudo tar -xvf - -C /var/lib/waydroid/overlay/vendor/'
ssh 10.42.0.137 'sudo ln -sfn libprotobuf-cpp-lite-3.9.1.so \
  /var/lib/waydroid/overlay/vendor/lib64/libprotobuf-cpp-lite.so'
ssh 10.42.0.137 'sudo systemctl restart waydroid-container'
```

The container restart leaves the session stopped; restart it as `jmelanso` (see docs/21).
Verify with `bin/widevine-test.sh`.
