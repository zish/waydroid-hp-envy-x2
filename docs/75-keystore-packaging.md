# 75 — the keystore, packaged: `waydroid-ext-keystored`, `waydroid-ext-strongbox`, and overlay-sync 1.2.0

**Date:** 2026-10-23 (bigtab01's clock). **Status: installed on bigtab01 the same evening and
verified through a real boot and a real session; the auth test passed 32/32 against the packaged
daemon** (*Deployed on bigtab01*, below). The stage-5 StrongBox from [74](74-keystore-stage5-auth.md)
becomes two packages, and the reconciler that every overlay component depends on learns one new kind
of edit.

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

What only bigtab01 could show has now been shown there (*Deployed on bigtab01*, below). Two items
remain:

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

## Deployed on bigtab01 — 2026-10-23

Installed the same evening in the order planned, with the owner at the machine for sudo, the logout,
the LUKS passphrase and the unlock. Times are bigtab01's (EDT).

1. **The hand deployment ended first.** The owner logged out at 18:32:09, and
   [hand-deploy.sh](../artifacts/keystore/hand-deploy.sh) removed its manifest, its
   `/usr/local/bin` daemon and its boot guard, then exited. Installing over it would have left two
   daemons registering one name. The order mattered for a second reason, found while checking: the
   guard and `waydroid-overlay-sync.service` are both `Before=waydroid-container.service` and
   `After=local-fs.target`, ordered against nothing else. So had a reboot come first, the guard's
   `rm` could have deleted the manifest the package had just derived.
2. **One transaction**, from `/var/tmp/keystore-rpms/`:
   `rpm-ostree uninstall waydroid-ext-overlay-sync --install` the three RPMs (the
   [60](60-wifi-nl80211.md) rule for replacing a layered local package). bigtab01 was on
   overlay-sync **1.1.0**; 1.1.1 was a lint-only release that never went there. `db diff` showed
   exactly overlay-sync 1.1.0 → 1.2.0 and the two additions; the base commit did not move
   (`67054bd…`, 44.20261016.0), and nothing in `/etc/systemd/system` or `/usr/local/bin` shadows
   either package. Rebooted at 18:40:30 into `0672d3b2…`, not `--apply-live`, which is not an
   install until a reboot follows ([71](71-swtpm-host.md)). The previous deployment, `9394b8cc…`,
   is the rollback: booted from GRUB, its overlay-sync 1.1.0 removes the manifest because its
   component is gone. That removal path exists and is unexercised for this file.

At the greeter, before anyone logged in:

| Check | Result |
|---|---|
| the daemon's domain | `system_u:unconfined_r:unconfined_t:s0`, from `/usr/lib/systemd/system/waydroid-keystored.service` |
| the gate | `no waydroid session yet; waiting for one before probing binder`, 18:41:20 |
| `waydroid-overlay-sync --verify` | exit 0. The derived manifest hashes `3f2a8b70…`, the row's result, and the image's stock manifest `0695403b…`, the row's stock hash |
| kernel log, boot to login (about 9½ minutes) | two lines matching `binder`, both systemd mounting binderfs. **No pings** |

The first session, the owner logging in at about 18:50:

| | |
|---|---|
| the gate opens | 18:50:57.227 (`waiting for the container's hwservicemanager on /dev/binderfs/hwbinder`) |
| `Added "android.hardware.keymaster@4.0::IKeymasterDevice/strongbox"` | 18:50:57.231 |
| keystore2 binds | 18:50:57.291 `getHardwareInfo -> STRONGBOX`; 18:50:57.293 `computeSharedHmac over 2 participants -> OK` |
| kernel lines matching `binder` in the session's first minute | 18, none from the daemon (pid 900): four failed pings from `waydroid-sensord` (pid 3058) in the 300 ms before hwservicemanager existed, eight lines; five of init's gralloc `exec`, which names `/dev/host_hwbinder`; one `-22` ioctl from `system_server`; four `RLIMIT_NICE not set` from pid 3144, since exited ([40](40-binder-nice.md)) |
| [bin/keystore-auth-test.sh](../bin/keystore-auth-test.sh) | **32/32**: the stage-4 suite 20/20, auth-gen 5/5, auth-fresh 4/4 (started at the unlock, 19:47:34), auth-stale 2/2, auth-clean 1/1 |
| the auth decision, from the unit's journal | 19:47:35, token type 1, MAC of zeros, **977 ms old of 15 000 allowed**, accepted by `--accept-unsigned-auth-tokens`; the TEE's verification token valid |

So `unconfined_t` under systemd, `/dev/binderfs/hwbinder`, a quiet greeter and the gate's timing
against keystore2 all hold. The gate opened 64 ms before keystore2 asked for the StrongBox.

Two findings.

- **The daemon checks the TPM before swtpm listens.** `After=waydroid-swtpm.service` waits for
  swtpm's *start*, and that unit is `Type=simple`, so started means forked. The daemon's first
  `createprimary` ran at 18:41:18.96 and could not connect to `/run/swtpm-waydroid/sock`. The
  wrapper logged its first line at 18:41:19.13. The daemon logged `TPM not ready … key operations
  will fail until it is` and went on to the gate. That is the runtime guarantee under *A correction
  first*, exercised by accident on the first boot: the daemon registered regardless, and
  `Engine::ensurePrimary()` latches only success. So the first key operation, at 19:45:51, found
  the persistent primary with no further message. The cost is one false alarm in every boot's
  journal. **Not fixed.** It needs a `keystored` 1.0.1 and a reboot to deploy. The fix belongs in the
  daemon, which can check the TPM after the gate instead of before it: by the time a session
  exists, swtpm has been listening for as long as the greeter was up.
- **The auth test printed another session's daemon lines.** Its last section read
  `/var/tmp/waydroid-keystored.log`, hand-deploy.sh's file, which outlives the hand deployment, so
  this run printed the 12:29 daemon's start and its 14:35 negotiation as if they were its own. It now reads the unit's
  journal whenever `waydroid-keystored.service` exists. The messages carry the same leading
  timestamp, so the `since` filter is unchanged. Rerun against this session, it prints 18:50:57's
  negotiation and 19:47:35's decision.

**Open question 4 is no closer.** This boot declared a StrongBox and served it. The case that question
is about, declared with nothing serving it, is still unbooted, and it stays optional.
