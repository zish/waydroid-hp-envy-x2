# One package per modification

*2026-09-16.*

[docs/36](36-packaging.md) packaged this project as four source RPMs producing twelve binary
packages. That was the right first step — it answered "what is installed and what version is
it?" — but it does not survive the next question, which the owner asked directly:

> if I get an update upstream that breaks one of the mods, I don't want to have to release
> every single change just for the one fix.

Four source packages cannot do that. Every subpackage in a spec shares one `Version-Release`,
so a three-byte fix to the camera wrapper reissues Widevine, the battery HAL and the Wi-Fi
feature XML along with it. Whether that *harms* anything is debatable; what is not debatable
is that it makes the changelog useless and forces a rebuild of payload nobody touched.

So the unit of release becomes the modification, not the subsystem. This note is the design.

## The question that had to be answered first

**Do we need to keep backups of the files we replace in the overlay?**

**No — because it really is an overlay.** Read off the live host on 2026-09-16:

```
overlay /var/lib/waydroid/rootfs overlay ro,relatime,
    lowerdir=/var/lib/waydroid/overlay:/var/lib/waydroid/rootfs,
    upperdir=/var/lib/waydroid/overlay_rw/system,
    workdir=/var/lib/waydroid/overlay_work/system

overlay /var/lib/waydroid/rootfs/vendor overlay ro,relatime,
    lowerdir=/var/lib/waydroid/overlay/vendor:/var/lib/waydroid/rootfs/vendor,
    upperdir=/var/lib/waydroid/overlay_rw/vendor,
    workdir=/var/lib/waydroid/overlay_work/vendor
```

`/var/lib/waydroid/overlay` is the **first** lowerdir, stacked over the loop-mounted ext4
image, which is mounted `ro` and is never written. Our files shadow the image's; the image's
bytes are untouched. Delete an overlay file, restart the container, and the stock file is
back. That is the whole restore procedure, and it is why `waydroid-overlay-sync` can remove a
component's files with no backup step and no risk.

Three caveats that follow from the same mount line, and are worth having written down:

- **`upperdir` outranks us.** `/var/lib/waydroid/overlay_rw/{system,vendor}` sits *above* our
  lowerdir, so anything there masks our payload — silently, exactly like the mounted-lowerdir
  trap in [docs/32](32-wifi-stage3.md). Checked on 2026-09-16: `overlay_rw` holds **zero
  files**, so this is theoretical today. `--verify` should learn to look.
- **We can add and replace; we do not delete.** Removing a stock file through a lowerdir needs
  a `mknod c 0 0` whiteout, which nothing here does and nothing here has needed.
- **Not everything we change is in the overlay**, and the things that are not *do* need their
  originals kept. That list is the next section.

### What is not an overlay, and therefore is a real edit

| What | Where | Owner | Original kept? |
|---|---|---|---|
| `lxc.net.0.name = wlan0` | `/var/lib/waydroid/lxc/waydroid/config` | Waydroid, regenerated | no — and `waydroid upgrade` erases the edit ([docs/34](34-wifi-second-radio.md)) |
| dexopt properties | `/var/lib/waydroid/waydroid_base.prop` | Waydroid, regenerated | yes — `install.sh` writes `.pre-dexopt` |
| mDNS reflector | `/etc/avahi/avahi-daemon.conf` | the `avahi` package | repo copy only ([artifacts/mdns](../artifacts/mdns)) |
| mDNS source-port rule | firewalld `public.xml` | firewalld | repo copy only |
| `use_compaction=true` | Android `device_config`, in `/data` | Android | n/a — lost every restart ([docs/43](43-app-freezer.md)) |

These are in-place modifications of files that belong to somebody else, and they are the
only places in this project where "what did it look like before?" is a question with no
cheap answer. Every one of them needs the same treatment: an **idempotent reconciler** that
merges rather than overwrites, keeps a `.pre-waydroid-ext` copy the first time it changes
anything, and can be re-run forever. `artifacts/dexopt/install.sh` already does exactly this
and is the pattern to copy — including the detail that matters, which is refusing to
overwrite the saved original with an already-modified copy on a second run.

The firewalld edit should not be an edit at all: firewalld takes a permanent rich rule via
`firewall-cmd`, which is additive and removable by name. Only avahi genuinely has no drop-in.

### The `.orig` files are not restore points — they are the upstream tripwire

`artifacts/*/….orig`, `artifacts/waydroid-vendor-original/` and `artifacts/lib/android-*.so`
are copies of the **stock** files our overlay shadows. Nothing restores from them, because
nothing needs to. Their real value is the one the owner's question implies: they are the only
way to notice that an image upgrade changed a file we are shadowing, at which point our copy
is silently reverting somebody's fix.

Of the twelve overlay files, **seven replace a stock file and five add a new one**:

| Overlay path | replaces? | stock copy in repo |
|---|---|---|
| `vendor/lib64/libgbm_mesa_wrapper.so` | replaces | `artifacts/lib/libgbm_mesa_wrapper.so` |
| `vendor/lib/libgbm_mesa_wrapper.so` | replaces | `artifacts/lib/libgbm_mesa_wrapper-32.so` |
| `vendor/lib/camera.device@3.4-external-impl.so` | replaces | `artifacts/camera/…impl.so.orig` |
| `vendor/etc/external_camera_config.xml` | replaces | `artifacts/waydroid-vendor-original/…` |
| `vendor/bin/hw/android.hardware.health@2.0-service.waydroid` | replaces | `artifacts/health/….orig` |
| `system/etc/init/wificond.rc` | replaces | `artifacts/overlay/system/etc/init/wificond.rc.orig` |
| `vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc` | replaces | `artifacts/overlay/vendor/etc/init/….rc.orig` |
| `system/etc/permissions/android.hardware.wifi.xml` | adds | — |
| `vendor/etc/vintf/manifest/manifest_…wifi.supplicant.xml` | adds | — |
| `vendor/lib64/libwvaidl.so` | adds | — |
| `vendor/bin/hw/android.hardware.drm-service-lazy.widevine` | adds | — |
| `vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc` | adds | — |
| `vendor/etc/vintf/manifest/manifest_…drm-service.widevine.xml` | adds | — |

Those seven rows are the entire surface on which an upstream image update can break a mod.
So the manifest format grows one field — the sha256 of the stock file the entry shadows —
and `waydroid-overlay-sync --check-upstream` loop-mounts `system.img` and `vendor.img`
read-only and reports every row where the image no longer matches what the component was
built against. The stock copies to seed that are already in the repo, so it costs nothing to
adopt. Note `waydroid.cfg` cannot substitute: `system_datetime` and `vendor_datetime` are
both `0` here and `system_ota` is `None`, because the images were sideloaded into
`/etc/waydroid-extra/images`.

## The split

Prefix is `waydroid-ext-`, with `waydroid-ext-hw-*` reserved for anything that names this
machine's hardware. Most of what this project produced is *not* HP Envy x2 specific — the
minigbm fix is a bug in Waydroid's own wrapper, the health HAL patch is Waydroid's own
hardcoded fakes — and a package named after one laptop will not be installed by anyone else.

**Overlay components.** Each ships payload to `%{_datadir}/waydroid-overlay/<component>/`
plus a manifest, and requires `waydroid-ext-overlay-sync`. None owns a file in `/var`.

| Package | Files | Doc |
|---|---|---|
| `waydroid-ext-camera-gbm` | the minigbm wrapper, both ABIs | [08](08-camera-fixed.md) |
| `waydroid-ext-camera-hal` | external camera HAL (`LENS_FACING_BACK`) + its config | [11](11-camera-facing.md) |
| `waydroid-ext-battery` | health HAL with `healthd_board_battery_update()` patched out | [10](10-battery-fixed.md) |
| `waydroid-ext-wifi-framework` | the feature XML that wakes Android's dormant Wi-Fi stack | [31](31-wifi-stage2.md) |
| `waydroid-ext-wifi-hostd` | `wificond.rc` stand-down + supplicant VINTF entry | [34](34-wifi-second-radio.md) |
| `waydroid-ext-brightness-overlay` | stub light-HAL stand-down | [37](37-brightness.md) |
| `waydroid-ext-widevine` | `.rc` + VINTF manifest + **fetcher**, no blob | [21](21-netflix-widevine.md) |

**Host daemons and services.**

| Package | Arch | Contents | Doc |
|---|---|---|---|
| `waydroid-ext-overlay-sync` | noarch | `waydroid-overlay-sync`, its unit, the staging tree. The dependency everything overlay-shaped has | [36](36-packaging.md) |
| `waydroid-ext-sensord` | x86_64 | the sensors + `ILight` daemon | [14](14-sensors.md), [18](18-sensor-axes.md), [37](37-brightness.md) |
| `waydroid-ext-wifid` | x86_64 | the wificond replacement, its unit, `waydroid-wifi-nudge` | [31](31-wifi-stage2.md)–[35](35-wifi-stage5.md) |
| `waydroid-ext-wifi-sync` | noarch | credential reconciler + timer | [36](36-wifi-credential-sync.md) |
| `waydroid-ext-media` | noarch | `waydroid-mediad` + unit | [46](46-removable-media.md) |
| `waydroid-ext-android-power` | noarch | suspend/lock key + `sleep.target` hook | [27](27-android-power-button.md) |
| `waydroid-ext-graceful-exit` | noarch | logout handler, user unit, sway `config.d` | [24](24-graceful-logout.md) |
| `waydroid-ext-graceful-shutdown` | noarch | shutdown inhibitor + container drop-in | [23](23-graceful-shutdown.md) |
| `waydroid-ext-cage` | noarch | the kiosk session | [25](25-waydroid-in-cage.md) |
| `waydroid-ext-binder-nice` | noarch | `RLIMIT_NICE` drop-in — one file, ~1 000 000 log lines a boot | [40](40-binder-nice.md) |
| `waydroid-ext-backlight-selinux` | noarch | CIL module + udev rule | [42](42-backlight-selinux.md) |
| `waydroid-ext-uvc-autosuspend` | noarch | the UVC autosuspend rule | [12](12-v4l2-frame-errors.md) |
| `waydroid-ext-mdns` | noarch | avahi reflector + firewalld rule reconciler | [45](45-mdns-reflection.md) |
| `waydroid-ext-dexopt` | noarch | dexopt property reconciler, values in `%config(noreplace)` | [43](43-app-freezer.md) |
| `waydroid-ext-lxc-config` | noarch | **new** — reconciles `lxc.net.0.name` before container start | [34](34-wifi-second-radio.md) |
| `waydroid-ext-tools` | noarch | `bin/*-test.sh` and the stdlib probes | — |

**Hardware-specific.**

| Package | Contents |
|---|---|
| `waydroid-ext-hw-ite8350` | sensor-hub resume check, sleep hook, the reprobe machinery ([19](19-sensor-hub-suspend-wedge.md)) |
| `waydroid-ext-hw-envyx2` | metapackage: `hw-ite8350` + the Core M-5Y70 dexopt values + `uvc-autosuspend` |

**Android apps.** APK plus a helper that installs it into a running container; they cannot be
installed by rpm, only staged.

| Package | Contents |
|---|---|
| `waydroid-ext-media-app` | "Removable Media" ([media-app/](../media-app)) |
| `waydroid-ext-sensor-app` | "Sensor Info" ([sensor-app/](../sensor-app)) |

**Groups.** Nothing but `Requires`, so a user picks a feature rather than a file list.

```
waydroid-ext-camera      -> camera-gbm, camera-hal, uvc-autosuspend
waydroid-ext-wifi        -> wifid, wifi-framework, wifi-hostd, wifi-sync
waydroid-ext-sensors     -> sensord, binder-nice
waydroid-ext-brightness  -> sensord, brightness-overlay, backlight-selinux
waydroid-ext-storage     -> media, media-app
waydroid-ext-kiosk       -> cage, graceful-exit, graceful-shutdown, android-power
waydroid-ext-all         -> every group above
```

Note what a group *is not*: it is not where the dependencies live. `waydroid-ext-wifi-hostd`
requires `waydroid-ext-wifid` on its own, because shipping the `wificond.rc` stand-down
without the daemon leaves Android with a Wi-Fi framework and no wificond behind it — worse
than stock, which at least fails honestly. The groups are convenience; the hard edges stay on
the individual packages so that installing one by hand cannot produce a broken system.

## How ~25 specs stay maintainable

Hand-writing and hand-maintaining twenty-five specs guarantees drift: a packaging fix gets
applied to the four you remembered. So the specs are **generated**, from one template and one
metadata file per modification.

```
packaging/mods/<name>.mod          version, summary, licence, deps, file list, docs
packaging/mods/<name>.changelog    that modification's changelog, and only its own
packaging/templates/rpm.spec.in    the one spec skeleton
packaging/templates/deb/*          the one debian/ skeleton (see the roadmap below)
packaging/gen-spec.sh <name>       render
packaging/build-rpms.sh [<name>…]  render, tarball, rpmbuild
```

The `.mod` file is shell-sourceable `key=value`, matching this repo's stdlib-only habit — no
YAML parser to depend on. Each modification gets **its own source tarball**, containing only
its own payload, its installer and the docs it ships. That is what makes the licence question
answerable per package (the Widevine fetcher and `waydroid-sensord`'s droidian derivation stop
contaminating a GPL tarball that has nothing to do with them), and it is what makes
`rpm -q --changelog` mean something.

Version bumps are per `.mod`, so fixing the camera wrapper touches exactly two files:
`camera-gbm.mod` and `camera-gbm.changelog`.

## The post-install hook

The owner asked for scripts that run after install and do not fail when Waydroid has not been
initialised. The mechanism already exists and already behaves: `waydroid-overlay-sync` opens
with a preflight that exits 0 with an explanation when `/var/lib/waydroid` is absent, precisely
because the packages may be installed before `waydroid init`. So every overlay package carries:

```rpm
%post
%{_bindir}/waydroid-overlay-sync --quiet || :

%postun
if [ $1 -eq 0 ]; then %{_bindir}/waydroid-overlay-sync --quiet || :; fi
```

Four things make that safe rather than merely brief:

- **`|| :`** — a scriptlet must never fail a transaction. There is no state a failed reconcile
  can leave that the boot-time unit will not fix.
- **`$1 -eq 0` on `%postun`** — scriptlets run on upgrade too, and reconciling in the middle of
  one would remove files the new version is about to reinstall.
- **It never restarts the container.** On this kiosk host that drops the session to the SDDM
  greeter and needs someone at the machine, so the tool prints the command and stops.
  `--apply` opts in, and a package must not.
- **The unit is still the authority.** `waydroid-overlay-sync.service` runs
  `Before=waydroid-container.service` on every boot regardless, so the scriptlet is an
  optimisation for the mutable-distro case, not the mechanism. On rpm-ostree it is inert by
  construction — scriptlets run against the compose, where `/var/lib/waydroid` does not
  exist — and the reboot `rpm-ostree install` already requires is when the work happens.

The same shape covers the non-overlay reconcilers: `waydroid-ext-dexopt`,
`waydroid-ext-mdns` and `waydroid-ext-lxc-config` each ship a reconciler that is a no-op on an
uninitialised host and is wired to both a `%post` and an `ExecStartPre`.

## Gaps this design exposed

- **The manifest format cannot express a symlink.** It is `<mode> <sha256> <path>`, and
  Widevine needs `vendor/lib64/libprotobuf-cpp-lite.so -> libprotobuf-cpp-lite-3.9.1.so`,
  without which `libwvaidl.so` does not load. Today that symlink is created by hand and is
  documented in [artifacts/widevine/README.md](../artifacts/widevine/README.md) but owned by
  nothing. The format needs a `link` row type.
- **Widevine becomes a fetcher.** The payload is a Google prebuilt extracted from a ChromeOS
  recovery image, pinned by commit and md5. Redistributing it in an RPM is a licence question
  nobody needs; downloading it on the target is how every distro handles this class of blob.
  The pin is already recorded, so the fetcher is a `curl`, an `md5sum` and an `unzip` into
  `/var/lib/waydroid-overlay/fetched/widevine/`, with the manifest generated at fetch time.
  `/var` rather than `/usr` because the fetch happens on the host, where `/usr` is read-only.
- **`waydroid-ext-lxc-config` does not exist yet.** It is listed above as a package because
  the `lxc.net.0.name = wlan0` edit is still the one durability hole in the Wi-Fi work, and
  giving it a package name is the cheapest way to stop it being forgotten.
- **The overlay packages must not be `noarch`.** [docs/36](36-packaging.md) made
  `waydroid-overlay` and all five of its component subpackages noarch, which is wrong for any
  component carrying Android ELF: `libgbm_mesa_wrapper.so`, the camera HAL, the health HAL and
  `libwvaidl.so` are x86_64 and x86 binaries, and a noarch package would install cleanly on an
  aarch64 host and break Android there instead of refusing on the shelf. Only the XML and `.rc`
  components (`wifi-framework`, `wifi-hostd`, `brightness-overlay`) are genuinely
  architecture-independent. The generator takes `ARCH` per modification for this reason.
- **Nothing here has been built.** [packaging/README.md](../packaging/README.md) is blunt about
  it: zero percent of this project's output is installed as an RPM on bigtab01 today. This
  design does not change that; it changes what gets built when somebody finally builds it.

## File diversion: Debian has it, RPM does not, and we should not want it

The question was whether RPM can redirect a file another package installs, the way
`dpkg-divert` does, as a way of backing up files we replace.

**RPM has no equivalent.** There is no diversion database in the rpmdb and no diversion verb in
`rpm`. The closest thing that exists is [`rpm-divert`](https://github.com/g7/rpm-divert), a
third-party tool written precisely because the feature is missing; it is a shim that renames
files and hooks scriptlets, not an rpm feature, and taking a dependency on it would put a
non-distribution tool between our packages and the filesystem.

What RPM does have, and what each is actually for:

| Mechanism | What it does | Useful here? |
|---|---|---|
| **File triggers** (`%filetriggerin`, `%transfiletriggerin`, rpm ≥ 4.13) | run a script whenever *any* package installs files under a path prefix | **yes, for one thing** — see below |
| `%config(noreplace)` + `.rpmsave` / `.rpmnew` | rpm's own backup of a changed config file | only for files the package itself owns |
| `%ghost` | own a path without shipping content, so uninstall still cleans it | for files created at runtime, not diversion |
| identical-file sharing | two packages may own one path if content, mode, owner and group match exactly | not applicable |
| `alternatives` | symlink arbitration between interchangeable implementations | the idiomatic answer to "two packages provide the same thing", not to "back up someone else's file" |

**And we do not need a diversion, because the overlay already is one — a better one.** For
everything Android-side, the kernel does the diversion: the original stays in a read-only image,
our file shadows it, and the undo is deleting one file. `dpkg-divert` renames the original and
records the rename in a database that then has to stay consistent across upgrades. The overlay
has no database and no rename. Reaching for a diversion tool for those files would be strictly
worse.

The only files this project modifies that belong to another package are two host config files,
and neither wants a diversion:

- **firewalld's zone** should not be edited at all. `firewall-cmd --permanent --add-rich-rule`
  is additive, named and removable, and leaves the package's file alone.
- **`/etc/avahi/avahi-daemon.conf`** genuinely has no drop-in directory — verified on the host,
  `avahi-daemon` contains no `conf.d` path string. So it is an in-place edit, and the right
  treatment is the one `artifacts/dexopt/install.sh` already uses: idempotent merge, keep a
  `.pre-waydroid-ext` copy the first time anything changes, refuse to overwrite that copy on a
  re-run. A diversion here would be worse than an edit on three counts: `rpm -V avahi` would
  start lying, a diverted file stops receiving avahi's own security updates, and on an
  rpm-ostree host the scriptlet that set it up would run against the compose rather than the
  booted system.

That last point generalises and is why no scriptlet-based mechanism can be load-bearing here:
**rpm-ostree runs scriptlets at compose and layering time, not against the running system.**
It is the same constraint that made [docs/36](36-packaging.md) forbid `%post` outright, and it
is why the `%post` this design does use is only an optimisation on top of a boot-time unit.

**The one RPM mechanism worth adopting is the file trigger**, and not for diversion: a
`%transfiletriggerin -- /usr/lib/waydroid` on `waydroid-ext-overlay-sync` would re-run the
reconcile whenever the `waydroid` package itself is updated, which is exactly when a component
can start shadowing a file upstream just changed. On rpm-ostree it fires at the wrong time, so
the boot unit stays the authority there — the same "useful on mutable distros, inert on ostree"
shape as the `%post`. Debian's equivalent is a `dpkg` trigger (`interest-noawait`), which the
`debian/` templates can carry from the same metadata.

## Debian and Ubuntu, and the other distros

Waydroid is in more official archives than [docs/36](36-packaging.md) assumed, which makes the
question worth restating. Verified 2026-09-16:

| Distro | Waydroid | `libgbinder` | Package format |
|---|---|---|---|
| **Fedora** 43/44 | official (`waydroid`, `waydroid-selinux`) | official | RPM — the host, built |
| **Fedora Atomic** (Silverblue, Kinoite, Sway Atomic, CoreOS) | same RPMs | same | RPM |
| **Debian** forky/sid, trixie-backports | official (`waydroid 1.6.3+ds-2`) | official (`libgbinder-dev`, via `python-gbinder`) | **deb — do this next** |
| **Ubuntu** | universe, synced from Debian; `repo.waydro.id` covers focal→questing | via Debian sync | **deb — same work** |
| **Arch** | official `extra/waydroid 1.6.3-1` | AUR | PKGBUILD |
| **Alpine** edge | official `community/waydroid` | official `community/libgbinder` | APK |
| **postmarketOS** | inherits Alpine's | inherits | APK |
| **NixOS** | nixpkgs, plus a `virtualisation.waydroid.enable` module | nixpkgs | Nix derivation |
| **openSUSE** | **not** in the main repos — OBS home projects only | OBS | RPM, but prerequisites first |
| **RHEL / Rocky** | not in the official repos or EPEL | not packaged | RPM, prerequisites first |

So the roadmap, in the order the work is actually worth doing:

1. **Debian and Ubuntu.** Both the runtime and the build dependencies are in the official
   archive, `libgbinder-dev` included, so the two compiled daemons build natively rather than
   needing the `--prebuilt` escape hatch this repo uses for Fedora on a Debian dev box. The
   `.mod` metadata renders `debian/control`, `debian/changelog` and `debian/rules`; every
   `artifacts/*/install.sh` already honours `DESTDIR`, which is exactly what
   `override_dh_auto_install` wants, so the install layout is described once and consumed by
   both packaging systems. Three real differences to handle: `dh_installsystemd` enables units
   rather than this repo's shipped `.wants` symlinks; Debian expects maintainer scripts where
   the ostree constraint forbade scriptlets, so the `%post` above becomes a `postinst` that is
   allowed to do slightly more; and there is no SELinux, which makes
   `waydroid-ext-backlight-selinux` and `waydroid-wifid.service`'s `SELinuxContext=` inert
   rather than wrong. **And this dev box is Debian**, so it is the one target that can be
   built and tested without borrowing a machine.
2. **Arch.** One `PKGBUILD` per mod from the same metadata, `package_*()` split packages for
   the groups. Cheapest third format; `pacman` has no scriptlet restriction.
3. **Alpine / postmarketOS.** `APKBUILD` is close enough to `PKGBUILD` to be a small
   increment, and postmarketOS is the one place where a *phone*-shaped Waydroid host is
   normal, which makes the sensor and brightness work interesting to somebody other than us.
4. **openSUSE and EL.** Both need Waydroid itself packaged before any of this means anything.
   Not worth the effort until somebody asks.

One spec set with conditionals remains the answer *within* RPM, for the reasons
[docs/36](36-packaging.md) gives. Generating from `.mod` metadata extends the same argument
across formats: the expensive content — the file lists, the dependency reasoning, the
install layout — is written once, and each format's template is only the part that genuinely
differs.

## What exists now

Written 2026-09-16. **Built 2026-09-17**, once `rpm` 4.20.1 and `rpmlint` 2.7.0 were installed
on the Debian 13 dev box — so for the first time in this project something here has actually
been through `rpmbuild` rather than only staged and reasoned about.

| File | What it is |
|---|---|
| [packaging/mods/](../packaging/mods) | one `.mod` + one `.changelog` per modification. Three written as proof of shape: `camera-gbm` (overlay), `wifid` (compiled host daemon), `camera` (group) |
| [packaging/templates/rpm.spec.in](../packaging/templates/rpm.spec.in) | the one spec skeleton. `@TOKEN@` alone on a line splices a block; inline it substitutes a value |
| [packaging/gen-spec.sh](../packaging/gen-spec.sh) | renders a `.mod` into a spec. `--list` shows every known modification |
| [packaging/stage-overlay.sh](../packaging/stage-overlay.sh) | the generic `%install` for overlay components. Reads the file table on stdin, writes payload plus manifest |
| [packaging/build-mod.sh](../packaging/build-mod.sh) | tarball, spec, `rpmbuild`, `rpmlint`. Overlay components' source file lists are *derived* from the same `FILES` table `%install` consumes, so payload can never be in the spec but missing from the tarball |
| [packaging/waydroid-ext.rpmlintrc](../packaging/waydroid-ext.rpmlintrc) | every rpmlint filter, each with the reason it is inapplicable rather than merely noisy |
| [README.md](../README.md) | the repository had no front door at all. Now it has one, aimed at somebody installing the packages rather than at us |
| [docs/user/overlay.md](user/overlay.md) | user-facing: nothing to back up and why, the `overlay_rw` trap, what wipes the overlay |
| [docs/user/lxc-config.md](user/lxc-config.md) | user-facing: what each package needs from the container configuration, and which of those files Waydroid regenerates |

`docs/user/` is deliberately separate from the numbered notes: those are an engineering record
and assume the reader is us, while these ship in the packages as `%doc` and assume the reader
has just installed something and wants to know why it is not working. Both user pages are in
the `DOCS` of the mods that need them.

Verified:

- All three `.mod` files render, and the three `KIND`s produce the right shape — overlay gets
  the dependency-generator exclusions, the payload heredoc, the `%post`/`%postun` reconcile and
  an `ExclusiveArch`; the group gets `BuildArch: noarch`, dependencies and no `%files` payload;
  the daemon gets its `pkgconfig()` BuildRequires and `%config(noreplace)`.
- `stage-overlay.sh` stages `camera-gbm` into a scratch `DESTDIR` and writes a manifest
  carrying the stock hash of both files the component replaces.
- **The extended manifest is backward compatible.** The stock rows are written as
  `# stock <sha256> <path>`, which the existing `waydroid-overlay-sync` parser skips as a
  comment — deliberately, so the reconciler did not have to change to gain the data. Checked
  against a scratch overlay: first sync installs both files, `--verify` then reports
  "overlay matches the staged components" and exits 0.
- **The scriptlet's premise holds.** `waydroid-overlay-sync` against a non-existent
  `/var/lib/waydroid` exits 0, both quiet and loud. That is what makes `%post` safe on a host
  where Waydroid has never been initialised, and inert in an rpm-ostree compose.

Also written, because a warning in a document nobody has read is weaker than the tool saying
so: `waydroid-overlay-sync` now reports files in `overlay_rw` that shadow a component's
payload, as `shadowed:` lines, and `--verify` exits 3 on them. The path mapping is asymmetric
because the two mounts are — `overlay/vendor/X` is Android `/vendor/X` and maps to
`overlay_rw/vendor/X`, while `overlay/X` is Android `/X` and maps to `overlay_rw/system/X`.
Exercised against a scratch overlay: clean before, `shadowed:` and exit 3 after planting a file
in `overlay_rw`. The whiteout branch (a char device 0:0, which hides the path from every layer)
is written but **not** exercised — `mknod` of a character device needs root, which this dev box
does not spend on a test.

### What building actually found

Five things, none of which review had caught.

- **`/usr/share` was the wrong place for the payload.** rpmlint's
  `arch-dependent-file-in-usr-share` is correct: `/usr/share` is defined as
  architecture-independent data and most components carry x86_64 Android ELF. Staging moved to
  `%{_prefix}/lib/waydroid-overlay` — `%{_prefix}/lib` and **not** `%{_libdir}`, because this is
  package data the reconciler reads rather than a linkable library and must not land in
  `/usr/lib64` on a multilib host, which is the same reason systemd, udev and dracut stage
  there. The reconciler searches the old `/usr/share` location after the new one, so nothing
  staged the old way stops working, and the superseded `waydroid-overlay.spec` pins
  `STAGEDIR` to its old layout and keeps building.
- **Space-separated dependency lists cannot express a versioned dependency.**
  `pkgconfig(libgbinder) >= 1.1.47` word-split into three entries; squeezing the spaces out
  instead produced `comparison-operator-in-deptoken`, which rpm parses but which is wrong.
  Dependencies are now one per **line**.
- **`artifacts/wifi/install.sh` serves two modifications at once.** It installs the daemon and
  `waydroid-wifi-sync` unconditionally, so it cannot yet be the `%install` of either one alone
  and `waydroid-ext-wifid` can only be built as an SRPM. It needs the component-argument
  treatment `artifacts/overlay/install.sh` already has, with `all` as the default so the
  superseded spec keeps working. This is the first concrete cost of the split, and it is the
  kind of thing only a real build surfaces.
- **`rpmlint`'s TOML `Filters` do nothing.** Filters set in a `-c` config file are parsed, show
  up in `--print-config`, and filter nothing. `addFilter()` in an rpmlintrc passed with `-r`
  works. An hour of "why is this not filtering" lives in that sentence.
- **The `%check` was worth writing for its own sake.** It re-hashes the staged payload against
  the manifest the same `%install` step just wrote. That is not box-ticking: the manifest is
  what `waydroid-overlay-sync` trusts at deploy time and it refuses to copy a file whose hash
  does not match, so a manifest disagreeing with its own payload would produce a package that
  installs and then silently deploys nothing. Exercised both ways — passes intact, fails on a
  tampered manifest.

### Results

| Modification | renders | `-bs` | `-ba` | rpmlint |
|---|---|---|---|---|
| `camera-gbm` (overlay) | yes | yes | **yes** | clean bar `no-signature`, `invalid-url Source0` |
| `camera` (group) | yes | yes | **yes** | same, plus `no-%check-section` |
| `wifid` (host, compiled) | yes | **yes** | no — see above, and `libgbinder-devel` is a Fedora package | same |

The built `waydroid-ext-camera-gbm` was inspected rather than assumed: `Requires` is exactly
`waydroid-ext-overlay-sync` plus `/bin/sh` and rpmlib, with **no** `libutils.so()(64bit)` and
friends, so the dependency-generator exclusions work; `Provides` is the package itself and not
`libgbm_mesa_wrapper.so()(64bit)`, so the provides exclusions work too; and both scriptlets are
present and correctly guarded.

rpmlint went from 41 errors and 14 warnings to 2 errors and 1 warning per package, all three
of which are deliberately **unfiltered** because they are real: the packages are unsigned, and
`Source0` is a bare filename because there is no release download URL yet. Both are release
work. Everything filtered is filtered with its reason written down.

Not built: `--check-upstream`. The manifest now carries the data it needs, and the stock
copies of all seven replaced files are already in the repo, but the mode itself — loop-mount
`system.img` and `vendor.img` read-only, hash the shadowed paths, report drift — is designed
and not written.

Not written: the remaining twenty-odd `.mod` files, the `debian/` templates, and the changes
to [packaging/build-rpms.sh](../packaging/build-rpms.sh) that would drive the generator instead
of the four hand-written specs. Those four specs still stand and are still the only thing that
could be built today.
