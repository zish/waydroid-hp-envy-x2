# Packaging the host-side work as RPMs

*2026-09-09.*

Everything this project adds to bigtab01 outside the Android images is host-side: two
compiled daemons, a set of overlay files, and the shell that ties them to systemd. Until
now all of it arrived by `scp` and `sudo install` from a build script. That works, and it
is invisible: nothing on the host records what any of it is, what it was built against, or
whether it is still the file that was put there. `rpm -q` answers all three, which is the
reason for this work — the owner asked for it as "a courtesy to let a user keep track of
security patch levels", and that is exactly the gap.

Four source packages now, up from one.

| Spec | Packages | Arch | What it carries |
|---|---|---|---|
| [waydroid-bigtab01.spec](../packaging/waydroid-bigtab01.spec) | `waydroid-bigtab01`, `-graceful-exit`, `-cage` | noarch | Suspend/lock, sensor-hub resume check, graceful logout, the cage kiosk session |
| [waydroid-sensord.spec](../packaging/waydroid-sensord.spec) | `waydroid-sensord` | x86_64 | The sensors daemon (goal 2) |
| [waydroid-wifid.spec](../packaging/waydroid-wifid.spec) | `waydroid-wifid`, `-sync` | x86_64 | The Wi-Fi daemon, its unit, the credential reconciler (goal 4) |
| [waydroid-overlay.spec](../packaging/waydroid-overlay.spec) | `waydroid-overlay`, `-camera`, `-battery`, `-wifi`, `-brightness`, `-widevine` | noarch | Every file this project puts inside the Android images |

The daemons are split out from `waydroid-bigtab01` for three reasons that would each be
enough on their own: they are compiled, so the package is arch-specific and the noarch one
must stay noarch; they carry a dependency set — libgbinder, libglibutil — that the noarch
package does not; and `waydroid-sensord` is a derivative work of
[droidian/waydroid-sensors](https://github.com/droidian/waydroid-sensors) where nothing
else here is, which belongs in `rpm -qi` rather than in a comment.

## The overlay is state, so no package owns it

This is the part worth reading. The obvious way to package `/var/lib/waydroid/overlay` is
to list those thirteen paths in `%files` and let rpm own them. That is wrong here, three
times over.

**The overlay gets wiped by things that are not package operations.** `waydroid init -f`,
an image upgrade, a container rebuild after a bad session, a restore of `/var` from a
backup older than the packages — all of them can empty or diverge it, and rpm will not
notice any of them. The files would be "installed" and absent.

**On an rpm-ostree host, `/var` is outside the deployment.** Content a package ships there
is not part of the ostree commit and does not come back with a rollback. So `/var` is
precisely the wrong place to put files whose integrity you want the package manager to
stand behind. `/usr` is right — read-only, versioned, part of the commit — and that makes
it a source worth trusting.

**The overlay directory is a mounted overlayfs lowerdir.** `waydroid-container.service`
creates that mount once, at container start, and a file added to a mounted lowerdir is
undefined behaviour that here resolves to "invisible". This bit a Stage 0 file that sat on
disk, unread, for a day ([docs/32](32-wifi-stage3.md)). Deployment therefore has to be
*ordered* against the container, which is a unit's job and not a `%post`'s.

So the packages stage, and a reconciler deploys:

```
/usr/share/waydroid-overlay/<component>/{system,vendor}/...   payload, from the RPM
/usr/share/waydroid-overlay/manifests/<component>.manifest    mode, sha256, path
        |
        |  waydroid-overlay-sync, from waydroid-overlay-sync.service,
        |  Before=waydroid-container.service, every boot
        v
/var/lib/waydroid/overlay/...                                 what Android sees
/var/lib/waydroid-overlay/deployed.list                        what we put there
```

`waydroid-overlay-sync` installs what is missing, replaces what has drifted, removes what
no component claims any more, and — the part that keeps it safe to run unattended —
refuses to remove a file that was edited after it was deployed, saying so and keeping it
tracked so `--force` can still act later. It verifies the staged payload against the
manifest before copying, so a corrupt read out of `/usr` cannot overwrite a good file in
`/var`. `--verify` reports drift and changes nothing, which is the answer to "is the
overlay still what the packages say it should be?".

Because a wiped overlay is repaired on the next boot, and because `rpm-ostree install`
requires a reboot anyway, installing an overlay package and having it take effect are the
same event. That is not luck; it is the reason the unit is ordered where it is.

What it will not do is restart the container. On this kiosk host that drops the session
back to the SDDM greeter and needs someone at the machine, so the tool prints the command
and stops. `--apply` opts in.

## The payload is exactly what is running

Every one of the thirteen files was compared by sha256 against `/var/lib/waydroid/overlay`
on the live host on 2026-09-09. All thirteen match, and the table in
[artifacts/overlay/install.sh](../artifacts/overlay/install.sh) is the only place the
mapping is written down.

| Component | Overlay path | Source in this repo |
|---|---|---|
| camera | `vendor/lib64/libgbm_mesa_wrapper.so` | `artifacts/phase2/libgbm_mesa_wrapper-fixed-64.so` |
| camera | `vendor/lib/libgbm_mesa_wrapper.so` | `artifacts/phase2/libgbm_mesa_wrapper-fixed-32.so` |
| camera | `vendor/lib/camera.device@3.4-external-impl.so` | `artifacts/camera/…-impl.so.back` |
| camera | `vendor/etc/external_camera_config.xml` | `artifacts/overlay/vendor/etc/…` |
| battery | `vendor/bin/hw/android.hardware.health@2.0-service.waydroid` | `artifacts/health/…` |
| brightness | `vendor/etc/init/android.hardware.light@2.0-service.waydroid.rc` | `artifacts/overlay/vendor/etc/init/…` |
| wifi | `system/etc/permissions/android.hardware.wifi.xml` | `artifacts/overlay/system/etc/…` |
| wifi | `system/etc/init/wificond.rc` | `artifacts/overlay/system/etc/init/…` |
| wifi | `vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml` | `artifacts/overlay/vendor/etc/…` |
| widevine | `vendor/lib64/libwvaidl.so` | `artifacts/widevine/vendor/lib64/…` |
| widevine | `vendor/bin/hw/android.hardware.drm-service-lazy.widevine` | `artifacts/widevine/vendor/bin/hw/…` |
| widevine | `vendor/etc/init/android.hardware.drm-service-lazy.widevine.rc` | `artifacts/widevine/vendor/etc/init/…` |
| widevine | `vendor/etc/vintf/manifest/manifest_android.hardware.drm-service.widevine.xml` | `artifacts/widevine/vendor/etc/…` |

Note which camera HAL the table names: `artifacts/camera` holds three builds of it
(`.orig`, `.front`, `.back`) and only `.back` is the deployed fix ([docs/11](11-camera-facing.md)).
That ambiguity is exactly what a manifest is for.

## Dependencies, and why each one is there

The interesting ones are not the sonames — rpm generates those itself from the ELF. They
are the package-level statements, which exist so that "what do I have to keep patched for
this?" has a direct answer.

- **`waydroid-sensord` → `libgbinder >= 1.1.47`, `libglibutil >= 1.0.82`.** Named as
  packages, not just sonames, because `libgbinder.so.1` does not tell an operator which
  source package to watch. The versions are floors, not pins: they are what the daemon was
  built and verified against, and `gbinder_*` carries no stable-ABI promise across
  versions, which is why `sensors/build.sh` goes to the trouble of matching the host.
- **`waydroid-sensord` → `Recommends: waydroid-bigtab01`.** The ITE8350 does not reliably
  survive s2idle; recovery is a driver reprobe and the units that do it live there
  ([docs/19](19-sensor-hub-suspend-wedge.md)). The daemon is correct without them — it just
  has no safety net — so this is a Recommends and not a Requires.
- **`waydroid-wifid` → `NetworkManager`.** Hard: `NmBackend::init()` refuses to start if NM
  is not answering on the system bus. It is also the one dependency the design is built to
  let someone replace, which is why the backend lives behind `WifiBackend.h` and why this
  is its own package rather than part of a general integration package.
- **`waydroid-overlay-wifi` → `waydroid-wifid`.** The load-bearing one. That component's
  `wificond.rc` execs `/system/bin/true` to stop the guest's own wificond from taking the
  service name the host daemon must register. Install the overlay without the daemon and
  Android has a Wi-Fi framework with no wificond at all behind it — worse than the stock
  image, which at least fails honestly.
- **`waydroid-wifid` → `Recommends: waydroid-overlay-wifi`** — the other direction, and
  deliberately not a Requires, so the pair is not a dependency cycle. The daemon is
  independently testable against an image that has never had an overlay file, and that is
  how Stage 2 was verified ([docs/31](31-wifi-stage2.md)).
- **`waydroid-overlay-brightness` → `waydroid-sensord`.** The same shape as the wifi
  component's dependency and for the same reason: that component's only file neuters the
  guest's stub light HAL, which would otherwise register `ILight/default` after the host
  daemon and take the name back. Shipping the neutering without the daemon that serves
  ILight leaves the interface served by nobody rather than by a stub — no worse in effect,
  since neither moves the panel, but half a fix is not worth shipping.
- **`waydroid-overlay` → `coreutils`, `Recommends: policycoreutils`.** `sha256sum`, `stat`,
  `install`, `mktemp` are the reconciler's entire toolchain; `restorecon` is optional and a
  missing one is read as "this host does not use SELinux".

No package has a `%post`, `%postun` or any other scriptlet. Units are enabled by shipping
the `.wants` symlink that `systemctl enable` would create, and SELinux labels come from the
rpm-ostree compose. Both are requirements of an ostree host, where scriptlets run against
the compose and not against the booted system.

## Building

```
packaging/build-rpms.sh                    # all four, real source builds
packaging/build-rpms.sh --prebuilt         # daemons from build/ binaries
packaging/build-rpms.sh waydroid-overlay   # one package
```

`waydroid-bigtab01` and `waydroid-overlay` are noarch and build anywhere `rpmbuild` runs,
including the Debian dev box. `waydroid-sensord` and `waydroid-wifid` compile against
`libgbinder-devel` and `libglibutil-devel`, which are Fedora packages — both exist for
Fedora 44 at exactly the versions bigtab01 has installed (1.1.47-1.fc44, 1.0.82-1.fc44), so
a real source build wants a Fedora machine or mock.

`--prebuilt` is the way round that here, and it is not a hack for its own sake: this repo's
whole build policy is that binaries are produced on the dev box and copied to a host that
cannot compile them ([docs/06](06-next-session.md)). It packages the binaries
`wifi/build.sh` and `sensors/build.sh` already produce and that are deployed today; rpm
still reads the ELF and generates the same soname dependencies. The source build remains
the default.

The tarball is built from the working tree rather than from `HEAD`, on purpose: packaging
is usually being edited while it is being built, and a `git archive HEAD` would quietly
build the last commit instead of what is on disk.

## One spec set, many distros

The question came up as "Fedora, Fedora Silverblue and the other ostree variants, openSUSE,
Rocky — one rpmbuild repo or one per distro?" One, with conditionals. Two things make that
the easy answer here rather than the optimistic one.

**The content is distro-independent.** Three of the four packages are shell, Python, XML
and prebuilt Android payload; the other two are C++ against libgbinder and glib. Nothing in
any of them is Fedora-specific. What differs between distros is only how each one *names*
things.

**Forking the specs would duplicate the hard parts to avoid the easy ones.** The `%files`
lists, the install layout, the staging-versus-deploying design and the dependency reasoning
are the expensive content, and they are identical everywhere. The parts that genuinely
differ come to three conditionals. A per-distro fork would make every future change a
four-way edit, and the copies would drift — silently, because nobody builds all four on the
same day.

So: three levers, applied across all four specs.

- **`pkgconfig()` BuildRequires instead of `-devel` names.** Fedora ships
  `libgbinder-devel`; another distro may call it `libgbinder1-devel` or fold it into the
  library package. All of them provide `pkgconfig(libgbinder)`, because the `.pc` file is in
  the payload — verified: libgbinder installs `libgbinder.pc` (module `libgbinder`) and
  libglibutil installs `libglibutil.pc`. Version constraints still work, since rpm compares
  the version out of the `.pc`.
- **`%{_unitdir}` and `%{_userunitdir}` from `systemd-rpm-macros`**, never a hardcoded
  `/usr/lib/systemd/system`.
- **Explicit runtime `Requires` guarded by `%if 0%{?fedora} || 0%{?rhel}`.** Naming
  `libgbinder` and `glib2` as packages is what makes `rpm -q --requires` answer a
  patch-level question directly, and those names are only known to be right on Fedora and
  EL. Everywhere else rpm's own ELF scan emits the soname dependencies, which every distro
  satisfies under whatever name it uses. Nothing is lost but legibility.

| Target | Status | What it needs |
|---|---|---|
| Fedora 44 | The host. `waydroid`, `libgbinder`, `libglibutil` are all in the official repos | nothing extra |
| Fedora Sway Atomic, Silverblue, Kinoite, CoreOS | Same RPMs, no changes | `rpm-ostree install` plus a reboot |
| openSUSE Tumbleweed, MicroOS | Untested — no openSUSE machine here | Waydroid and libgbinder come from OBS, not the main repos |
| Rocky / RHEL 9 | Untested, and the prerequisites are the problem | Neither `waydroid` nor `libgbinder` is in the official repos or EPEL; needs a third-party or self-built repo first |

The ostree variants need no spec changes at all, but only because the packaging already
obeys the three rules they impose: no scriptlets, nothing owned under `/var`, and units
enabled by shipping the `.wants` symlink. Those were adopted for Fedora Sway Atomic and
they are what makes Silverblue, CoreOS and MicroOS free. The overlay design gets a bonus
there — `rpm-ostree install` requires a reboot, and the reboot is exactly when
`waydroid-overlay-sync` runs, so installing an overlay package and having it take effect
are the same event.

One asymmetry worth naming: `waydroid-wifid.service` carries
`SELinuxContext=system_u:unconfined_r:unconfined_t:s0`, which systemd applies only when
SELinux is enabled. On an AppArmor distro the directive is inert — which is correct, since
the denial it works around ([docs/35](35-wifi-stage5.md)) is an SELinux policy rule that
does not exist there.

Building for more than one distro is a build-host question, not a spec question: `mock` for
Fedora and EL with a different chroot per target, OBS for openSUSE, both consuming the same
tarball that `packaging/build-rpms.sh` produces. Neither runs on this dev box, which has no
working container runtime.

## Migrating off the hand-installed layout

Both traps are silent, and both would present as "the package installs but nothing
changes".

**`/usr/local/bin` precedes `/usr/bin` on root's PATH.** The existing daemons live there.
Install the RPMs without removing them and Waydroid keeps starting the old binaries —
`container_manager.py` finds `waydroid-sensord` by `which()`, and it will find the old one.

**A unit in `/etc/systemd/system` completely overrides one in `/usr/lib/systemd/system`.**
The existing `waydroid-wifid.service` is in `/etc`. Left there, the packaged unit is inert
and the package can be upgraded forever with no effect.

```
systemctl disable --now waydroid-wifid waydroid-wifi-sync.timer
rm -f /etc/systemd/system/waydroid-wifid.service \
      /etc/systemd/system/waydroid-wifi-sync.service \
      /etc/systemd/system/waydroid-wifi-sync.timer \
      /usr/local/bin/waydroid-wifid /usr/local/bin/waydroid-wifi-nudge \
      /usr/local/bin/waydroid-wifi-sync /usr/local/bin/waydroid-sensord
```

`/etc/waydroid-wifid.conf` and `/etc/waydroid-wifi-share.conf` stay: both are
`%config(noreplace)` in the package and the existing ones are the operator's, not ours.

## What is verified and what is not

Verified on 2026-09-09:

- All thirteen overlay payload files match the live host byte for byte (sha256), across all
  five components.
- Each installer was run with `DESTDIR` into a scratch buildroot; the resulting tree
  matches every `%files` list file for file, with no unsubstituted `@BINDIR@` anywhere and
  the intended modes (0600 on `waydroid-wifi-share.conf`).
- `waydroid-overlay-sync` was exercised end to end against a scratch overlay: first sync,
  idempotent re-run, `--verify` clean and dirty (exit 3), a wiped overlay rebuilt from
  nothing, a component uninstalled and its files removed with empty directories pruned, a
  locally-edited orphan refused and then removed with `--force`, and `/usr/local` staging
  overriding `/usr/share`.

Not verified: see [packaging/README.md](../packaging/README.md) for the current build
status. Nothing here has been installed on bigtab01 — the host still runs the hand-placed
copies, and migrating it is a deliberate act that costs a container restart.
