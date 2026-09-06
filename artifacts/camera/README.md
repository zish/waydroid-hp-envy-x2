# External camera HAL — lens facing

All three files are `/vendor/lib/camera.device@3.4-external-impl.so` (ELF32 i386, 407,412 bytes),
pulled from the running vendor image on bigtab01 (LineageOS 20,
`20.0-20260403-GAPPS-waydroid_x86_64`). There is **no 64-bit counterpart** — the camera provider is
a 32-bit process. The 3.5 and 3.6 implementations are unused and contain neither the tag constant
nor the store pattern.

| File | md5 | `ANDROID_LENS_FACING` | |
|---|---|---|---|
| `…-impl.so.orig`  | `2b2b0a73e12e0083f684496f224d54b0` | `2` = `EXTERNAL` | as shipped |
| `…-impl.so.back`  | `add7e8d07c7d8549204e7a62c82b1e7d` | `1` = `BACK` | **deployed** |
| `…-impl.so.front` | `6368286e69d60410408b3032b78dd79a` | `0` = `FRONT` | built, **never deployed or tested** |

The only difference is **one byte at file offset `0x2c061`** (decimal 180321), the immediate of a
`movb` in `ExternalCameraDevice::initDefaultCharsKeys`:

```
2d05d: c6 44 24 2d 02      movb $0x2,0x2d(%esp)     <-- the byte; 02 = EXTERNAL
2d062: 8d 44 24 2d         lea  0x2d(%esp),%eax
2d066: 6a 01               push $0x1
2d068: 50                  push %eax
2d069: 68 05 00 08 00      push $0x80005            <-- ANDROID_LENS_FACING: identifies the site
2d06f: e8 fc 30 03 00      call CameraMetadata::update@plt
```

Locate it in an unfamiliar build by the 17-byte string `c644242d028d44242d6a01506805000800`
rather than by offset. Section headers give the vaddr→file-offset delta as `-0x1000`.

Reproduce from the original without this repo:

```bash
printf '\x01' | dd of=<binary> bs=1 seek=$((0x2c061)) conv=notrunc   # BACK
dd if=/dev/zero of=<binary> bs=1 seek=$((0x2c061)) count=1 conv=notrunc   # FRONT
```

Deploy to `/var/lib/waydroid/overlay/vendor/lib/` as **mode 0644** (a library, not a service
binary), then `waydroid session stop && waydroid session start` — a `container restart` will not
pick it up, because the overlay is a live overlayfs `lowerdir`.

This machine has exactly one physical camera, so `BACK` and `FRONT` are mutually exclusive;
`EXTERNAL` satisfies neither. Full reasoning in
[docs/11-camera-facing.md](../../docs/11-camera-facing.md).
