# 54 — No binaries from external sources, and what that costs

**Policy set by the owner on 2026-09-24**, recorded in [AGENTS.md](../AGENTS.md) under
*Repository conventions*: do not commit a binary that came from somewhere else. If a package
needs one, it is obtained at RPM install time or inside Android, never carried in this
repository.

This note is the inventory it applies to and the migration out. **Nothing here complies yet.**

## The inventory

Every tracked binary, what it is, and where it came from. Sizes are the files themselves, not
their weight in git history — see the last section for that distinction.

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
| `artifacts/phase2/libgbm_mesa_wrapper-fixed-64.so` | 1,068,888 | **our own NDK r27c build** | `camera-gbm` | not external — see *The one open question* |
| `artifacts/phase2/libgbm_mesa_wrapper-fixed-32.so` | 1,070,036 | **our own NDK r27c build** | `camera-gbm` | not external — same |
| `artifacts/acpi/*.aml` (7 files) | 148,480 | **this machine's own firmware** | never | out of scope — evidence, not payload |
| `artifacts/hid/*.rd` (2 files) | 8,192 | **this machine's own devices** | never | out of scope — same |

**4,439,156 bytes — 4.23 MiB — came from a third party.** Two thirds of that is Widevine.

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

1. **A derived row.** `<mode> derive <source path in the image> <stock sha256> <result sha256>`
   plus a patch list. The reconciler extracts the source, refuses if its hash is not the recorded
   stock hash, applies the offsets, refuses if the result hash is wrong, and installs. Covers
   `camera-hal` and `battery`. The refusal is the feature: a stock hash that stopped matching
   means the image changed under a file we silently replace, which is precisely the alarm
   [docs/47](47-package-split.md) specified and never built.
2. **A fetched row**, for Widevine only — the one case where the bytes genuinely are not on the
   machine. Download the pinned archive, verify its digest, extract, install. `%ghost` in
   `%files`. Already designed in [docs/47](47-package-split.md).
3. **A hash-only tripwire.** The fourth column of a `FILES` row currently names a *file* in this
   repo whose sha256 gets recorded. It should name the sha256 directly. Same manifest output,
   same `--check-upstream` value, and `artifacts/lib/*.so` and every `….orig` stop existing.

A symlink row is also outstanding, for Widevine's `libprotobuf-cpp-lite.so`. It is unrelated to
this policy and is recorded in [docs/47](47-package-split.md).

## What this does to the five packages built on 2026-09-24

| Package | Payload | Affected |
|---|---|---|
| `camera-hal` | vendor `.so` + XML | **yes** — the `.so` must become a derived row |
| `battery` | vendor binary | **yes** — must become a derived row |
| `brightness-overlay` | one `.rc` | no — text, written here |
| `wifi-framework` | one XML | no — text, AOSP-shaped but written here |
| `wifi-hostd` | one `.rc` + one XML | no — text, written here |

So three of the five are already compliant and can migrate to bigtab01 whenever the owner wants.

**`camera-hal` and `battery` should be held out of the third migration.** They work and their
payload is byte-identical to what is live, but installing 1.0.0 puts a package on the machine
whose whole shape is about to change, and the point of a migration is to stop having two answers
to "where does this file come from". They go in after the derived row exists.

## Deleting them from `HEAD` does not remove them from the repository

Every one of these blobs is in the history as well as the working tree, so `git rm` leaves a
repository that still carries 4.23 MiB of somebody else's binaries and still hands them to anyone
who clones it. Actually satisfying the policy means a history rewrite.

That is less alarming here than it sounds: **this repository has already had one**
(`7c2490e` repointed a doc cross-reference the last rewrite invalidated), the remote is already
in a non-fast-forward state relative to local, and nothing has been published. It is still the
owner's call and it is not reversible for anyone who has already cloned.

## The one open question

`artifacts/phase2/libgbm_mesa_wrapper-fixed-{32,64}.so` — 2.04 MiB — are **not** from an external
source. They are this project's own NDK r27c build, from `phase2/build.sh`, `phase2/stubs/` and
`phase2/0001-gbm_import-geometry.patch`, all of which are in the repository. The policy as stated
is about third-party binaries and does not reach them.

But they are still committed build output, and building them needs NDK r27c plus minigbm and Mesa
sources fetched at build time. [docs/53](53-release-readiness.md) currently treats having them
committed as an *advantage* — "the NDK is not needed in CI at all, because the built wrapper is
already committed". Whether the policy should extend from "not external" to "not built output" is
the owner's call, and it is a much larger one: it puts a 757 MB-class toolchain into the package
build path for every builder.
