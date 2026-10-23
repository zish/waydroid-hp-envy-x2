# 75 — the keystore, packaged: `waydroid-ext-keystored`, `waydroid-ext-strongbox`, and overlay-sync 1.2.0

**Date:** 2026-10-23 (bigtab01's clock). **Status: built and tested offline; not yet installed on
bigtab01.** The stage-5 StrongBox from [74](74-keystore-stage5-auth.md) becomes two packages, and
the reconciler that every overlay component depends on learns one new kind of edit. The section
*Not yet verified* lists what only bigtab01 can show.

| Package | Kind | What it ships |
|---|---|---|
| `waydroid-ext-keystored` 1.0.0 | host, x86_64 | the daemon, `waydroid-keystored.service` (enabled), `/etc/waydroid-keystored.conf` |
| `waydroid-ext-strongbox` 1.0.0 | overlay, noarch | one **derive** row: the vendor VINTF manifest declaring `strongbox`, made from the user's own `vendor.img` |
| `waydroid-ext-overlay-sync` 1.2.0 | host, noarch | derive rows may now **insert** bytes; its first `%check` |

`strongbox` hard-requires `keystored`, and `keystored` recommends `strongbox`. That is the shape of
the wifid and wifi-hostd pair, and the reason is the same: one direction is harmful alone, the other
is not. Without the manifest, the daemon registers and keystore2 never contacts it. Without the
daemon, the manifest declares a strongbox with nothing serving it.

## A correction first: open question 4 is still open

[73](73-keystore-stage1-engine.md) says [65](65-tpm-keystore.md)'s open question 4 was answered
safe. The stage-2 boot it cites had the strongbox **undeclared**: keystore2 reached for one, found no
instance and carried on with `-68`. Stage 3a then established that keystore2 engages only a
*declared* strongbox. So the case open question 4 is actually about, a declared strongbox with
nothing serving it, has never been booted. [hand-deploy.sh](../artifacts/keystore/hand-deploy.sh)
already said so and guarded against a reboot leaving exactly that. A package has to keep it
unreachable. Two things do:

- **By package operations:** `strongbox` cannot be installed without `keystored`, and removing
  `keystored` removes `strongbox` with it.
- **At runtime:** the daemon registers even when the TPM does not answer. It logs `TPM not ready` and
  fails key operations until it does. So a missing or broken TPM never leaves the declaration empty.

The gap neither closes is a person running `systemctl disable --now waydroid-keystored` with
`strongbox` still installed. The unit's header says so. Booting that case on purpose would answer
open question 4. It is optional, and it costs the owner a logout to try and another to recover.

## The launch model, and the gate it could not ship without

The daemon runs as a unit from boot, in waydroid-wifid's shape. It waits for a session, registers
the moment the session's hwservicemanager appears, and exits when the session ends; `Restart=always`
then starts a new process for the next session. A fresh process per session is wanted rather than
tolerated: keystore2 negotiates the shared HMAC key once a session, so each session should meet a
new party with a new seed and nonce.

**The stage-5 daemon could not have been packaged as it was.** It went straight into
`gbinder_servicemanager_wait()`, which pings binder handle 0 once a second. Every ping that lands
while no hwservicemanager exists writes two kernel log lines, the fault
[69](69-wifid-binder-ping-spam.md) measured and fixed in wifid. Measured today on bigtab01's journal,
for the 2 h 6 min the hand-deployed daemon waited before the owner logged in:

| PID | Process | `cannot find target node` |
|---|---|---|
| 589128 | `waydroid-keystored` | **7,551** |
| 1261 | `waydroid-wifid` (gated since docs/69) | 1 |
| 1340 | `waydroid container start` | 1 |

That came to 15,113 kernel lines in two hours, all but a handful from this daemon, against zero in
the same span before it started. A unit running from boot on a machine left at the greeter would do
that indefinitely. The daemon now polls `id.waydro.Container`'s `GetSession` over D-Bus, which costs
no binder traffic, and opens hwbinder only once a session exists. The port follows
[wifi/service.cpp](../wifi/service.cpp)'s gate exactly, including its fallback: if `GetSession`
never answers in 60 s, the daemon probes binder unguarded, so a Waydroid without the method still
gets a working daemon.

Registering up to a second later is safer here than it was for Wi-Fi. keystore2 retries a
*declared* strongbox, which is how it beat hwservicemanager's failed lazy start in stage 3a, so a
late daemon delays the negotiation rather than missing it. That is reasoning, not yet measurement;
see *Not yet verified*.

## The domain

The unit pins `SELinuxContext=system_u:unconfined_r:unconfined_t:s0`, the domain the daemon was
developed and verified in, as waydroid-wifid does. It was asked of the kernel with
`selinux_check_access()` on bigtab01 rather than inferred, per [42](42-backlight-selinux.md):

| source → target | `binder call` | `binder transfer` |
|---|---|---|
| `unconfined_service_t` → `container_runtime_t` | allow | allow |
| `container_runtime_t` → `unconfined_service_t` | allow | **deny** |
| `unconfined_t` → `container_runtime_t` | allow | allow |
| `container_runtime_t` → `unconfined_t` | allow | allow |

So `unconfined_service_t`, what systemd would give a `bin_t` binary, would also serve
keymaster@4.0. That interface never has Android pass a binder *to* the daemon, which is the one flow
denied. The pin is therefore not a fix for a known denial, as it is in wifid. It keeps the daemon in
the domain it was tested in, because each test of a different one costs the owner a logout.
`PrivateTmp=yes` is added because the tpm2-tools backend passes key blobs and operation data through
a 0700 directory under `/tmp`.

## The manifest, as a derive row with insertions

The override is the image's whole `/vendor/etc/vintf/manifest.xml` with two lines added inside the
keymaster `<hal>`. A fragment cannot add an instance to a HAL the image already declares; libvintf
calls that a conflict and rejects the whole manifest ([73](73-keystore-stage1-engine.md)). Shipping
the file would break [the vendored-binaries policy](54-no-vendored-binaries.md) in spirit. It would
also be wrong in practice: a full override silently hides anything an image update changes in the
manifest, where a derive row refuses and says so.

Until now a derive row could only swap single bytes (`offset:old:new`), and adding a line is an
insertion. **overlay-sync 1.2.0** adds `offset+hexbytes`, which inserts before that offset. Every
offset in a row, of either kind, is into the **stock** file, the one the stock hash names and the one
a person reads offsets from. The edits are applied from the highest offset down so that none moves
another. Where a replacement and an insertion share an offset, the replacement goes first, so the
insertion lands before that byte rather than inside it. The result hash still judges everything.
`stage-overlay.sh` rejects a malformed insertion at build time: whole bytes, hex only, at least one.

`waydroid-ext-strongbox`'s row inserts at stock offsets `0xa68` and `0xab5`:

    derive 0644 vendor/etc/vintf/manifest.xml vendor /etc/vintf/manifest.xml
           0695403b…16c7cc  3f2a8b70…0fb0fc86  a68+…,ab5+…

The edits were derived from the image's own manifest. It was pulled with `debugfs`, unprivileged,
into the scratchpad, and never committed. Three checks then agreed:

- the stock file hashes to the `STOCK_SHA` that [strongbox-manifest.sh](../artifacts/keystore/strongbox-manifest.sh) pins;
- the edits, applied by the **real reconciler** to that stock file, produce `3f2a8b70…`;
- that output is **byte-identical** (`cmp`) to the manifest in bigtab01's overlay that keystore2 bound
  in every session since 2026-10-22.

## Verified offline

| | Result |
|---|---|
| [artifacts/overlay-manager/selftest.sh](../artifacts/overlay-manager/selftest.sh), the reconciler's first test | **19/19** under `sh` and `dash`, and in `rpmbuild`'s `%check` |
| the same, with the edit order made ascending | fails 5 — mid-file insertions break |
| the same, with the tie rule reversed | fails 4 — the shared-offset case breaks |
| [artifacts/keystore/selftest.sh](../artifacts/keystore/selftest.sh), static half | **12/12** |
| its live half, the engine against a throwaway swtpm | **87/87** |
| the static half with the manifest hash pair broken and the binder node changed | exactly those two checks fail |
| `keystore/hal/build.sh --rpm` against stand-in `.pc` files, with Fedora-style flags | compiles, links, `BIND_NOW`; same `NEEDED` as the by-hand build |
| the by-hand daemon build | zero warnings |
| `build-mod.sh overlay-sync strongbox`, `build-mod.sh --prebuilt keystored` | all three `-ba`; `%check` 19/19 and 11 + 2 skipped inside `rpmbuild` |
| `test-install.sh overlay-sync strongbox keystored` | **18/18**; `keystored`'s edited conf kept as `.rpmsave` |
| `verify-units.sh` | `waydroid-keystored.service` verifies, with `@BINDIR@` substituted |
| rpmlint, new findings only | `keystored` matches `wifid`'s baseline; `strongbox` joins the derive-row filter beside `camera-hal` and `battery` |
| `tests/run.sh selftest` | all six suites pass, both new ones picked up automatically |

Two notes on that. The reconciler's derive path had **no test at all** before this: since 1.1.0 it
had been verified only by `battery` and `camera-hal` living on bigtab01. The new selftest uses a
stub `debugfs` that serves files from a directory standing in for the image, because neither a build
root nor the dev box can be assumed to have e2fsprogs or an ext4 image. Its expected results are
built with `printf` and hashed separately, so the code is never judged against its own output.

## Not yet verified

- **Anything on bigtab01.** In particular: that the unit starts the daemon as `unconfined_t`; that
  `/dev/binderfs/hwbinder` behaves as `/dev/hwbinder` did; that the gate opens before keystore2 needs
  the StrongBox (read the daemon's `Added` line against keystore2's `computeSharedHmac` in the first
  session); and that the journal is quiet at the greeter.
- **The source arm on Fedora.** The dev box is Debian and cannot install `libgbinder-devel`, so CI's
  `rpm` job is the first real source build. The `--rpm` path has been exercised here only against
  stand-in `.pc` files.
- **Open question 4**, as above. It is optional.

## What a StrongBox gives apps here, and what it cannot

Recorded because the question was asked on 2026-10-23, and the honest answer is narrower than the
word "secure element" suggests.

- **Keys outside Android.** This image's default keymaster is SOFTWARE-level: its keys are blobs
  Android itself holds and can read ([73](73-keystore-stage1-engine.md)). A StrongBox key is a TPM
  object, and Android holds only a wrapped blob that the TPM's seed, outside the container, is
  needed to open. On swtpm that seed is a file on the host's disk, so the protection is against
  Android, including Android root, and not against the host. On a hardware TPM it would be against
  both.
- **Only for apps that ask.** An app gets a StrongBox key only by calling
  `setIsStrongBoxBacked(true)`. Many apps first check `FEATURE_STRONGBOX_KEYSTORE`, which is
  deliberately **not declared** here ([74](74-keystore-stage5-auth.md), *Still not done*), so those
  apps will not ask. Declaring it is the owner's policy call.
- **No attestation, ever.** Anything that judges a device by key attestation needs a chain rooted in
  Google's key, which a TPM cannot produce: Play Integrity's strong verdict, and the apps that gate
  on it. This is the explicit non-goal in [65](65-tpm-keystore.md).
- **Not the other secure-hardware HALs.** Protected Confirmation needs a trusted UI, and
  `TRUSTED_CONFIRMATION_REQUIRED` is refused. Identity Credential (mobile driving licences) and
  Weaver are separate HALs this does not provide.

## Deploying it on bigtab01

Not done. It needs the owner, for sudo and for a logout or reboot.

1. **Let the hand deployment end first.** It removes its manifest, binary and guard unit at the next
   logout. Installing over it would leave two copies of the daemon registering the same name.
2. **One rpm-ostree transaction:** replace the layered `waydroid-ext-overlay-sync` with 1.2.0
   (uninstall and install together, the [60](60-wifi-nl80211.md) rule for a layered local package),
   and add `waydroid-ext-keystored` and `waydroid-ext-strongbox`. bigtab01 runs overlay-sync
   **1.1.0**, not 1.1.1, which was a lint-only release that never went there. Every runtime
   dependency is already installed (`tpm2-tools` 5.7, `libgbinder` 1.1.47, `e2fsprogs`), so the
   transaction needs no repository. Then reboot, or `--apply-live`. An
   apply-live is not an install until a reboot follows ([71](71-swtpm-host.md)); `mdns` was lost
   that way.
3. **Before the first session:** `waydroid-overlay-sync --verify` must report the manifest
   `derived`/matching; `systemctl status waydroid-keystored` must show the gate's `no waydroid session
   yet` line, and the kernel log no binder pings.
4. **The first session:** `bin/keystore-auth-test.sh`, which needs the owner to unlock once when the
   screen re-locks.
