# How these packages change Android, and what can silently undo it

Almost everything this project changes inside Android is a **Waydroid overlay file**. This
page explains what that means, what it guarantees, and the three ways it can appear to stop
working when nothing is actually wrong with the package.

If you read only one section, read [When your own changes win instead](#when-your-own-changes-win-instead).

## Nothing inside the Android images is modified

Waydroid boots Android from `system.img` and `vendor.img`, which are loop-mounted **read-only**
and never written. On top of them it stacks an overlayfs whose extra layer is a plain directory
on the host:

```
lowerdir = /var/lib/waydroid/overlay : /var/lib/waydroid/rootfs
             ^ our files here          ^ the read-only image
```

A file at `/var/lib/waydroid/overlay/vendor/lib64/libgbm_mesa_wrapper.so` *shadows* the one in
the image. The image's copy is untouched and still there.

**So there is nothing to back up, and uninstalling is exact.** Remove the file, restart the
container, and Android sees the stock file again — byte for byte, because it never moved. That
is also why `waydroid-overlay-sync` deletes a component's files with no backup step: there is
nothing it could destroy.

Two limits follow from the same mechanism:

- **These packages can add a file and replace a file. They cannot delete one.** Hiding a file
  that the image ships would need a whiteout device node, which nothing here creates.
- **Two packages must never claim the same path.** `waydroid-overlay-sync` reports that as a
  conflict rather than picking a winner.

## Deploying is not copying

`/var/lib/waydroid/overlay` is the *lower* directory of a mount that
`waydroid-container.service` creates once, when the container starts. **Adding a file to a
mounted lowerdir is undefined behaviour, and in practice Android simply cannot see it.** No
error appears anywhere. `ls` shows your file. Android behaves as though you never wrote it.

This is why the packages do not copy files into place themselves. They stage payload into
`/usr/share/waydroid-overlay/`, and `waydroid-overlay-sync.service` reconciles it into
`/var/lib/waydroid/overlay` **before** `waydroid-container.service` on every boot.

If you change anything by hand, the container has to be restarted for it to exist:

```bash
sudo systemctl restart waydroid-container.service
```

Be aware that on a kiosk or single-session setup this ends your Waydroid session and can drop
you back to the display manager, which is why no package does it for you.

## When your own changes win instead

There is a **third** layer, above the one these packages use, and it belongs to you:

```
upperdir = /var/lib/waydroid/overlay_rw/{system,vendor}      <- highest priority
lowerdir = /var/lib/waydroid/overlay                         <- these packages
           /var/lib/waydroid/rootfs                          <- the stock image
```

Anything in `overlay_rw` **outranks everything these packages install**, silently. There is no
warning, no log line, and `waydroid-overlay-sync --verify` will happily report that the overlay
matches what the packages expect — because it does. It is just not the layer Android is reading.

You get files in `overlay_rw` by writing to `/system` or `/vendor` **from inside Android**.
That is not exotic: a great many Waydroid guides tell you to do exactly that —

```bash
sudo waydroid shell
mount -o remount,rw /        # anything written after this lands in overlay_rw
```

— to install GApps or microG by hand, to edit `build.prop`, to drop in a different HAL, or to
follow an ARM-translation how-to. Any of those can leave a copy of a file this project also
ships, and from then on yours is the one Android uses, forever, including after you update the
package.

**Symptom to recognise:** a fix that used to work stops working after you edited something
inside Android, the package is installed and current, `--verify` is clean, and reinstalling
changes nothing.

Check for it:

```bash
sudo find /var/lib/waydroid/overlay_rw -type f
```

On a system where nobody has hand-edited Android, that prints nothing. Anything it does print
is shadowing the corresponding path. To hand a file back to the packages, delete your copy and
restart the container:

```bash
sudo rm /var/lib/waydroid/overlay_rw/vendor/lib64/libgbm_mesa_wrapper.so
sudo systemctl restart waydroid-container.service
```

`waydroid-overlay-sync --verify` reports these as `shadowed:` lines so you do not have to
remember to look.

A related case: a **whiteout** in `overlay_rw` (from deleting a file inside Android) hides the
path from every layer below, including ours. `find` shows those as character devices with major
and minor 0.

## What can wipe the overlay, and why that is survivable

None of these are package operations, so no package manager notices them:

| What you did | Effect |
|---|---|
| `waydroid init -f` | rewrites `/var/lib/waydroid`; overlay emptied |
| upgrading the Android images | overlay may be emptied or left stale against a new image |
| rebuilding the container after a bad session | same |
| restoring `/var` from a backup older than the packages | overlay reverts to whatever it held then |

`waydroid-overlay-sync.service` runs on every boot, before the container, so the overlay is
rebuilt from `/usr` without anyone watching. After any of the above, a reboot is enough. To do
it immediately:

```bash
sudo waydroid-overlay-sync            # reconcile
sudo waydroid-overlay-sync --verify   # report drift, change nothing
```

`--verify` exits non-zero if anything differs, so it is usable from a monitoring script.

One thing the reconciler will **not** do unattended is remove a file you edited after it was
deployed. It says so and keeps tracking the file; `--force` removes it.

## When an Android image update changes a file we replace

Seven of the files these packages ship *replace* a file that Waydroid's image also provides.
If an image update changes one of those, our copy keeps winning — which means it can quietly
revert somebody else's fix.

Each component's manifest records the checksum of the stock file it replaces, so this is
detectable rather than mysterious. After updating your Waydroid images, re-run
`waydroid-overlay-sync --verify` and check the project's issue tracker if a fix that used to
work behaves oddly.

## What is *not* in the overlay

A few things this project changes are ordinary files on your host, not Android files, and the
overlay's "nothing to back up" guarantee does not cover them. Every one is modified by an
idempotent reconciler that keeps the original the first time it changes anything:

| File | Owned by | Original kept at |
|---|---|---|
| `/var/lib/waydroid/waydroid_base.prop` | Waydroid (regenerated) | `waydroid_base.prop.pre-dexopt` |
| `/etc/avahi/avahi-daemon.conf` | your distribution's `avahi` package | `avahi-daemon.conf.pre-waydroid-ext` |
| `/var/lib/waydroid/lxc/waydroid/config` | Waydroid (regenerated) | see [lxc-config.md](lxc-config.md) |

The firewalld change is not an edit at all — it is a named rich rule added with `firewall-cmd`,
which you can list and remove independently.
