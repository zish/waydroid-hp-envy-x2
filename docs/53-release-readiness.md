# What stands between here and a repository anyone can install from

*2026-09-22.*

The owner configured a GitHub origin (`git@github.com:zish/waydroid-hp-envy-x2.git`) and asked,
before pushing anything, whether the project is actually in a state somebody else could use:
is everything packaged, are the docs enough, are the paths portable, is anything unpackageable,
and what should CI look like. This note is the audit that answered that, plus the two things
fixed on the spot.

Nothing here is hypothesis unless it says so. Every count was taken from the tree or from the
built packages, not from the design documents — which is the point, because the design documents
are ahead of the code in several places and reading them alone gives the wrong answer.

## The short version

| Question | Answer |
|---|---|
| Is every change available as an RPM? | **No — 7 modifications written of ~36 named, and only 4 of those 7 install** |
| Could a general user build and install? | **No** — the two compiled daemons cannot be built off this dev box at all |
| Are repository paths portable? | **Nearly** — 5 exceptions, all named below; git history is no worse than HEAD |
| Anything genuinely un-RPM-able? | **Four things**, all small, none of them blocking |
| lefthook + GitHub Actions? | Good fit, with a clear split: lefthook is the gate, Actions is the pipeline |

## Packaging coverage, measured rather than assumed

[docs/47](47-package-split.md) names ~33 packages, plus `restartd`, `pidguard` and `btd` added
afterwards — about **36**, excluding the APK packages. `packaging/mods/` holds **7**.

That ratio is the optimistic reading. The pessimistic one comes from asking `rpm` what the built
packages actually require:

```
$ rpm -qp --requires build/rpm/RPMS/*/*.rpm
```

| Built RPM | Installable today | Why not |
|---|---|---|
| `waydroid-ext-btd` | **yes** | — |
| `waydroid-ext-pidguard` | **yes** | — |
| `waydroid-ext-restartd` | **yes** | — |
| `waydroid-ext-backlight` | yes, but inert | needs `waydroid-ext-sensord`, which has no `.mod` |
| `waydroid-ext-camera-gbm` | **no** | `Requires: waydroid-ext-overlay-sync` — no such package |
| `waydroid-ext-camera` | **no** | requires `camera-hal` and `uvc-autosuspend` — neither exists |
| `waydroid-ext-wifid` | **no** | SRPM only |

**`waydroid-ext-overlay-sync` is the keystone and it is missing.** Every overlay component hard-
requires it by design, and it has no `.mod` file. So the entire Android-side half of the project —
all 12 overlay files, including the camera fix that is nominally the one packaged feature — is
unreachable by RPM. `packaging/README.md` already says zero percent of this project is installed
as an RPM on bigtab01; what it does not say is that even the packages that *build* could not be
installed if somebody tried.

### A third reason `wifid` cannot do a full build, which nobody had written down

[packaging/mods/wifid.mod](../packaging/mods/wifid.mod) sets:

```
BUILD='sh wifi/build.sh --rpm'
```

`wifi/build.sh` accepts `--deps`, `--check`, `--install` and `--unit`, and its argument parser
ends with `*) echo "unknown argument: $1" >&2; exit 2`. **There is no `--rpm` mode.** The
generated spec's `%build` would fail before `libgbinder-devel` or the shared `install.sh` — the
two reasons `packaging/README.md` does record — ever came into it.

This is the same class of finding as the rest of docs/47's "what building actually found"
section: the only thing that catches it is running it.

### What is unpackaged, by feature

Cross-referencing `packaging/README.md`'s host audit against the seven mods: `sensord` and its
`ILight` half, `mediad`, `wifi-sync`, the cage session, graceful exit and shutdown,
android-power, binder-nice, uvc-autosuspend, mdns, dexopt, the ITE8350 resume machinery, the
`lxc.net.0.name` edit, and **10 of the 12 overlay files** — the camera HAL and its config XML,
the health HAL, `wificond.rc`, the light `.rc`, the Wi-Fi feature XML, the supplicant VINTF
manifest, and all three Widevine files.

## Documentation: not enough, and the gap is structural

[README.md](../README.md) is a good front door and is honest that nothing is published.
[docs/user/overlay.md](user/overlay.md) and [docs/user/lxc-config.md](user/lxc-config.md) are the
right shape for somebody who has just installed a package. What is missing is everything between
those two points. There is no `BUILDING.md` and no `INSTALL.md`.

The blocking item is not a missing page:

- **The two compiled daemons cannot be built by anyone but us.** `sensors/build.sh --deps` and
  `wifi/build.sh --deps` `scp` `libgbinder.so.1.1.47` and `libglibutil.so.1.0.82` **off
  `10.42.0.137`**, deliberately, so the ABI cannot drift. That is the right answer for a dev box
  that cannot compile against Fedora's headers; it is not a build anybody else can run, and there
  is no documented native path (`dnf install libgbinder-devel && …`). The `--rpm` mode that was
  supposed to *be* that path does not exist, per above.
- **APK builds deploy to a hardcoded account** and download 757 MB of toolchain with no
  prerequisites page.
- **Prerequisites live only in script headers** — JDK 17/21, `rpm`, `rpmlint`, aapt2/d8/apksigner
  — and are never collected anywhere.

Two pieces of doc drift a reader would hit immediately:

- [README.md](../README.md) line 87 and [docs/user/overlay.md](user/overlay.md) line 43 both say
  payload lands in `/usr/share/waydroid-overlay/`. docs/47 moved it to `/usr/lib/waydroid-overlay`
  on rpmlint's advice. It *works* — `waydroid-overlay-sync` searches both, deliberately — but the
  user-facing pages describe the superseded layout. `artifacts/overlay/install.sh` also still
  stages to `$PREFIX/share` while `artifacts/overlay-manager/install.sh` uses `$PREFIX/lib`.
- `packaging/README.md` opens by saying the four-spec layout is "superseded in design, not yet in
  code", which leaves a reader unable to tell which of two packaging systems to use.

## Paths: the discipline holds, with five exceptions

The repo-relative habit is real and consistent. Every build and install script resolves itself
(`src=$(dirname "$0")`, `repo=$(cd "$here/.." && pwd)`); all nine `OUT=` defaults are
`$repo/build/…`; every `.mod` `SOURCES` and `DOCS` path is repo-relative; and the *daemons* and
test scripts glob `/home/*/.local/share/waydroid/data` rather than naming a user.

**The whole history was scanned, not just HEAD** — `git grep` for non-system absolute roots
across all 94 revisions of master. It returns the same file-and-line set as the working tree:
no path was ever committed and later cleaned up, so there is nothing hiding in the history that
a rewrite would be needed to remove.

The exceptions, in rough order of how much they matter:

1. **Hardcoded username, not overridable** — the remote Waydroid data directory in six APK build
   scripts: `drm-probe/build.sh:41`, `quat-monitor/build.sh:46`, `touch-probe/build.sh:52`,
   `sensor-app/build.sh:178`, `bt-app/build.sh:140-141,163`, `media-app/build.sh:146-147`. The
   daemons get this right and the build scripts do not. Fixing it is one `WDATA=${WDATA:-$(ssh
   "$HOST" 'echo ~')/…}` or a glob, per script.
2. **Dev-box paths as defaults** — `phase2/build.sh:26-27` defaults `MINIGBM` and `OUT` to
   `/home/coder/extra_space/…`. Overridable, but `MINIGBM` has no in-repo equivalent, so that
   build is not reproducible elsewhere regardless.
3. **`HOST` defaults to `10.42.0.137`** in nine build scripts and `bin/rsh`. Overridable and
   documented; worth noting only because it is a private LAN address in a public repository.
4. **`$HOME/ndk-dl/android-ndk-r27c`** in `phase1/build.sh` and `phase2/build.sh`. Overridable
   via `NDK`.
5. **Eight wrong self-URLs.** Fixed this session — see below.

Acceptable and left alone: `bin/removable-probe.sh:20` falls back to `jmelanso` only when both
`$SUDO_USER` and `$USER` are unset.

## What genuinely cannot be applied and unapplied by RPM

Most of the gap is "not written yet" rather than "impossible". Four things are actually outside
RPM's reach, and all four are small:

- **Android settings living in `/data`.** `use_compaction=true` via `device_config`
  ([docs/43](43-app-freezer.md)) and `sysui_qs_tiles` for the Bluetooth tile
  ([docs/50](50-bluetooth.md)). Both need `system_server` already running, so no scriptlet and no
  `ExecStartPre` can reach them — only an `ExecStartPost` one-shot — and both are lost on a
  framework restart or factory reset anyway. A package can ship the tool; it cannot own the state.
- **APK installation.** RPM can stage the file; `pm install` needs a live container.
- **The Widevine CDM.** Licensing makes it a fetcher rather than payload, so an uninstall removes
  the fetcher, the `.rc` and the VINTF manifest but orphans the blob in
  `/var/lib/waydroid-overlay/fetched/` unless the package `%ghost`s it.
- **`/var/lib/waydroid/overlay_rw/`.** Anything a user put there outranks our lowerdir and no
  package can touch it. `waydroid-overlay-sync` reporting it as `shadowed:` is the correct
  response and already exists.

One edge worth stating plainly because it is the only one of its kind:
**`/etc/avahi/avahi-daemon.conf` cannot be cleanly unapplied.** It has no drop-in directory
(verified on the host — `avahi-daemon` contains no `conf.d` path string), so it is an in-place
edit of another package's file. Afterwards `rpm -V avahi` lies and the file stops tracking
avahi's own updates. docs/47 already prescribes the idempotent-reconciler treatment; there is no
version of it that leaves no trace.

Everything else — `lxc.net.0.name`, the dexopt properties, the firewalld rule — fits the
reconciler pattern `artifacts/dexopt/install.sh` already implements. The firewalld one should
stop being a file edit at all: `firewall-cmd --permanent --add-rich-rule` is additive, named and
removable.

## CI/CD: lefthook as the gate, Actions as the pipeline

They compose well. lefthook is a single static Go binary with no runtime; there is no first-party
Action but installing it is one step. The reason to adopt it is that the same job definitions run
locally and on the runner — `lefthook run pre-push --all-files` in CI — so a check cannot pass
locally and mean something different upstream.

Four things to know before wiring it:

- In CI you never run `lefthook install` (that writes `.git/hooks`); you only `lefthook run`.
- **`lefthook run pre-commit` with nothing staged checks nothing.** `--all-files` is mandatory in
  CI, and `{staged_files}` templating is empty there — use `{all_files}`.
- `skip` / `only` can key off the `CI` environment variable, so slow checks run only on the
  runner and fast ones only locally.
- **lefthook is not a CI engine.** No matrix, artifacts, caching, secrets or scheduling. Building
  and signing RPMs, `createrepo_c`, `fdroid update` and the Pages deploy are Actions jobs.

### The checks worth adding, given what this repository actually is

Pre-commit, fast and offline: **shellcheck** is the single highest-value check here — there are
50+ shell scripts including every `install.sh`, and they are the packaging's `%install` steps.
Plus `shfmt`, `ruff`, and `gitleaks`.

Actions only, because they need network or a vulnerability database: **rpmlint as a gate**
(`build-mod.sh --lint` already runs it), `bandit` on the Python daemons, `ktlint`/`detekt` on the
Kotlin apps, **CodeQL for C++** (free on public repositories — `wifi/` and `sensors/` are
binder-facing C++), **Trivy or Grype plus a `syft` SBOM** (the real exposure here is the committed
prebuilt Android `.so` blobs), and `rpm -K` after signing. Do not put scanners in pre-commit:
Trivy's database alone is 50–200 MB.

### One blocker for the F-Droid half

Every APK build script auto-generates a **debug keystore with the password `android`** if one is
missing — `media-app/build.sh:124-132` and the same block in the other four. F-Droid needs a
stable, real signing key held in Actions secrets, and if the keystore is ever lost, updates break
for every installed user. This has to be fixed before any APK is published anywhere.

### Storage, measured

| | Size |
|---|---|
| Repo clone | **10 MB** (`git count-objects -vH`: 10.23 MiB) |
| Built RPMs today | 0.9 MB total; largest is `camera-gbm` at 636 KB |
| Full ~36-package set, projected | **4–6 MB per version**, plus ~2 MB of SRPMs |
| One APK | 699 KB (`removable-media.apk`, measured) |
| Android toolchain (`build/android`) | **757 MB**; ~470 MB if the zips are discarded after extraction |
| C++ daemon build | ~5 MB of output — the 129 MB in `build/wifi` is disassembly evidence, not build input |
| NDK r27c, only if the minigbm wrapper is rebuilt | ~2.3 GB download, **~6.5 GB extracted** |

Per-job ephemeral disk: ~2 GB for an RPM job, ~1.5 GB for an APK job, ~8 GB if the camera wrapper
is ever rebuilt. GitHub-hosted runners give roughly 14 GB on `/` and 65 GB on `/mnt`, so all three
fit — but **the NDK is not needed in CI at all**, because the built wrapper is already committed
at `artifacts/phase2/*.so`.

Cache: only the Android toolchain is worth caching, ~300–400 MB compressed against a 10 GB
default limit. Published repositories: an RPM repo with ten versions retained is ~50 MB, an
F-Droid repo ~20–50 MB, against GitHub Pages' 1 GB site cap and 100 GB/month soft bandwidth
limit. None of this is close to a constraint. On a public repository Actions minutes and storage
are free.

## Done this session

**All commits in a branch must now be signed before they can be pushed.**
[bin/check-signed-commits.sh](../bin/check-signed-commits.sh) is wired two ways: a generated
`.git/hooks/pre-push` shim that works today, and a [lefthook.yml](../lefthook.yml) `pre-push` job
for when lefthook is installed. `lefthook install` replaces the shim with its own dispatcher,
which reaches the same script — so the handover is seamless, but a broken `lefthook.yml` would
silently drop the gate.

The check reads `%G?` rather than shelling out to `git verify-commit`, which exits non-zero for
both "bad signature" and "no signature" and would need gpg's output parsed to tell them apart.
`G` and `U` pass; `U` only means the key is not marked trusted *in this keyring*, which is a
property of the checking machine and would make the hook behave differently on a fresh clone.
`X` and `Y` (expired keys) fail, on the grounds that a signature which cannot be re-verified
later is not much better than none. `ALLOW_UNSIGNED_PUSH=1` is the escape hatch and is
deliberately loud, with no config setting, so it cannot be switched on once and forgotten.

All **94 commits on master are already signed** (`%G?` = `G` for every one), so the gate cost
nothing to adopt. Full run is 0.29 s.

**The eight wrong self-URLs are fixed.** Three systemd `Documentation=` lines pointed at
`github.com/jmelanso/bigtab01-waydroid/blob/main/…` — wrong account, wrong repository, and a
branch that does not exist — and five spec `URL:` fields at `github.com/zish/bigtab01-waydroid`,
right account, wrong repository. All now point at `github.com/zish/waydroid-hp-envy-x2`, and the
`Documentation=` lines use **`/blob/HEAD/`** rather than naming a branch, so a rename cannot break
them again.

Nine other `bigtab01-waydroid` strings were left alone on purpose: they are the *project* name,
not the repository name, and one of them — `sensors/Sensors.h:35`'s `kVendor` — is a runtime
string Android reports through the sensors HAL, so changing it changes observable behaviour.

## Two things to know before the first push

- **The remote is not empty.** `git ls-remote` shows `refs/heads/master` at
  `5eae25dd2942eb5c58f32e11ec8507d91b3ec498`, a commit not present locally, and remote `HEAD`
  points at `master` (so the default branch is `master`, not `main`). The first push will be a
  non-fast-forward and will need `--force-with-lease` or a deliberate reconcile.
- **There are no remote-tracking refs locally** (`git branch -r` is empty — nothing has been
  fetched). The pre-push hook handles this: when the remote sha git hands it is one we do not
  have, it falls back to checking every commit reachable from the tip, which is the stricter
  reading anyway.

## To do, in the order it is worth doing

1. **Build the RPMs.** This is the next session's work — see
   [docs/06-next-session.md](06-next-session.md). Start with `waydroid-ext-overlay-sync`, because
   nothing overlay-shaped can install without it and two already-built packages are blocked on it.
   Then implement `wifi/build.sh --rpm` and give `artifacts/wifi/install.sh` the component
   argument that `artifacts/overlay/install.sh` already has, which unblocks `wifid`'s `-ba`.
2. **Move the APKs into their own GitHub repositories**, one per app, each with its own CI/CD.
   Added at the owner's request, 2026-09-22. There are six — [media-app/](../media-app)
   (`lan.syshlt.removablemedia`), [sensor-app/](../sensor-app) (`…sensorinfo`),
   [bt-app/](../bt-app) (`…bluetooth`), [quat-monitor/](../quat-monitor) (`…quatmon`),
   [drm-probe/](../drm-probe) (`…drmprobe`) and [touch-probe/](../touch-probe)
   (`…touchprobe`) — and they have nothing in common
   with the host packaging: a different toolchain (757 MB of SDK and kotlinc against `rpmbuild`),
   a different distribution channel (F-Droid against an RPM repo), a different signing story
   (an Android keystore against a GPG key), and a release cadence that has no reason to match.
   Keeping them here means every APK change drags the RPM pipeline along and vice versa. Fix the
   debug-keystore problem above as part of the move, not after it — a published APK signed with a
   throwaway key cannot be un-published.
   One decision the owner still has to make: only three of the six are *products* — Removable
   Media, Sensor Info and Bluetooth. `quat-monitor`, `drm-probe` and `touch-probe` are
   instruments, built to settle a question and read once
   ([docs/20](20-quat-monitor.md), [docs/21](21-netflix-widevine.md), and the multitouch
   count respectively), and publishing them to F-Droid would be publishing a debugging tool as
   an app. They may be better as one `waydroid-probes` repository, or as branches of the notes
   they belong to. The three products are the F-Droid candidates.
3. **Write `BUILDING.md`.** Prerequisites in one place, and a native build path for the two
   daemons that does not involve copying `.so` files off bigtab01.
4. **Reconcile the two packaging systems** — retire the four legacy specs or say clearly in
   `packaging/README.md` which one a reader should use.
5. **Fix the six hardcoded `jmelanso` paths** in the APK build scripts. Cheapest if done during
   the repository split, since those scripts are moving anyway.
