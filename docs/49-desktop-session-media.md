# Removable media under a GNOME or KDE session — giving the desktop control

**Status: measured 2026-09-19 and 2026-09-20 on the host, nothing built.** A follow-on to
[46-removable-media.md](46-removable-media.md), which designed for a cage kiosk where nothing
else mounts anything. In a GNOME or KDE session something else does, and this note establishes
what collides, what the desktops actually do, and which shape keeps them in charge.

The requirement is the owner's, and it is a constraint rather than a preference: **on a desktop
session, the desktop owns removable media.** Waydroid follows.

## What we do today

`waydroid-mediad` ([../artifacts/media/waydroid-mediad](../artifacts/media/waydroid-mediad)) owns
the mount outright: a root system unit, woken by udev block events, reconciling desired against
actual and calling `mount(8)` itself, straight into the FUSE lower directory at
`<data>/media/0/Removable/<label>` with `uid=1023,gid=1023,dmask=0007,fmask=0007`. Eject is a
marker file from the helper app plus `umount(8)`. docs/46 ruled out gvfs and udisks2, on grounds
that were correct **for a kiosk**: no desktop shell means nothing ever automounts, and a
`systemd --user` watcher is not in a login session so polkit falls through to `auth_admin`.

Both of those reasons are session-dependent. Under GNOME or KDE neither holds — we would not be
calling udisks2 at all, the desktop would.

One line decides the whole compatibility question, in `candidates()`:

```python
mountpoint = dev.get("mountpoint")
if mountpoint and not is_ours(mountpoint, base_real):
    continue                       # somebody else got there first
```

## What GNOME and KDE actually do

Neither mounts anything itself. Both are udisks2 clients, and udisks2 is a *system* service, so
the mechanism is identical and only the policy differs.

| | GNOME (Shell 40+) | KDE Plasma 6 |
|---|---|---|
| Who decides | `AutomountManager` in gnome-shell → GVolumeMonitor → `gvfs-udisks2-volume-monitor` | Solid's UDisks2 backend → Device Notifier + the `kded` device automounter |
| Automount default | **on** (`org.gnome.desktop.media-handling automount`, `automount-open`) | **off** — disabled by default upstream; the notifier appears and the user clicks |
| Mount call | `org.freedesktop.UDisks2.Filesystem.Mount()` | the same call |
| Mount point | `/run/media/$USER/<label>` | the same |
| Eject | `Filesystem.Unmount()` then `Drive.Eject`/`PowerOff` | the same |

`/run/media/$USER` is udisks2's convention, **not a fixed path** — Ubuntu patches it to
`/media/$USER`. Anything we build discovers the location from udisks2 or `mountinfo`; it does not
hardcode it.

udisksd mounts as root on the session user's behalf (`filesystem-mount` is `implicit active: yes`)
with its built-in option defaults, read from this host's own
`/etc/udisks2/mount_options.conf.example`:

```
vfat_defaults=uid=$UID,gid=$GID,shortname=mixed,utf8=1,showexec,flush
exfat_defaults=uid=$UID,gid=$GID,iocharset=utf8,errors=remount-ro,sys_tz
iso9660_defaults=uid=$UID,gid=$GID,iocharset=utf8,mode=0400,dmode=0500
udf_defaults=uid=$UID,gid=$GID,iocharset=utf8
```

`udisks2.service` has `UMask=0022`, so vfat and exfat land 0755/0644 — world-readable. iso9660 is
explicitly owner-only.

## Three collisions

1. **The race, and we lose it on GNOME.** gnome-shell automounts within milliseconds; our
   reconcile sits behind a 0.6 s coalescing delay. The desktop wins, `candidates()` skips the
   device, and **nothing appears in Android at all**. On KDE, where automount is off by default,
   *we* win — so the same code behaves oppositely on the two desktops, and flips again when a user
   ticks one checkbox. That is a coin toss, not a design.

2. **Eject breaks in both directions.** udisks2 reports *every* mountpoint of a device from
   `mountinfo` — measured here on the root device, which lists six, including a single-file bind
   of `waydroid.prop`. A volume *we* mounted is absent from udisks2's state file, and
   `handle_unmount()` then treats it as root-mounted:

   ```c
   if (mount_point == NULL)
     /* allow unmounting stuff not mentioned in mounted-fs, but treat it like root mounted it */
     mounted_by_uid = 0;
   …
   if (caller_uid != 0 && (caller_uid != mounted_by_uid))
     action_id = "org.freedesktop.udisks2.filesystem-unmount-others";
   ```

   So the session user clicking Eject in Nautilus or Dolphin is asked for an admin password.
   Conversely our own `umount(8)` goes behind udisks2's back and leaves its state stale.

3. **The permission models do not meet** — see the measurements below.

## Measured, 2026-09-19 and 2026-09-20

All of this was run on bigtab01 with the container up (init pid 1109901) and the isohybrid USB
stick mounted by `waydroid-mediad` throughout. Every test object was removed afterwards; the live
mount, `/run/media` and the daemon were left as they were found.

### Who actually reads the files

| | |
|---|---|
| FUSE daemon | uid **10141** = `com.android.providers.media.module`, holding `media_rw` (1023) as a supplementary group |
| Files it creates | land on the lower filesystem as **10141:10141**, not as `media_rw` |
| Lower dir | `/data/media/0` is `media_rw:media_rw` 0770, with a default ACL granting `group:1023:rwx` |

### Ownership models, read and write through FUSE

Three directories under `Removable/`, each emulating one mount's permission bits, read as uid 2000
(`shell`) through `/storage/emulated/0`:

| Case | Lower ownership | Read | Write |
|---|---|---|---|
| udisks2 vfat/exfat defaults | `1000:1000`, dir 0755, file 0644 | **yes** | **no** — `Permission denied` |
| udisks2 iso9660/udf defaults | `1000:1000`, dir 0500, file 0400 | **no** | no |
| ours today | `1023:1023`, dir 0770, file 0660 | yes | yes (file landed as 10141:10141) |

Two things worth keeping:

- **The owner-only case is denied even to root inside the container.** The check that fails is the
  FUSE daemon's own access to the lower file, so container-root does not bypass it. A `sudo
  waydroid shell` test is therefore a valid test here, which is not usually true.
- **There are two independent gates, and they look identical.** Reading as uid 10210 — the media
  helper app, which deliberately holds no storage permission — was denied on *all three* cases,
  including our own working one. That is MediaProvider's app-permission gate, not file modes. Test
  with uid 2000, or a permission failure will be blamed on the mount.

So: a desktop-mounted FAT volume is **readable but not writable** by Android, and a desktop-mounted
optical/isohybrid volume is **not visible at all**.

### The mirror works — with a real udisks2 mount, not just a stand-in

The first pass tested this with a tmpfs standing in for the volume, which was not good enough and
hid a blocker. The second pass used **real udisks2**, mounting a real vfat filesystem (a loopback
image, because udisks2 cannot open `/dev/sdb2` while `waydroid-mediad` holds the whole disk
mounted — `Can't open blockdev`, docs/46's isohybrid trap seen from the other side).

The mirror is made **before any volume exists**, which is the real boot order:

```
sudo mount --rbind /run/media <data>/media/0/ZZ_mirror
```

The new mount **joins `/run`'s peer group** rather than becoming independent — host `shared:17`, the
same group as `/run` — because binding a subtree of a shared mount produces a peer. It appears
immediately in the container at two paths, as `shared:… master:17`, i.e. slaved to that same group:

```
4570 71   0:29 /media /var/home/…/data/media/0/ZZ_mirror              shared:17
1024 4571 7:2  /      /data/media/0/ZZ_mirror/root/ZZVFAT             shared:994 master:928
1025 4572 7:2  /      /mnt/pass_through/0/emulated/0/ZZ_mirror/…      shared:994 master:928
```

(The second container path is vold's own `pass_through` view, noted in docs/46.)

Measured end to end:

| Step | Result |
|---|---|
| `udisksctl mount -b /dev/loop2` | mounted at `/run/media/root/ZZVFAT` |
| propagation into the container | **immediate**, both paths, no restart, no LXC change, **no propagation flags needed** |
| Android reading a real file through FUSE as uid 2000 | `hello from a real udisks-mounted vfat` |
| `udisksctl unmount -b /dev/loop2` | **succeeded with no complaint**, though udisks2 lists our mirror path in `MountPoints` |
| after that unmount | zero mounts left on host *and* in container; Android read → `No such file or directory` |

So `--rbind` does work for this, against real udisks2, in both directions. Two smaller
corroborations came free: `udisksctl` from a **non-seated ssh session is refused**
(`NotAuthorizedCanObtain`), which is docs/46's polkit session-class finding seen directly; and
udisks2 reports **both** mount points for the volume, so a desktop UI will see the Waydroid path.

### The blocker the stand-in hid: the media root is not world-traversable

udisks2 creates its per-user media root as:

```
drwxr-x---+ 2 root root /run/media/root      # ACL: user::rwx user:root:r-x group::r-x mask::r-x other::---
```

`other::---`. My tmpfs stand-in was 0755, which is why the first pass missed it. With the mirror in
place and the volume mounted, Android's read was **`Permission denied`** — MediaProvider's daemon
cannot traverse the media root, and nothing about the volume's own permissions matters until it can.

The fix is one ACL on a tmpfs directory, and it is the cleanest thing in this note:

```
sudo setfacl -m g:1023:x /run/media/$USER
```

Traverse only, no read, no write. It lives on `/run`, so it is **not persistent** and never touches
anyone's volume. It has to be (re)applied whenever udisks2 creates a new per-user media root, which
makes it the daemon's job, not a one-time install step.

### Three caveats on the mirror, all measured

- **An open file inside Android defeats the propagated unmount.** With a process in the container
  holding a descriptor under the mirror, unmounting the source reported success, the propagated
  unmount was **skipped**, and the container kept the mount:

  ```
  4358 3797 0:155 / /data/media/0/ZZ_mirror/FAKEVOL                  shared:1002 master:969
  ```

  Android went on reading the volume after the host believed it gone, so the desktop's "safely
  remove" would be lying. We cannot veto a udisks2 unmount, so the honest response is to notice it
  and say so — a job for the helper app's notification.
- **A second bind of the same volume keeps its superblock alive** past the desktop's unmount
  (observed with the idmapped clone below). That is the argument for mirroring *one directory*
  rather than binding each device.
- **FUSE serves stale content on the first read after a remount at a path it has read before.**
  Seen twice, on different days and different filesystems: a freshly `mkfs`-ed volume returned the
  *previous* volume's file contents at the same path, and the next read was correct. This is
  MediaProvider's cache, not the mount — the host showed the right bytes throughout. It matters
  because volume names repeat: two unlabelled sticks, or the same stick reformatted, land on the
  same path and the first thing the user sees may be the old volume's data.

## Permissions: four levers, three of which are dead ends

### POSIX ACLs — work exactly where idmapping was proposed, and better

On a filesystem with real ownership (loopback ext4, mounted by udisks2, standing in for an external
drive):

| | Result |
|---|---|
| `setfacl -R -m g:1023:rwX -m d:g:1023:rwX <mount>` | **OK** |
| Android read before the ACL | OK (mkfs leaves 0755) |
| Android write before the ACL | `Permission denied` |
| Android write after the ACL | **`WRITE OK`** |
| survives `udisksctl unmount` + `mount` | **yes** — it is on-disk metadata |

So ACLs replace idmapped mounts outright for ext4/btrfs/xfs: no `EOVERFLOW`, no per-filesystem
kernel support question, no second mount to keep the superblock alive. Two costs worth stating:
the ACL is **persistent metadata written onto someone else's volume**, and files Android creates
land owned by **10141:10141** — MediaProvider's app uid, which means nothing on the host — so a
volume written by Android and then carried to another machine shows unfamiliar ownership. The
default ACL is what keeps such files accessible to everyone who needs them.

### FAT, exFAT, ISO9660, UDF — no ACLs, no modes, no bits of any kind

On a real udisks2-mounted vfat volume, as root:

```
setfacl -m g:1023:rwx <mount>  →  Operation not supported
chmod 2775 <mount>             →  Operation not permitted
chmod g+s <mount>              →  Operation not permitted
chown :1023 <mount>            →  Operation not permitted
```

FAT stores no ownership or mode. Everything is decided by `uid=`/`gid=`/`fmask`/`dmask` **at mount
time** and cannot be altered afterwards except by remounting; udisks2 also mounts `nosuid`, so a
setuid bit would be inert even if it could be stored. For the media people actually plug in,
**mount options are the only lever that exists.**

And a caller cannot supply that option:

```
udisksctl mount -b /dev/loop2 -o "gid=1023,dmask=0007,fmask=0007"
  → OptionNotPermitted: Mount option `gid=1023' is not allowed
```

udisks2's built-in allowlist is `vfat_allow=uid=$UID,gid=$GID,…` — the caller's *own* ids only.
Since the caller is GNOME or KDE and not us, that is moot anyway. The option has to come from
**server-side `/etc/udisks2/mount_options.conf`**, and that **works** (measured 2026-09-20):

```ini
[defaults]
vfat_defaults=uid=$UID,gid=1023,shortname=mixed,utf8=1,showexec,flush,dmask=0007,fmask=0007
vfat_allow=uid=$UID,gid=$GID,gid=1023,flush,utf8,shortname,umask,dmask,fmask,codepage,iocharset,usefree,showexec
```

After `systemctl restart udisks2`, a plain `udisksctl mount` produced:

```
rw,nosuid,nodev,relatime,gid=1023,fmask=0007,dmask=0007,allow_utime=0020,codepage=437,…
drwxrwx--- 2 0 1023   /run/media/root/ZZVFAT
```

and Android — as uid 2000, through the mirror — could **read, write and delete**, including
deleting a file the host had just created. Deleting the config and restarting udisks2 put the
built-in `fmask=0022` defaults back, verified by remounting.

Two details worth keeping. The daemon needed the **restart** to pick the file up; whether it
re-reads per mount was not tested. And both `vfat_defaults` and `vfat_allow` carried `gid=1023` in
this test, so which of the two was load-bearing was not isolated — the `_defaults` line alone is
the likely answer, since the caller passed no options at all.

FAT's one advantage over ext4 turns up here: because it has no per-file ownership, files Android
writes show up as the **mounting user's**, not as uid 10141. On this test the caller was root, so
they landed `0:1023`; under a desktop session they would land as the desktop user.

For the record, this is what real udisks2 actually mounted (root caller, so no `uid=`/`gid=` in the
string):

```
rw,nosuid,nodev,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,
shortname=mixed,showexec,utf8,flush,errors=remount-ro
```

### Group membership cannot be handed over from the host

The idea of adding a host user to the owning group, or setting setgid on the mount point, does not
reach the process that does the work. The lower-filesystem I/O is done by MediaProvider **inside the
container**:

```
Uid: 10141  Gid: 10141
Groups: 1015 1023 1065 1077 1078 1079 3007 9997 20141 50141
```

Those supplementary gids are assigned by Android at fork time from the app's own definition. The
container has its own static AOSP group database and no NSS, so the host's `/etc/group` is never
consulted and no host-side `usermod` changes them. The workable inversion is to **mount with a gid
the daemon already holds** — `1023` (`media_rw`) — which is also narrower than granting Android a
host user's group: it reaches that one volume rather than everything that group owns.

### Idmapped mounts — demoted to a footnote

Measured on 2026-09-19 and kept only because the failure is instructive. `X-mount.idmap=b:1000:1023:1`
works on tmpfs and Android reads through it, but **writes fail `EOVERFLOW`** because MediaProvider
writes as uid 10141, which no such map covers; **iso9660 refuses idmapping outright**
(`mount_setattr() … Invalid argument`); and for FAT it is the wrong mechanism entirely, there being
no on-disk ownership to remap. ACLs do the one job it was wanted for. Do not build on it.

## The shape this points to

**mediad stops mounting and starts following**, with owning the mount kept as the fallback for when
nothing else claims the device — which is exactly the cage kiosk, so bigtab01's own behaviour is
unchanged.

1. **Reflect with one directory mirror**, not per-volume binds: a single `--rbind` of the desktop's
   media root into `<data>/media/0/Removable`. Desktop mounts and unmounts then cross the namespace
   boundary by themselves, names match what the desktop shows, and we never hold a mount of a
   device. Measured against real udisks2, in both directions.
2. **Grant traverse on the media root with an ACL** — `setfacl -m g:1023:x /run/media/$USER` — and
   re-apply it whenever udisks2 creates a new one. Without this nothing else in this list matters,
   because `other::---` stops MediaProvider at the door. It is `/run`, so nothing persists.
3. **Discover the media root** from udisks2's `MountPoints` or from `mountinfo`. Never hardcode
   `/run/media/$USER` — Ubuntu uses `/media/$USER`.
4. **Handle permissions by filesystem class, because they are not alike:**
   - *ext4, btrfs, xfs* — `setfacl -R -m g:1023:rwX -m d:g:1023:rwX` on the volume. Android reads
     and writes, it survives remount, and no idmapping is involved. Costs persistent metadata on
     someone's volume and leaves Android-written files owned by uid 10141.
   - *FAT, exFAT, ISO9660, UDF* — mount options are the only lever, a caller cannot supply them,
     and a server-side `/etc/udisks2/mount_options.conf` carrying `gid=1023,dmask=0007,fmask=0007`
     **is measured to give Android full read/write/delete**. It is a host-wide policy change
     applying to every udisks2 caller, and it needs a `udisks2` restart to take effect, which is
     the honest cost. Without it these volumes are **read-only** in Android, which also works.
     iso9660/udf additionally need `mode`/`dmode` widened from udisks2's owner-only defaults, by
     the same file; that half is untested.
   - *Never idmapping.*
5. **Route Android's Eject through udisks2** `Filesystem.Unmount` rather than `umount(8)` — the
   daemon is root, so no polkit question arises, and the desktop's notifier stays coherent.
6. **Decide the situation rather than being told it**: whether anything else mounts removable
   devices here is answerable by watching whether a device that appears gets mounted by someone
   else within a short window, with `--mode=follow|own|auto` to override the guess.

**Deliberately not chosen: a udev rule setting `UDISKS_IGNORE=1`.** It would hide removable devices
from GNOME and KDE entirely and hand us sole control, which is the opposite of the requirement. It
stays documented only as a kiosk escape hatch.

## Still open

- **iso9660/udf defaults via `mount_options.conf` are untested** — the vfat case is measured, but
  the optical case needs `mode`/`dmode` widened and nothing verified that udisks2 accepts them
  there. Testing it needs the isohybrid stick free, which means stopping `waydroid-mediad` first.
- **Which key in `mount_options.conf` is load-bearing** — `vfat_defaults` or `vfat_allow` — and
  whether udisks2 re-reads the file without a service restart.
- **Whether udisks2 reuses a media root we pre-created.** The mirror needs the directory to exist
  at bind time; udisks2 normally creates it itself, `drwxr-x---+` with an ACL. What it does when it
  finds ours, and whether it rewrites the mode, is unmeasured.
- **What a desktop's UI does with two mount points.** udisks2 itself did not balk — its own unmount
  succeeded and propagation cleared our copy — but what gvfs and Solid *display*, and whether an
  eject of a volume **we** mounted prompts for `filesystem-unmount-others`, needs a real GNOME or
  KDE session.
- **Which user's media root to mirror** when the Waydroid session user is not the desktop user, and
  what to do with two logged-in users.
- **MTP is unchanged by any of this** — docs/46's `allow_other` objection to gvfs holds regardless
  of which desktop is running.

## Reproducing

```bash
# --- the permission model, with plain directories standing in for mounts ---
D=<data>/media/0/Removable
sudo install -d -o 1000 -g 1000 -m 0755 $D/ZZ_desktop_world      # udisks vfat/exfat shape
sudo install -d -o 1000 -g 1000 -m 0500 $D/ZZ_desktop_owner      # udisks iso9660 shape
sudo install -d -o 1023 -g 1023 -m 0770 $D/ZZ_ours               # ours today
sudo nsenter -t <container-init-pid> -m -p -S 2000 -G 2000 \
     /system/bin/cat /storage/emulated/0/Removable/ZZ_desktop_world/hello.txt

# --- the mirror, against real udisks2 ---
sudo mount --rbind /run/media <data>/media/0/ZZ_mirror        # before any volume exists
sudo truncate -s 64M /var/tmp/zz-vfat.img && sudo mkfs.vfat -n ZZVFAT /var/tmp/zz-vfat.img
sudo udisksctl loop-setup -f /var/tmp/zz-vfat.img --no-user-interaction
sudo udisksctl mount -b /dev/loopN --no-user-interaction     # lands in /run/media/root/ZZVFAT
sudo grep ZZVFAT /proc/<container-init-pid>/mountinfo        # already inside the container
sudo setfacl -m g:1023:x /run/media/root                     # without this: Permission denied
sudo nsenter -t <container-init-pid> -m -p -S 2000 -G 2000 \
     /system/bin/cat /storage/emulated/0/ZZ_mirror/root/ZZVFAT/hello.txt
sudo udisksctl unmount -b /dev/loopN --no-user-interaction   # propagates out of the container

# --- ACLs on a filesystem that has them ---
sudo mkfs.ext4 -q -L ZZEXT4 /var/tmp/zz-ext4.img             # loop-setup + mount as above
sudo setfacl -R -m g:1023:rwX -m d:g:1023:rwX /run/media/root/ZZEXT4
sudo nsenter -t <container-init-pid> -m -p -S 2000 -G 2000 \
     /system/bin/sh -c "echo x > /storage/emulated/0/ZZ_mirror/root/ZZEXT4/probe.txt"
```

Two tricks carry most of this. `nsenter -S 2000 -G 2000` runs a container binary as an Android uid
without needing a debuggable app, which is what separates a file-mode failure from
MediaProvider's app-permission gate. And a **loopback image through `udisksctl loop-setup`** is a
real udisks2 mount — same code path, same state file, same mount-point creation — so the desktop
half can be tested with no hardware attached and nothing of the owner's touched.
