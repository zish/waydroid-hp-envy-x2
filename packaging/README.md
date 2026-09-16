# Packaging status

What has been through `rpmbuild` and what has not. Kept here rather than in each spec
header so there is one place to correct when it changes.

Design, dependency rationale and the migration steps are in
[docs/36-packaging.md](../docs/36-packaging.md).

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

There is no rpm toolchain on the dev box (`rpmbuild`, `rpmspec` and `rpm` are all absent),
and layering one onto bigtab01 costs a reboot. `sudo apt-get install -y rpm` provides
`rpmbuild` and `rpmspec` here; `packaging/build-rpms.sh` drives them.

The two daemon specs need Fedora's `libgbinder-devel` and `libglibutil-devel` for a real
source build. `packaging/build-rpms.sh --prebuilt` packages the binaries `wifi/build.sh`
and `sensors/build.sh` already produce instead, which is how they can be built on this box
at all.
