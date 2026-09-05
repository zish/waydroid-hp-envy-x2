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

### sudo

Password auth for `sudo` is temporarily disabled, so sudo commands will run unprompted.
**Always confirm with me before running anything under sudo.**

## Goals, in priority order

1. **Camera** — **root cause pinned to one function; needs a rebuilt library.** The camera,
   driver, HAL, enumeration, and V4L2 streaming all work. Waydroid's minigbm `gbm_mesa` gralloc
   allocates the camera buffer as a 4096x338 R8 fallback but then *imports* it as
   `total_size x 1` with the YV12 luma stride — a shape Mesa rejects, so the map returns NULL and
   the camera HAL gets an all-zero plane layout. No configuration fixes it. The upstream `yuv`
   fix does **not** apply here: it needs YUV allocation that neither the host's nor Android's
   Mesa has. See [docs/07-phase1-android-mesa.md](docs/07-phase1-android-mesa.md), then
   [docs/01-camera-investigation.md](docs/01-camera-investigation.md) and
   [docs/04-phase0-gbm-map.md](docs/04-phase0-gbm-map.md).
2. **Accelerometer and vibration** — expose these to Waydroid.
3. **Power** — make Waydroid report correct battery statistics and AC adapter state.
4. **Removable media** — let Waydroid see USB sticks and MicroSD cards when inserted.
   Exposing the user's `/run/media/<username>` directory is probably sufficient.

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
  installed and layering a package on an Atomic host costs a reboot
- `artifacts/` — configs pulled from or staged for the host, with originals kept alongside

Record what was *ruled out* and why, not just what worked. Distinguish clearly between what has
been verified on the host and what is still hypothesis.
