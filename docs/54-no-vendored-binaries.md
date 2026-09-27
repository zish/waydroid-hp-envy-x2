# 54 — No binaries from external sources, and what that costs

**Policy set by the owner on 2026-09-24**, recorded in [AGENTS.md](../AGENTS.md) under
*Repository conventions*: do not commit a binary that came from somewhere else. If a package
needs one, it is obtained at RPM install time or inside Android, never carried in this
repository.

This note is the inventory it applies to and the migration out. **The packages comply as of
2026-09-26; the repository does not yet.** `camera-hal` 2.0.0 and `battery` 2.0.0 ship a patch
instead of a patched binary, and every stock tripwire is now a bare hash rather than a copy of the
file it watches — so no RPM this project builds carries a third-party binary any more, and the
files those packages used to need are referenced by no `.mod`. What remains is Widevine, which is
genuinely not on the user's disk and needs the fetcher, and the question of deleting the
now-unreferenced files from the tree and from the history. Build output this project produced is a
separate case and was ruled compliant the same day — see *What we built is not external*, below.

## The inventory

Every tracked binary, what it is, and where it came from. Sizes are the files themselves, not
their weight in git history — see *Deleting them from `HEAD`…* for why that distinction matters.

| File | Bytes | Provenance | Shipped by | Verdict |
|---|---|---|---|---|
| `artifacts/camera/…impl.so.orig` | 407,412 | LineageOS 20 `vendor.img` | — (tripwire) | **violates** — becomes a hash |
| `artifacts/camera/…impl.so.back` | 407,412 | same, one byte patched | `camera-hal` | **violates** — becomes a patch |
| `artifacts/camera/…impl.so.front` | 407,412 | same, one byte patched | — (never deployed) | **violates** — becomes a patch, or goes |
| `artifacts/health/…waydroid.orig` | 82,544 | LineageOS 20 `vendor.img` | — (tripwire) | **violates** — becomes a hash |
| `artifacts/health/…waydroid` | 82,544 | same, five bytes patched | `battery` | **violates** — becomes a patch |
| `artifacts/lib/libgbm_mesa_wrapper.so` | 28,680 | Waydroid image, stock | — (tripwire) | **violates** — becomes a hash |
| `artifacts/lib/libgbm_mesa_wrapper-32.so` | 24,172 | Waydroid image, stock | — (tripwire) | **violates** — becomes a hash |
| `artifacts/lib/android-libgbm_mesa.so` | 13,752 | Waydroid image, stock | — (reference) | **violates** — becomes a hash |
| `artifacts/lib/android-libgbm_mesa-32.so` | 12,796 | Waydroid image, stock | — (reference) | **violates** — becomes a hash |
| `artifacts/widevine/…drm-service-lazy.widevine` | 12,056 | Google prebuilt, ChromeOS `nissa` | (planned) `widevine` | **violates** — fetched at install |
| `artifacts/widevine/…libwvaidl.so` | 2,960,376 | Google prebuilt, ChromeOS `nissa` | (planned) `widevine` | **violates** — fetched at install |
| `artifacts/phase2/libgbm_mesa_wrapper-fixed-64.so` | 1,068,888 | **our own NDK r27c build** | `camera-gbm` | **compliant** — ours, on a signed commit |
| `artifacts/phase2/libgbm_mesa_wrapper-fixed-32.so` | 1,070,036 | **our own NDK r27c build** | `camera-gbm` | **compliant** — same |
| `artifacts/acpi/*.aml` (7 files) | 148,480 | **this machine's own firmware** | never | out of scope — evidence, not payload |
| `artifacts/hid/*.rd` (2 files) | 8,192 | **this machine's own devices** | never | out of scope — same |

**4,439,156 bytes — 4.23 MiB — came from a third party.** Two thirds of that is Widevine. The
2.04 MiB of `artifacts/phase2/` is not in that figure: it is ours, and it stays (see below).

`bin/__pycache__/magn-calibrate.cpython-313.pyc` is also tracked, and is neither evidence nor
payload: it is build spoil that predates the `.gitignore` entry covering it. Delete it.

## What makes this cheap: the bytes are already on the user's machine

`camera-hal` and `battery` are a **one-byte** and a **five-byte** patch of files that ship inside
Waydroid's own `vendor.img`. There is nothing to fetch from anywhere, because every user who can
run these packages already has the input.

Verified on bigtab01, 2026-09-24, **unprivileged — no `sudo`, no loop mount, no `mount` at all**:

```
$ file -b /etc/waydroid-extra/images/vendor.img
Linux rev 1.0 ext2 filesystem data, … volume name "vendor" (extents) …

$ debugfs -R "dump /lib/camera.device@3.4-external-impl.so /tmp/s1" \
      /etc/waydroid-extra/images/vendor.img
$ debugfs -R "dump /bin/hw/android.hardware.health@2.0-service.waydroid /tmp/s2" \
      /etc/waydroid-extra/images/vendor.img
$ sha256sum /tmp/s1 /tmp/s2
95b1b3e4ff6d17ce7cd56086626b6cbc0db7c70fd49760b57414f8128c91dd69  /tmp/s1
de3cf6bc2565079893dbc3db5c52791c30b168df9c3684e4b4857db4a483a79b  /tmp/s2
```

Both hashes are **exactly the `# stock` rows already written into
`camera-hal.manifest` and `battery.manifest`** by `packaging/stage-overlay.sh`. The manifest
format has been recording the one number this design needs since the day it was written; it was
recording it for a `--check-upstream` that was never implemented.

The images are `0644 root:root` and `images_path` is in `waydroid.cfg`, so a reconciler running as
root at boot certainly can read them, and so can an ordinary user. `debugfs` is `e2fsprogs`,
which is already a dependency of anything that made those images.

## The three mechanisms this needs

All three are changes to the same two places — `packaging/stage-overlay.sh` and
`waydroid-overlay-sync` — and therefore **a version bump of `waydroid-ext-overlay-sync`, the
keystone package already installed on bigtab01.** That is the real cost of this policy: it is a
migration of the thing every other overlay component depends on, not an edit to five `.mod`
files.

**Built 2026-09-26 as `waydroid-ext-overlay-sync` 1.1.0: mechanisms 1 and 3 are done, 2 is
deferred with Widevine.** Every component using a new row type carries
`Requires: waydroid-ext-overlay-sync >= 1.1.0`, so an older reconciler cannot be handed a manifest
it would misread — and the new row types are keyword-led rather than hidden behind a `#` for the
same reason, so that an older one fails loudly instead of finding no rows it recognises and
reporting success. 37 checks in [bin/overlay-sync-test.sh](../bin/overlay-sync-test.sh) cover it
against a real ext2 image. **Built here, not deployed there: bigtab01 still runs 1.0.0.**

1. ~~**A derived row.**~~ **Done.** As built it is
   `derive <mode> <image> <path in image> <stock sha256> <result sha256> <patches> <path>`, the
   patch list inline as comma-separated `<hex offset>:<old>:<new>` — so a derive row adds no file
   to the package at all and the manifest stays the single source of truth. The reconciler extracts
   with `debugfs` (read-only and unprivileged: the images are 0644 ext2), refuses if the hash is
   not the recorded stock hash, applies the offsets, refuses if the result hash is wrong, and
   installs. One refused row does not abandon the rest of the overlay, which was verified rather
   than assumed. The refusal is the feature: a stock hash that stopped matching means the image
   changed under a file we silently replace, which is precisely the alarm
   [docs/47](47-package-split.md) specified and never built. `--check-upstream` now asks that same
   question of every row recording a stock hash, changing nothing, which is its other half.
2. **A fetched row**, for Widevine only — the one case where the bytes genuinely are not on the
   machine. Download the pinned archive, verify its digest, extract, install. `%ghost` in
   `%files`. Already designed in [docs/47](47-package-split.md).
3. ~~**A hash-only tripwire.**~~ **Done.** The fourth column of a `FILES` row may now be the
   sha256 itself, and all five overlay components that had one were converted. Same manifest
   output, same `--check-upstream` value. `artifacts/lib/*.so` and every `….orig` are now
   referenced by nothing that builds — but **they are still in the tree on purpose**, for one
   session longer: they are the oracle [bin/overlay-sync-test.sh](../bin/overlay-sync-test.sh)
   asserts the derived bytes against, and removing them is entangled with the history-rewrite
   decision below, which is the owner's to make. The policy win is banked either way, because no
   package carries them.

A symlink row is also outstanding, for Widevine's `libprotobuf-cpp-lite.so`. It is unrelated to
this policy and is recorded in [docs/47](47-package-split.md).

## What this does to the five packages built on 2026-09-24

| Package | Payload | Affected | As of 2026-09-26 |
|---|---|---|---|
| `camera-hal` | vendor `.so` + XML | **yes** — the `.so` must become a derived row | **2.0.0**: derive row, plus the XML as a plain row with a bare stock hash. 36 KB tarball, from ~600 KB |
| `battery` | vendor binary | **yes** — must become a derived row | **2.0.0**: derive row. The RPM is one manifest and a doc directory, nothing else |
| `brightness-overlay` | one `.rc` | no — text, written here | 1.0.1, stock hash inlined |
| `wifi-framework` | one XML | no — text, AOSP-shaped but written here | unchanged: it replaces nothing, so it never had a tripwire |
| `wifi-hostd` | one `.rc` + one XML | no — text, written here | 1.0.1, stock hash inlined |

So three of the five were already compliant and can migrate to bigtab01 whenever the owner wants.

~~**`camera-hal` and `battery` should be held out of the third migration.**~~ **The reason for that
hold is gone**: the shape that was about to change has changed, and both are 2.0.0. What replaces
it is narrower and firmer — both hard-require `waydroid-ext-overlay-sync >= 1.1.0` and bigtab01
has 1.0.0, so **the keystone must migrate first or rpm will refuse them.** That is worth having
caused deliberately: it is the dependency mechanism doing the job the "two answers to where does
this file come from" argument was standing in for.

**The deployed bytes do not change.** Deriving from the stock file in `vendor.img` reproduces
exactly what 1.0.0 shipped, asserted for both packages byte for byte by
[bin/overlay-sync-test.sh](../bin/overlay-sync-test.sh) against the patched copies this repository
already carries. For `battery` that assertion earns its keep: five bytes across three unrelated
sites is where an offset error would hide, and the test turns a wrong offset into a failed result
hash rather than a subtly broken HAL nobody notices for a fortnight.

## Deleting them from `HEAD` does not remove them from the repository

Every one of these blobs is in the history as well as the working tree, so `git rm` leaves a
repository that still carries 4.23 MiB of somebody else's binaries and still hands them to anyone
who clones it. Actually satisfying the policy means a history rewrite.

That is less alarming here than it sounds: **this repository has already had one**
(`7c2490e` repointed a doc cross-reference the last rewrite invalidated), the remote is already
in a non-fast-forward state relative to local, and nothing has been published. It is still the
owner's call and it is not reversible for anyone who has already cloned.

## What we built is not external — settled 2026-09-24

`artifacts/phase2/libgbm_mesa_wrapper-fixed-{32,64}.so` — 2.04 MiB — are this project's own NDK
r27c build, from `phase2/build.sh`, `phase2/stubs/` and `phase2/0001-gbm_import-geometry.patch`,
all of which are in this repository. **The owner's ruling is that build output we produced is not
external and may be committed, on the condition that the commit is signed.** So `camera-gbm`
needs no redesign, and [docs/53](53-release-readiness.md)'s position stands: the NDK stays out of
the package build path for everyone not changing the wrapper.

**The signature is the whole mechanism, so it is worth being exact about what it does.** A
committed binary carries no provenance of its own — it is bytes, and nothing in the file says who
produced it or from what. A signature over the commit that introduced it says a known key vouched
for exactly those bytes at exactly that point in history, which is the record that was otherwise
missing. It is checkable years later, by anyone, without trusting the person asking.

The asymmetry is what makes the policy coherent rather than arbitrary:

| | what a signature attests | is that enough? |
|---|---|---|
| our own build output | *we* produced these bytes, from sources in this tree | **yes** — that is the provenance claim being made |
| a third-party binary | we chose to redistribute somebody else's bytes | **no** — it attests the act, not the origin, and redistribution is the thing being avoided |

A signature is not a licence, and it cannot make Widevine's prebuilt ours.

Checked rather than assumed, 2026-09-24:

```
$ git log --format='%G?' | sort | uniq -c
    108 G
$ git log --format='%h %G? %s' -- 'artifacts/phase2/*.so'
91f9d6a G Goal 1 done: fix the camera by rebuilding libgbm_mesa_wrapper.so
```

Every commit in the repository verifies, including the one that introduced the wrapper binaries,
so the attestation holds retroactively and nothing needs re-committing.

**This promotes `bin/check-signed-commits.sh` from an authorship check to a provenance
mechanism.** It is wired two ways on purpose — a generated `.git/hooks/pre-push` shim and a
`lefthook.yml` `pre-push` job — so it holds whether or not lefthook is installed, and
[docs/53](53-release-readiness.md) lists re-running it in CI. Weakening it now costs more than it
used to. The corollary is a rule with teeth: **build output committed on an unsigned commit is a
binary with nothing standing behind it**, and is the one way to reintroduce this problem under a
compliant-looking policy.
