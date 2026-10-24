# 74 — the keystore HAL, stage 5: the shared HMAC key, and StrongBox keys bound to the user

**Date:** 2026-10-22, live session 2026-10-23 (bigtab01's clock). **Status: works in Android — an
app's StrongBox key bound to the owner's lockscreen signed one second after a real unlock and refused
before it and after it (*In Android* below).** Built and verified on the dev box and on bigtab01 over
real binder first, with no logout. This is
[65](65-tpm-keystore.md)'s stage 5 on top of [73](73-keystore-stage1-engine.md)'s stages 1–4: the
StrongBox now joins keystore2's shared-secret negotiation for real, and serves keys bound to a
lockscreen authentication (`setUserAuthenticationRequired(true)`), which it refused before. Source in
[keystore/](../keystore); nothing is packaged.

The work started from a question with a guessed answer — *what is the pre-shared key the TEE
keymaster and gatekeeper use?* — and every piece of it turned on reading the answer out of this image
instead. Four facts did, and three of them are not what a reader of the HAL would expect.

## Four facts, read off the image before any code

All four are this image's (`20.0-20260403-GAPPS-waydroid_x86_64`, A13), from its own binaries pulled
out of `vendor.img` with `debugfs` (unprivileged, into the scratchpad, never committed) and from the
running TEE keymaster itself.

**1. The pre-shared key K is 32 zero bytes.** The TEE is `vendor.keymaster-4-0`, AOSP's software
keymaster (`android.hardware.keymaster@4.0-service` over `libpuresoftkeymasterdevice.so`). Its
`SoftKeymasterEnforcement::ComputeSharedHmac` (at `0x15ae0`) passes `ckdf()` a key built by
`dup_buffer(0x6990, 0x20)`, and the 32 bytes at `0x6990` are all zero — AOSP's
`kFakeKeyAgreementKey`, unchanged. The label beside it is `KeymasterSharedMac` at `0x643d`. So the
shared HMAC key H that every participant derives,

    H = CKDF(K, "KeymasterSharedMac", seed1 || nonce1 || ... || seedN || nonceN)

follows from values every participant publishes. Matching it buys interoperability with this TEE, not
secrecy, and nothing below pretends otherwise. (The names are the HAL's: K pre-shared, H derived.)

**2. This image's gatekeeper signs nothing.** `vendor.gatekeeper-1-0` is the 5.7 KB passthrough
wrapper over **`gatekeeper.waydroid.so`** — not AOSP's `.software` service, but Waydroid's own copy of
gatekeeperd's older `SoftGateKeeper` (its symbols are `waydroid::SoftGateKeeperDevice` and the vtable
for `gatekeeper::SoftGateKeeper`). Slot 6 of that vtable, `ComputeSignature`, is at `0x3670` and is
four instructions: `if (signature) memset(signature, 0, signature_length)`. The library imports no
`HMAC` function at all — only `SHA256`, `PKCS5_PBKDF2_HMAC` and `crypto_scrypt`. So **every
HardwareAuthToken this image produces carries a MAC of 32 zero bytes**: there is no key to verify it
against, because nothing ever computed one.

**3. The TEE's VerificationTokens are not in the HAL's format.** `types.hal` says a
VerificationToken's MAC covers `"Auth Verification" || challenge || timestamp || securityLevel` with
all three integers **big-endian**. AOSP's `SoftKeymasterEnforcement::VerifyAuthorization` writes them
in **machine order**, and over its own level, `SOFTWARE`. Then km_compat — the only path keystore2 has
to a HIDL StrongBox — relabels every token it forwards as `TRUSTED_ENVIRONMENT`
(`convertTimestampTokenToLegacy`, "Legacy verification tokens were always minted by TEE"). So a
StrongBox written to the HAL would reject every verification token it is ever handed, and one that
believed the level field would compute the wrong MAC even in the right byte order.

**4. The TEE's clock is the host's `CLOCK_BOOTTIME`, to the millisecond.** Both are
`clock_gettime(CLOCK_BOOTTIME)` on one kernel — Waydroid's LXC sets no time namespace. That lets this
StrongBox, which unlike a secure element has a clock, enforce `AUTH_TIMEOUT` itself.

**1, 3 and 4 were measured against the live TEE without deploying anything.** `km-bench --tee-probe`
makes two calls to the image's own `IKeymasterDevice/default`, both read-only:
`getHmacSharingParameters` returns the per-boot values it already gave keystore2, and
`verifyAuthorization` mints a token from its existing key — exactly what km_compat's `SecureClock` asks
for on every StrongBox operation. With no StrongBox declared that session, keystore2 had negotiated with
the TEE alone, so if K is zero, H is `CKDF(0, label, seed || nonce)` and the token verifies under it:

    seed 0 bytes, nonce cdfa43d029aa83b9...
    token: level 0, timestamp 1583228 ms; host CLOCK_BOOTTIME 1583228..1583228 ms
    HAL form, big-endian, level as sent                  no
    HAL form, big-endian, level TRUSTED_ENVIRONMENT      no
    AOSP software form, machine order, level SOFTWARE    MATCHES

That settles K, the KDF, the label, the context encoding, the token format and the clock against the
binary that is the other party, in one run. It also showed why `computeSharedHmac` is the one call this
probe must never make: it re-keys the TEE mid-session.

One more fact explains why none of this was ever visible: **the TEE validates nothing**. Its
`ValidateTokenSignature` returns `true` and its `auth_token_timed_out` returns `false`
(`soft_keymaster_enforcement.h`), so on this image a TEE key bound to the lockscreen is gated entirely
by keystore2, which matches SIDs and auth type itself and checks a token's age against when *it
received* the token (`enforcements.rs`, `authorize_create`).

## The decision those facts force

A StrongBox that follows the HAL verifies a token's MAC under H. Here that refuses every password token
there will ever be, so a StrongBox key bound to the lockscreen could be generated and never used. There
is no third way: the token is the gatekeeper's, and the gatekeeper wrote zeros.

So the daemon takes **`--accept-unsigned-auth-tokens`**, and bigtab01 runs it with that flag. Without
it, a token must carry `HMAC(H, ...)` — the default, and the right one wherever an authenticator does
sign (a fingerprint HAL that knows H would, [66](66-fingerprint-hal.md)). With it, a MAC of exactly 32
zero bytes is also accepted, and everything else about the token is still enforced on every
operation: a USER_SECURE_ID in common with the key, the authenticator type, the age against
`AUTH_TIMEOUT` (or the challenge, for a per-operation key), and a verification token's MAC when one is
handed over. A MAC that is neither zero nor valid is still refused.

What the flag changes is **what the StrongBox claims**. A tag in `hardwareEnforced` is reported to apps
at the STRONGBOX level; a tag in `softwareEnforced` is reported at the KEYSTORE level — keystore2's own.
With unsigned tokens accepted, `USER_SECURE_ID`, `USER_AUTH_TYPE` and `AUTH_TIMEOUT` go in
`softwareEnforced`, so `KeyInfo.isUserAuthenticationRequirementEnforcedBySecureHardware()` answers
**false**, which is the truth: the checks run here, but the tokens they rest on are ones anything could
have written, and keystore2 — which decides what reaches us — is the real gate. The key material is
still in the TPM either way, which is the property a StrongBox here actually has.

**This corrects [73](73-keystore-stage1-engine.md)**, which said km_compat "ignores softwareEnforced".
It does not: for any non-SOFTWARE device, `processLegacyCharacteristics` turns `softwareEnforced` into
the KEYSTORE-level characteristics. That is what makes the flag's honest reporting possible at all.

## What the engine enforces now

| Key has | Checked at | What must hold |
|---|---|---|
| no `USER_SECURE_ID` | — | nothing new; tokens are ignored, as before |
| `USER_SECURE_ID` and `AUTH_TIMEOUT` | `begin` | a token whose MAC verifies (or is zero, with the flag); `userId` or `authenticatorId` among the key's SIDs; `authenticatorType & USER_AUTH_TYPE` non-zero; `0 ≤ now − timestamp ≤ timeout`, against this daemon's `CLOCK_BOOTTIME` — a token dated even 1 ms in the future is refused, since the clocks are one clock |
| `USER_SECURE_ID`, no `AUTH_TIMEOUT` | every `update` and `finish` | the same token checks, and `challenge` = the operation handle |
| either, and a VerificationToken arrives | `update`/`finish` | its challenge is the handle and its MAC verifies under H, in the HAL's form or the AOSP software one; a token carrying `parametersVerified` is refused, since that list is not MACed here |

A `USER_SECURE_ID` binds the key even alongside `NO_AUTH_REQUIRED` — the safe reading of a
contradiction. `TRUSTED_USER_PRESENCE_REQUIRED` and `TRUSTED_CONFIRMATION_REQUIRED` are still refused
at generation (`UNSUPPORTED_TAG`): each needs a token from hardware this machine does not have. Every
auth decision is logged with its reason — `signed with the shared key, 2000 ms old of 60000 allowed`,
`auth token is unsigned (32 zero bytes)`, `auth token was issued for another operation` — and the MAC
itself never is.

`computeSharedHmac` returns `INVALID_ARGUMENT`, and keeps any earlier key, unless the daemon's own
parameters are in the list — AOSP's rule. The daemon's seed and nonce are random per process, so a
restarted daemon is a new party; keystore2 negotiates once a session, which is one more reason a daemon
restart mid-session leaves a dead StrongBox ([73](73-keystore-stage1-engine.md)).

The arithmetic — AES (forward only), AES-CMAC, CKDF and HMAC-SHA256 — is new in
[soft_crypto.cpp](../keystore/soft_crypto.cpp) and runs in software, still with no OpenSSL. That is a
choice, not a shortcut: every input to it is public here, starting with K, so the TPM would protect
nothing. The token logic is [auth.h](../keystore/auth.h)/[auth.cpp](../keystore/auth.cpp).

## Verified before Android saw it

| | Dev box | bigtab01 |
|---|---|---|
| [tests/cpp/test_keystore_auth.cpp](../tests/cpp/test_keystore_auth.cpp), plain and under ASan/UBSan | **21/21** | — |
| `keystore-engine selftest` (a throwaway swtpm) | **87/87** | **87/87** |
| `km-bench`, real binder, daemon in its default mode | — | **30/30** |
| `km-bench`, real binder, `--accept-unsigned-auth-tokens` | — | **30/30** |
| `km-bench --tee-probe`, the image's own TEE, read-only | — | **4/4** |

Every expected value comes from somewhere other than this code. The known-answer tests use FIPS 197
(C.1, C.3), RFC 4493 and SP 800-38B (CMAC, all four message lengths each), RFC 4231 (HMAC, including a
key longer than the block), and **OpenSSL 3.5** for the rest: `openssl kdf ... KBKDF` in counter mode
with CMAC is SP 800-108 with exactly CKDF's `i || label || 0x00 || context || L`, and token bytes were
packed with Python's `struct` and MACed with `openssl mac`. The commands:

    openssl kdf -keylen 32 -kdfopt mac:CMAC -kdfopt cipher:AES-256-CBC \
        -kdfopt hexkey:$(printf '00%.0s' $(seq 32)) -kdfopt salt:KeymasterSharedMac \
        -kdfopt hexinfo:<seed1||nonce1||seed2||nonce2> KBKDF
    printf 'Keymaster HMAC Verification' | openssl mac -digest SHA256 -macopt hexkey:<H> HMAC

km-bench's `computeSharedHmac` check runs OpenSSL on the host too, so the daemon's answer over binder
is judged by code it shares nothing with. km-bench also reads the daemon's mode off its answer rather
than being told it: auth tags at KEYSTORE must come with unsigned tokens accepted, and at STRONGBOX
with them refused — both runs held that pairing.

## Tooling

- **[bin/keystore-bench.sh](../bin/keystore-bench.sh)** runs all of the bigtab01 column above from the
  dev box in about a minute, with **no sudo and no logout**: `/dev/hwbinder` is 0666, so the bench
  daemon registers as the ssh user; swtpm runs as that user on a throwaway state directory; and km-bench
  enters `container_runtime_t` through `runcon` ([73](73-keystore-stage1-engine.md) finding 4). The
  service swtpm is never touched.
- **[artifacts/keystore/hand-deploy.sh](../artifacts/keystore/hand-deploy.sh)** is the stage-4 hand
  deployment written down, where it had lived only in `/var/tmp`. Run detached as root, it installs the
  daemon, waits for the logout, puts the strongbox manifest in the vendor overlay and starts the daemon
  in the gap, and removes all of it at the logout after. A reboot in between would have left a declared
  strongbox with nothing serving it — the one combination never booted ([65](65-tpm-keystore.md) open
  question 4) — so it also installs a self-removing oneshot unit, ordered before
  `waydroid-container.service`, that clears the manifest and binary at boot.
- **[bin/keystore-auth-test.sh](../bin/keystore-auth-test.sh)** is the Android half. On a device with
  no lockscreen credential it sets a temporary PIN and authenticates with `cmd lock_settings verify`; on
  one that has a credential it never touches it and uses the owner's own unlock instead. See *In
  Android*.

## Three faults the tooling found

**Fault 1: `keystore/selftest.sh` leaked a swtpm on bigtab01 every time it ran there.** It stopped its
throwaway TPM with `swtpm_ioctl -s 2>/dev/null`, and `swtpm_ioctl` is in `swtpm-tools`, which
`waydroid-ext-swtpm` does not pull in — so on bigtab01 the stop failed silently and the process stayed.
Four were found running after two bench runs; the earlier stage 1–4 runs' had been cleared by reboots.
Both scripts now start swtpm with `--pid file=` and stop it by that PID, and a bench run leaves only the
service's swtpm behind.

**Fault 2: the lint gate had been failing since stage 1.** `tests/run.sh lint` runs `shellcheck -S
warning` over every tracked script, and three keystore scripts committed in stages 1–4 failed it
(`SC1007` twice, a false `SC2054` on `-Wl,--gc-sections`). Nobody saw it because shellcheck is not
installed on the dev box. Fixed; the gate passes over all 104 scripts.

**Fault 3: `keystore-auth-test.sh` reported an unlock that never happened.** Its first owner-unlock run
waited inside the container for `deviceLocked=0` and then printed `UNLOCKED`. Nobody unlocked, the wait
ran out at about 7 minutes, and the script carried on as if someone had. The cause is that
**`waydroid shell` ends every run with its cosmetic error on stdout, and that error quotes the whole
command line** (`Use '--details-to-stdout' … /usr/sbin/waydroid --details-to-stdout shell -- sh -c
<command>`). The command contained `echo UNLOCKED`, so the match on the output always succeeded. Any
match on `waydroid shell` output can match the command's own text. The script's `wsh` now cuts
everything from `--details-to-stdout` on. The wait also has a real 10-minute deadline from `date +%s`,
where before it counted iterations budgeted at 0.3 s each, which `dumpsys trust` stretches to about
half a second. Both fixes were checked against the live container before the run that passed: a command
containing `UNLOCKED` returns only its real output, and a 3-second deadline on a locked screen returns
only `TIMEOUT`.

Two smaller ones from the new code: UBSan caught CMAC passing an empty message's null `data()` to a
zero-length `memcpy`, and GCC's `-Wstringop-overflow` could not prove the last block is at most 16 bytes
until the arithmetic was restructured so it is visibly so.

## In Android

**Verified 2026-10-23, with every phase passing, using the owner's own lockscreen unlock as the
authentication.** [artifacts/keystore/hand-deploy.sh](../artifacts/keystore/hand-deploy.sh), armed at
21:51 the evening before, took effect at the owner's logout at 12:29:02 and served the next session.

**The negotiation.** The daemon registered `IKeymasterDevice/strongbox` at 14:35:58, within a second of
the session's hwservicemanager appearing. keystore2 ran `computeSharedHmac` over **two participants**,
the TEE and this StrongBox; it was the first session where there was more than one. It then logged
`Shared secret negotiation concluded successfully`, which keystore2 only says when every participant's
sharing check agrees. So the daemon derived the same H as the TEE in a real two-party negotiation,
where `--tee-probe` had shown it only for the TEE alone. The line after it every session, `StrongBox
does not provide a challenge, so no RoT transfer`, is informational: the HIDL path has no
`getRootOfTrustChallenge`.

**The run**, [bin/keystore-auth-test.sh](../bin/keystore-auth-test.sh), with each phase one launch of
Keystore Probe:

| Phase | Result | What decided it |
|---|---|---|
| the stage-4 suite | **20/20**, four times this session | — |
| `auth-gen`: generate both keys, then try to sign | **5/5** | keystore2: `authorize_create: matching auth token is expired` |
| the owner unlocks, 15:41:33 | — | gatekeeper verifies; gatekeeperd hands keystore2 the token |
| `auth-fresh`, started within a second | **4/4**: both keys sign, and both signatures verify in software | **this daemon**, which checked the auth token and the verification token |
| `auth-stale`, 18 s later | **2/2** | keystore2, with the same message as `auth-gen` |
| `auth-clean` | **1/1** | — |

**What the daemon saw at the one operation that reached it** (15:41:34; the key-generation line is from
`auth-gen`, abridged):

    generateKey {... USER_SECURE_ID=3207170475768154505 USER_AUTH_TYPE=1 AUTH_TIMEOUT=15} -> OK, 384-byte blob
    begin purpose=2 {ALGORITHM=3 DIGEST=4} -> OK, op 66e62ae8a0bec007 (1 open)
      auth: token type=1, 32-byte MAC of zeros; unsigned, accepted by --accept-unsigned-auth-tokens, 1008 ms old of 15000 allowed
    finish op 66e62ae8a0bec007 +500 -> OK, 72 bytes out
      auth: token type=1, 32-byte MAC of zeros, verification token; authorized at begin; verification token valid (AOSP software keymaster form)

Those lines show the four facts again, this time on the live path rather than a bench:

- **Fact 2.** The gatekeeper's token for a real unlock carries a MAC of 32 zero bytes. Its type is 1,
  `PASSWORD`, because a pattern counts as a password to gatekeeper.
- **Facts 1 and 3.** The TEE's verification token arrived at `finish` and verified under the H this
  session negotiated, in the AOSP machine-order form. It comes from km_compat's `SecureClock`, which is
  needed because a StrongBox has no clock in the HAL's model. This is a second, independent proof that H
  matches the TEE's, and it can only hold if K is zero.
- **Fact 4.** By this daemon's own `CLOCK_BOOTTIME` the token was 1008 ms old. That agrees with logcat,
  which shows `spBasedDoVerifyCredential` at 15:41:33.065 and the probe's signature at 15:41:34.
- **The key's binding.** Its `USER_SECURE_ID` is `0x2c82288e2e480989`, the SID `dumpsys lock_settings`
  reports for user 0. `isUserAuthenticationRequirementEnforcedBySecureHardware()` was **false** for
  the StrongBox key, as *The decision those facts force* intends.

**This run did not exercise the StrongBox's own refusals.** In both phases with no recent unlock,
keystore2 refused at `authorize_create` before calling `begin`, so those operations never reached the
daemon. It is the same gate that makes a TEE key here keystore2's to enforce. The daemon's refusal paths
are covered only by km-bench over real binder and by
[test_keystore_auth.cpp](../tests/cpp/test_keystore_auth.cpp), not by Android: an expired token, a
future-dated one, the wrong SID, the wrong authenticator type, the wrong challenge, a bad MAC. The run
also had no per-operation key (no `AUTH_TIMEOUT`, bound by challenge), because the probe only makes
timeout keys.

**The authentication was the owner's own unlock, not the planned PIN.** The script was written to set a
temporary PIN and authenticate with `cmd lock_settings verify`. It found that this Android already has
a **Pattern** credential, set 2026-09-07, and refused to touch it, as designed. Its refusal said
"already set" for a reason worth knowing: on A13, `lock_settings verify` with no `--old` throws
`Credential can't be null or empty` only when `isSecure()` is already true, and it throws before
reaching gatekeeper, so the check costs no attempt. The script now has a second path for this case.
That path never sets, verifies or clears the credential, because a wrong guess counts toward lockout.
First it refuses if a trust agent is granting trust. Then it locks the screen with `KEYCODE_SLEEP` and
`KEYCODE_WAKEUP` (`lock_screen_lock_after_timeout` is 0 here). Finally, one shell inside the container
waits for `dumpsys trust` to report `deviceLocked=0` and starts the probe the moment it does. That is
the real lockscreen path through `spBasedDoVerifyCredential` and gatekeeperd, so it is the stronger
test; its cost is that it needs a person at the machine. Its first attempt also produced Fault 3 above.

## Still not done

RSA, HMAC, 3DES and EC import; `upgradeKey` and `importWrappedKey`; the ESAPI backend; and the
`FEATURE_STRONGBOX_KEYSTORE` feature XML. The launch model and the RPM were done the next day as
`waydroid-ext-keystored` and `waydroid-ext-strongbox`, installed on bigtab01 that evening, where this
note's auth test passed 32/32 against the packaged daemon ([75](75-keystore-packaging.md)). On the feature XML specifically: stage 4 held it
back because auth-bound keys would fail here, and they no longer do — but advertising the feature tells
apps this machine has a StrongBox of the CDD's kind, and with unsigned tokens accepted its auth binding
is keystore2's, not its own. That is now a policy question for the owner rather than a missing piece.
