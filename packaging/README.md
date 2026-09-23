# Packaging status

What has been through `rpmbuild` and what has not. Kept here rather than in each spec
header so there is one place to correct when it changes.

Design, dependency rationale and the migration steps are in
[docs/36-packaging.md](../docs/36-packaging.md).

**The four-source-package layout below is superseded in design, not yet in code.**
[docs/47-package-split.md](../docs/47-package-split.md) replaces it with one source package
per modification, generated from `packaging/mods/*.mod`, so a fix to one mod does not reissue
every other one. It also answers the overlay-backup question (no backups: the overlay really
is an overlayfs lowerdir over a read-only image), names the seven overlay files that *replace*
a stock file and are therefore the surface an image upgrade can break, and carries the
Debian/Ubuntu and other-distro roadmap. Read it before touching anything here.

## Built is not the same as installable — audited 2026-09-22

The table below says which modifications survive `rpmbuild`. It does not say whether the
resulting package can be installed, and for two of them it cannot. Asked directly:

```
$ rpm -qp --requires build/rpm/RPMS/*/*.rpm
```

`waydroid-ext-camera-gbm`'s only dependency is **`waydroid-ext-overlay-sync`**, which has no
`.mod` file and has never been built. `waydroid-ext-camera` additionally requires
`waydroid-ext-camera-hal` and `waydroid-ext-uvc-autosuspend`, neither of which exists. So the
two camera packages build cleanly and are uninstallable, and since every overlay component
hard-requires `overlay-sync` by design, **the whole Android-side half of the project is
unreachable by RPM until that one package is written**.

Of the seven modifications here, four produce something installable today: `btd`, `pidguard`,
`restartd`, and `backlight` — the last of which installs but does nothing, because it grants a
permission to `waydroid-sensord`, which also has no `.mod`.

Write `overlay-sync` first. It is the cheapest change with the largest effect on this table.

Full audit in [docs/53-release-readiness.md](../docs/53-release-readiness.md).

## Generated per-modification packages — these have been built

`rpm` 4.20.1 and `rpmlint` 2.7.0 were installed on the Debian 13 dev box on 2026-09-17, so
"never been through rpmbuild" is no longer true of everything here. Built with
`packaging/build-mod.sh --lint`:

| Modification | Spec renders | `rpmbuild -bs` | `rpmbuild -ba` | rpmlint clean |
|---|---|---|---|---|
| `camera-gbm` | yes | yes | **yes** | yes, bar `no-signature` and `invalid-url Source0` |
| `camera` (group) | yes | yes | **yes** | same, plus `no-%check-section` — a metapackage has nothing to check |
| `wifid` | yes | **yes** | no | same |
| `pidguard` | yes | yes | **yes** | same, plus `no-manual-page-for-binary` |
| `restartd` | yes | yes | **yes** | same |
| `btd` | yes | yes | **yes** | same |
| `backlight` | yes | yes | **yes** | yes, bar `no-signature` and `invalid-url Source0` |

The four host packages added on 2026-09-22 all build fully, because none of them compiles
anything: two are `bash`, two are stdlib or system-library Python, and `backlight` is a CIL
module plus a udev rule. They cover the four `artifacts/` directories that had a
`DESTDIR`-clean `install.sh` and no packaging at all — the gap found by comparing
`artifacts/*/install.sh` against what `packaging/` references.

Three things were corrected while packaging them, each of which applies beyond its own
modification:

- `build-mod.sh` now defines `_udevrulesdir` alongside `_unitdir` when `systemd-rpm-macros`
  is absent, so a udev rule can use the real macro instead of `%{_prefix}/lib/udev/rules.d`,
  which rpmlint correctly reports as a hardcoded library path.
- All four declare `BuildRequires: systemd-rpm-macros`, which `wifid` already did and which
  every package referencing `%{_unitdir}` needs.
- `backlight` installs its udev rule to `%{_udevrulesdir}` rather than the installer's `/etc`
  default. A packaged rule belongs there, udev reads both, and it leaves `/etc` free for an
  admin override instead of shipping a `%config` nobody is expected to edit.

`backlight` is also the first modification with real scriptlets: `semodule -i` on install
(no `$1` guard, because a changed CIL must land on upgrade too) and `semodule -r` only on
uninstall. Both are wrapped in `selinuxenabled` so they are inert rather than wrong on a host
built without SELinux, and every line ends `|| :` because no scriptlet may fail a transaction.

`wifid` cannot do a full `-ba` here for **three** separate reasons, and only the first is about
this box: `libgbinder-devel` is a Fedora package, and `artifacts/wifi/install.sh` installs the daemon
*and* `waydroid-wifi-sync` unconditionally, so it cannot yet serve either modification alone —
an `-ba` build would fail on unpackaged files. That installer needs the component-argument
treatment `artifacts/overlay/install.sh` already has, with `all` as the default so the
superseded `waydroid-wifid.spec` keeps working. Recorded in `packaging/mods/wifid.mod`.

The third reason was found on 2026-09-22 and fails before either of the others:
`wifid.mod` sets `BUILD='sh wifi/build.sh --rpm'`, and **`wifi/build.sh` has no `--rpm` mode**.
It accepts `--deps`, `--check`, `--install` and `--unit`, and its parser ends with
`*) echo "unknown argument: $1" >&2; exit 2`. Implementing it means a native build against
Fedora's `libgbinder-devel`, as opposed to the `--deps` path that copies `.so` files off
bigtab01 to guarantee an ABI match — which is the right answer for a dev box that cannot
compile against those headers, and the wrong one inside `rpmbuild`.

`no-signature` and `invalid-url Source0` are deliberately not filtered: both are real and both
are release-time work. Everything else rpmlint said is filtered with a written reason in
[waydroid-ext.rpmlintrc](waydroid-ext.rpmlintrc).

## The superseded four-spec layout

| Spec | Payload staged and checked against `%files` | Parsed by `rpmspec` | Built by `rpmbuild` | Installed on bigtab01 |
|---|---|---|---|---|
| `waydroid-bigtab01.spec` | yes (2026-09-07) | no | no | no |
| `waydroid-sensord.spec` | yes (2026-09-09) | no | no | no |
| `waydroid-wifid.spec` | yes (2026-09-09) | no | no | no |
| `waydroid-overlay.spec` | yes (2026-09-09) | no | no | no |
| `waydroid-bigtab01.spec` → `media` subpackage | yes (2026-09-15) | no | no | no |

"Payload staged and checked" means every `install.sh` these specs call as their `%install`
step was run with `DESTDIR` into a scratch buildroot and the resulting tree compared,
file by file, against the `%files` lists — including modes and with no unsubstituted
`@BINDIR@` left anywhere. Treat `%files` as verified and everything else — macro
expansion, dependency generation, subpackage splits — as unproven until this table says
otherwise.

## What is actually deployed on bigtab01 today

Audited 2026-09-15, because "how much is packaged?" turned out to have a blunt answer.

**None of it. Zero percent of this project's output is installed as an RPM.** Every spec above is
written and payload-verified; none has been built, and `rpm -qa` on the host lists only Fedora's own
`waydroid` and `waydroid-selinux`. Everything this repository produces is hand-placed, and survives
only because nothing has overwritten it yet.

What that means concretely — all of the following is unowned by any package (`rpm -qf` says so for
each):

| Where | What | Count |
|---|---|---|
| `/usr/local/bin` | `waydroid-{mediad,sensord,wifid,cage-session,graceful-exit,android-key,android-lock,shutdown-android,shutdown-inhibitor,sync,sync-sleep,bt-restore,wifi-nudge,wifi-sync}`, `ite8350-resume-check` | 15 |
| `/etc/systemd/system` | units for mediad, wifid, wifi-sync, android-lock, sync, sync-sleep, shutdown-inhibitor, ite8350-sleep, ite8350-resume-check | 9 |
| `/etc/systemd/system/*.d` | `waydroid-container.service.d/{graceful-shutdown,nice-limit}.conf`, `systemd-initrd-objects.service.d/bluetooth-wait.conf` | 3 |
| `/etc/udev/rules.d` | `99-waydroid-backlight.rules`, `99-bluetooth-boot.rules` | 2 |
| `/etc/wayland-sessions` | `waydroid-cage.desktop` | 1 |
| SELinux | `waydroid_backlight` module, loaded via `semodule` | 1 |
| `/var/lib/waydroid/overlay` | 12 Android files — the camera wrapper for both ABIs, the health HAL, Widevine, the Wi-Fi feature XML and `.rc` files | 12 |
| `/var/lib/waydroid/lxc/waydroid/config` | the hand-edited `lxc.net.0.name = wlan0` | 1 line |

Note `/usr/local/bin` is deliberate and not an accident of laziness: `/usr` is read-only on an
rpm-ostree host, `/usr/local` is a symlink into `/var`, and it is the only writable bin directory. An
RPM would install to `%{_bindir}` instead, which is why every `install.sh` takes `PREFIX`.

**One discrepancy worth correcting.** AGENTS.md states that overlay content "is now packaged rather
than hand-copied" and that `waydroid-overlay-sync` reconciles it before container start. On the host,
`/usr/share/waydroid-overlay` does not exist and `waydroid-overlay-sync` is not installed — the
overlay is still 12 hand-copied files with no self-repair. The machinery is written and staged; it
has simply never been deployed, because deploying it means building and installing the RPM. The
documentation describes the design, and the design is not in force.

**The practical risk this leaves** is the one the specs exist to close: a `waydroid upgrade` or
`waydroid init` erases the LXC config edit and the overlay, and nothing reinstalls them; an
rpm-ostree deployment rollback keeps `/var` but nothing reconciles `/usr/local` against what the
repo expects. Today the recovery is a human re-running installers from this tree.

## Planned, not yet specced

**One reconciler for mutable Waydroid state, and a `waydroid-dexopt` subpackage.** Added to the
list 2026-09-12. Three separate customisations now live in `/var/lib/waydroid`, which is *state* and
so cannot be owned by an RPM — the package can only stage payload into `/usr/share` and have
something reconcile it into place at the right point in the container lifecycle:

| what | file | when it must be applied | status |
|---|---|---|---|
| overlay payload | `overlay/` | before container start | **solved** — `waydroid-overlay-sync` |
| `lxc.net.0.name = wlan0` | `lxc/waydroid/config` | before container start | unsolved, erased by `waydroid upgrade` ([docs/34](../docs/34-wifi-second-radio.md)) |
| dex2oat properties | `waydroid_base.prop` | before container start | unsolved, same trap ([docs/43](../docs/43-app-freezer.md)) |
| `use_compaction=true` | Android settings in `/data` | **after** `system_server` is up | unsolved, lost on every restart |

The recommendation is **not** an RPM per item. It is to generalise `waydroid-overlay-sync` (or add a
sibling beside it) to reconcile all three pre-start inputs from `/usr/share`, wired as a single
`ExecStartPre` on `waydroid-container.service`, plus one `ExecStartPost` one-shot for the
device_config flag, which is the only item that needs the container already running. Shipping that
as a subpackage of the noarch `waydroid-bigtab01` closes the `wlan0` durability hole for free,
because it is the same machinery. `artifacts/dexopt/install.sh` already honours `DESTDIR`, so it
drops into a `%install` step unchanged.

APKs were considered and rejected for all of it: an APK cannot set system properties or write
`waydroid_base.prop`, and writing `device_config` from an app needs the signature-level
`WRITE_DEVICE_CONFIG`, which would mean shipping a privileged system app into the overlay to do
what a host-side one-shot already does.

The dev box now has `rpm` 4.20.1 and `rpmlint` 2.7.0 (Debian 13). Layering a toolchain onto
bigtab01 would still cost a reboot, so builds stay here. `packaging/build-mod.sh` drives the
generated per-modification packages; `packaging/build-rpms.sh` still drives the four legacy
specs.

Two things the Debian host does not provide, both handled rather than ignored:
`systemd-rpm-macros` is a Fedora package, so `build-mod.sh` defines `%{_unitdir}` and
`%{_userunitdir}` itself when they are missing and stands aside when they are not; and Debian's
rpmlint has no SPDX identifier list, so correct licence strings are reported invalid and are
filtered by identifier.

The two daemon specs need Fedora's `libgbinder-devel` and `libglibutil-devel` for a real
source build. `packaging/build-rpms.sh --prebuilt` packages the binaries `wifi/build.sh`
and `sensors/build.sh` already produce instead, which is how they can be built on this box
at all.
