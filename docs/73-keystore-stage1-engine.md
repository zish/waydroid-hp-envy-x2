# 73 — keystore HAL stage 1: the TPM-backed keyblob engine

**Date:** 2026-10-21. **Status:** built and verified on the dev box and on bigtab01, 15/15 both.
No binder, no Android interface, nothing installed — this is [65](65-tpm-keystore.md)'s stage 1, the
TPM semantics settled and proven in a host CLI before a line of HIDL. Source in
[keystore/](../keystore); [71](71-swtpm-host.md) is the stage-0 swtpm it runs against.

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

**Not yet done (stage 4/5):** key operations — `generateKey`/`begin`/`update`/`finish` still return
a transaction error, so an app cannot yet *make* a StrongBox key; the `KeyParameter` /
`KeyCharacteristics` marshalling for those; a correct `computeSharedHmac`; the
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
