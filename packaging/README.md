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

"Payload staged and checked" means every `install.sh` these specs call as their `%install`
step was run with `DESTDIR` into a scratch buildroot and the resulting tree compared,
file by file, against the `%files` lists — including modes and with no unsubstituted
`@BINDIR@` left anywhere. Treat `%files` as verified and everything else — macro
expansion, dependency generation, subpackage splits — as unproven until this table says
otherwise.

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
