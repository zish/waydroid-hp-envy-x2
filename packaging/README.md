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

## Built is not the same as installable — audited 2026-09-22, revised 2026-09-24

The table below says which modifications survive `rpmbuild`. It does not say whether the
resulting package can be installed, and for two of them it still cannot. Asked directly:

```
$ rpm -qp --requires build/rpm/RPMS/*/*.rpm
```

**The keystone is no longer missing.** `waydroid-ext-overlay-sync` was written on 2026-09-23
and builds, lints to the same baseline as every other package here, and installs. That closes
`waydroid-ext-camera-gbm`, whose only unsatisfiable dependency it was, and with it the general
case: every overlay component hard-requires `overlay-sync` by design, so **the Android-side
half of the project is now reachable by RPM.** Proved rather than assumed —
`rpm --test -i camera-gbm.rpm` reports `waydroid-ext-overlay-sync is needed by
waydroid-ext-camera-gbm`, and adding `overlay-sync` to the same transaction removes that line,
leaving only base-OS dependencies an empty test root cannot have.

~~What is still uninstallable is the `camera` **group**~~ — **resolvable since 2026-09-24.**
It required `waydroid-ext-camera-hal`, which is now written, and
`waydroid-ext-uvc-autosuspend`, which is now [retired](../docs/12-v4l2-frame-errors.md) rather
than written. Proved the same way `camera-gbm` was: `rpm --test -i` on the group alone reported
both missing packages by name before, and reports only base-OS dependencies an empty test root
cannot have once the group, `camera-hal`, `camera-gbm` and `overlay-sync` are in one
transaction. The group went to 1.0.1 for the dependency change.

**Of the fourteen modifications here, twelve produce something installable**: `overlay-sync`,
`sensord`, `camera-gbm`, `btd`, `pidguard`, `restartd`, `backlight` — no longer inert, because
the `waydroid-sensord` it grants a permission to is now a package, so its `Recommends`
resolves for the first time — and, as of 2026-09-24, `camera-hal`, `battery`,
`brightness-overlay`, `wifi-framework` and the `camera` group.

**The two that are not installable are `wifid` and `wifi-hostd`, and it is one cause.** `wifid`
is SRPM-only on this box because its source build needs Fedora's `libgbinder-devel` and it
declares no `PREBUILT=`, so `build-mod.sh --prebuilt` has nothing to stage; `wifi-hostd`
hard-requires it, correctly — standing wificond down with no daemon behind it is worse than
stock. So `rpm --test -i wifi-hostd.rpm` reports `waydroid-ext-wifid is needed by
waydroid-ext-wifi-hostd` and will keep reporting it until `wifi/build.sh` can produce a
binary here. That is the same item as
[docs/53](../docs/53-release-readiness.md)'s `wifi/build.sh --rpm`.

Next cheapest, for the reason `overlay-sync` and `sensord` were: `mediad`, then `wifi-sync`.

### `sensord` is built `--prebuilt` here, and why that is not a fudge

`packaging/build-mod.sh --prebuilt` stages the binary `sensors/build.sh` already produced into
the tarball under `prebuilt/` and passes `--with prebuilt` to rpmbuild, exactly as the older
`build-rpms.sh --prebuilt` does. The `.mod` declares the **source build as the default** — it
is what a distribution builder runs, and a source package that cannot be built from source is
not one — and the `%bcond` selects the other arm. This box is Debian and has no
`libgbinder-devel`, so the prebuilt arm is the only one it can execute.

Two `%global`s apply to that arm alone. `debug_package %{nil}`, because there is no source in
the build tree for a debuginfo package to point at and the extraction needs `eu-strip`, which
this box does not have — that failure is how this was found. `__brp_strip %{nil}`, so the
packaged binary stays byte-for-byte the file that was built and tested against bigtab01;
verified, both are sha256 `0e6dcd15…`. The resulting `unstripped-binary-or-object` warning is
therefore expected and is deliberately **not** filtered: filtering it would also hide a
genuinely unstripped binary in a future source build.

rpm still reads the ELF and generates the real soname dependencies from it —
`libgbinder.so.1`, `libglibutil.so.1`, `libglib-2.0.so.0` — on top of the declared ones, which
is what makes a prebuilt package honest about what it links rather than merely what it claims.

Full audit in [docs/53-release-readiness.md](../docs/53-release-readiness.md).

## Install and uninstall are tested, without touching bigtab01

`packaging/test-install.sh` installs every built package into a throwaway root, edits every
file it owns behind rpm's back, uninstalls it, and checks what happened. It needs no sudo, no
container runtime and no reboot: `unshare -r` supplies a user namespace in which `rpm --root`
may chroot, which is the only privilege the exercise actually requires.

```
$ packaging/test-install.sh --selftest --all
test-install: 46 passed, 0 failed
```

It does not run scriptlets — rpm chroots to run them and the test root has no shell — so they
are syntax-checked with `sh -n` instead. That catches the error that really happens, a typo in
a `%postun` nobody executed before shipping.

**The policy it enforces**, decided 2026-09-23: an uninstall must never fail, and must never
silently discard a file somebody edited. Measured, not assumed — on erase, rpm preserves an
edited `%config` as `.rpmsave` and prints a warning, and deletes an edited plain file without
a word. Both exit 0. So the enforceable rule is *anything under `/etc` must be `%config`*,
because `/etc` is where an administrator edits; everything else lands in `/usr`, which is
read-only on an rpm-ostree host and cannot be edited in place at all.

Failing the transaction instead was considered and rejected. A `%preun` that exits non-zero
aborts the erase, leaving a package that cannot be removed without `--noscripts`, and on
bigtab01 that failure surfaces inside an rpm-ostree deployment build rather than as a message
anybody reads. It also contradicts the rule this repository already adopted for `backlight`'s
`semodule` scriptlets: no scriptlet may fail a transaction.

`--selftest` is not decoration. Every package here happens to ship no `%config` file, so the
two checks that matter most never fire on real input, and a check that has never failed is not
known to work. It builds two deliberate fixtures — one correct, one shipping an `/etc` file
plain — and asserts the harness reaches the right verdict on each.

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
| `overlay-sync` | yes | yes | **yes** | same, plus `no-manual-page-for-binary` |
| `sensord` | yes | yes | **yes**, `--prebuilt` only | same, plus `no-manual-page-for-binary` and `unstripped-binary-or-object` |
| `camera-hal` | yes | yes | **yes** | yes, bar `no-signature` and `invalid-url Source0` |
| `battery` | yes | yes | **yes** | same |
| `brightness-overlay` | yes | yes | **yes** | same |
| `wifi-framework` | yes | yes | **yes** | same |
| `wifi-hostd` | yes | yes | **yes** | same |
| `appfuse` | yes | yes | **yes** | yes — the backlight baseline exactly: `no-signature`, `invalid-url Source0`, `no-%check-section`, `no-manual-page-for-binary` |

### The five overlay components added 2026-09-24

They take the packaged share of the overlay from 2 files of 13 to 9, and they are the last
`.mod` files the existing machinery can express — the remaining four are Widevine's and need
manifest mechanism that does not exist (see [docs/47](../docs/47-package-split.md)).

| Package | Overlay files | Hard dependency beyond `overlay-sync` | Why |
|---|---|---|---|
| `camera-hal` | the external camera HAL, `external_camera_config.xml` | `camera-gbm` | it only makes *more* apps willing to open a camera whose frames are black without that package |
| `battery` | the health HAL | — | the only overlay component with no companion: it reads the host's power supply through the container's own sysfs |
| `brightness-overlay` | the light `.rc` | `sensord` | the file exists to lose a name to that daemon; with no daemon there is nothing to lose it to |
| `wifi-framework` | the feature XML | — (`wifid` recommended) | alone it produces a Wi-Fi panel that fails honestly at "no wlan0", which is how Stage 0 was verified |
| `wifi-hostd` | `wificond.rc`, the supplicant VINTF manifest | `wifid` | standing wificond down with nothing behind it is worse than stock |

Three decisions inside those rows are worth keeping, because none is obvious from the file list:

- **`brightness-overlay` hard-requires `sensord`; `backlight` only recommends it.** Same daemon,
  different strength, and the difference is real. `backlight`'s SELinux label is correct before
  anything uses it and was staged that way. A stood-down HAL is correct only in the daemon's
  presence.
- **`wifi-framework` recommends `wifid`; `wifi-hostd` requires it.** The feature XML alone is a
  legitimate configuration — it is the Stage 0 experiment that proved the framework proceeds past
  a missing vendor HAL — so a hard dependency would forbid a thing that was deliberately done.
  `wifi-hostd` is the case [docs/47](../docs/47-package-split.md) names as the reason hard edges
  live on individual packages rather than on groups.
- **`camera-hal` ships the resolution cap, and the cap costs something.** Trimming every mode
  above 1280x720 is what stops the HAL picking 1080p and failing its own frame conversion, which
  is a black preview. A camera that can do 1080p is capped at 720p while the package is
  installed, so that is stated in the package description and not only in a comment.

**Verified before any of this is installed anywhere**, which is the check that made the second
migration safe and is the same one here:

- Seven overlay files hashed on bigtab01 against the five packages' payload. **Five are
  byte-identical.** The two that are not are the light `.rc` and `wificond.rc`, and the entire
  difference is one word in a comment — the live copies still say `CLAUDE.md` where the repo
  says `AGENTS.md`, left behind by the file rename. init does not read comments, so installing
  these packages would rewrite two files without changing their meaning, and there is nothing
  for a container restart to apply. Modes match on all seven.
- All six components reconciled into a scratch overlay by `waydroid-overlay-sync` with
  `STAGE_DIRS`/`OVERLAY_DIR`/`STATE_DIR` pointed at a temporary tree: nine files installed, a
  second run reports "overlay already matches the staged components", and `--verify` exits 0.
  The live overlay was not touched.
- `packaging/test-install.sh --all`: 101 passed, 0 failed.

**One cosmetic defect, not fixed here.** Every shipped manifest says `staged from
bigtab01-waydroid unknown`, because `stage-overlay.sh` reads the commit with `git rev-parse` and
inside `rpmbuild` it is running against an unpacked tarball with no `.git`. It is not new — the
`camera-gbm` manifest installed on bigtab01 says the same — and the version-release in the
package already identifies the build. Fixing it means stamping the commit into the tarball at
`build-mod.sh` time, which is a change to the shared machinery and does not belong in a batch
whose point was to add components without touching it.

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

### First real migration — done 2026-09-24

**Five packages are installed and in force on bigtab01**, which makes the "zero percent" answer
below historical rather than current. (Nine as of later the same day — the overlay half went in
afterwards, over two further migrations; see the two sections below this one.) `waydroid-ext-{sensord,btd,restartd,pidguard,backlight}`
are layered as `LocalPackages` on an otherwise unchanged base commit (`8b4dcffc…`); re-resolving
the layer also pulled 71 already-layered packages to current versions, which is inherent to how
rpm-ostree layering works and was not a base-image update.

The reboot alone changed nothing, exactly as predicted: `/usr/local/bin` precedes `/usr/bin` in
PATH and units in `/etc/systemd/system` outrank `/usr/lib/systemd/system`, so the packages sat
shadowed and inert until the hand-placed copies were removed. That shadowing is the trap in
this migration — install without removing and you have changed nothing while believing you
have. Verified after: all three units now resolve to `/usr/lib/systemd/system`, every binary
resolves into `/usr/bin` and `rpm -qf` names its package, and the running daemons are
`/usr/bin/python3 /usr/bin/waydroid-{btd,restartd}`.

Removed, after a backup to `~jmelanso/waydroid-handplaced-2026-09-24.tar.gz` (16 entries):
five binaries from `/usr/local/bin`, four units and three enable symlinks from
`/etc/systemd/system`, and the duplicate udev rule from `/etc/udev/rules.d` — that last only
after confirming it was byte-identical to the packaged one. **`waydroid-sensord` keeps running
from its deleted inode** (`/var/usrlocal/bin/waydroid-sensord (deleted)`) until the next session
start, which is harmless because the packaged binary is byte-identical to it.

Two pre-existing failures are visible in `systemctl --failed` and neither is ours:
`systemd-backlight@backlight:intel_backlight` failed at 21:30:02, before the removals at 21:33,
and failed identically on the previous boot; `systemd-remount-fs` has failed since 2026-09-12
with `overlay: No changes allowed in reconfigure`, which is ordinary read-only-root behaviour.

#### `systemctl is-enabled` reports `disabled`, and that is correct and harmless

Do not "fix" it. These packages ship the enable symlink inside
`/usr/lib/systemd/system/<target>.wants/` rather than running `systemctl enable` from a
scriptlet, because on an ostree host scriptlets run against the compose and not the booted
system. systemd honours those symlinks for activation — `systemctl show multi-user.target -p
Wants` lists `waydroid-btd.service` and `waydroid-restartd.service`, and `timers.target` lists
`waydroid-pidguard.timer` — but `is-enabled` defines "enabled" as a symlink under `/etc`, which
is deliberately not where these live. The units do start at boot; the word is a reporting
artifact of where the symlink lives.

#### Fixed: `waydroid-ext-backlight` did not load its policy on an ostree host

Found on the first real install and fixed the same day, in 1.0.1.

`backlight`'s `%post` ran `semodule -i`, and **it did not take.** Proved by looking at the
deployment's pristine `/usr/etc`, which is what the live `/etc` is merged from at boot: it held
`extra_varrun` and `permissive_bootupd_t` and no `waydroid_backlight`. The module was loaded on
the running system only because the hand-loaded copy from before the migration was carried
forward by that merge. The package installed, its SELinux half did nothing, and nothing
anywhere reported a problem — so the hand-loaded module was deliberately left in place rather
than removed as the migration plan originally had it, which would have broken brightness with
nothing to restore it.

The fix is the one `overlay-sync` already uses: the module is loaded at boot by
`waydroid-backlight-policy.service`, not from a scriptlet, and the enable symlink is shipped
rather than created by `systemctl enable`. `%post` still calls the loader, which makes the fix
immediate on an ordinary host and is a harmless no-op on ostree.

The loader is **idempotent by CIL hash, not by module name**. `semodule -l` answers whether a
module of that name is loaded, never whether it is *this* one, so an upgrade carrying a changed
policy would look already-done and be skipped; and `semodule -i` rebuilds the whole policy store
and takes seconds, so reloading unconditionally every boot would be a visible cost for nothing.
A stamp under `/var/lib/waydroid-backlight` records what was loaded.

Validated against the real host before shipping: `waydroid-backlight-policy --verify` on
bigtab01 reported `differs: waydroid_backlight (loaded unknown, packaged fdf43f5c…)` and exited
3 — correctly identifying the hand-loaded module as of unknown provenance — while changing
nothing. After the reboot it reported *already loaded and current*, with the stamp matching and
the label applied, which is what confirms the boot unit did the work rather than finding the
old module and shrugging.

#### And the regression that verification then exposed — fixed in 1.0.2

Once the packaged policy was in force, the one remaining failed unit turned out to be this
project's own doing. Relabelling `brightness` to a private type silently revoked
`systemd-backlight`'s access to it: the unit succeeded on 2026-09-09, failed on 2026-09-10 —
the day the module first landed — and had failed **978 times** since, leaving the host
permanently `degraded`. No AVC is logged for it even with `dontaudit` disabled, so the only
symptom is a bare `EACCES` with nothing implicating SELinux. Confirmed by experiment
(relabel to `sysfs_t` → succeeds; relabel back → fails) and fixed with one `allow init_t` line.
Full account in [docs/42](../docs/42-backlight-selinux.md). 1.0.2 is **installed** on
bigtab01 and the unit has finished cleanly on both boots since, which is what closes the
978-failure run; the full brightness sweep was re-run against the packaged stack on
2026-09-24 and passed.

The lesson generalises to every private type this project introduces: **a narrow type takes
access away as well as granting it**, so ask what else writes the file before narrowing it.

#### And the shadow that made 1.0.2 look like it worked when it had not

Verifying the fix after the reboot turned up a third thing, and it is the same trap as the
`/usr/local/bin` shadowing that Phase 3 was written to clear — in a location Phase 3 did not
cover. The loader searches `/usr/local/share/waydroid-backlight` before `/usr/share`, on
purpose, so a hand-staged policy can beat a packaged one on an immutable host. An unowned CIL
left over from the by-hand install was still sitting there, *without* the `init_t` fix. The
loader picked it, its hash matched the stamp, and it reported "already loaded and current"
while the policy actually in force was the old one — brightness worked only because the fixed
module happened to survive in `/etc` from a hand `semodule -i` before the reboot.

A sweep of `/var/usrlocal` — and it must be that path, because `/usr/local` is a symlink and
`find` will not follow it, which is an easy way to get a falsely clean result — showed exactly
one file shadowing a packaged one. The other thirteen hand-installed binaries there have no
packaged twin yet and are not shadows. Removing it made the loader pick the packaged CIL,
reinstall, and write the matching stamp.

1.0.3 makes this announce itself: the loader now says which file won whenever it is not the
packaged one, and says louder when the two differ. **The migration lesson is broader than
PATH**: when a modification moves from hand-installed to packaged, the old copy has to be
removed from *every* location the tool searches, not just from `/usr/local/bin` and
`/etc/systemd/system`. `waydroid-overlay-sync` has the same precedence design and will want
the same treatment before it is installed.

#### The first live package update — `sensord` 1.0.1, same day

Everything above landed at a boot. `waydroid-ext-sensord` 1.0.1 did not, and the way it went in
is worth recording because it removes a reboot from the loop for any one-file fix.

The change itself is one token — the daemon logged each brightness change at `GDEBUG`, which
`container_manager.py` has no way to enable, so `bin/brightness-test.sh`'s policy-independent
mapping check had never run on the real host. `GINFO` fixes it; [docs/42](../docs/42-backlight-selinux.md)
has the full account.

Three things learned putting it on the machine:

- **An upgrade is not additive, and `apply-live` is additive by default.** It counts the removal
  and the addition separately and refuses with `error: packages would be changed: 2, allow
  replacement to override`. `--allow-replacement` is the flag. The transaction itself is the
  ordinary `rpm-ostree uninstall <name> --install <file.rpm>` pair, which does both halves at
  once and reports a clean `Upgraded: waydroid-ext-sensord 1.0.0-1 -> 1.0.1-1`.
- **Live-applied is not live-running.** The daemon kept the old inode until the container was
  restarted — exactly the deleted-inode behaviour recorded above for the hand-placed copies,
  and for the same reason. Nothing re-execs a running process.
- **The file size was identical across the change**, 868088 bytes both sides, because flipping
  a log level changes one immediate operand and nothing about the layout. Only the inode and
  the hash distinguished them. Any deployment check that compares sizes, or eyeballs `ls -l`,
  would have reported this update as not having happened.

- **`LiveCommit` is how you check the apply landed, and whether a reboot is outstanding.**
  `rpm-ostree status` annotates the booted deployment with `LiveCommit` and `LiveDiff` once a
  live apply has happened. The running filesystem is consistent exactly when that hash equals
  the *pending* deployment's `Commit`:

  ```
  * fedora:fedora/44/x86_64/sericea      <- booted
                     Commit: 63d6f6c9…
                 LiveCommit: 8b954b23…   <- what is actually running
                   LiveDiff: 1 upgraded

    fedora:fedora/44/x86_64/sericea      <- pending
                     Commit: 8b954b23…   <- the same commit
  ```

  When they match there is nothing left to apply: the running system is already at the state
  the next boot lands on, whether that boot is planned or a power cut. A reboot then buys only
  the retirement of the `LiveCommit` line — worth taking opportunistically, since this project
  has twice lost time to something that looked installed and was not, but not worth the LUKS
  passphrase on its own.

The cost that remains is the container restart, which drops the kiosk to the SDDM greeter and
needs someone at the machine — but not the console, and not the LUKS passphrase.

### Second migration — the overlay half, done 2026-09-24

`waydroid-ext-overlay-sync` 1.0.0 and `waydroid-ext-camera-gbm` 1.0.0 are installed and live,
which makes **seven** `waydroid-ext-*` packages layered on bigtab01 and the Android-side half of
this project packaged for the first time. `waydroid-ext-backlight` went to 1.0.3 in the same
session, first and deliberately: 1.0.3 is the version that announces a `/usr/local` shadow, and
the thing being installed next has the same precedence design.

Be precise about what this closes, because the headline overstates it: the overlay holds **13
files and exactly 2 of them are now owned by a package.** What is fixed is the *mechanism* — a
wiped overlay repairs itself, and `waydroid-overlay-sync --verify` answers "is the overlay what
the packages say it should be?" in one command. The *coverage* is 2 of 13. The other 11 are still
hand-placed and unowned, and `waydroid init -f` still erases them with nothing to put them back:
`camera.device@3.4-external-impl.so` and `external_camera_config.xml`, the health HAL, the light
`.rc`, `wificond.rc`, `android.hardware.wifi.xml`, the supplicant VINTF manifest, and the four
Widevine files. Packaging those is the rest of this phase.

> **Seven of those eleven were packaged later the same day** — see *The five overlay components
> added 2026-09-24* above — and **two of those seven were installed in a third migration**, which
> took the coverage to 4 of 13. The other 9 files are still hand-placed. `camera-hal` and
> `battery` are built and held back on purpose, `wifi-hostd` is built and blocked on `wifid`, and
> the remaining four are Widevine's. See *Third migration* below.

**The docs have been saying 12 overlay files and three Widevine files; both are off by one, and it
is the same one.** The Widevine payload is four — `android.hardware.drm-service-lazy.widevine`, its
`.rc`, `manifest_android.hardware.drm-service.widevine.xml`, and `vendor/lib64/libwvaidl.so` —
presumably the one left out, being the only Widevine file whose name does not say Widevine.
Counted on the host rather than from the design notes: 13 files, 4 of them Widevine. Every "12" and "10 of the 12" elsewhere in this file and
in [docs/53](../docs/53-release-readiness.md) predates that recount.

#### Why this was safe to do with the container running, which is not the usual answer

Normally an overlay change needs `systemctl restart waydroid-container.service` and therefore
somebody at the machine. This one needed nothing, because it changed no bytes: the hand-placed
wrappers were already byte-identical to the packaged payload and already mode `644`, so the
reconciler's install loop — which skips on matching sha256 **and** mode — did nothing at all.
Checked on both sides before the transaction (`d74e5de0…` 64-bit, `ccf61a8e…` 32-bit) rather than
after, because "it probably matches" is not a reason to write into a mounted lowerdir.

Confirmed the way [AGENTS.md](../AGENTS.md) insists — from *inside* the container, not by `ls`:

```
# waydroid shell -- sh -c "sha256sum /vendor/lib64/libgbm_mesa_wrapper.so"
d74e5de03be83fa065a1f7daa64f9e8dd5aa2b28689e2532992df3ad3964d626  /vendor/lib64/…
```

So Android is reading the packaged bytes, and it was reading them before the install too. The
package took ownership of a fix that was already in force, which is the cheapest possible first
step and the reason to take it first.

#### The shadow sweep was empty, and that was checked rather than assumed

The lesson from `backlight` 1.0.2 is that a hand-staged file beats a packaged one silently. So
before installing: `/var/usrlocal` holds 14 binaries, two user units and
`share/waydroid-dexopt/dexopt.prop` — no `waydroid-overlay-sync` — and none of the four staging
directories the reconciler searches (`/usr/{lib,share}/waydroid-overlay`,
`/usr/local/{lib,share}/waydroid-overlay`) existed. It has to be `/var/usrlocal` and not
`/usr/local`: the latter is a symlink, `find` will not follow it, and the falsely clean result
looks exactly like a real one. 1.0.3 also printed no shadow note on the live host afterwards,
which is the new code path staying correctly quiet rather than not working.

#### `%post` could not do the reconcile, and that is the design

The package's `%post` runs `waydroid-overlay-sync --quiet`, and on this host it did nothing twice
over: scriptlets run against the compose, where there is no `/var/lib/waydroid` at all — so the
reconciler's preflight exits 0 with *waydroid is not initialised* — and `apply-live` does not run
scriptlets in the first place. `/var/lib/waydroid-overlay` was absent before the install and
appeared only once `waydroid-overlay-sync.service` was started by hand. That unit is the real
boot path, so starting it is what was verified, not the scriptlet.

> **`systemctl start` only works the first time, and the third migration found that out.** The
> unit is `Type=oneshot` with `RemainAfterExit=yes`, so once it has run it stays `active` and
> `systemctl start` on it is a silent no-op — exit 0, no journal line, no reconcile. The recipe
> above is correct exactly once per boot. Any later hand reconcile needs `systemctl restart
> waydroid-overlay-sync.service`, or the binary directly.

`deployed.list` then recorded **both** files even though neither had been rewritten, because the
state file is written from the wanted set rather than from what changed. That is what makes the
tool own a file it merely agreed with, so a later `camera-gbm` removal cleans up instead of
orphaning.

#### Self-repair was tested against a scratch overlay, not the live one

The claim worth proving is that a wiped overlay comes back. Run with `--overlay-dir` and
`--state-dir` pointed at `/tmp`, as an unprivileged user, against the real staged payload:

| | result |
|---|---|
| fresh materialisation into an empty overlay | both files placed, mode `644`, hashes correct |
| one file deleted, reconcile | restored, and only that one reported |
| one file edited, `--verify` | `differs: vendor/lib/libgbm_mesa_wrapper.so`, exit **3**, file untouched |
| same file, reconcile | restored to the manifest hash |

**Why a scratch directory and not the live overlay:** deleting a file from a *mounted* overlayfs
lowerdir is the same undefined behaviour this entire tool exists to warn about, and restoring it
produces a new inode under a mount that has already cached the old dentry. Testing self-repair on
the live overlay is legitimate either before the container starts or immediately after a restart;
doing it under the running kiosk session would have risked the camera for that session to learn
what a throwaway directory teaches for nothing.

#### One defect found, deliberately not fixed here

The *"The container is RUNNING, so none of the above is visible to Android yet"* warning fires on
any reconcile that changed something, with no check that `OVERLAY_DIR` is actually the
container's. In the scratch run it advised restarting the container over files written to `/tmp`.
Harmless there, but the advice is expensive — it ends a kiosk session — so a false one should not
be issued. Gate it on `OVERLAY_DIR` being the real overlay. Not fixed in this session on purpose:
it is a code change to a package that was just installed and verified, and it belongs in the next
version alongside the remaining overlay components.

#### Two verification details worth reusing

- **`rpm -V` reports `.......T.` on every file of all three packages, and that is mtime only** —
  an ostree checkout artifact, not drift. Size, mode, digest, owner and capabilities all match.
  Checked against packages nobody touched this session: `waydroid-ext-btd` and `waydroid-selinux`
  each have **0** lines that are not mtime-only. (Fedora's own `waydroid` has 42, which is its own
  story and not ours.) Without that comparison the output reads as twenty-one modified files.
- **`LiveCommit` `19258cf9…` equals the pending deployment's `Commit`**, so the running system is
  already what the next boot lands on and nothing is owed. A reboot now buys only the retirement
  of the `LiveCommit` line.

`backlight` 1.0.3 cost no policy rebuild: the CIL is unchanged from 1.0.2, so the stamp already
matched (`ac8cb72e…`), `semodule` was not re-run, and `--verify` reports *already loaded and
current* with `waydroid_backlight_t` on the attribute. `systemd-backlight` has stayed off
`systemctl --failed` — the only failed unit is `systemd-remount-fs`, failing since 2026-09-12 and
ordinary read-only-root behaviour.

### Third migration — two more overlay files, done 2026-09-24

`waydroid-ext-wifi-framework` 1.0.0 and `waydroid-ext-brightness-overlay` 1.0.0 are installed and
live. That makes **nine** `waydroid-ext-*` packages layered on bigtab01 and takes the overlay from
**2 of 13 files owned to 4 of 13**. `LiveCommit a370a645…` equals the pending deployment's
`Commit`, so the running system is again already what the next boot lands on.

Two of the five components from that batch were held back, for unrelated reasons:

- **`wifi-hostd` is blocked, not deferred.** It requires `waydroid-ext-wifid`, which has no binary
  RPM because `wifi/build.sh` has no `--rpm` mode. Building that is the prerequisite, and it is
  the same item already recorded in `wifid.mod`.
- **`camera-hal` and `battery` were held out on purpose.**
  [docs/54](../docs/54-no-vendored-binaries.md) is about to change their payload from a patched
  vendor binary into a derived row, and installing a version whose shape is about to change is how
  a machine ends up with two answers to where a file comes from.

#### One file was free and one was not, and which was which was known before the transaction

`wifi-framework`'s payload was byte-identical to the live file (`21e1bd1e…`) at mode `644`, so the
reconciler skipped it, exactly as it skipped both camera wrappers in migration 2.
`brightness-overlay`'s was not. The live light `.rc` differed from the packaged one by **one word
in one comment** — `CLAUDE.md` where the repo now says `AGENTS.md`, line 53, left behind by the
file rename. `--verify` before the reconcile named that one file and nothing else, exit **3**.

So this migration deliberately did the thing migration 2 was able to avoid: it wrote into a
mounted overlayfs lowerdir. The shadow sweep was empty again beforehand — no `/usr/local` staging
directories, nothing matching `*waydroid-overlay*` under `/var/usrlocal`, and
`waydroid-overlay-sync` resolving to `/usr/bin`. `overlay_rw` was empty too, so nothing was masking
the layer.

#### `install` replaces the inode on this host, so Android's view went stale instead of updating

The write was predicted to be safe on the grounds that `install -D -m` truncates in place and
keeps the inode, leaving the mount's cached dentry valid. **On bigtab01 it does not.** Measured
across the reconcile:

| | before | after |
|---|---|---|
| inode | `2005375` | `2405078` |
| sha256 on disk | `9e842e3d…` | `71f2b6fa…` (the manifest hash) |
| sha256 **read from inside the container** | `9e842e3d…` | `9e842e3d…` — unchanged |

The file did not vanish; Android still reads it, at 3087 bytes with its original mtime. It is
simply the *old* bytes, because the mount had already cached the inode the reconcile replaced.
That is the same invisibility AGENTS.md documents for files *added* to a mounted lowerdir, and it
applies just as much to files *modified* there.

SELinux is not the cause and was ruled out on the host: a probe with source and destination
carrying the same label, on the same filesystem, replaces the inode too. The visible difference is
the coreutils version — `install` is 9.10 on bigtab01 and 9.7 on the development box, where the
same probe keeps the inode. Either way the lesson is the version-independent one: **do not reason
about what a lowerdir write does from a test run on a different machine.**

The consequence here is nil, because the difference is a comment and `init` reads the file only at
container start, which is also when the view becomes consistent again. The consequence in general
is not nil, and it is the argument for keeping the byte-identical check in front of every future
migration rather than treating it as a formality.

#### What was verified

- `--verify` exits **0** and reports *overlay matches the staged components*.
- `deployed.list` now records **four** files — the two camera wrappers plus
  `system/etc/permissions/android.hardware.wifi.xml` and the light `.rc` — so a later removal of
  either package cleans up after itself instead of orphaning.
- Staged payload in `/usr/lib/waydroid-overlay/` hashes equal to the shipped manifests for both
  new components.
- The reconcile ran from the unit, not the binary, because the unit is the boot path. It took a
  `systemctl restart` to do it; see the note under the second migration for why `start` did
  nothing.
- The container was never restarted and the kiosk session survived the whole migration.

## What was deployed on bigtab01 before that — audited 2026-09-15

**None of it. Zero percent of this project's output was installed as an RPM.** Every spec above was
written and payload-verified; none had been built, and `rpm -qa` on the host listed only Fedora's own
`waydroid` and `waydroid-selinux`. Everything this repository produced was hand-placed, and survived
only because nothing had overwritten it. The five packages above are the first part of that to
change; the rest of the table below still stands.

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
| `/var/lib/waydroid/overlay` | 13 Android files — the camera wrapper for both ABIs, the camera HAL and its config XML, the health HAL, the light `.rc`, four Widevine files, the Wi-Fi feature XML, `wificond.rc` and the supplicant manifest (recounted 2026-09-24; this row said 12) | 13 |
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

> **Partly resolved 2026-09-24.** `waydroid-overlay-sync` is now installed and reconciles on every
> boot, so the mechanism is in force — but for 4 of the 13 overlay files after the third migration,
> not all of them, and the
> staging directory is `/usr/lib/waydroid-overlay` rather than the `/usr/share` path named above.
> The sentence in AGENTS.md was accurate about the design and wrong about the deployment; it is now
> accurate about both, with the coverage stated. See *Second migration* above.

**The practical risk this leaves** is the one the specs exist to close: a `waydroid upgrade` or
`waydroid init` erases the LXC config edit and the overlay, and nothing reinstalls them; an
rpm-ostree deployment rollback keeps `/var` but nothing reconciles `/usr/local` against what the
repo expects. Today the recovery is a human re-running installers from this tree.

> **Still true for 11 of the 13 overlay files, and for the LXC config edit**, as of 2026-09-24.
> `camera-gbm`'s two files now repair themselves; nothing else in that list does. Seven more of
> the eleven now have a package that *would* repair them, but the packages are built and not
> installed, and a package on the dev box repairs nothing on bigtab01.

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
