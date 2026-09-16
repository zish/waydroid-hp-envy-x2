# Removable media — letting Android see USB, SD, MTP and network volumes

**Status: scoped 2026-09-15 at the owner's request, nothing built.** Goal 6, which stays below
goal 5 (audio). `bin/removable-probe.sh` was run unprivileged on the host the same day with a
MicroSD card and a USB stick both plugged in, so the host-side claims below are now **measured**;
the Android-side ones still need the root pass and stay marked (unverified).

The starting question was "does cage give access to gvfs?". It does, and that turns out not to
matter, because gvfs is the wrong layer for two independent reasons.

## What the probe measured

Both devices were attached throughout. Nothing had mounted them, and `/run/media/jmelanso` **did not
exist at all** — the "nothing automounts under cage" claim below, confirmed on the machine rather
than argued from the package list. gvfs 1.60.2 *is* installed, which is what makes that result the
interesting one: gvfs being present changes nothing, because no shell ever asks it to mount.

| | Measured |
|---|---|
| udisks2 | 2.11.2, `udisksd` running, one name on the system bus |
| gvfs | 1.60.2 installed; `gvfs-mtp`, `gvfs-gphoto2`, `simple-mtpfs`, `jmtpfs` all **absent** |
| `/run/media/jmelanso` | **does not exist**; zero mounts under it with two devices attached |
| SD reader | **native SDHCI** — `mmcblk0`, `mmc` transport, `mmc0` host, 29.1 GB, vfat, unmounted |
| USB stick | `sdb`, 7.2 GB, **iso9660** — an isohybrid image (2.2 G iso9660 + 12.9 M vfat + 300 K), unmounted |
| Optical | no `/dev/sr*`; no internal drive, none attached |
| Propagation | `/run` **shared**, `/` **shared** — Plan A's first precondition holds |
| LXC include order | `config_nodes` line 14, `config_session` line 15 — **`config_nodes` is first**, which breaks Plan A as written |
| `/data` bind | `lxc.mount.entry = /home/jmelanso/.local/share/waydroid/data data none rbind 0 0` — `rbind`, no propagation flag |
| `default.target` | active for uid 1000 |
| Sessions | 3 — an ssh session (no seat), the user manager (class `manager`, no seat), and session 99 on **seat0**, tty4 |
| polkit `filesystem-mount` | `implicit active: yes`, `implicit inactive: auth_admin`, `implicit any: auth_admin` |
| vfat label here | `/boot/efi` is `system_u:object_r:dosfs_t:s0` |
| ~~**`waydroid_t` → removable labels**~~ | ~~every probe denied~~ — **superseded: wrong source domain**, see the second root pass below |

The root pass followed the same day and corrected two predictions this note had made:

| | Measured | |
|---|---|---|
| `persist.sys.fuse` | **`true`** — SDK 33, Android 13; `/storage/emulated` is `/dev/fuse`, `allow_other` | **prediction was wrong** |
| `vold` | **running**, pid 31, full emulated-storage stack | **prediction was wrong** |
| File managers | `com.android.documentsui`, `com.amaze.filemanager`, `com.google.android.apps.nbu.files` | half 4 unblocked |
| `/sdcard` | symlink → `/storage/self/primary` |  |
| `/data/media/0` | `drwxrws--- media_rw media_rw` — mode 0770, setgid, **not world-readable** |  |
| Per-app storage mounts | `/mnt/user/0/emulated`, `/mnt/installer/0/emulated`, `/mnt/androidwritable/0/emulated` | new risk, see half 3 |
| `/mnt/pass_through/0/emulated` | btrfs, `subvol=/home` — **Android's own vold**, not a Waydroid feature (`grep pass_through` over `/usr/lib/waydroid` is empty) |  |
| `config_nodes` | 23 entries, **no block devices at all** |  |
| `config_session` | 4 entries: a `/run/xdg` tmpfs, the wayland socket, the pulse socket, and the `/data` rbind |  |

Four of these changed the design. The include order kills Plan A in the form it was written; the
SELinux result promotes "expect a denial" to a confirmed hard blocker; FUSE being on both revives the
late-submount question and introduces the per-app mount-namespace risk; and vold running means the
"no volume management" dismissal had to be re-argued on cost rather than absence.

## gvfs is ruled out, twice

**Cage is not the obstacle.** gvfs is a set of D-Bus *session*-activated daemons. The session bus
at `/run/user/1000/bus` exists because logind created the user session, not because of the
compositor, so `gvfs-udisks2-volume-monitor` would activate on demand under cage exactly as under
sway. There is no compositor-shaped problem here.

The two real reasons:

1. **gvfs does not automount.** Automounting is *desktop shell* policy — GNOME Shell's
   `AutomountManager`, Nautilus, or `udiskie`. A cage kiosk runs none of them, and
   [25-waydroid-in-cage.md](25-waydroid-in-cage.md) already records that `graphical-session.target`
   never starts under cage at all. Insert a stick today and `/run/media/jmelanso` stays empty no
   matter what gvfs is installed. Whatever we build has to **mount**, not merely observe.

2. **gvfs mounts cannot cross into the container.** The gvfs FUSE view lives at
   `/run/user/1000/gvfs`, mounted without `allow_other`, which makes it unreadable by any other uid
   — *including root* — and therefore unreadable from another mount namespace. Bind-mounting it into
   Waydroid yields an empty directory or `EACCES`. This is a property of FUSE, not a permissions
   detail to be worked around.

**The right layer for block devices is udisks2, on the system bus.** `/run/media/$USER` is udisks2's
own convention; gvfs-udisks2 is just one of its callers. udisks2 is a system service, so it is
independent of compositor, session type and `graphical-session.target`. The events are
`org.freedesktop.UDisks2`'s ObjectManager `InterfacesAdded` and `PropertiesChanged` on
`Filesystem.MountPoints`; the action is `Filesystem.Mount()`.

gvfs survives in scope for exactly one thing — MTP — and even there it is the wrong tool for the
same `allow_other` reason. See the device-class table.

## The problem is four independent halves

Only one of them is hard, and it is not the one the goal text implies.

| | Half | Risk |
|---|---|---|
| 1 | Host: detect insertion and mount it | Low — udisks2, one polkit question |
| 2 | **Get the mount across the LXC namespace boundary** | **High — this decides the design** |
| 3 | Make a path browsable by Android's storage framework | Medium — SELinux and uid, both with repo precedent |
| 4 | Notification and tap-to-open | Low, but gated on a file manager existing in the image |

AGENTS.md's "exposing the user's `/run/media/<username>` directory is probably sufficient" is half 2
and half 3 compressed into one clause, and it is where the work actually is.

## Half 1 — the host side

A watcher on the system bus, matching udisks2's ObjectManager signals, calling `Filesystem.Mount()`
on anything that appears with a filesystem and no mount point.

**The obvious plan was `systemd --user`, and the probe killed it.** The reasoning was that
`org.freedesktop.udisks2.filesystem-mount` is `implicit active: yes`, a cage login is an active
seat-local session, and `default.target` is reached under cage — all three of which the probe
confirms. The flaw is in the last step: **a `systemd --user` service is not in a login session at
all.** It lives under `user@1000.service`, `sd_pid_get_session()` on it fails, and polkit therefore
falls through to `implicit any: auth_admin`. The probe shows this directly — the user manager is
listed as its own session of class `manager` with **no seat**, distinct from the seated session 99
on seat0. A watcher there would be prompted for an admin password on every insertion, on a kiosk
with nobody to type one.

**So drop udisks2 as the mount mechanism and keep it only as the event source.** The watcher becomes
a *system* unit at root that matches udisks2's ObjectManager signals and then calls plain `mount(8)`
itself. This is better than a polkit rule on three counts, and the probe's other findings are what
make it so:

- **We need custom mount options anyway.** Half 3 requires `-o context=…` for SELinux and
  `gid=1023,dmask=0007,fmask=0007` for the uid problem. udisks2 filters mount options against an
  allowlist and would need `/etc/udisks2/mount_options.conf` edited to pass them; mounting ourselves
  needs no such hook.
- **Root is required regardless**, because half 2's `nsenter` bind needs `CAP_SYS_ADMIN`. Splitting
  the work across a user-session half and a privileged half buys nothing.
- **The mount point stops mattering.** `/run/media/jmelanso` is udisks2's convention for a *caller*;
  mounting ourselves we pick the path, and AGENTS.md's goal text already says "or something
  similar". `/run/waydroid-media/<label>` is the honest name, and it avoids colliding with a real
  desktop session's mounts if the machine is ever booted into sway instead of cage.

That does put the daemon back in `unconfined_service_t`, which is exactly the trap
[35-wifi-stage5.md](35-wifi-stage5.md) lost a day to. It does not bite here for the same reason: that
failure was about `binder { transfer }` from `container_runtime_t`, and this daemon passes no binder
— it mounts, and it shells out to `waydroid shell`. Worth re-reading that note before writing the
unit anyway, and `SELinuxContext=` is the remedy if anything does surface.

## Half 2 — the namespace boundary, and why it decides everything

**The timing is the whole problem.** udisks2 mounts the stick in the host's root mount namespace
*after* `lxc-start` has already run. `rbind` is a point-in-time snapshot of a submount tree, so
`config_session`'s `~/.local/share/waydroid/data` → `/data` bind will never see a mount that appears
later. Per-device bind mounts under the host's data directory are therefore useless unless the
session restarts, which is not a thing to do on device insertion.

That leaves two approaches.

### Plan A — one static entry with slave propagation

[44-audio-alsa-backend.md](44-audio-alsa-backend.md) already established the mechanics and they are
reusable verbatim: `set_lxc_config()` — which writes `config` and `config_nodes` — is called **only**
from `initializer.py`, i.e. `waydroid init`. Container start regenerates only `config_session`. So a
hand-added entry in `/var/lib/waydroid/lxc/waydroid/config_nodes` persists until the next
`waydroid init` or image upgrade, which is how `lxc.net.0.name = wlan0` survived the 2026-09-10
reboot.

```
lxc.mount.entry = /run/media/jmelanso data/media/0/Removable none bind,create=dir,rslave,optional 0 0
```

For later host mounts to appear inside, **three things must all hold**:

- the host's `/run` is in a shared peer group — **measured: `/run` is `shared` and `/` is `shared`.**
  This one holds;
- LXC honours the propagation flag on the entry and does not subsequently rec-slave or rec-private
  the tree in a way that severs the peer group (still unverified);
- Waydroid's rootfs mount options do not force private propagation (still unverified).

**And there is a fourth sharp edge, independent of propagation: ordering — which the probe confirms
is a real problem, not a hypothetical one.** `data/media/0/Removable` is a path inside `/data`, which
is itself bind-mounted by `config_session`. LXC processes entries in file order, and the config reads:

```
14:lxc.include = /var/lib/waydroid/lxc/waydroid/config_nodes
15:lxc.include = /var/lib/waydroid/lxc/waydroid/config_session
```

`config_nodes` is **first**. An entry there targeting `data/media/0/Removable` with `create=dir` would
create the directory in the *image's* `/data` and `config_session`'s `rbind` would then cover it. The
mount would land somewhere permanently invisible, and — worse — it would look like a propagation
failure, sending the investigation to the wrong half.

**The fix is to put the entry in `config` itself, after line 15**, not in `config_nodes`. Includes
are expanded in place, so anything below line 15 is processed after `/data` is bound. `config` is
written only by `waydroid init`, the same as `config_nodes`, and the hand-edited
`lxc.net.0.name = wlan0` from [34-wifi-second-radio.md](34-wifi-second-radio.md) living there and
surviving the 2026-09-10 reboot is the proof that an edit sticks.

Note also that `config_session`'s data entry carries **no propagation flag**:

```
lxc.mount.entry = /home/jmelanso/.local/share/waydroid/data data none rbind 0 0
```

so `/data` itself is a plain `rbind` snapshot. Our entry has to set its own propagation; it inherits
nothing useful.

### Plan B — the host daemon enters the container's mount namespace

```
nsenter -t <container init pid> -m -- mount --bind /run/media/jmelanso/LABEL /data/media/0/Removable/LABEL
```

**This is probably the better primary, not the fallback**, and it is worth being explicit about why,
because Plan A looks cheaper and is not:

- no `config_nodes` edit, so it survives `waydroid init` and image upgrades — Plan A does not;
- no dependency on mount propagation at all, which deletes the highest-risk unknown;
- no include-ordering problem, because the bind happens after boot when `/data` is already in place;
- per-device control, and unmount is symmetric — `umount` in the same namespace on removal;
- the container is a privileged LXC with no idmap, so host root is root in that namespace and
  `CAP_SYS_ADMIN` is available. (unverified, but "no idmap" is established in
  [44](44-audio-alsa-backend.md).)

The cost is that it needs a root-side daemon rather than a config line. The repo already does this
everywhere — [14-sensors.md](14-sensors.md), `waydroid-wifid` — so it is a familiar shape rather than
new machinery. The split would be a `systemd --user` half that owns the udisks2 conversation (for the
polkit seat) and a tiny privileged half that does the bind, or one system unit plus a polkit rule.

**Plan A is still worth the 60 seconds it costs to test**, because if propagation simply works then
the static entry handles every future device with no daemon in the mount path at all. The decisive
experiment is at the end of this note.

## Half 3 — making Android see it

**DocumentsUI browses `DocumentsProvider` roots, not filesystem paths**, so Android is not going to
discover a mount by itself.

An earlier draft of this note said flatly that there is no vold here. **That was wrong — `vold` is
running** (pid 31), with a complete emulated-storage stack behind it. What it does not have is
anything to discover: `config_nodes` binds no block devices at all (23 entries, all character
devices, tmpfs and `/sys/kernel/debug`), and `NETLINK_KOBJECT_UEVENT` is scoped to a network
namespace, which the container has its own of — so vold sees no `sd*`, no `mmcblk*`, and no uevents
announcing them. The conclusion survives, but for a reason worth stating correctly, because it also
says what *would* have to change for the proper Android route to become available.

The move that makes the owner's "no file I/O through the helper app" constraint satisfiable is to
land the mount **under primary external storage**: `/data/media/0/Removable/<label>`, which is
`/sdcard/Removable/<label>` inside Android. `ExternalStorageProvider` already indexes primary
external storage, so DocumentsUI browses it for free and the helper app never touches a byte. The
alternative — a `DocumentsProvider` in the helper app — is the textbook Android answer and gives a
proper separate volume, but it proxies every read and write, which is exactly what was ruled out.

Three things stand between that path and a working browse, two of them with direct repo precedent.

**FUSE, and it is on.** `persist.sys.fuse=true`, and `/storage/emulated` is a real `/dev/fuse`
mount with `allow_other`, layered over `/data/media/0` by MediaProvider. So the question this note
originally deferred is live: does the daemon traverse a submount that appears under its lower
directory after it started? Probably yes — it stats the lower directory on demand, and
`ExternalStorageProvider` enumerates with `File.listFiles()` rather than from MediaProvider's index,
so browsing should work even though the media database knows nothing about the files.

**And FUSE being on drags in a second problem that is probably worse: per-app mount namespaces.**
The mount table shows `/mnt/user/0/emulated`, `/mnt/installer/0/emulated` and
`/mnt/androidwritable/0/emulated` as three separate FUSE mounts of the same storage. That is Android
13's storage-mode machinery, and it exists *because* apps run in their own mount namespaces
depending on their `MOUNT_EXTERNAL_*` mode. A bind made with `nsenter -m` into the container's **init**
namespace therefore may not be visible to an app that zygote already forked. This is the sharpest
remaining unknown in the whole design and it cuts against Plan B specifically:

- it may force the bind to be made on the **host** side of the `/data` rbind instead, where it is
  underneath everything — except `config_session`'s entry is a plain `rbind` with no propagation
  flag, so a late submount there does not cross either;
- or it may force the mount to exist **before** zygote starts, which means container-start ordering
  and a static path rather than per-device mounts;
- or per-app namespaces may share the relevant subtree, in which case none of this matters.

Measure before choosing. `readlink /proc/1/ns/mnt` against a running app's is the whole test.

**SELinux, and a correction worth recording.** It is tempting to reason in Android's labels and
conclude the mount needs `media_rw_data_file`. That is wrong here: host and container share one
kernel and therefore **one loaded policy, Fedora's**. Android's policy is not loaded, which is why
[40-binder-nice.md](40-binder-nice.md) and [42-backlight-selinux.md](42-backlight-selinux.md) talk
about `waydroid_t` — a Fedora refpolicy type — rather than about `untrusted_app`. `media_rw_data_file`
does not exist in this kernel's policy at all.

The real question is whether `waydroid_t` may read whatever label the mounted filesystem carries,
and **this is now measured rather than expected**. vfat has no xattrs, so the whole mount takes a
single genfscon-derived type; `/boot/efi` on this host is `system_u:object_r:dosfs_t:s0`, which is
what any vfat stick or SD card will get. Asking the kernel directly:

| `waydroid_t` → | class | perm | |
|---|---|---|---|
| `dosfs_t` | dir | search | **DENY** |
| `dosfs_t` | dir | read | **DENY** |
| `dosfs_t` | file | read | **DENY** |
| `dosfs_t` | file | write | **DENY** |
| `iso9660_t` | dir | search | **DENY** |
| `iso9660_t` | file | read | **DENY** |
| `removable_device_t` | blk_file | read | **DENY** |
| `fusefs_t` | dir | search | **DENY** |

**Everything is denied.** This is not a risk to keep an eye on; it is a hard blocker that has to be
solved before any of the rest can be tested, and it would have presented as "the bind mount is
empty" — indistinguishable from a propagation failure. Solve it first, or half 2's experiment cannot
be read.

`fusefs_t dir search` being denied led to a prediction that **this image has
`persist.sys.fuse=false`**, since Android works today and would not if `/sdcard` were a FUSE mount
`waydroid_t` could not enter. **The root pass falsified that flatly: `persist.sys.fuse` is `true`**,
and `/storage/emulated` really is `/dev/fuse`, mounted `allow_other`, on SDK 33 / Android 13.

So the contradiction is real and unresolved: `waydroid_t` is denied `fusefs_t dir search`, and
`waydroid_t` processes are reading a FUSE mount right now. Only two things can explain it — the FUSE
mount does not carry `fusefs_t`, or container processes are not `waydroid_t` after all — and the
first is far likelier, because [40](40-binder-nice.md) and [42](42-backlight-selinux.md) establish
the second. **Do not design around this until the label is measured** (`ls -Zd` from inside the
container). It matters directly: whatever label the FUSE mount carries is the one the removable bind
has to be reachable *through*, and it may make `waydroid_media_t` unnecessary or insufficient.

Two ways out, and the probe changes which is better:

- **a private type plus `-o context=`** — define `waydroid_media_t` in a CIL module, allow
  `waydroid_t` on it, and mount every removable volume with
  `-o context=u:object_r:waydroid_media_t:s0`. `context=` works precisely on filesystems without
  xattr support, which is all of vfat, exfat, iso9660 and UDF;
- **a CIL module granting `waydroid_t` access to `dosfs_t` and `iso9660_t` directly** — fewer moving
  parts, but it hands the container every vfat filesystem on the machine, `/boot/efi` included.

**The private type is the right answer**, and it is [42-backlight-selinux.md](42-backlight-selinux.md)'s
shape exactly: a private type on the one object rather than a broad grant on a shared one, written in
CIL so it needs no `selinux-policy-devel` and no reboot. It also composes with half 1's decision to
mount by hand — `context=` is not in udisks2's option allowlist, so this only works *because* we
stopped asking udisks2 to mount.

**The denials are silent in the usual way.** This is the fourth time — [35](35-wifi-stage5.md),
[40](40-binder-nice.md), [42](42-backlight-selinux.md) — and the method that worked is the one from
[42](42-backlight-selinux.md): ask the kernel with `selinux.selinux_check_access()` rather than wait
for an audit record. One trap of its own, hit while writing the probe: the Python binding takes
**four** arguments, not five — there is no audit-data parameter — and passing five raises a
`TypeError` that a loose `except` will happily report as though it were the answer.

**uid/gid, with no idmap.** Host uid 1000 (`jmelanso`) *is* Android uid 1000 (`system`), and udisks2
mounts vfat with `uid=<caller>,gid=<caller>`. An ordinary app running as `u0_a###` owns nothing.
Reads probably still work — vfat's default masks give world-readable directories — but writes will
not. The tidy fix is to mount with `gid=1023,dmask=0007,fmask=0007`: Android's `media_rw` group is
gid 1023, and with no idmap that is host gid 1023, which is almost certainly unassigned on Fedora and
can simply be created. Same `mount_options.conf` hook. Filesystems that *do* carry real uids (ext4)
are a separate and messier case, since the stick's uids are arbitrary — note it and defer.

This is the same class of trap as the camera: [44](44-audio-alsa-backend.md) records that
`/dev/video0` being world-accessible is the only reason the camera HAL can open it, and that
`/dev/snd/*` not being world-accessible is why audio will need a udev rule. Removable media is that
question a third time.

## 2026-09-15, second root pass: a premise error, a confirmed blocker, and a better plan

Three measurements landed together and between them they invalidate part of half 2 and most of
half 3. Recorded here rather than edited into place, because the wrong reasoning is instructive.

### The SELinux analysis asked the wrong question

Half 3's denial table is measured correctly and means nothing, because **`waydroid_t` is not the
domain Android runs in.** It is the domain of the *host* daemon that `container_manager.py` spawns —
that is what [14](14-sensors.md), [40](40-binder-nice.md) and [42](42-backlight-selinux.md) are all
about, and the habit of reaching for it here was a straight confusion of two different things.

The container's own config settles it: there is **no `lxc.selinux.context`** line, so the container
inherits the domain of `waydroid-container.service`, and the labels bear that out —
`/storage/self/primary` is **`container_runtime_tmpfs_t`**, which is a container type, not a
`waydroid_*` one. The storage stack labels are:

| Path | Label |
|---|---|
| `/data/media/0` | `data_home_t` |
| `/mnt/pass_through/0/emulated` | `data_home_t` |
| `/storage/emulated/0` | **`fusefs_t`** |
| `/storage/self/primary` | `container_runtime_tmpfs_t` |

`/storage/emulated/0` being `fusefs_t` while apps read it happily is the resolution of the earlier
contradiction: the source domain was wrong, not the target. **Every DENY in half 3's table has to be
re-measured against the real domain** (`ps -AZ` inside the container) before any policy is written.
It may turn out there is no SELinux work here at all.

### Per-app mount namespaces: confirmed, and Plan B is dead as written

Every app is in its own mount namespace, and all of them differ from init's:

```
init(1)                    mnt:[4026532783]
zygote64 (73)              mnt:[4026532930]
system_server (298)        mnt:[4026532931]
com.android.systemui (526) mnt:[4026532932]
com.android.launcher3      mnt:[4026532933]
com.android.phone          mnt:[4026532934]
```

So `nsenter -t <init> -m -- mount --bind …` puts the mount somewhere **no app can see**. That is the
risk flagged above, confirmed rather than feared.

### Why that does not matter, and what to do instead

Apps do not reach storage through a mount they can see. They reach it through **FUSE**, and FUSE
serves *content*, which crosses namespaces freely. The chain is:

```
app  →  /storage/emulated/0   (fusefs_t, /dev/fuse, allow_other)
     →  MediaProvider's FuseDaemon
     →  /mnt/pass_through/0/emulated   (data_home_t, btrfs)
     =  /home/jmelanso/.local/share/waydroid/data/media/0   ON THE HOST
```

The lower directory **is the host's own filesystem**, reached through `config_session`'s
`/data` rbind. So the mount never has to be visible to an app at all — it only has to be visible to
the FUSE daemon, and the simplest way to achieve that is to put it where the daemon is already
looking.

**Plan C, and it is better than A and B both:** mount the removable device on the host directly at

```
/home/jmelanso/.local/share/waydroid/data/media/0/Removable/<label>
```

and let it propagate through the existing `/data` rbind. This needs **no LXC config edit** (so
nothing to survive `waydroid init`), **no `nsenter`**, **no container restart** — and therefore
never drops the kiosk session to the greeter, which both earlier plans did. It also makes the path
inside Android fall out for free: `/sdcard/Removable/<label>`, exactly what half 3 wanted, indexed by
`ExternalStorageProvider` with no helper-app I/O.

Preconditions, two of three already measured:

- the host mount must propagate into the container — `/var/home` is **shared** and the LXC config
  sets no `lxc.rootfs.options` and no propagation flags, so this is plausible and is the one live
  test left;
- `/data/media/0` is `drwxrws--- media_rw media_rw`, i.e. uid/gid **1023**, and with no idmap that is
  host gid 1023 — so the mount options want `gid=1023` and the host side needs root, since `jmelanso`
  (1000) gets `Permission denied` on that directory today;
- the label question above, re-measured against the real domain.

**The live test is non-destructive and needs no restart**, which is what makes Plan C testable in a
way A and B never were: mount a tmpfs at that path on the host, look for it in the container's
`/proc/mounts`, then read it from `/storage/emulated/0/Removable`, then unmount.

## Half 4 — notification and tap-to-open

**Transport: host watcher pushes in.** On mount, the host side runs

```
waydroid shell -- am broadcast -a lan.syshlt.bigtab01.MEDIA_MOUNTED --es label … --es path …
```

`waydroid shell` is root inside Android, so this needs no in-guest privilege work. The receiver
should be exported with an `android:permission` so nothing else in the image can forge it. This was
chosen over a binder daemon ([14](14-sensors.md)'s pattern) because "a directory appeared" does not
justify a HAL, and over guest-side polling because a continuous poll costs CPU on a Core M and fights
Android 13's background limits.

**The notification** is an ongoing one (`setOngoing(true)`), which on Android 13 needs the
`POST_NOTIFICATIONS` runtime permission — grantable with `pm grant` at install time, the same way
`sensor-app/build.sh --install` already deploys and grants.

**The tap** is a plain intent, no I/O:

```kotlin
val uri = DocumentsContract.buildDocumentUri(
    "com.android.externalstorage.documents", "primary:Removable/$label")
Intent(Intent.ACTION_VIEW).apply {
    setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
}
```

**This half is gated on a file manager existing in the image.** Waydroid's LineageOS images normally
ship `com.android.documentsui`, but that is unverified here, and if it is absent the tap has nowhere
to land and one has to be shipped alongside the helper. It costs one `pm list packages` to find out,
so find out before designing any of the UX.

**Removal needs as much thought as insertion**: the notification has to be cancelled on unmount, and
Android must not hold the mount busy. Nothing in Android keeps the path open except while someone is
browsing it, but a live DocumentsUI may hold a descriptor, so eject is not automatically clean.

## The four device classes are not equally tractable

All of them are in scope at the owner's request. Recorded honestly rather than flattened:

| Class | Mechanism | Verdict |
|---|---|---|
| **USB mass storage** | udisks2 as event source, our own `mount` | **Tractable.** The design above is written for this case. Do it first and alone. |
| **SD / MicroSD** | Same, via `mmcblk*` | **Same as USB, and now confirmed:** the reader is **native SDHCI** (`mmcblk0`, `mmc0`), not an internal USB reader. Different udev matching, identical design. |
| **USB optical** | udisks2 handles it; `usb-storage` → `sr`, iso9660/UDF | **Mostly shared — see below.** Halves 2, 3 and 4 are unchanged, and `iso9660_t` is already forced into scope by the attached stick. Half 1 needs a two-level event model. |
| **MTP / PTP phones** | udisks2 **cannot do these at all.** gvfs-mtp could, but mounts to `/run/user/1000/gvfs` without `allow_other` — unshareable, per the top of this note. | **A different mechanism entirely**: `simple-mtpfs` or `jmtpfs` with `-o allow_other`, driven from udev. **Confirmed absent**: `gvfs-mtp`, `gvfs-gphoto2`, `simple-mtpfs` and `jmtpfs` are all uninstalled, so this costs an `rpm-ostree install` plus a reboot, or a build. Worst effort-to-benefit of the set. **Land it last and separately**, if at all. |
| **Internal optical** | — | **Out by hardware.** No `/dev/sr*`; the Envy x2 is a detachable tablet with no drive and no bay to put one in. |
| **Network shares (SMB/NFS)** | Not removable media — there is no insertion event | **Reuses halves 2 and 3 unchanged** — same bind, same intent, same SELinux and uid questions — but the notification model does not fit, because nothing arrives. Mount with systemd `.mount` units and either skip the notification or fire it on unit activation. Cheap *after* USB works; pointless before. |

### Is USB optical included in the USB/SD design?

Partly, and the split is worth being precise about, because the answer is "the filesystem yes, the
event model no".

**Already included, at no extra cost.** An external USB drive enumerates through `usb-storage` as a
SCSI `sr` device, udisks2 handles it natively, and a data disc is iso9660 or UDF. Halves 2, 3 and 4
— crossing the namespace, landing under `/sdcard`, the notification and the `ACTION_VIEW` intent —
do not change by a line. More than that, **iso9660 is already mandatory whether or not an optical
drive ever appears**: the USB stick plugged into this machine right now *is* iso9660, an isohybrid
installer image, and the SELinux table above shows `iso9660_t` denied exactly as `dosfs_t` is. The
CIL module has to cover it either way.

**Not included, and genuinely extra.** Three things:

1. **Optical has a two-level event model.** For a stick or a card, "device appeared" and "filesystem
   available" are the same event. For optical they are not: the *drive* is plugged in, possibly
   empty, and *media* arrives later and can be swapped without a replug. udisks2 models this on the
   `Drive` interface — `MediaAvailable`, `MediaChangeDetected`, the `Optical*` properties — so the
   watcher has to match `PropertiesChanged` on `org.freedesktop.UDisks2.Drive`, not only
   `InterfacesAdded` on Block/Filesystem. Small, but it is a second code path and a second set of
   states to get wrong.
2. **Some media has no mountable filesystem at all.** Audio CDs, blank discs, and packet-written UDF
   give nothing to mount, so a notification whose entire premise is "tap to open this path" has no
   path to offer. That needs a deliberate branch — suppress, or notify differently. Audio CDs are
   gvfs-cdda's job, which is ruled out for the same `allow_other` reason as MTP, so the honest scope
   is **data discs only**, with audio and blank media a documented no-op rather than a bug.
3. **Eject is a real operation here and is not, for the others.** Optical has a physical tray and
   `Drive.Eject()`, unmount must precede it, and a notification action for it would be the natural
   UX. Spin-up also means a mount call can block for seconds, so the watcher must not be synchronous
   on it — a stick never taught us that lesson because it never needed to.

**Recommendation: handle iso9660/UDF in the filesystem and SELinux work from day one** — free, and
the attached stick forces it anyway — but treat drive-versus-media events as a **small separate
increment after USB mass storage works end to end**. Worth noting one practical limit before buying
hardware for it: a bus-powered USB optical drive often draws more than a single port supplies, and
this is a detachable tablet, so a Y-cable or a powered drive may be the difference between working
and mysteriously not.

## The decisive experiment

Run this before writing any code. It settles half 2, which is the only half that can change the
design, and it needs none of the infrastructure above.

```bash
# On the host, with the container running.
findmnt -o TARGET,PROPAGATION /run /run/media          # is the source shared?

# Plan A: add the entry to config_nodes, restart the container, then --
sudo mkdir -p /run/media/jmelanso/PROPTEST
sudo mount -t tmpfs none /run/media/jmelanso/PROPTEST   # a mount made AFTER lxc-start
sudo touch /run/media/jmelanso/PROPTEST/hello
sudo waydroid shell -- ls /data/media/0/Removable/PROPTEST
```

**Read the result from `/proc/mounts`, not from `ls`.** Now that half 3's denials are measured, an
empty directory is ambiguous: it means either "the mount did not propagate" or "it propagated and
`waydroid_t` cannot enter it". Those need completely different fixes, and `ls` cannot tell them
apart. The mount table can, because reading it does not depend on the mounted filesystem's label:

```bash
sudo waydroid shell -- cat /proc/mounts | grep Removable
```

- **a line in `/proc/mounts`, and `hello` visible** → propagation works and the label is fine.
- **a line in `/proc/mounts`, but the directory reads empty or `EACCES`** → propagation works; this
  is half 3, and the CIL module is the fix.
- **no line at all** → propagation genuinely failed. Plan A is dead and the answer is Plan B's
  `nsenter` bind — which, given the include-order finding above, is where this was probably heading
  anyway.

## Open questions for the host

The unprivileged pass of `bin/removable-probe.sh` ran on 2026-09-15 and answered everything that
does not need root. **Answered** — see the measurement table at the top: udisks2 present and running,
gvfs present but irrelevant, SD reader is native SDHCI, `/run` is shared, `default.target` active,
include order is `config_nodes` then `config_session`, vfat is `dosfs_t`, and `waydroid_t` is denied
every removable label.

The root pass ran the same day and answered the rest — FUSE is on, vold runs, three file managers
are installed, `/data/media/0` is `media_rw`-owned mode 0770. Both results that mattered went against
the prediction, which is the argument for having run it before writing code rather than after.

**Still open, and each one can still change the design:**

| Question | How | Why it matters |
|---|---|---|
| **What label does the FUSE mount carry?** | `waydroid shell -- ls -Zd /storage/emulated/0 /data/media/0 /mnt/pass_through/0/emulated` | Resolves the `fusefs_t`-denied-but-working contradiction, and tells us what label the removable bind must be reachable *through*. Nothing in half 3 should be built before this |
| **Do apps share init's mount namespace?** | `waydroid shell -- sh -c 'readlink /proc/1/ns/mnt; for p in $(pidof com.android.documentsui); do readlink /proc/$p/ns/mnt; done'` | Decides whether Plan B's `nsenter` bind can reach a running app at all |
| Does vold list anything mountable? | `waydroid shell -- vdc volume list` | Confirms the block-device/uevent reasoning above rather than inferring it |
| Does a late submount cross the `/data` rbind? | the decisive experiment, read from `/proc/mounts` | The remaining half-2 unknown |

`sesearch` is not installed (`setools-console`) and layering it would cost a reboot, so
`selinux.selinux_check_access()` is the tool for policy questions here — as it was in
[42](42-backlight-selinux.md), and as it will be for confirming the CIL module afterwards.

## Built, 2026-09-15

Plan C was tested live and worked on the first attempt, so it is what shipped. The measurements that
mattered:

```
init(1)   system_u:system_r:container_runtime_t:s0     <- NOT waydroid_t
tmpfs on host  ->  /data/media/0/Removable                    (propagated, no restart)
               ->  /mnt/pass_through/0/emulated/0/Removable
/dev/mmcblk0   ->  /storage/emulated/0/Removable/SDCARD        DCIM, bbbb.html
```

**There is no SELinux work.** Android runs as `container_runtime_t`, which reads `dosfs_t` perfectly
well — the real vfat SD card was readable through FUSE immediately. Half 3's entire denial table was
measuring `waydroid_t`, which is the *host daemon's* domain and has nothing to do with the container.
The private-type-plus-`context=` design was never needed and was not built.

**Propagation works with no LXC edit and no container restart**, and FUSE carried the content past
the per-app mount namespaces exactly as the theory said it would. Neither Plan A nor Plan B was built.

### What shipped

| | |
|---|---|
| [artifacts/media/waydroid-mediad](../artifacts/media/waydroid-mediad) | root daemon: udev wake-up, reconcile, mount, broadcast |
| [artifacts/media/waydroid-mediad.service](../artifacts/media/waydroid-mediad.service) | system unit; the header records why it is not a `--user` unit |
| [artifacts/media/install.sh](../artifacts/media/install.sh) | `DESTDIR`/`PREFIX`/`UNITDIR`, per repo convention |
| [media-app/](../media-app) | "Removable Media" — notification and tap-to-open, no file I/O |
| [bin/media-test.sh](../bin/media-test.sh) | end-to-end check, naming which link is broken |

**Reconciliation, not event-diffing.** A udev block event only wakes the loop; `reconcile()` then
compares what should be mounted against what is, and fixes the difference. Startup, a missed event
and a hotplug are all the same code path, which is why `--once` and the service behave identically.

### Six bugs found while building, all worth keeping

1. **The system-disk guard was inert.** `root_disk()` asked `findmnt -o SOURCE /`, which on an
   rpm-ostree host answers `overlay` — not a block device — so it returned `None` and *no disk was
   ever protected*. The internal disk was spared only by the transport allowlist. Replaced with a
   guard derived from `lsblk`: any disk carrying a mount anywhere is off limits, children included.
   It now reports `protected=['loop0', 'loop1', 'luks-…', 'sda', 'sda1', 'sda2', 'sda3', 'zram0']`.
   A guard that silently protects nothing is worse than no guard, because it reads as safe.
2. **`/home` is a symlink to `/var/home`.** `lsblk` reports the resolved path, so every "is this
   mount one of ours?" comparison against the configured base failed. Left unfixed this would have
   made `reconcile()` unmount its own work on the very next pass. Every such test now uses
   `os.path.realpath`.
3. **An isohybrid stick carries a filesystem on the whole disk *and* in a partition.** `/dev/sdb` is
   iso9660 and so is `/dev/sdb1`; mounting the disk makes its partitions unopenable, which surfaced
   as two `Can't open blockdev` failures per insertion. When the disk itself is mountable it is the
   one to use, so its children are dropped.
4. **A freshly installed app is in the "stopped" state and receives no broadcasts.** Android has
   withheld them since 3.1, and it presents exactly like a broken receiver. The daemon sends
   `am broadcast --user 0 -f 32`, where 32 is `FLAG_INCLUDE_STOPPED_PACKAGES`.
5. **An interrupted `pm install` leaves the package FROZEN, and every symptom points elsewhere.**
   `pm install` takes minutes on this Core M; the first attempt was cut short by a command timeout,
   and what followed looked like a broadcast problem in every way that could be checked quickly:
   `am broadcast` reported `Broadcast completed: result=0` even with an explicit `-n` component,
   `dumpsys package` listed the receiver and its intent filters correctly, and nothing appeared in
   logcat. The truth was only in unfiltered logcat:

   ```
   ActivityManager: java.lang.SecurityException: Package … is currently frozen!
   AppHibernationService: Package … is not installed for user 0
   BroadcastQueue: Unable to launch app … : process is bad
   ```

   `pm list packages` showed nothing, which should have been checked first. Recovery is
   `pm uninstall` then install again. `media-app/build.sh` now checks for `Success` and fails
   loudly instead of `|| true`-ing past it — a half-install that reports success is the worst of
   both worlds.

   Two diagnostic traps rode along with it, both self-inflicted and both worth avoiding:
   `dumpsys notification … | head -N` **truncates the dump with a broken pipe** before reaching a
   late package, so absence of evidence there means nothing; and `logcat -s TAG:*` is not valid
   filter syntax — it silently matches nothing, where `logcat -d TAG:I *:S` works. Between them they
   turned a clear failure into an ambiguous one.
6. **Android 8+ does not deliver implicit broadcasts to manifest-declared receivers**, and says
   nothing about it. Measured side by side on this host, with the app healthy:

   | Broadcast | Result |
   |---|---|
   | `am broadcast -a <action>` (implicit) | `Broadcast completed: result=0`, **receiver never fires** |
   | `am broadcast -p <package> -a <action>` | fires |
   | `am broadcast -n <pkg>/<class> -a <action>` | fires |

   All three report success, which is what made this expensive: there is no error anywhere, in
   logcat or in `am`'s output. The daemon now sends `-p lan.syshlt.removablemedia`. **`-p` rather
   than `-n`** deliberately: it keeps dispatch action-based, so renaming the receiver class cannot
   silently break the host side.

### One thing that looks like a bug and is not

`dumpsys notification` shows **three** records for the package when two volumes are mounted. The
third has `tag=ranker_group`, `id=2147483647` (`Integer.MAX_VALUE`) and `flags=0x702`
(`FLAG_GROUP_SUMMARY` | `FLAG_ONGOING_EVENT`). That is Android's own `GroupHelper` auto-bundling two
ungrouped notifications from one app under a synthetic summary — LinkedIn has an identical record on
this device. Nothing in `media-app` creates it, and the per-volume ids (`label.hashCode() or 1`)
match their labels exactly: `SD_Card_4CFC8D` → `-1866659175`, `Fedora-Src-ostree-x86_64-44` →
`-475209671`.

### Mount options, and why they are what they are

`uid=1023,gid=1023` — Android's `media_rw`, and with no idmap that is host uid/gid 1023 too. It
matches `/data/media/0`, which is what lets MediaProvider's FUSE daemon read the files and serve them
on. `dmask=0007,fmask=0007` keeps them off-limits to everything else on the host.

ext4, btrfs and xfs are mounted **read-only** on purpose: they carry real on-disk ownership, have no
`uid=` option, and writing as the wrong uid is worse than not writing. vfat and exfat are read-write.
iso9660 and UDF are read-only by nature, which is the USB-optical case handled in advance.

### Hotplug, verified by hand

The owner unplugged and replugged the USB stick while the daemon ran untouched. Both directions work
with no intervention:

```
remove →  journal:  unmounted …/Removable/Fedora-Src-ostree-x86_64-44
          logcat:   I RemovableMedia: unmounted: Fedora-Src-ostree-x86_64-44
          Android:  entry gone from /storage/emulated/0/Removable, notification cancelled

insert →  journal:  mounted /dev/sdb (iso9660, ro,uid=1023,…) -> …/Removable/Fedora-Src-…
          logcat:   I RemovableMedia: mounted: … at /sdcard/Removable/… (iso9660)
          Android:  ls /storage/emulated/0/Removable/Fedora-Src-… -> EFI, LICENSE, boot, images
```

Two things worth knowing for the next person testing this:

- **Give it a couple of seconds.** The first check after each event came back empty and looked like a
  failure; the mount landed about a second later. Between the kernel enumerating the device (the
  `dmesg` trail runs from `Attached SCSI removable disk` through to `ISO 9660 Extensions`) and the
  daemon's own 0.6 s coalescing delay, an immediate query is simply too early. Read the journal, not
  a single snapshot.
- **The app is killed between events and restarted to receive each broadcast** — its pid changed
  across the remove/insert cycle. That is `FLAG_INCLUDE_STOPPED_PACKAGES` working on the removal path
  as well as on first install, which was not separately designed for.

### Ejecting

There is no channel from inside the container back out to the host — the daemon pushes events in
with `am broadcast`, but nothing pulls the other way. The Eject button on the notification therefore
works by the helper app dropping a **zero-byte marker named after the volume** into its own
app-private files directory, which on this host is plain host filesystem underneath
(`<data>/data/lan.syshlt.removablemedia/files/eject/<label>`); `waydroid-mediad` polls that directory
once a second, unmounts, and consumes the marker.

**On the app's "no file I/O" rule**: this is the only file the app ever writes. It lives in the app
sandbox, never on the removable volume, and carries no data at all — the entire message is the
filename. Two alternatives were considered and are worse: a logcat line scraped by the host is
fragile across ring-buffer wraps, and `Settings.Global` would need `WRITE_SECURE_SETTINGS` plus a
`waydroid shell` round-trip on every poll.

Polling rather than inotify because the stdlib has no inotify binding and this is an immutable host
where a dependency costs a reboot. One `scandir` a second on a directory that is almost always empty
is not worth optimising away.

Two details that took a second pass to get right:

- **An ejected volume must stay ejected.** Without a record of it, the very next reconcile — a udev
  event on any device will do — sees a still-plugged-in device with no mount and helpfully mounts it
  straight back. The daemon keeps an `ejected` set, and prunes it when the device actually goes away
  so that re-inserting the same stick works normally. Verified: after an eject, `udevadm trigger
  --action=change` left it unmounted; a service restart restored it.

  **This is intentional and matches desktop Linux, so do not "fix" it.** An ejected device that is
  still plugged in stays unmounted until it is physically removed and reinserted — the behaviour
  every GNOME/gvfs-era desktop has had for decades. It was raised here as a possible UX gap (a
  mistaken eject has no in-Android way back, short of reseating the device or restarting the
  service) and the owner confirmed it as the expected convention. A "Remount" action was considered
  and deliberately **not** built.
- **The daemon must not create the marker directory.** It runs as root, and a root-owned
  `files/eject` is unwritable by the app (uid 10210 here, no idmap). The app creates it inside its
  own sandbox; the daemon only reads and unlinks. This was found the hard way — a test that created
  the directory with `mkdir -p` as root would have silently broken every subsequent Eject press.

### The failed copy: the bundled AOSP file manager, not the mount

The owner copied a screenshot from DocumentsUI's **Images** root onto the SD card and it silently
failed. The destination is not at fault, and that was worth establishing before changing anything:

| Check | Result |
|---|---|
| Card write-protected? | no — `blockdev --getro` 0 |
| Mount read-only? | no — `rw,…,uid=1023,gid=1023,fmask=0007,dmask=0007,flush` |
| Host write | OK |
| Android write through FUSE (`touch`) | OK |
| Android write of 4 MB through FUSE | OK, and visible from the host |
| **That exact filename, with data, through FUSE** | **OK** |
| Free space | 2.7 GB of 30 GB |

What logcat actually shows is a failure inside DocumentsUI's own copy machinery, on a document from
the **legacy `MediaDocumentsProvider`**:

```
E CopyJob: … readExceptionWithFileNotFoundExceptionFromParcel
           at com.android.documentsui.services.CopyJob.copyFileHelper(CopyJob.java:580)
E FileOperationService: Job failed to process docs: [DocumentInfo{docId=image:1000000027,
   name=Screenshot_….png … } @ content://com.android.providers.media.documents/document/image%3A…]
```

A `FileNotFoundException` crossing a binder from one of `copyFileHelper`'s two `openFile` calls. The
source *is* readable — `content read` on that exact URI returns a valid PNG header — but `content
read` runs as shell (uid 2000) with far broader access than DocumentsUI has.

**A second attempt produced the complete stack trace, and it settles the question.** The exception
names the **source** document, and the failing call is `openFile` on it — the destination is not
involved at the point of failure:

```
E CopyJob: Failed to copy content://com.android.providers.media.documents/document/image%3A1000000029
E CopyJob: ResourceException: Failed to open a file for content://…/image%3A1000000029 …
           at CopyJob.copyFileHelper(CopyJob.java:587)
E CopyJob: Caused by: java.lang.NullPointerException
           at android.os.Parcel.createExceptionOrNull(Parcel.java:3039)
           at android.content.ContentProviderProxy.openFile(ContentProviderNative.java:678)
           at android.content.ContentProviderClient.openFile(ContentProviderClient.java:461)
           at CopyJob.copyFileHelper(CopyJob.java:580)
```

The `NullPointerException` inside `Parcel.createExceptionOrNull` is the signature of a remote
provider throwing something the parcel **cannot reconstruct** — DocumentsUI does not even learn what
went wrong, which is why this reads as a silent failure from the outside.

The ordering is visible in the log too: MediaProvider logs `Failed to update quota type for
/storage/emulated/0/Removable/SD_Card_…/Screenshot_….png` three times just before the failure, so
the **destination file was created** — and then rolled back when the source open threw. Those quota
warnings are benign in themselves (vfat has no project-quota support) and appear for writes that
succeed, including a plain `touch`.

Two hypotheses were tested and **disproven**, and are recorded so nobody re-runs them:

- **Stale media database.** The rows are correct: `_data` points at
  `/storage/emulated/0/Pictures/Screenshots/…` and the files exist with sizes matching the database
  exactly (2922628 and 82337 bytes). (Note `content query --projection` is **colon**-separated; a
  comma-separated list fails with `Invalid column`, which cost one round.)
- **A permissions gap on the file's owner.** The screenshots are owned by `u0_a141`, which is
  `com.android.providers.media.module` — MediaProvider itself, the very process serving the
  document. DocumentsUI holds `MANAGE_DOCUMENTS` and not `MANAGE_EXTERNAL_STORAGE`, which is normal
  for it.

**The destination's provider surface has since been checked too, and it is clean.**
`ExternalStorageProvider`'s flags for our directory are *identical* to those of a normal
internal-storage directory, except that `Download` carries one extra **restriction**:

```
primary:Removable/SD_Card_4CFC8D   flags=16716
primary:Download                   flags=49484
    both:            SUPPORTS_DELETE  DIR_SUPPORTS_CREATE  SUPPORTS_RENAME
                     SUPPORTS_MOVE    SUPPORTS_METADATA
    Download only:   DIR_BLOCKS_OPEN_DOCUMENT_TREE
```

`DIR_SUPPORTS_CREATE` is set, which is the bit DocumentsUI needs to create a file in a directory. So
the destination advertises exactly the capability required.

**That conclusion was premature and is withdrawn.** Copying from the **BigTab01** root
(`ExternalStorageProvider`, `primary:Pictures/Screenshots/…`) onto the card failed with the *same*
signature — same `NullPointerException` in `Parcel.createExceptionOrNull`, same
`ContentProviderClient.openFile` frame, same `CopyJob.java:580`. Two different source providers, one
identical failure, so the source is not the variable.

The methodological mistake is worth recording: **both tests varied the source while holding the
destination constant at the card.** The one experiment that discriminates — varying the *destination*
— had not been run.

`ExternalStorageProvider` itself is demonstrably healthy on the mount. Measured from a shell:

| Operation via `content` + ESP document URI | Result |
|---|---|
| read a file on internal storage | OK |
| read a file **on the card** | OK — returned its contents |
| **write** a file **on the card** | OK — contents replaced |

So ESP can open documents on the card for both read and write, and the filesystem beneath it accepts
everything. Whatever `CopyJob` is hitting is not a plain permission or writability problem, and the
`NullPointerException` inside `createExceptionOrNull` means DocumentsUI receives an exception *code*
it cannot even decode — the remote's real error never reaches it.

**Resolved by the owner: it is DocumentsUI.** The same copy performed in **Google Files** works.
The failing component is the old AOSP file manager bundled with this Waydroid image — its `CopyJob`
is broken here — and removable media is confirmed uninvolved. Every layer this feature owns had
already tested clean, and the working copy through a different app is the direct confirmation.

**The lesson is about the diagnosis, not the bug.** Three file managers were listed in the very
first root probe (`documentsui`, `amaze`, `nbu.files`), and trying a second one was always the
cheapest possible discriminator — it varies the *whole client stack* in one action, where each of
the provider-level experiments above varied a single layer. Instead the investigation spent several
rounds decoding parcel exceptions and provider flags, and twice varied the source while holding the
destination constant, which could not have discriminated anything. **When a failure is reported
through one application, try a second application before instrumenting the stack beneath it.**

A practical consequence worth knowing: the notification's tap opens whichever app handles
`ACTION_VIEW` for a directory, which on this image may be DocumentsUI. Browsing works there; copying
does not. Use Files or Amaze for file operations.

Superseded reasoning, kept because it was the basis of the withdrawn conclusion: Every layer this feature owns has been shown good — the filesystem is
writable, FUSE writes succeed including the exact filename with real data, and the provider
advertises `DIR_SUPPORTS_CREATE` and serves reads and writes on the mount. That all remains true;
what it does not establish is that the destination is uninvolved.

One correction to the report: the failure was **not silent**. DocumentsUI posted its own
`Couldn't copy 1 item` notification — it is still in `dumpsys notification` — it was simply missed
among the others.

Noted in passing: `dmesg` reports `FAT-fs (mmcblk0): Volume was not properly unmounted. Some data may
be corrupt. Please run fsck.` on every mount. That predates this work — the card arrived with a dirty
FAT — but it is a good argument for the Eject button existing, and the card is worth an `fsck.vfat`.

### Still open
- **The notification tap is unverified end to end.** The notification itself is confirmed posted,
  ongoing, with the right title and path and a live `contentIntent`
  (`PendingIntentRecord{… startActivity}`); what nobody has done is tap it and watch DocumentsUI
  open `content://com.android.externalstorage.documents/document/primary%3ARemovable%2F<label>`.
- **Unmount while Android is browsing** falls back to a lazy unmount. Whether DocumentsUI holds a
  descriptor long enough to matter is untested.
- **`forget()`-style cleanup**: if the daemon is SIGKILLed rather than stopped, mounts survive and
  are re-adopted on next start, which is correct — but a stale notification in Android is not
  cleared until the next event.
- Packaging: no RPM yet; `artifacts/media/install.sh` is `DESTDIR`-clean so the spec is mechanical.

## Ruled out, and why

- **gvfs as the mechanism** — does not automount without a desktop shell, and its FUSE view is
  unshareable across uid and namespace. Both reasons are independent and either alone is fatal.
- **Handing the block device to the container** — the [second-radio](34-wifi-second-radio.md) move
  does not transfer, though not for the reason first written here. vold *is* running and does manage
  public volumes in AOSP; what is missing is the block device nodes (`config_nodes` binds none) and
  the uevents to announce them (netlink is network-namespace scoped, and the container has its own).
  Supplying both is a much larger change than the `/sdcard` route, and unlike a spare Wi-Fi dongle
  the host wants to keep reading the stick too. Ruled out on cost, not on impossibility.
- **A `DocumentsProvider` in the helper app** — correct Android design, gives a real separate volume,
  and violates the owner's explicit "no file I/O through the helper app" constraint while duplicating
  what `ExternalStorageProvider` already does for free on the `/sdcard` path.
- **Guest-side polling for insertion** — continuous CPU cost on a Core M and Android 13 background
  limits, to replace one host-side D-Bus match.
- **Reasoning in Android's SELinux labels** — only Fedora's policy is loaded. See half 3.
