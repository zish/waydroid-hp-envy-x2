# 65 — A TPM behind Android's keystore: swtpm on bigtab01, Intel PTT on vidiot01

**Date:** 2026-10-10. **Status:** feasibility only when written. **Stage 0 done 2026-10-19** —
`waydroid-ext-swtpm` is built, packaged, installed and verified on bigtab01, and corrects two claims
below; see [71](71-swtpm-host.md). **Stages 1–4 done by 2026-10-22: StrongBox keys work from an ordinary
app on bigtab01, 20/20** ([73](73-keystore-stage1-engine.md)); stage 5 (the shared secret, and with it
auth-bound keys) and packaging are not started. Opened at the
owner's request as two roadmap items — *deploy swtpm to bigtab01 and configure LineageOS to use it*,
and *configure vidiot01's hardware TPM2 device to Waydroid*. They are scoped together here because
they are **one component with two backends**, in the same sense that
[29](29-wifi-plan.md)'s `WifiBackend` made NetworkManager one implementation among several.

Everything in the measurement tables was read off the two machines on 2026-10-10. Nothing in this
note is inherited from the other documents without being re-measured.

## The question, and the thing that decides its shape

The request reads as "point Android at the TPM". It cannot be done that way, and the reason is worth
stating before any plan: **nothing in Android speaks TPM 2.0.** There is no TPM client, no TCTI, no
`/dev/tpm*` consumer anywhere in either image. Android's hardware-backed key storage is reached
through exactly one interface — `IKeymasterDevice` on Android 13, `IKeyMintDevice` plus
`ISecureClock` and `ISharedSecret` on Android 16 — and that interface is served by a HAL.

So "configure LineageOS to use the TPM" means, unavoidably: **write a KeyMint HAL whose backend is
TPM 2.0.** That is the whole of the work. Deploying swtpm is an afternoon; the HAL is the project.

Short answers: **both are possible.** vidiot01 is the one with a security payoff. bigtab01's swtpm
buys **no security property whatsoever** over what its image already does, and is worth doing anyway
— as the development and regression rig for vidiot01's HAL, which is a real and separate use.

## What is on the two hosts

| | **bigtab01** | **vidiot01** |
|---|---|---|
| Hardware, per the owner | **TPM 1.2** | Intel PTT, TPM 2.0 |
| Exposed to the OS | **no** — `/dev/tpm*` absent, `/sys/class/tpm/` empty, and this boot logged `ima: No TPM chip found, activating TPM-bypass!` | `/dev/tpm0` *and* `/dev/tpmrm0` (in-kernel resource manager) |
| ACPI | **no TPM device in any of the ten tables** — no `MSFT0101` string and no `PNP0C31` EisaId in the DSDT, the six static SSDTs, or the three dynamically loaded ones (SSDT7–9); **no `TCPA` table** (1.2) and **no `TPM2` table** (2.0) among 23 | n/a (device present) |
| but the firmware does carry TPM plumbing | the DSDT *calls* `\_SB.TPM.PTS` and `SSDT1` branches on a `TPMP` flag — HP's physical-presence hooks, with no device declared anywhere behind them | |
| Kernel driver | `CONFIG_TCG_TPM=y`, `CONFIG_TCG_TIS=y` — **built in**, so a `tpm_tis.force=1` probe is a kernel argument and an rpm-ostree reboot, not a `modprobe` | in use |
| TPM identity | — | `TPM2_PT_MANUFACTURER` = **`INTC`**, vendor string `Intel`, family 2.0, revision **1.38**, firmware `0x1930001` — i.e. **Intel PTT, a firmware TPM in the ME**, not a discrete chip |
| `tpm2-tools` / `tpm2-tss` | 5.7-5.fc44 / present | 5.7-4.fc43 / 4.1.3-8.fc43 |
| `swtpm` | **not installed** | **already installed** — `swtpm`, `swtpm-tools`, `libtpms` 0.10.2 |
| OS shape | Fedora 44 Sway Atomic, rpm-ostree — a layered package costs a reboot (see [docs/user/ostree.md](user/ostree.md)) | Fedora 43 Workstation, traditional `dnf`, no reboot ([64](64-vidiot01-atv-host.md)) |
| `/dev/tpmrm0` ownership | — | `root:tss`, mode 0660 |
| SELinux label | — | `system_u:object_r:tpm_device_t:s0` |

**bigtab01's TPM is real and completely invisible, and that is a firmware state rather than a
hardware fact.** The owner's machine has a **TPM 1.2**; what is measured here is that *nothing is
exposed to the OS* — no device in any ACPI table including the three loaded at runtime, neither of
the two possible TPM tables, no driver bind, and the kernel saying so in as many words. The DSDT
calling `\_SB.TPM.PTS` while no `TPM` device is declared anywhere is the signature of a device
**hidden in firmware setup**, with its declaration simply not present.

So the first action on this item is not code. **Spend five minutes in that machine's firmware setup**
— HP of this generation puts it under Security as a *TPM Device* (Hidden / Available) plus a *TPM
State* (Disabled / Enabled). Three outcomes, in descending order of how good they are:

- **Best: the setup offers a TPM 1.2 → 2.0 mode switch.** HP shipped exactly that on much of its
  2015-era fleet, sometimes as a firmware utility rather than a setup item. If this unit has it,
  bigtab01 gets a **real TPM 2.0**, runs the same single code path as vidiot01, and the swtpm rig
  becomes a convenience rather than the only option. Switching clears the TPM, and nothing here
  depends on its current contents.
- **Second: the 1.2 device becomes visible.** Useful, with heavy qualifications — see the section
  below, which is the direct answer to "can we use the 1.2?".
- **Worst: it stays hidden.** Then swtpm is the only path, and the `tpm_tis.force=1` kernel argument
  is the one cheap thing left to try before giving up on the hardware.

**The largest practical TPM win on that machine has nothing to do with Android, and needs 2.0.**
[02](02-ssh-access.md) records that a cold boot halts at a LUKS passphrase prompt and that `sshd`
then has to be started by hand, so the machine is invisible until someone is physically at it. A TPM
2.0 would allow a `systemd-cryptenroll` sealed unlock and end that. **A TPM 1.2 would not** —
`systemd-cryptenroll` and `clevis` are both TPM2-only — and **swtpm cannot either**, for a
structural reason: its state file would live on the encrypted disk it is being asked to unlock.

## vidiot01's TPM is already in use, and must not be cleared

| | |
|---|---|
| Persistent handles resident | **4** — `0x81000001`, `0x81000002`, `0x81000009`, `0x81010001` |
| NV indices resident | `0x01410001`, `0x01410002` (8 bytes each, `written`) |
| Persistent slots free | 22 |
| NV indices free / NV counters free | 7 / 4 |
| **Transient object slots** | **3** (`TPM2_PT_HR_TRANSIENT_AVAIL = 0x3`, `HR_LOADED = 0`) |
| Owner hierarchy auth | **empty** — `tpm2_createprimary -C o` succeeds with no password |

The handle layout is the conventional one a Windows installation leaves behind — an SRK at
`0x81000001` and an RSA EK at `0x81010001`. **A `tpm2_clear` would destroy them**, and nothing in
this work needs one: the owner hierarchy takes no password, so our primary can be created under it
without disturbing anything. Decide with the owner whether those objects are expendable *before*
touching the TPM, not after.

**Three transient slots is the constraint that will shape the daemon.** A KeyMint backend cannot
keep Android's keys loaded; it must store wrapped blobs and load/flush per operation, and it must
serialise — which is the right design anyway, and is the design the measurements below support.

## It is fast enough — measured, not assumed

Each row is `/usr/bin/time` around a `sudo tpm2_*` invocation, so every number includes process
spawn and TSS startup and is an **upper bound** on what a resident daemon would pay:

| Operation | vidiot01 (Intel PTT) |
|---|---|
| `tpm2_createprimary -C o -G ecc` | 0.18 s |
| `tpm2_create -G ecc256` | 0.18 s |
| `tpm2_load` | 0.18 s |
| `tpm2_sign` (ECDSA, SHA-256) | 0.21 s |
| `tpm2_create -G rsa2048` ×5 | 0.12, 0.15, 0.14, 0.14, 0.14 s |
| 10 × ECDSA sign, one `sudo`, loop inside | 2.20 s total |

RSA-2048 key creation in ~0.14 s is unusual for a firmware TPM and was re-run five times for that
reason; it is consistent. **This retires the obvious objection** — that a TPM-backed keystore would
stall every app that generates a key — but only for the `strongbox` shape recommended below. Behind
the *default* keystore, 0.2 s per operation on every app's every key is a different proposition.

## What is in the two Android images

Read from the running containers and from the mounted rootfs on each host.

| | **bigtab01 — A13, SDK 33**, `20.0-20260403-GAPPS-waydroid_x86_64` | **vidiot01 — A16, SDK 36.1**, `BP4A.251205.006` |
|---|---|---|
| Interface in play | **HIDL** `android.hardware.keymaster@4.0::IKeymasterDevice` | **AIDL** `android.hardware.security.keymint` |
| Service running | `vendor.keymaster-4-0` → `/vendor/bin/hw/android.hardware.keymaster@4.0-service` | `vendor.keymint-default` → `/vendor/bin/hw/android.hardware.security.keymint-service` |
| Gatekeeper | `vendor.gatekeeper-1-0` (HIDL 1.0) + `gatekeeperd` | `vendor.gatekeeper_nonsecure` registering `IGatekeeper/default` **and `ISharedSecret/gatekeeper`** + `gatekeeperd` |
| `keystore2` | running | running |
| VINTF declares | `android.hardware.keymaster`, `android.hardware.gatekeeper` | `android.hardware.security.keymint`, `…secureclock`, `…sharedsecret` |
| Framework feature | **none** — no `android.hardware.hardware_keystore` in 76 features | **`android.hardware.hardware_keystore=400`** and `android.hardware.keystore.app_attest_key`, of 85 |
| KeyMint libs in image | `keymint-V1`/`V2` cpp+ndk | `keymint-V1`, **`keymint-V4`** ndk, `libpuresoftkeymasterdevice.so`, `libkeymint_fake_latest.so` |
| `hwservicemanager` / `servicemanager` | both running | both running |
| `android.software.secure_lock_screen` | declared | declared |

Two things fall out of that table. **A16 already runs a three-way shared-secret arrangement** —
gatekeeper and keymint both participate in `ISharedSecret`, which is the mechanism any third
participant (a fingerprint HAL — see [66](66-fingerprint-hal.md)) would have to join. And **A16
claims `hardware_keystore` version 400 today, on a software KeyMint**: the image is already telling
apps it has hardware-backed keys. There is no TEE under a container on a Linux host, so that claim
is false now; a TPM-backed instance would be the first thing on either machine that could make a
version of it true.

## The recommendation: add a `strongbox` instance, do not replace `default`

Both HIDL keymaster 4.0 and AIDL KeyMint are *instanced* interfaces with two conventional names,
`default` and `strongbox`. Android surfaces the second one as
`FEATURE_STRONGBOX_KEYSTORE`, and apps reach it only by asking —
`setIsStrongBoxBacked(true)`. That is the shape this work should take, for four reasons:

- **Failure is contained.** If the daemon is slow, wedged or incomplete, every existing app keeps
  using the image's software keystore and nothing regresses. Replacing `default` puts the lockscreen,
  every credential and every app's keys behind our first draft.
- **The gate is one overlay file**, `/system/etc/permissions/android.hardware.strongbox_keystore.xml`
  — the same mechanism that woke the whole Wi-Fi framework in [31](31-wifi-stage2.md)'s stage 0, and
  the same directory `artifacts/overlay/system/etc/permissions/android.hardware.wifi.xml` already
  lives in.
- **Nothing has to be stood down.** Replacing `default` means taking a name the stock service already
  holds, which is the `wificond.rc` manoeuvre from [34](34-wifi-second-radio.md) — deployable, but a
  boot-path change on the one subsystem that can lock a user out of their own device.
- **It is the shape the prior art uses**: `JavaCardKeymaster` and Thales' `javacard-keymint-hal` are
  both StrongBox instances backed by hardware that is not the TEE.

The honest cost of the recommendation is that almost no app asks for StrongBox, so the visible
result is a feature flag, a `dumpsys` line and whatever test app we write — not a changed phone. Say
that out loud now rather than discovering it at the end.

## TPM 1.2 — the direct answer

**Can bigtab01's TPM 1.2 be used?** Technically yes, for exactly one job, and it still should not be
the backend. Four facts decide it:

- **`tpm2-tools` and `tpm2-tss` cannot talk to a 1.2 chip at all.** They are not a compatibility
  layer; TPM 1.2 and 2.0 are different command sets. The 1.2 userspace is **TrouSerS** (`tcsd`,
  `libtspi`), which is still built for Fedora 44 — `trousers-0.3.15-17.fc44`, actively maintained,
  checked 2026-10-10 — so the stack does exist. The alternative is hand-rolling the handful of
  ordinals needed straight onto `/dev/tpm0`, which is a real option but means implementing 1.2's
  OIAP/OSAP authorization-session HMAC protocol ourselves.
- **Its algorithm set cannot run Android's crypto.** TPM 1.2 is RSA (≤2048) plus SHA-1, with no ECC,
  no AES and no general HMAC engine. Android asks for EC P-256, AES-GCM/CBC and HMAC-SHA256. None of
  those can happen inside a 1.2 chip.
- **But the hybrid design does not ask it to.** The design this note recommends has the TPM protect a
  wrapping key while operations run in the daemon — and `TPM_Seal`/`TPM_Unseal` plus an RSA storage
  key is precisely what a 1.2 chip is good at. It is also what ChromeOS did with Chaps on TPM 1.x
  for years. So a 1.2 backend is **implementable**, and it would be a genuine improvement on swtpm
  on that machine: the wrapping key would really be non-exportable.
- **The cost is a second TSS for the machine where the result matters least.** bigtab01 is a
  two-core Broadwell tablet running a kiosk, 1.2 seal/unseal is slow, 1.2 RSA keygen is slower
  still, and the whole point of swtpm there was to keep **one** TPM 2.0 code path shared with
  vidiot01.

**So the decision is a design decision, not a build decision:** write the backend contract narrowly
enough that a 1.2 chip can satisfy it — *seal a blob, unseal a blob, wrap and unwrap a key, and
nothing else* — and leave the 1.2 implementation unwritten until someone wants it. That keeps the
option alive at no cost, and it is a better contract anyway, because it is also the contract a
smartcard or a Yubikey could satisfy. bigtab01 has a Yubikey 5 permanently attached (see
[66](66-fingerprint-hal.md)'s `lsusb`), which makes that last point less hypothetical than it sounds.

## How to settle the firmware question on bigtab01

The machine is identified from SMBIOS: **HP ENVY x2 Detachable PC 13**, SKU `J9M66UAR#ABA`, **Insyde**
BIOS **F.0F** dated 2016-05-30, platform firmware 15.15, EC 94.26. Three things follow, all measured
2026-10-10.

**SMBIOS cannot answer it.** The TPM Device structure is **DMI type 43**, introduced in SMBIOS 3.1,
and this firmware reports **SMBIOS 2.7** — so there is no type-43 record to read and the chip cannot
be identified from the OS while the device is hidden. UEFI cannot answer it either: **none** of the
73 variables in `/sys/firmware/efi/efivars/` is a TCG, TPM or physical-presence variable, so the
firmware is not exposing a PPI interface in this configuration.

**So the answer is in setup, and there is a password on it.** DMI type 24 reports *Administrator
Password Status: Enabled*, so entering setup needs that password. On an Insyde BIOS the settings live
under **Security**, named any of *Security Device Support*, *TPM Device*, *Intel Platform Trust
Technology*, then *TPM State*, and — the one that matters — a *TPM Version* or *TPM Device Mode*
selector offering **1.2 or 2.0**. **If that selector exists, it is the switch.** Three outcomes:

| What setup shows | What it means |
|---|---|
| A 1.2 / 2.0 version or mode selector | **Best case.** Switch to 2.0, which clears the TPM (nothing here depends on its contents), and bigtab01 runs the same single code path as vidiot01 against real hardware |
| TPM settings, but no version selector | Enable it and read `cat /sys/class/tpm/tpm0/tpm_version_major` — `1` or `2`, definitive, no guessing. A `1` puts you in the section above |
| No TPM entry at all | Likely on a consumer Insyde BIOS. HP's *TPM Configuration Utility*, the 1.2↔2.0 switcher, was published for its **commercial** lines (EliteBook, ProBook, ZBook), not generally for Envy units — so expect this and plan for swtpm |

**One cheap attended test remains if setup shows nothing.** `tpm_tis` is built into this kernel
(`CONFIG_TCG_TIS=y`), so forcing a probe of the standard TIS window is a kernel argument rather than
a `modprobe` option: `rpm-ostree kargs --append-if-missing=tpm_tis.force=1`, then reboot. If a chip
answers there, it appears without any ACPI declaration. Do it with the machine in front of you —
[02](02-ssh-access.md): a reboot there means the LUKS passphrase and starting `sshd` by hand — and
drop the argument again if nothing appears.

> **Done 2026-10-20 — nothing appeared, and this is now the settled answer.** Password cleared (DMI
> type 24 *Disabled*), no hidden menu by any keystroke, WMI still only `Sure_Start`, no TCG efivar.
> `tpm_tis.force=1` returned `TPM vid 0xFFFF, did 0xFFFF … error -19` — a floating bus, so no discrete
> chip. The ME is present (10.0.25.1048) but PTT is un-activated and unreachable from the OS. The
> third table row is the real one: **swtpm is bigtab01's backend.** Evidence in [71](71-swtpm-host.md).

## swtpm works with no TPM hardware at all — demonstrated

Run in the **dev container on 2026-10-10**, which is the closest available analogue of bigtab01: it
has no usable TPM (`/dev/tpmrm0` is passed through from vidiot01 but is `root:tss` 0660 and the
container's `coder` is not in that group, so `tcti-device` fails outright). No privilege was used at
any point.

| | |
|---|---|
| Packages | `swtpm` 0.7.1 and `tpm2-tools` 5.7 from Debian trixie, both installed on the dev box for this |
| **`tcti-swtpm` is shipped by all three environments** | `libtss2-tcti-swtpm.so` is in tpm2-tss on the dev box, on **vidiot01 (F43)** and on **bigtab01 (F44)** — so no custom TCTI is needed anywhere |
| Identity through the TCTI | TPM **2.0**, `TPM2_PT_MANUFACTURER` = `IBM`, vendor string `SW` (libtpms) |
| Transient object slots | **3** — the same as the Intel PTT, which is a happy accident worth keeping: the dev rig has the constraint the real hardware has |
| Persistent slots | 65 |
| NV survives a new client connection | **yes** — `tpm2_evictcontrol` to `0x81000020`, then `tpm2_getcap handles-persistent` from a separate process lists it |
| `createprimary` (ECC) | **0.015 s** |
| `create` (ECC P-256) | **0.014 s** |

**That is ~12× faster than the Intel PTT's 0.18 s, which is a warning rather than a win: never
performance-test the HAL on swtpm.** Timing claims have to come from vidiot01, and latency budgets
from the slowest machine in play.

Two gotchas cost time and are worth having before stage 0. The TCTI **appends `.ctrl` itself**, so
the control channel must be named `<server-path>.ctrl` — `--ctrl type=unixio,path=/run/swtpm/s.ctrl`
against `--server type=unixio,path=/run/swtpm/s` — and a mismatch fails with *Failed to set locality*
rather than anything about sockets. And swtpm refuses a long unixio path outright (*Path for UnioIO
socket is too long*), so the socket belongs somewhere short like `/run/swtpm/`, not under a deep
build directory. The invocation that worked:

```bash
swtpm socket --tpm2 --tpmstate dir=/run/swtpm/state \
  --server type=unixio,path=/run/swtpm/s \
  --ctrl   type=unixio,path=/run/swtpm/s.ctrl \
  --flags not-need-init,startup-clear --daemon
export TPM2TOOLS_TCTI="swtpm:path=/run/swtpm/s"
```

> **Corrected 2026-10-19 ([71](71-swtpm-host.md)).** This demonstration passed only because it
> stopped at two objects. swtpm has no resource manager and tpm2-tools leave every object they load
> behind, so the third object fails `TPM_RC_OBJECT_MEMORY` and swtpm refuses everything until it
> restarts. Any client of the socket must flush what it loads.

**Prefer this unix-socket shape to the two alternatives**, for a reason that is about the host policy
rather than taste: a socket involves no character device, so none of the `tpm_device_t` labelling
question arises at all, whereas `swtpm cuse` creates a `/dev/vtpmX` whose label would have to be
dealt with, and the mssim TCP shape would open a port on a machine that also serves the `vidiot` AP
([64](64-vidiot01-atv-host.md)). Note that swtpm's own control channel is **not** the Microsoft
simulator protocol — `tcti-mssim` against `swtpm socket` fails on `MS_SIM_NV_ON`, which is measured,
not assumed.

## What a TPM buys here, and what it cannot

| | **vidiot01, Intel PTT 2.0** | **bigtab01, swtpm** | **bigtab01, TPM 1.2 if enabled** |
|---|---|---|---|
| Keys unextractable from the machine | **yes** — sealed under a TPM primary, usable only on this fTPM | **no** — the state file is a file, protected by file permissions | **yes**, for the wrapping key only |
| Rate limiting / lockout on key misuse | yes, TPM dictionary attack logic | simulated, and resettable by deleting a file | yes, and cruder — 1.2 lockout is punishing |
| Can perform Android's own algorithms | partly, and the design does not need it to | partly | **no** — RSA and SHA-1 only |
| Works with the tpm2 stack already installed | yes | yes | **no** — needs TrouSerS or hand-rolled ordinals |
| Better than the software keymaster already in the image | **yes** | **no — identical trust boundary** | yes, marginally |
| Hardware key attestation apps can verify | **no** | **no** | **no** |
| Useful as a development and CI target for the HAL | yes | **yes, and this is its entire value** | no — it is a third backend, not a rig |

**The attestation row is the one that disappoints people**, so it is worth being precise. `attestKey`
has to return an X.509 chain rooted in a key Google signed and published. A TPM-backed HAL can only
self-sign, and the TPM's own EK certificate is an Intel certificate attesting to an Intel fTPM — not
to an Android device. So anything that checks hardware attestation (Play Integrity's strong verdict,
enterprise attestation, some banking apps) will reject it. Key *protection* is achievable here;
attestation is not, and no amount of work changes that. It is an explicit non-goal.

## Why the binder surface is not the hard part — and where the hard part is

The interface is small. Upstream, `IKeymasterDevice` 4.0 is 19 methods; KeyMint splits roughly 13 on
`IKeyMintDevice`, 4 on `IKeyMintOperation`, 1 on `ISecureClock`, 2 on `ISharedSecret` and 3 on
`IRemotelyProvisionedComponent`. Against the **203 method slots** [30](30-wifi-aidl-surface.md)
counted for the supplicant, this is a small surface. Those counts are upstream-derived and should be
pinned against these images' own bytecode with the technique [30](30-wifi-aidl-surface.md) used for
`IWificond` before a line is written.

The work is in the semantics:

- **Key blobs.** Keymaster keys are opaque blobs the HAL mints and parses, carrying the
  authorization list. The natural TPM mapping is `TPM2_Create` under a persistent primary, with the
  wrapped blob plus our tag encoding handed back to Android. Tag enforcement is ours to implement;
  the TPM will not do it for us.
- **The hybrid every shipping implementation uses.** A TPM 2.0 does not offer everything Android's
  tag model asks for, so the practical design is for the TPM to protect a wrapping key and for
  operations to run in the daemon against material unsealed per use. That is what ChromeOS's
  `arc-keymaster` does through Chaps and cryptohome. It is also the design's weak point and should be
  written down as such: during an operation, key material is in host RAM.
- **The operation state machine.** `begin`/`update`/`finish`/`abort` with operation handles, against
  three transient TPM slots, needs a queue and a cap, and Android will ask for more concurrent
  operations than the TPM can hold.
- **`upgradeKey`, boot levels and rollback resistance** all have to do something defensible.
- **`computeSharedHmac`.** Joining the shared-secret negotiation is what makes
  `HardwareAuthToken`s verifiable, which is the hinge between this note and
  [66](66-fingerprint-hal.md).

## Plumbing, including two traps already paid for elsewhere

- **SELinux is already out of the way** — and this was measured rather than assumed, with
  `selinux.selinux_check_access()` exactly as [42](42-backlight-selinux.md) recommends, because the
  denial would otherwise be `dontaudit`ed and invisible. On vidiot01, `unconfined_service_t`,
  `unconfined_t` **and** `container_runtime_t` are all allowed `read write open ioctl` on
  `tpm_device_t:chr_file`. No policy module is needed for TPM access.
- **The daemon needs `root` or group `tss`** for `/dev/tpmrm0` (0660 `root:tss`). Prefer `tpmrm0`
  over `tpm0`: the in-kernel resource manager is what makes concurrent contexts survive three
  transient slots.
- **Expect the binder `transfer` denial on A16, and not on A13.** `IKeyMintDevice::begin()` returns
  an `IKeyMintOperation` **binder**, so a host daemon must transfer a binder into the container —
  which is the precise permission that is allowed for `call` and denied-and-`dontaudit`ed for
  `transfer`, cost [35](35-wifi-stage5.md) a day, and presents as a bare `DeadObjectException` with a
  clean `ausearch`. A13's HIDL keymaster passes only value types and will not show this. Set
  `SELinuxContext=` in the unit from the first commit.
- **libgbinder on A16 wants `aidl6`**, per [64](64-vidiot01-atv-host.md): Waydroid moves
  `service_manager_protocol` at API 36 and `wifi/service.cpp` hardcodes `aidl3`. vidiot01's
  libgbinder 1.1.47 implements `aidl6`. Any new daemon should take the version from a parameter.
- **A VINTF fragment declares the instance**, the same mechanism the widevine fix and Wi-Fi stage 4
  use; `artifacts/overlay/vendor/etc/vintf/manifest/` already holds one to copy.
- **An overlay file is not live until the Waydroid *session* restarts.** The overlay merge and the
  LXC `config_nodes` entries are both read at session start: on bigtab01 that means logging out of
  the `waydroid-cage` session and back in, and in app mode `waydroid session stop` and relaunching
  the app ([63](63-second-host-and-android-16.md)). Neither `waydroid container restart`
  ([32](32-wifi-stage3.md)) nor `systemctl restart waydroid-container.service` applies it — the
  second ends the session, applies nothing and still reports success
  ([AGENTS.md](../AGENTS.md)). Read the file from inside the container to confirm it.

## Prior art worth reading before designing anything

- **ChromeOS `arc-keymaster` / `arc-keymint`** — a *host* daemon serving Android's keymaster HAL,
  backed by the host's TPM through Chaps (PKCS#11) and cryptohome. This is the same architecture as
  `waydroid-sensord` and `waydroid-wifid`, already shipping, for this exact interface. Closest match
  there is. <https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/arc/README.md>
- **`divegeek/JavaCardKeymaster`** and **`ThalesGroup/javacard-keymint-hal`** — KeyMint/Keymaster
  implementations for a StrongBox instance backed by non-TEE hardware; the reference for the
  instance shape recommended above.
- **`Infineon/optiga-tpm-aosp`** — cross-compiling tpm2-tss into AOSP and running against a TPM
  simulator. Relevant if the HAL ever has to live *inside* Android rather than on the host, and for
  its simulator wiring, which is bigtab01's swtpm story in a different costume.

## Staging, in the order that makes each step verifiable

0. **The firmware check first** — it can change this entire item, and it costs five minutes with the
   machine in front of you. The host rig behind it is **already proven on the dev box** (above), so
   what is left is: layer `swtpm`/`swtpm-tools` on bigtab01 (one rpm-ostree transaction and a
   reboot — and check that the `tss` user gets created, because `tpm2-tss` is installed there today
   without one and its tmpfiles fail on every boot — **corrected in [71](71-swtpm-host.md): `tss` is
   uid 59 in `/usr/lib/passwd`, and the failing lines are the initrd's**), then show the same tpm2-tools sequence passing
   through `swtpm:path=…` on bigtab01 and through `device:/dev/tpmrm0` on vidiot01. Deliverable: one
   script in `bin/` that takes the TCTI as a parameter and passes on both hosts — which is the
   backend seam appearing at the shell before it appears in code.
1. **Backend first, Android last.** A keyblob service — seal, unseal, generate, sign, with the
   wrapping-key design and a hard concurrency cap — exercised by a test harness on the host. No
   binder yet. This is where the TPM semantics get settled, and it is portable between the two hosts
   by construction.
   **Done 2026-10-21 — [73](73-keystore-stage1-engine.md), 15/15 on the dev box and on bigtab01.**
   One design change on contact: the engine is **native-TPM, not the wrapping-key hybrid**. A TPM
   2.0 does EC P-256 / AES / HMAC natively, so a stage-1 key is a TPM child object and the primitive
   runs *inside* the TPM — no OpenSSL, no build dependency, and key material never leaves the TPM
   mid-operation (the hybrid's weak point). The hybrid seal/unseal contract is kept as the path to a
   1.2/smartcard/Yubikey backend behind the same `TpmBackend` seam, not written. The backend under
   that seam is tpm2-tools-exec for now; the ESAPI backend that ships in the RPM drops in unchanged.
2. **The feature XML alone**, into the overlay, plus a VINTF fragment for a `strongbox` instance with
   nothing behind it. Expect `keystore2` to log a declared-but-absent instance. That informative
   first failure is the stage-0 result, and it also answers the open question about whether each
   framework surfaces the feature at all.
   **Answered from the baseline, 2026-10-22, so never armed; and the fragment turned out to break
   boot** — a VINTF fragment re-declaring keymaster@4.0 conflicts with the vendor manifest, and the
   working route overrides `manifest.xml` whole ([73](73-keystore-stage1-engine.md)).
3. **Register the instance over libgbinder**, `getHardwareInfo` only. This is where the
   binder-`transfer` trap appears on A16, so expect it and keep the stage small.
   **Done 2026-10-22 (stage 3a): keystore2 binds it as STRONGBOX.**
4. **EC P-256 and AES keys**, generate / sign / verify, tags enforced. Verified by a dependency-free
   APK in the `sensor-app/` mould, since nothing in the image will ask for StrongBox on its own.
   **Done 2026-10-22: [keystore-probe/](../keystore-probe) passed 20/20 from Android** — EC P-256
   signing, AES-GCM and AES-CBC, with GCM built from the TPM's ECB ([73](73-keystore-stage1-engine.md)).
5. **Auth-bound keys and `computeSharedHmac`**, which is the step that makes
   [66](66-fingerprint-hal.md)'s auth tokens real.

Non-goals, stated so they do not creep in: attestation; replacing `default`; anything inside the
Android image; and any claim that bigtab01's swtpm improves that machine's security.

## Open questions

1. **What does bigtab01's firmware setup actually offer** — a *TPM Device* / *TPM State* pair, and
   crucially a **1.2 → 2.0 mode switch**? **Answered 2026-10-20: there is no TPM in reach, and no
   OS-side way to put one there — this item has one backend on bigtab01, swtpm, not two.** The owner
   cleared the administrator password (DMI type 24 now reads *Administrator Password Status:
   Disabled*) and still found **no hidden setup menu** by any keystroke — the third table outcome
   above, the one predicted for a consumer Insyde BIOS. With the password gone the writable WMI
   surface is unchanged: `hp-bioscfg` exposes only `Sure_Start` and `fwupdmgr` only a read-only
   `pending_reboot`, so there is no TPM attribute to set; no TCG/TPM/PPI EFI variable exists; and the
   one place the bit could live, the 1404-byte Insyde `Setup` blob, has its offset locked in the
   encrypted firmware image. The attended `tpm_tis.force=1` probe then settled the hardware — the
   kernel read **`TPM vid 0xFFFF, did 0xFFFF … error -19`**, a floating bus with *nothing* wired at
   the TIS window, so there is **no discrete chip**. The Management Engine is present and healthy
   (Wildcat Point-LP, `mei_me`, ME firmware **10.0.25.1048**), so the "TPM 1.2" is **Intel PTT the
   firmware never activates**, not a discrete part — and PTT is switched on only in setup, which
   offers no such control. Real hardware TPM 2.0 stays vidiot01's alone. Full evidence in
   [71](71-swtpm-host.md).
2. **Are vidiot01's four resident persistent handles and two NV indices expendable?** They look like
   a prior Windows install's SRK and EK. Nothing here needs them cleared; confirm before anyone is
   tempted.
3. **Does A13's `keystore2` surface `FEATURE_STRONGBOX_KEYSTORE` from a declared second HIDL
   keymaster instance**, or does it need more than the feature XML? Pin from `services.jar` bytecode.
   **Answered 2026-10-22 from a clean boot, no overlay change — yes, and it needs a *served
   instance*, not the feature XML.** `android.security.compat` (`IKeystoreCompatService`) is running,
   and `keystore2` already reaches for a StrongBox KeyMint **every boot** through its km_compat
   *Legacy wrapper* — the boot log reads `keystore2::error: In get_keymint_device … In
   connect_keymint: Trying to get Legacy wrapper … Error::Km(ErrorCode(-68))` (−68 =
   `HARDWARE_TYPE_UNAVAILABLE`), and `shared_secret_negotiation: No StrongBox Keymint available`. So
   the discovery path is live with no VINTF strongbox entry present; serving
   `android.hardware.keymaster@4.0::IKeymasterDevice/strongbox` (as the `default` HIDL instance
   already is, wrapped for TEE) is what turns −68 into a real StrongBox. The feature XML is only
   PackageManager's half. Still to pin: whether the legacy wrapper needs the VINTF declaration to
   *bind* a served instance or binds it from hwservicemanager regardless — stage 3 settles it.
   **Settled by stage 3a: it needs the declaration.** Served but undeclared, keystore2 never contacts
   the daemon at all ([73](73-keystore-stage1-engine.md)).
4. **What does each `keystore2` do when a strongbox instance fails `computeSharedHmac`?** If it
   refuses to boot the keystore rather than dropping the instance, stage 3 is riskier than it looks
   and belongs behind a `session stop` rather than a reboot.
   **The *absent* case is answered 2026-10-22: `keystore2` does not refuse to boot.** With no
   StrongBox present it logs the −68 above, `earlyBootEnded` fails for `STRONGBOX` (and `vold` logs
   `earlyBootEnded returned service specific error: -68`), shared-secret negotiation still
   *concludes successfully* for the TEE instance, and `keystore2` registers and runs with a working
   lockscreen. So a declared-but-absent StrongBox is safe — the stage-2 "informative failure" was
   obtained from the baseline, which is why no empty instance was ever armed. *Corrected by stage 3a:*
   that baseline was **undeclared**, not declared-but-absent — with no manifest entry keystore2 never
   reaches for the instance at all. A strongbox that is declared with nothing serving it has still
   never been booted, which is why the manifest and the daemon are deployed and removed together.
   **The *present but failing* case is still unproven**: when a strongbox instance joins shared-secret negotiation and
   computes a *disagreeing* HMAC, whether negotiation still concludes for everyone or breaks the TEE
   instance too is the real stage-3/5 risk. Treat `computeSharedHmac` as load-bearing from the first
   strongbox commit, and land stage 3 behind a `session stop`, not a reboot, until this is measured.
   **Answered safe by stage 3a, 2026-10-22:** with our empty check keystore2 logged `NOT PROVISIONED
   CORRECTLY`, still concluded negotiation, and the TEE instance and the lockscreen were unaffected
   ([73](73-keystore-stage1-engine.md)).
