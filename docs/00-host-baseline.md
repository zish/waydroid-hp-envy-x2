# Host baseline — bigtab01

All facts below were read directly off the host on 2026-09-05 unless marked otherwise.

## Identity

| Property | Value |
|---|---|
| DMI vendor | Hewlett-Packard |
| DMI product | `HP ENVY x2 Detachable PC 13` |
| Board | `22E0` |
| Marketing model | HP Envy x2 13-j012dx (2015 detachable) |
| CPU | Intel Core M-5Y70 @ 1.10 GHz (Broadwell-Y, x86_64) |
| RAM | 7.7 GiB |
| Swap | 23 GiB |

**Why the CPU matters:** Broadwell-Y has no Intel `atomisp` ISP. The camera is therefore a
conventional USB UVC device rather than a MIPI/CSI sensor behind a proprietary ISP — which is
the difference between "wire up a config" and "port a driver". Confirmed below.

## Operating system

| Property | Value |
|---|---|
| OS | Fedora Linux 44.20260904.0 (**Sway Atomic**) |
| Kernel | 7.1.13-200.fc44.x86_64 |
| Compositor | Sway (Wayland) — good, Waydroid requires Wayland |
| SELinux | **Enforcing** |

**This is an rpm-ostree image-based system.** Consequences for every change we make:

- `/usr` is read-only. Packages require `rpm-ostree install` (layering) and a reboot.
- `/etc` and `/var` are writable — udev rules, Waydroid config, and overlays live there.
- Prefer changes that land in `/etc` or `/var`. Treat `/usr` edits as a last resort.

## Camera hardware

```
/dev/video0   HP TrueVision Full HD    ID_V4L_CAPABILITIES=:capture:
/dev/video1   HP TrueVision Full HD    ID_V4L_CAPABILITIES=:
/dev/media0
```

Driver: `uvcvideo` (with `videodev`, `videobuf2_*`, `mc`). Not a USB-enumerated external
webcam in `lsusb` output, but driven by the standard UVC stack.

**`video0` is the capture node. `video1` has no capture capability** — it is the UVC
*metadata* node that modern kernels expose alongside the capture node. Android's external camera
HAL detects and skips it correctly on its own, so this needs no configuration; see
[01-camera-investigation.md](01-camera-investigation.md).

**The camera is confirmed working on the host** — Cheese captures normally. Cheese is installed
as a **Flatpak** (`org.gnome.Cheese` 44.1), so it appears in neither `rpm -q` nor `PATH`. On an
Atomic host, check `flatpak list` before concluding a GUI app is missing.

## Waydroid

| Property | Value |
|---|---|
| Version | 1.6.3 |
| Vendor type | MAINLINE |
| Images | `/etc/waydroid-extra/images` (`system.img` 2.58 GB, `vendor.img` 582 MB, dated Apr 28) |
| Session | RUNNING (user `jmelanso`, uid 1000, `wayland-1`) |
| Container | STOPPED — stopped 22:10:50, after running from 20:34 |
| Data | `/home/jmelanso/.local/share/waydroid/data` |
| Overlays | `mount_overlays = True` |

`mount_overlays = True` is important: it means we can override individual vendor and system
files by dropping them into `/var/lib/waydroid/overlay/` without rebuilding or modifying the
read-only images. This is the preferred mechanism for every Android-side change in this project.

## Host access quirk

Non-PTY SSH sessions hang on this host; PTY sessions work. See
[02-ssh-access.md](02-ssh-access.md) for the workaround and what is still unknown.
