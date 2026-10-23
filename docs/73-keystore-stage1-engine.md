# 73 — the keystore HAL, stages 1–4: a TPM-backed engine, and StrongBox keys from an app

**Date:** 2026-10-21 (stage 1) to 2026-10-22 (stage 4). **Status: StrongBox key operations work from
an ordinary Android app on bigtab01, backed by swtpm — 20/20 in a probe app, 2026-10-22.** EC P-256
signing and AES-GCM/CBC run through keymaster's begin/update/finish, the keys report security level
STRONGBOX, and every result is checked by something other than our daemon. Nothing is packaged: the
daemon is started by hand and the manifest is an overlay file, both removed again at the next logout
(see *State on bigtab01* at the end). This note covers [65](65-tpm-keystore.md)'s stages 1, 2, 3a and
4; source in [keystore/](../keystore), and [71](71-swtpm-host.md) is the stage-0 swtpm underneath.

The stage 1 sections below are kept as written on 2026-10-21. Two things in them were wrong and are
corrected in *Stage 4*: the engine encoded `PURPOSE` as the wrong tag type, and most of its error
numbers did not match keymaster's.

## What stage 1 is, and what it is not

It is the engine a keystore HAL is built on: mint a key as a TPM object, hand Android an opaque
blob, and on every later call re-read that blob, **enforce its authorization tags**, and run the
primitive in the TPM. It is a `keystore-engine selftest` binary and nothing else. It does **not**
appear in Android — no feature flag, no instance, no `dumpsys` line — because none of that exists
until stage 2 declares an instance and stage 3 serves it over binder. Saying so plainly: installing
or running stage 1 changes nothing a phone user or an app can see.

## The design decision that shaped it: native-TPM, not hybrid, for stage 1

[65](65-tpm-keystore.md) describes a *hybrid* backend — the TPM protects a wrapping key and crypto
runs in the daemon (OpenSSL) — because "a TPM 2.0 does not offer everything Android's tag model asks
for." That is true at the edges (GCM, odd paddings, HMAC variants), but it is the wrong starting
point. A TPM 2.0 does **natively** do the center of the target: EC P-256, RSA, AES-CFB and
HMAC-SHA256. So stage 1 makes each Android key an actual **TPM child object** and runs sign /
verify / encrypt / decrypt **inside** the TPM. Three things follow, all of them improvements:

- **No OpenSSL and no new build dependency** — the engine is plain C++17; the TPM does the math.
- **The key material never leaves the TPM during an operation**, which is the hybrid design's
  acknowledged weak point ("during an operation, key material is in host RAM"). On real hardware
  (vidiot01) that is a genuine security gain; on swtpm it is at least not a regression.
- **The blob is confidential at rest for free**: the TPM `TPM2B_PRIVATE` portion is encrypted under
  the persistent primary, whose seed lives in the TPM, so the blob Android stores is already wrapped.

The hybrid split is not abandoned — it is the path to a **TPM-1.2, smartcard or Yubikey** backend
(a chip that can seal a blob but cannot do P-256), and [65](65-tpm-keystore.md)'s "narrow
seal/unseal/wrap/unwrap contract" is exactly that backend's seam. Stage 1's seam is TPM-2.0-shaped
on purpose; the narrower one is a later refactor behind the same `TpmBackend` abstraction.

## The pieces

| File | What it is |
|---|---|
| [`keystore.h`](../keystore/keystore.h) | keymaster tag model (values match `keymaster@4.0::Tag` so stage 3 copies rather than translates), the `KeyBlob` format, and the `TpmBackend` seam |
| [`km_blob.cpp`](../keystore/km_blob.cpp) | blob serialize/parse — our own little-endian versioned format, deliberately **not** the HIDL `hidl_vec` wire format, so a blob survives a change of interface |
| [`tools_backend.cpp`](../keystore/tools_backend.cpp) | a `TpmBackend` that drives tpm2-tools by `exec` — zero build deps, the stage-1 and development backend |
| [`engine.cpp`](../keystore/engine.cpp) | the keymaster-semantics layer: request→`CreateSpec`, and **tag enforcement on every op** |
| [`main.cpp`](../keystore/main.cpp) | the `keystore-engine` CLI and its 15-check selftest |

**The `TpmBackend` seam is the [29](29-wifi-plan.md) `WifiBackend` idea applied to the TPM.**
Everything above it is algorithm-agnostic engine logic the stage-3 HIDL HAL reuses unchanged;
everything below it is one implementation of "do this on a TPM 2.0". `ToolsTpmBackend` is the first;
an **ESAPI backend** linking `libtss2` is the production one that will ship in the RPM, and it drops
in behind this seam with no engine change. The tools backend stays as the dependency-free fallback
and as what the selftest runs in CI.

**Tag enforcement is the whole point of the engine, because the TPM will not do it.** The blob
carries its authorization list in the clear (tags are not secret); the engine re-reads it from the
blob on every call and trusts nothing passed alongside. A sign with an AES blob is
`INCOMPATIBLE_ALGORITHM`, an EC key minted without `PURPOSE=SIGN` is refused at generation, a
`PURPOSE` the key does not hold is `INCOMPATIBLE_PURPOSE`, and a corrupt blob is `INVALID_KEY_BLOB` —
all returned as `keymaster@4.0::ErrorCode` numbers so stage 3 returns them unchanged.

## Slot discipline, carried over from stage 0

[71](71-swtpm-host.md) finding 3: swtpm has no resource manager and tpm2-tools leave every object
they load behind, so three transient slots run out on the third object. The backend answers it the
way `waydroid-tpm-check` does — the **primary is persistent** (evicted to `0x81010020` under the
owner hierarchy, created once, idempotent), so each operation loads only the *child* transiently and
the backend runs `tpm2_flushcontext -t` when it finishes. That also makes it self-healing: a leak
from a crashed prior op is cleared on the next call. Flushing *all* transient objects means two
operations must never overlap, so the engine serializes every backend call under one mutex;
`kMaxConcurrentOps` is 1 for this backend. A second concurrent client of the socket would need
`tpm2-abrmd` in front of swtpm — or the ESAPI backend, which can flush by specific handle.

## One gotcha worth recording

`tpm2_verifysignature` **rejects `--halg` (`-g`) together with a pre-hashed `--digest` (`-d`)** —
`ERROR: Cannot specify --digest (-d) and ( --msg (-m) or --halg (-g) )`. The hash algorithm is
carried inside the `TPMT_SIGNATURE` the sign step produced, so verifying a digest takes `-d` and
`-s` and no `-g`. The sign step is the opposite — it *needs* `-g sha256 -s ecdsa -d`. This cost the
one red test on the first run; the legitimate signature verified the moment `-g` came off.

## Verified

Each run stands up a throwaway swtpm (no sudo, no service socket, no container) via
[`selftest.sh`](../keystore/selftest.sh) and runs the 15 checks through it.

| | Dev box (Debian, swtpm 0.7.1, tpm2-tools 5.7) | bigtab01 (F44, swtpm 0.10.2, tpm2-tools 5.7) |
|---|---|---|
| Build | `g++ 14`, clean `-Wall -Wextra` | built on the dev box, binary copied |
| Binary loads on the host | — | yes — F44 runs the Debian-built binary |
| `keystore-engine selftest` | **15/15** | **15/15** |

The 15 checks: persistent primary; 16 random bytes not all zero; generate EC P-256; blob
serialize/parse round-trip; `ORIGIN=GENERATED` bound into the blob; sign a SHA-256 digest; verify;
verify rejects a tampered digest; EC-without-`SIGN` refused; generate AES-128; encrypt differs from
plaintext; decrypt round-trips; sign-with-AES refused; encrypt-with-EC refused; non-blob refused.

The portability result matters for the shape of this project: the engine is built on the dev box and
the binary runs on bigtab01's F44 unchanged, exactly as the sensors and Wi-Fi daemons are, so the
"build here, copy the artifact across" rule holds for the keystore too.

## Deliberately not done in stage 1

RSA and HMAC keys (the backend rejects them with `UNSUPPORTED_ALGORITHM`); the streaming
`begin`/`update`/`finish` operation model (stage 1 is one-shot — fine for a digest sign and a small
AES buffer, not for a stream); real IV handling for AES (CFB with a zero IV proves the mechanism,
stage 4 adds a random IV and GCM); auth-bound keys and `computeSharedHmac` (stage 5); and the ESAPI
backend. None of these is blocked; the types leave room for each.

## Stage 2 answered itself from the baseline (2026-10-22)

Stage 2 was going to declare an `android.hardware.keymaster@4.0::IKeymasterDevice/strongbox`
instance with nothing serving it, to see what `keystore2` does with a declared-but-absent StrongBox
— and it turned out **no arming was needed**, because `keystore2` already does exactly that probe on
every boot. With the owner at the console a clean session was read read-only, and the boot log shows:

- `keystore2::shared_secret_negotiation: No StrongBox Keymint available, so no RoT transfer`
- `keystore2 … connect_keymint: Trying to get Legacy wrapper … Error::Km(ErrorCode(-68))`
  (−68 = `HARDWARE_TYPE_UNAVAILABLE`) — i.e. `keystore2` reaches for a StrongBox KeyMint through its
  **km_compat Legacy wrapper** (`android.security.compat` is running) and only the missing instance
  stops it;
- then `Successfully registered Keystore 2.0 service`, a healthy unlocked system, and shared-secret
  negotiation *concluded successfully* for the TEE instance.

So [65](65-tpm-keystore.md)'s open question 4 is answered on the safe side — a declared-but-absent
StrongBox does **not** wedge `keystore2` — and open question 3 is answered yes: the discovery path
is live and wants a *served* `keymaster@4.0/strongbox` instance, not just the feature XML. Arming an
empty instance would have cost a session restart and the kiosk risk for information the baseline
already gives, so it was skipped. The staged overlay files in
[`artifacts/keystore/stage2/`](../artifacts/keystore) stay — they are what declares the instance
once stage 3 serves it.

## Stage 3a — StrongBox BINDS, 2026-10-22, and OQ4 is answered safe

**Measured end to end on bigtab01 with the owner at the console.** keystore2 now binds our
instance: `keystore2: found android.hardware.keymaster@4.0::IKeymasterDevice with interface name
strongbox and seclevel STRONGBOX`, then `earlyBootEnded succeeded for security level STRONGBOX` —
the `-68 HARDWARE_TYPE_UNAVAILABLE` is gone, and the daemon log shows keystore2 calling
`getHardwareInfo` (→ STRONGBOX), `getHmacSharingParameters` and `computeSharedHmac`. **swtpm appears
as a secure element in Android.**

**[65](65-tpm-keystore.md) open question 4 is answered on the safe side.** The stage-3a probe's
`computeSharedHmac` returns an empty check on purpose; keystore2 detected the mismatch
(`negotiate_shared_secret: … NOT PROVISIONED CORRECTLY`) and **still** concluded
`Shared secret negotiation concluded successfully`, booted to a working lockscreen, and the TEE
instance was unaffected. So a strongbox that disagrees on the shared secret is **tolerated, not
fatal** — `computeSharedHmac` can be made correct incrementally (stage 5) with no boot risk.

**Three mechanism findings, each paid for in a boot cycle:**

- **keystore2 only engages a *VINTF-declared* strongbox.** Serving the HIDL instance on
  hwservicemanager is necessary but not sufficient — with no manifest entry, keystore2 never
  contacts the daemon at all (zero transactions; `-68` as if absent). Declaration is the gate.
- **A VINTF manifest *fragment* cannot add an instance to an already-declared HAL.** Dropping a
  fragment that re-declares `android.hardware.keymaster@4.0` makes libvintf reject it as a
  *conflict* and **poison the whole device manifest** — keymaster and keystore2 then crash-loop and
  boot never completes. The fix is to override the whole `/vendor/etc/vintf/manifest.xml` in the
  overlay, adding `strongbox` as a second `<instance>` (and `<fqname>`) inside the existing
  keymaster `<hal>`. With that, zero VINTF conflicts and a clean boot.
- **Registration works from `unconfined_t`.** The hand-started daemon (ssh+sudo) registered the
  instance with no binder `{transfer}` denial, and keystore2's `getService` retry won the race
  against hwservicemanager's failed lazy-HAL start. A packaged deploy still wants the `waydroid_t`
  launch model (a session-start hook like sensors), but binding is not blocked on it.

**Not yet done at stage 3a** — and done since, in *Stage 4* below: the key operations and their
`KeyParameter`/`KeyCharacteristics` marshalling. Still not done: a correct `computeSharedHmac`; the
`FEATURE_STRONGBOX_KEYSTORE` feature XML (keystore2 has the seclevel, but PackageManager won't
advertise the feature to apps without it); the ESAPI backend; a persistent launch hook; and the RPM.

### How it was built (the daemon)

`waydroid-keystored` ([keystore/hal/](../keystore/hal)) is a libgbinder hwbinder service that
registers `android.hardware.keymaster@4.0::IKeymasterDevice/strongbox` and is backed by the stage-1
engine. It is modelled on `sensors/` (same `build.sh` ABI discipline — vendored gbinder/glibutil
headers at the host's exact tags, host `.so` copied for linking, static libstdc++, so the only
runtime deps are glibc/glib/libgbinder). `keymaster@4.0` is a public AOSP HIDL interface, so the
method order and struct layouts are standard, not reverse-engineered.

**Stage 3a's scope is *bind and measure*, not a finished HAL.** It serves `getHardwareInfo` (so
`keystore2`'s km_compat Legacy wrapper can bind it as the STRONGBOX level), accepts `addRngEntropy`
and the ErrorCode-only methods, and **instruments the two shared-secret methods** so the real risk
can be read off a boot: `getHmacSharingParameters` returns a well-formed per-boot seed+nonce with
`OK`, and `computeSharedHmac` returns `OK` with an **empty** sharing check — a deliberate, reversible
mismatch. The key-operation methods (`generateKey`/`begin`/`update`/`finish`/…) return a transaction
error; they are stage 4 and `keystore2` does not call them during binding or negotiation. Built
clean, all `DT_NEEDED` resolve on bigtab01, `--help` parses.

**What the next console session measures**, in order, each reversible:

1. **Does it bind?** Start the daemon so it is registered on the container's hwservicemanager
   *before* `keystore2` probes (the daemon can `gbinder_servicemanager_wait()` on `/dev/hwbinder`
   and register the instant the session's hwservicemanager appears, which is how it wins the race
   against `keystore2`), then watch for `−68` turning into a bound STRONGBOX in the keystore log.
2. **Does the empty-check `computeSharedHmac` break the TEE instance's negotiation**, or is it
   tolerated/isolated? This is [65](65-tpm-keystore.md) open question 4's present-but-failing case,
   and it decides whether `computeSharedHmac` must be fully correct before this instance may *ever*
   be served. Do it behind a `session stop`, with the owner at the machine.

**Two integration subtleties to solve at the bench, not guessed:** the daemon must run in a domain
allowed to *register* on hwservicemanager — `sensors/` gets `waydroid_t` by being spawned from
`container_manager.py`; a hand/ssh start is `unconfined_t` and may hit a binder `{transfer}` denial
on registration (docs/35), so the launch mechanism (a session-start hook like sensors, vs. a unit)
is itself part of the test. And whether the VINTF fragment in
[`artifacts/keystore/stage2/`](../artifacts/keystore) is needed to bind a *served* instance, or the
Legacy wrapper finds it on hwservicemanager regardless — the baseline probe ran with no VINTF entry,
so try daemon-only first.

**Then stage 3b/4:** a correct `computeSharedHmac` (needs the pre-shared key the TEE keymaster and
gatekeeper share, plus an HMAC/CKDF path — TPM or libcrypto), the KeyParameter/KeyCharacteristics
marshalling, `generateKey`/`begin`/`update`/`finish` wired to the engine, the ESAPI backend that
ships, and the RPM.

## Stage 4 — StrongBox keys work from an app, 2026-10-22

**Measured on bigtab01 with the owner at the console.** [keystore-probe/](../keystore-probe), an
ordinary app with no permissions, asked AndroidKeyStore for StrongBox keys and passed **20/20**:

| | Result | Time |
|---|---|---|
| EC P-256 `generateKeyPair`, `setIsStrongBoxBacked(true)` | `KeyInfo.getSecurityLevel()` = **STRONGBOX** | 306 ms |
| its certificate | **signed by the key itself** — keystore2's signing pass during generation went through our `begin`/`finish` | |
| `SHA256withECDSA` over 1000 bytes | verifies in the platform's **software** provider, from a copy of the public key AndroidKeyStore never touched | 58 ms |
| AES-256-GCM, 37 bytes | keystore-chosen 12-byte IV, round-trips | 112 / 117 ms |
| AES-256-GCM, 100 000 bytes | round-trips | 1045 / 1088 ms |
| a tampered GCM tag | `AEADBadTagException` | |
| AES-128-CBC/PKCS7, 1000 bytes | 1008 out, round-trips | |

Zero AVCs during the run, keystore2 stayed `running`, and nothing reached `logcat -b crash`. The
control — the same EC key without StrongBox — passed too, and reported its level as **SOFTWARE**:
this image's default keymaster is a software one that keystore2 wraps at the TEE level. So on
bigtab01 the StrongBox is the only key store whose keys are not plain files in Android's data.

### What stage 4 added

- **The engine** ([engine.cpp](../keystore/engine.cpp)) took keymaster's operation model:
  `begin` returns a handle, `update` buffers, `finish` runs the primitive. Buffering is deliberate
  — it is the only correct shape for GCM decryption, which must not release plaintext before the tag
  is checked. EC P-256 signs with `DIGEST` SHA-256 or NONE; AES does ECB, CBC, CTR and GCM, with
  PKCS7 for the first two. AES keys are created with mode NULL (`aes128null`), so one TPM key serves
  every mode; a key made as `aes128cfb` would refuse ECB with `TPM_RC_MODE`. Raw AES import and EC
  `exportKey(X509)` exist; EC import, RSA, HMAC and 3DES do not.
- **GCM is built from the TPM's ECB.** A TPM 2.0 has no GCM, so one TPM call encrypts the zero block
  (giving GHASH's subkey H), J0 and every counter block, and GHASH runs in
  [soft_crypto.cpp](../keystore/soft_crypto.cpp). Every keyed block operation is in the TPM, but **H
  is in host memory for the length of a GCM operation**. H lets you forge tags for that key, not
  decrypt with it, and anything that can read the daemon's memory can already drive the TPM socket,
  so it is no weaker than the daemon — but it is not "never leaves the TPM" either.
- **The blob's tag list is now bound to its TPM key.** Stage 1 kept the authorization list in the
  clear and trusted it, so an edited blob — `PURPOSE=SIGN` added to an encryption key — would have
  been honoured. Each TPM object's authValue is now SHA-256 of the list it was created with, and every
  use presents the digest of the list in the blob it was handed; an edited list fails authorization in
  the TPM. Every key also gets **`noda`**: without it each such failure counts toward the TPM's
  dictionary-attack lockout, which is TPM-wide, so a tampered blob replayed a few times would lock out
  every key on the TPM — on vidiot01, keys that are not ours. The selftest checks both: the edited
  blob fails with *authorization failure without DA implications*, and the real key still signs.
- **Refused, not faked:** auth-bound keys (`USER_SECURE_ID`, `AUTH_TIMEOUT`, ...) get
  `UNSUPPORTED_TAG`, because verifying a `HardwareAuthToken` needs the real shared secret (stage 5),
  and listing those tags as hardware-enforced without it would be a claim keystore2 believes.
  `attestKey` returns `UNIMPLEMENTED` (a non-goal, [65](65-tpm-keystore.md)); keystore2 then signs
  the key's certificate itself, which is the self-signed certificate above.
- **The feature XML is deliberately not deployed.** Advertising `FEATURE_STRONGBOX_KEYSTORE` would
  invite apps to put auth-bound keys here, which fail today, where they currently fall back to the
  TEE. Apps that ask for StrongBox without checking the feature get it already; that is what the
  probe does.

### Four findings, each paid for

**1. Stage 1 had two wrong constants, and its selftest could not see either.** `PURPOSE` is
`ENUM_REP | 1` (`0x20000001`); stage 1 encoded it as `ENUM` (`0x10000001`), so no Android request
would ever have carried a purpose the engine recognised. And most `KmError` values were hand-numbered
wrongly — `INVALID_KEY_BLOB` was −24; it is −33. Both passed because the selftest compared the engine
with itself. The stage-4 selftest checks against outside references instead — published SHA-256 and
GCM vectors, a reference AES for CBC/CTR/ECB, openssl verifying signatures — and Android confirmed
the corrected numbering on the first bench run: our −38 came back to the app as *Invalid argument*.

**2. libhwbinder does not register an empty vector's buffer with the kernel.** The first app run
failed every StrongBox `generateKey` with `INVALID_ARGUMENT`: the daemon could not parse the request.
The binder driver's own transaction log settled why — keystore2's `generateKey` with seven parameters
was **412 bytes of data and 16 bytes of offsets**, two kernel objects where nine were written.
libhwbinder's `Parcel::writeObject` records a `BINDER_TYPE_PTR` object in the offsets only when its
buffer is non-null, so every empty child — each non-bytes parameter's blob, every empty clientId,
appData and inParams — goes out as 40 bytes the kernel never translates. libgbinder's reader steps
through registered objects only and stopped at the first one. Our replies were never affected, because
libgbinder registers everything it writes; that is why keystore2 could still show the app our error.
`km_read_child()` in [km_parcel.h](../keystore/hal/km_parcel.h) reads each child either way: a
registered one through libgbinder, a null one recognised at the cursor and stepped over as data.
Reading `/sys/kernel/debug/binder/transaction_log` needs a 30 ms sampling loop — it is a 32-entry ring
and the sensors traffic rolls it in seconds.

**3. `tpm2_encryptdecrypt` takes at most 65 535 bytes of input per run.** The second app run passed
everything but the 100 KB GCM message (100 032 bytes to the TPM). The backend now splits on a block
boundary and chains the TPM's own `ivOut` between runs, reloading and flushing the key each time to
stay inside three transient slots; the selftest checks 150 000 bytes in all four modes against a
reference AES.

**4. Host processes cannot talk binder to each other here — only into Android's domain.** A host-side
test client failed with `transaction credentials failed` and an AVC `denied { call }` from
`unconfined_t` to `unconfined_t`. Measured with `selinux_check_access()`: neither `unconfined_t` nor
`unconfined_service_t` may binder-call either of them, both may call `container_runtime_t`, and
`container_runtime_t` may call both (but may `transfer` only to `unconfined_t` —
[35](35-wifi-stage5.md)'s trap again). `unconfined_t` may transition into `container_runtime_t`, which
accepts `bin_t` as an entrypoint, so the bench client runs as
`runcon -t container_runtime_t` on a `bin_t`-labelled copy — the same arrangement as production, an
Android-domain client calling an `unconfined_t` daemon.

### Testing without a logout per build

keystore2 binds the StrongBox once per session and cannot rebind, and a Waydroid service cannot be
restarted ([48](48-battery-frozen-and-netd-stale.md)), so every daemon build tested through Android
costs the owner a logout and login. Two things cut that to one logout per fix:

- **[km-bench](../keystore/hal/kmbench.cpp)**, a host-side libgbinder client that writes requests in
  libhwbinder's layout — empty children as unregistered raw objects — and drives a **second daemon
  instance** registered as `strongbox-bench`, which keystore2 never sees. Run first against the
  broken build, it never reached the daemon (finding 4); as `container_runtime_t` against the fixed
  build it passed **15/15**: generate, export with empty clientId/appData, characteristics, sign
  (openssl verifies), GCM with AAD both ways at 35 and 100 000 bytes, and an unknown handle.
- **A swap watcher**: a root shell that waits for the session to stop, kills the old daemon, and
  starts the installed one, so the new build is registered before the next login without anyone
  timing it.

Two traps from the bench: `pkill -f PATTERN` over ssh matches the remote shell's own command line and
kills it — kill by PID; and after a reboot an ordinary app does not run until the device has been
unlocked once (`sys.user.0.ce_available`), so a probe launched at the lock screen reports nothing.

### Verified

| | Dev box (Debian, swtpm 0.7.1) | bigtab01 (F44, swtpm 0.10.2) |
|---|---|---|
| `keystore-engine selftest` (throwaway swtpm) | **61/61** | **61/61** |
| `km-bench`, real binder, bench instance | — | **15/15** |
| keystore-probe from Android | — | **20/20** |

### Still not done

A correct `computeSharedHmac`, and with it auth-bound keys (stage 5); RSA, HMAC, 3DES and EC import;
`upgradeKey` and `importWrappedKey`; the ESAPI backend, which would also remove ~3 process spawns per
operation; a launch model that registers before keystore2 probes without a person at the console; the
feature XML, after stage 5; and the RPM. Making the manifest an overlay-sync derive row needs a new
row kind — it is an insertion, not the same-length byte swap derive rows do —
[strongbox-manifest.sh](../artifacts/keystore/strongbox-manifest.sh) is the derivation, hash-checked
at both ends.

### State on bigtab01 after the run

- **`waydroid-ext-swtpm` 1.0.0 is reinstalled**, by `rpm-ostree install --apply-live` on 2026-10-22
  (it had been removed and rebooted out that afternoon at the owner's request). A live apply is staged
  for the next boot too, but it is not durable until that boot happens — the mdns lesson in
  [packaging/README.md](../packaging/README.md). `/usr/bin/swtpm` reads `unlabeled_t` until then,
  because swtpm-selinux's policy is not loaded live; [71](71-swtpm-host.md) measured that
  `unconfined_service_t` may run it anyway, and it did.
- **Removed automatically at the next logout** by `/var/tmp/keystore-cleanup.sh`: the strongbox
  manifest in the overlay, `/usr/local/bin/waydroid-keystored`, and the bench scratch in
  `/var/tmp/wks`. A declared strongbox with nothing serving it is the one combination never booted,
  so the manifest goes when the daemon does. Its log, `/var/tmp/waydroid-keystored.log`, stays.
- **Keystore Probe stays installed in Android**, like the other probes.
