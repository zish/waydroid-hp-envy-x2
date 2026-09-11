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

There is no rpm toolchain on the dev box (`rpmbuild`, `rpmspec` and `rpm` are all absent),
and layering one onto bigtab01 costs a reboot. `sudo apt-get install -y rpm` provides
`rpmbuild` and `rpmspec` here; `packaging/build-rpms.sh` drives them.

The two daemon specs need Fedora's `libgbinder-devel` and `libglibutil-devel` for a real
source build. `packaging/build-rpms.sh --prebuilt` packages the binaries `wifi/build.sh`
and `sensors/build.sh` already produce instead, which is how they can be built on this box
at all.
