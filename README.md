# Waydroid hardware enablement for Linux laptops and tablets

Waydroid runs a full Android system in a container on a Linux host. Out of the box a lot of
the hardware underneath it is invisible to Android: the camera produces black frames, the
battery reads a hardcoded 85%, there are no sensors, the brightness slider moves nothing,
Wi-Fi settings are empty, and a USB stick you plug in does not appear.

This project fixes those, one at a time, as **separate packages you can pick from**. Each one
is a single modification with its own version, so installing the camera fix does not commit
you to anything else and updating it does not disturb anything else.

> **Status: packages are designed and staged, not yet published.** Everything here is running
> on the machine it was developed for, installed by hand from this repository. The package
> split described below is [designed](docs/47-package-split.md) and partly built; no RPM or
> deb has been published yet. If you are here now, you are reading the plan and the
> engineering notes, not a download page.

## Read these two pages first

They are short, and between them they cover every way these packages can appear broken when
nothing is wrong with them:

- **[How these packages change Android, and what can silently undo it](docs/user/overlay.md)** —
  nothing inside the Android images is ever modified, so uninstalling is exact and there is
  nothing to back up. But there is a layer *above* the one these packages use that belongs to
  you, and if you have ever done `mount -o remount,rw /` inside `waydroid shell` — which many
  guides tell you to do — your copy of a file wins over ours, permanently and silently.
- **[Custom Waydroid LXC configuration](docs/user/lxc-config.md)** — what the host daemons need
  from the container's configuration, which of those files Waydroid regenerates behind your
  back, and what breaks if your setup differs.

## What there is

**Camera** — Waydroid's minigbm wrapper imported the camera's fallback buffer with a width of
zero, so every preview frame was black. Rebuilt, both ABIs. Separately, the external camera
reports itself as a rear camera so that apps which require one will open it.

**Battery** — Waydroid's health HAL reads your real battery correctly and then overwrites every
field with hardcoded fakes on the one path that reaches Android. Patched out, so Android sees
the actual charge, voltage and adapter state.

**Sensors and screen brightness** — a host daemon that serves Android's sensor HAL from the
host's IIO devices, and its light HAL from `/sys/class/backlight`, so accelerometer,
gyroscope, magnetometer, orientation and rotation vector work, auto-rotation works, and the
brightness slider drives the real panel.

**Wi-Fi** — Android's own Wi-Fi settings, scanning and connecting to real networks, driven
through NetworkManager on the host. The container never owns a radio, so it can never strand
the host's network. The host backend is pluggable; NetworkManager is the first one.

**Removable media** — USB sticks, SD cards and optical media appear inside Android at
`/sdcard/Removable/<label>`, with a notification whose tap opens the volume in a file manager
and whose Eject action unmounts it. Hotplug included.

**Bluetooth** — an app that manages the host's BlueZ: scan, pair, connect, trust, rename and
forget, with pairing prompts — passkey confirmation, passkey entry, PIN — answered on the Android
screen. The container never gets the controller, so it cannot take the keyboard away from the host.
Useful mainly on a machine running Waydroid as its whole session, where there is no desktop
Bluetooth UI to reach. It can also take the place of Android's own Bluetooth tile in the
pull-down shade, which is dead weight in these images — there is no Bluetooth stack behind it.

**Session and power integration** — Android suspends and locks with the machine, shuts down
cleanly instead of being killed at logout, and can run full-screen as a kiosk session.

Machine-specific pieces — an ITE8350 sensor hub that needs reviving after suspend, and dexopt
tuning for a two-core Broadwell — are packaged separately under `hw-` names so you do not
inherit somebody else's laptop.

## How the packages fit together

Individual packages are `waydroid-ext-<thing>`. Group packages exist for convenience and pull
in the pieces of one feature:

```
waydroid-ext-camera      camera-gbm, camera-hal, uvc-autosuspend
waydroid-ext-wifi        wifid, wifi-framework, wifi-hostd, wifi-sync
waydroid-ext-sensors     sensord, binder-nice
waydroid-ext-brightness  sensord, brightness-overlay, backlight-selinux
waydroid-ext-storage     media, media-app
waydroid-ext-kiosk       cage, graceful-exit, graceful-shutdown, android-power
waydroid-ext-all         all of the above
```

A group is convenience only. Every hard requirement lives on the individual package, so
picking packages by hand cannot leave you with something installable but broken.

Android-side packages install their payload under `/usr/share/waydroid-overlay/` and a
reconciler deploys it before the container starts, on every boot. That is why installing a
package before you have ever run `waydroid init` is harmless, and why an overlay wiped by
`waydroid init -f` repairs itself at the next boot. See
[docs/user/overlay.md](docs/user/overlay.md).

## Supported platforms

Developed on Fedora Sway Atomic with Waydroid 1.6.3 and Android 13 (`MAINLINE`) images on an
HP Envy x2. Waydroid is in the official repositories of Fedora, Debian, Arch, Alpine and
nixpkgs; the packaging is being built for RPM first and Debian second. See
[docs/47-package-split.md](docs/47-package-split.md) for the distribution roadmap and
[docs/00-host-baseline.md](docs/00-host-baseline.md) for the reference machine.

The Android-side components are prebuilt binaries for **x86_64 Android 13**. They will not
work against a different Android version.

## The engineering notes

`docs/` is the record of the work — one numbered note per investigation, including what was
ruled out and why, not just what worked. It is written for whoever picks this up next, which
may well be you if you are porting any of it to different hardware.

Start with [docs/06-next-session.md](docs/06-next-session.md).

## Licence

GPL-3.0-or-later, except where a component says otherwise — the rebuilt minigbm wrapper is
Apache-2.0 and MIT, and the Widevine CDM is a Google proprietary prebuilt that these packages
fetch rather than redistribute. See [LICENSE](LICENSE) and each package's own metadata.
