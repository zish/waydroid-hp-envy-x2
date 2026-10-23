# 71 — swtpm on the host: docs/65's stage 0, packaged

**Date:** 2026-10-19. **Status:** built, packaged as `waydroid-ext-swtpm` 1.0.0, and **installed and
verified on bigtab01** the same day — layered with rpm-ostree, running from boot, 15/15 and then 19/19
across a restart, zero AVCs. This is the 25th `waydroid-ext-*` package on that machine.
**2026-10-22: uninstalled at the owner's request and rebooted out** (exactly the package and its four
swtpm dependencies left, nothing re-resolved), **then reinstalled the same evening** with
`rpm-ostree install --apply-live` to back stage 4 ([73](73-keystore-stage1-engine.md)). A live apply
is not durable until the next boot into it; until then `/usr/bin/swtpm` reads `unlabeled_t`, as
predicted below, and the service ran fine regardless.

This is stage 0 of [65](65-tpm-keystore.md): a software TPM 2.0 the host-side keystore backend can talk
to, and one script that proves a TPM does what that backend needs through any TCTI. **Nothing inside
Android can see it, and that is by design rather than unfinished business** — no Android interface
speaks TPM 2.0 ([65](65-tpm-keystore.md)), so the consumer is a keystore HAL that does not exist yet.
And on bigtab01 it buys no security property over the image's software keymaster: the TPM's seeds are a
file on the same disk.

## What it is

| | |
|---|---|
| Unit | `waydroid-swtpm.service`, enabled by a shipped `multi-user.target.wants` symlink |
| Process | `swtpm socket --tpm2 --flags not-need-init,startup-clear`, as user `tss`, via `/usr/libexec/waydroid-swtpm` |
| Socket | `/run/swtpm-waydroid/sock` (+ `sock.ctrl`), `tss:tss` 0660 in a 0750 directory |
| State | `/var/lib/swtpm-waydroid/tpm2-00.permall`, `tss` 0600 in a 0700 directory, **not** owned by the package |
| TCTI | `swtpm:path=/run/swtpm-waydroid/sock` — tcti-swtpm ships in tpm2-tss on F43, F44 and Debian |
| Check | `waydroid-tpm-check [--tcti T] [--save DIR \| --verify-saved DIR]` |

Source in [artifacts/swtpm/](../artifacts/swtpm), package definition in
[packaging/mods/swtpm.mod](../packaging/mods/swtpm.mod).

## Four findings, each of which changed the design

### 1. systemd cannot start Fedora's swtpm directly, by any of the three obvious routes

`swtpm` carries a rich dependency, `(swtpm-selinux if selinux-policy-targeted)`, so every targeted-policy
host gets `swtpm-selinux` with it. That module labels `/usr/bin/swtpm` `swtpm_exec_t` and declares
`swtpm_t` with `application_domain()` — **not** `init_daemon_domain()` — because its only intended caller
is libvirt. Asked of the loaded policy with `security_compute_create()` and `security_compute_av()` (not
`ausearch`, per [42](42-backlight-selinux.md)), on vidiot01, F43, `selinux-policy-43.10`, swtpm-selinux
0.10.2:

| How the unit could start it | What the policy says |
|---|---|
| `ExecStart=/usr/bin/swtpm` | no transition rule, so it would stay **`init_t`** — and `init_t` is **denied `execute`** on `swtpm_exec_t`: the unit cannot start at all |
| `SELinuxContext=…:swtpm_t:…` | `init_t → swtpm_t` **transition denied**; and `swtpm_t` may not `write`/`add_name` on `var_lib_t` or `var_run_t`, nor create files or sockets there — only libvirt's types |
| `SELinuxContext=…:unconfined_service_t:…` | the transition is allowed, but `unconfined_service_t` is **denied `entrypoint`** on `swtpm_exec_t` |
| a `bin_t` wrapper that `exec`s swtpm | **open**: `init_t` running `bin_t` defaults to `unconfined_service_t` (transition, `nnp_transition` and `entrypoint` all allowed), and `unconfined_service_t` may `execute_no_trans` `swtpm_exec_t`, staying put |

The same wrapper-route answers came back on bigtab01 (F44, `selinux-policy-44.11`) for every row that
does not need swtpm installed. So swtpm runs as `unconfined_service_t`, entered through a file that is
ours, with **no policy module** and nothing granted to any other domain. `/usr/local/libexec` is `usr_t`
rather than `bin_t`, and `init_t` → `usr_t` also defaults to `unconfined_service_t`, so a hand install
works too. The wrapper prints its domain on every start, so the journal says which domain it got
instead of leaving that to inference.

**Not done, deliberately:** a CIL module making `swtpm_t` an init daemon with private state types. It is
better confinement, but it is an iterative AVC hunt for every permission a systemd daemon needs, and a
`type_transition` of ours would collide at compile time the day swtpm-selinux grows its own — a module
that refuses to load is worse than the gap it closes. Revisit if this ever protects something.

### 2. Anything named `waydroid-*` inherits Waydroid's SELinux types

`matchpathcon` on both hosts gives `/var/lib/waydroid-swtpm` → **`waydroid_data_t`** and
`/run/waydroid-swtpm` → **`waydroid_var_run_t`**. The rules are prefix matches in Fedora's own waydroid
module:

```
/run/waydroid-(?!lxc).*   system_u:object_r:waydroid_var_run_t:s0
/var/lib/waydroid(.*)?    system_u:object_r:waydroid_data_t:s0
```

Those are types Android's own container domain is meant to reach, and a TPM's seeds should not wear
them. So the unit keeps the project's `waydroid-` prefix while the directories are inverted to
`swtpm-waydroid`, which label as plain `var_lib_t` and `var_run_t`. **This applies to every future
package here that creates a directory under `/run` or `/var/lib`** — check `matchpathcon` first.

### 3. Against swtpm, tpm2-tools leak every object, and three slots run out on the third

swtpm has no resource manager. Measured in the dev container: `tpm2_createprimary` leaves the primary
loaded at `0x80000000`; `tpm2_create -C primary.ctx` context-loads a *second* copy of the parent and
leaves that too; and `tpm2_load` then fails `TPM_RC_OBJECT_MEMORY` (`0x902`) with
`TPM2_PT_HR_TRANSIENT_AVAIL = 0x0`. From that point **swtpm refuses every object operation until it
restarts.** [65](65-tpm-keystore.md)'s demonstration passed only because it stopped at two objects. Behind
`/dev/tpmrm0` the kernel's resource manager flushes on close, which is why this never shows on vidiot01.

So `waydroid-tpm-check` snapshots the loaded transient objects and sessions when it starts and, after
every step, flushes whatever was not in that snapshot. A second run immediately after the first finds
all three slots free, and the selftest asserts exactly that. Two consequences for later stages:

- **The keystore backend must load and flush per operation and own the TPM connection** — which
  [65](65-tpm-keystore.md) already recommended for the three-slot reason and is now also required for
  correctness. A second concurrent client of the socket needs `tpm2-abrmd` in front of swtpm.
- **Do not run the check against swtpm while the backend is mid-operation**: a handle the backend loads
  after the check's snapshot is indistinguishable from one of the check's own.

Considered and rejected: `swtpm chardev --vtpm-proxy`, which would give the host a real
`/dev/tpm0`/`/dev/tpmrm0` backed by swtpm, with the kernel's resource manager and the *same* TCTI as
vidiot01's hardware. It is attractive and it is a trap: the host would then believe it has a TPM.
`systemd-cryptenroll --tpm2-device=auto` would accept it and seal a LUKS key into swtpm's state file,
which on bigtab01 sits inside the very LUKS volume it would be unlocking — `/var`, `/var/home`, `/etc`
and `/sysroot` are all on `sda3`'s one `crypto_LUKS` partition, measured — and which exists only after
boot, never in the initrd that has to do the unlocking. On a host whose `/var` is *not* encrypted, the
same enrolment would put the unlock secret in a file anyone with the disk can read. Either way the host
gains something that looks exactly like a TPM and is not one, and a package for "other people" must not
ship that.

### 4. swtpm logs one line per TPM command, and its log level cannot stop it

tcti-swtpm opens a fresh connection for each TPM command, and swtpm logs `swtpm: Data client
disconnected` on each close: **543 lines for three runs of the check** on bigtab01's 0.10.2, the same on
the dev box's 0.7.1. `--log level=0` still prints it, and `--log fd=2,…` makes swtpm exit silently, so
the unit drops exactly that message with `LogFilterPatterns=~^swtpm: Data client disconnected$` and keeps
everything else. Through a keystore backend it would have been several journal lines per Android key
operation.

## What was verified, and where

| | Dev box (Debian, swtpm 0.7.1) | bigtab01, unprivileged preflight (F44 swtpm 0.10.2) |
|---|---|---|
| `waydroid-tpm-check` through the wrapper | **15/15** | **15/15** |
| a second run on the same swtpm (no leak) | pass, `TRANSIENT_AVAIL` back to `0x3` | pass |
| restart on the same state, `--verify-saved` | **19/19** — same owner primary, sealed blob unseals | **19/19** |
| fresh state, `--verify-saved` | fails for the right reason: *owner primary differs* | not run |
| identity | `IBM` / `SW`, spec revision 1.64 | `IBM` / `SW`, spec revision **1.83** |
| per-operation latency | 8–16 ms | 7–18 ms |

The latencies are recorded for completeness and are **not** a performance claim, per
[65](65-tpm-keystore.md): swtpm is ~12× faster than vidiot01's Intel PTT.

The bigtab01 preflight ran Fedora 44's `swtpm`, `swtpm-libs` and `libtpms` extracted into `/var/tmp`
with `LD_LIBRARY_PATH`, against the host's own `tpm2-tools` 5.7 and `tcti-swtpm`, then deleted. No
library was missing. `rpm -K` said **`SIGNATURES NOT OK`**, and that is not a bad signature: `rpm -Kv`
shows `NOKEY`, because an rpm-ostree host's rpmdb holds no `gpg-pubkey`. Against a scratch keyring
holding only `/etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-44-primary`, all three packages report `signatures
OK`, key fingerprint `36f612dc…6d9f90a6` — the same key that signs bigtab01's own OS image. Read
`rpm -Kv`, not `rpm -K`, before concluding anything there.

0.10.2 also logs two warnings at every start that 0.7.1 did not — `Setting
OPENSSL_ENABLE_SHA1_SIGNATURES=1` and `Profile-enabled algorithms contain disabled 'RSA-1024-sign(SHA1,
pkcs1-pss)'` — which is libtpms 0.10's default profile meeting Fedora's crypto policy. Harmless here;
the keystore backend will not ask for SHA-1.

## Installed on bigtab01 — what the real boot showed

`rpm-ostree install /var/tmp/waydroid-ext-swtpm-1.0.0-1.noarch.rpm` resolved `swtpm`, `swtpm-libs`,
`libtpms` and `swtpm-selinux` 0.10.2 from Fedora's repositories, and the machine was rebooted into it
at the console. Every row is read off the booted system, 2026-10-19:

| | Measured |
|---|---|
| Booted commit | `1d1fb43f…`, nothing staged, no `InterruptedLiveCommit` |
| Unit | `active (running)` from boot, `NRestarts=0`, `FragmentPath=/usr/lib/systemd/system/waydroid-swtpm.service` — the packaged unit, nothing shadowing it |
| Domain | `ps -eZ`: `system_u:system_r:unconfined_service_t:s0 … swtpm`, and the wrapper's own journal line says the same |
| Labels | `/usr/bin/swtpm` `swtpm_exec_t`, `/usr/libexec/waydroid-swtpm` `bin_t`, `/var/lib/swtpm-waydroid` `var_lib_t`, `/run/swtpm-waydroid` and both sockets `var_run_t` |
| Ownership | state dir `tss:tss` 0700, `tpm2-00.permall` 0600; socket dir `tss:tss` 0750, both sockets 0660 |
| Policy | `semodule -l` lists `swtpm`, `swtpm_libvirt`, `swtpm_svirt` — swtpm-selinux's `%post` reached the booted system this time |
| `waydroid-tpm-check --save` | **15/15** against `/run/swtpm-waydroid/sock`, spec revision 1.83 |
| `systemctl restart`, then `--verify-saved` | **19/19** — new PID, clean `Deactivated successfully`, same owner primary, saved blob unseals |
| Journal for the unit, whole boot | **11 lines, 0 of them `Data client disconnected`**, across two checks — about 360 connections at the preflight's rate of ~180 per check — `LogFilterPatterns=` works |
| AVCs | **0** in `audit.log` mentioning swtpm |
| `systemd-analyze security` | **2.1 OK** |

**A pre-boot reading that looked like a finding and was not.** Before the reboot, `ostree ls -X` on the
staged commit reported `/usr/bin/swtpm` as `unlabeled_t`. After it, the same file reads `swtpm_exec_t`.
The commit was labelled correctly all along: the reading was taken through a kernel whose *loaded*
policy did not yet contain `swtpm_exec_t`, and the kernel reports a context it cannot map as
`unlabeled_t`. **Read a staged tree's labels as provisional until the policy that defines them is
loaded.** The design did not depend on the answer either way — `unconfined_service_t` may
`execute_no_trans` an `unlabeled_t` file, measured on bigtab01 for exactly this case.

### Getting it there took a reboot, and why

The plan was `--apply-live`, to avoid a reboot that needs someone at the console
([02](02-ssh-access.md)). It could not work, for a reason [user/ostree.md](user/ostree.md) had not
recorded:

- bigtab01 still carried an **`InterruptedLiveCommit`** from wifid 1.1.2's live apply, caused by the
  `/var`-owned-by-`jmelanso` fault that [packaging/README.md](../packaging/README.md)'s fifth migration
  found and left as the owner's call. **The owner had it fixed this time:** `chown root:root /var`,
  after which `systemd-tmpfiles --dry-run --boot --prefix=/run --prefix=/var` reported no unsafe path
  transition.
- **Fixing the fault did not unblock anything.** `apply-live` refused with *Previously interrupted
  while targeting commit 15e75a09…, cannot change target to 1d1fb43f…*: an interrupted live apply pins
  its target commit, and a new staged deployment is a new target. `--target=<the interrupted commit>`
  to finish it first, or `--reset` back to the booted commit, are the ways out without a reboot; the
  owner chose to reboot instead.
- `rpm-ostree install` also **re-resolved three unrelated layered packages** to newer Fedora updates
  (`android-tools`, `vim-filesystem`, `xxd`). A layered install is a new compose against today's repo
  metadata, not an addition to yesterday's.

## The firmware question, and Secure Boot

The owner enabled **Secure Boot** in firmware setup before this work, and asked whether that enables the
TPM 1.2 too. It does not — they are independent settings — and the measurement agrees: with
`SecureBoot=1`, `SetupMode=0` and the kernel reporting *locked down from EFI Secure Boot mode*, there is
still no `/dev/tpm*`, no `/sys/class/tpm/` entry, and neither a `TCPA` nor a `TPM2` ACPI table among
the 23 static and 3 dynamic ones. `ima: No TPM chip found` again. So swtpm stays bigtab01's backend,
which is what the owner asked for in that case.

**There is no OS-side way to read this machine's setup options.** It does expose
`/sys/class/firmware-attributes/hp-bioscfg` (HP's BIOS WMI, GUID `5FB7F034-…`), which looked like
exactly that — but on this consumer Insyde F.0F firmware it carries one attribute, `Sure_Start`, whose
two audit-log files return `EINVAL`, plus an unprovisioned Secure Platform Management node
(`is_enabled 0`, `key_mechanism not provisioned`) and `pending_reboot`. No TPM, security-device or
boot setting is enumerated. The setup screen is the only place the answer to
[65](65-tpm-keystore.md)'s open question 1 can be read.

**Settled 2026-10-20: the setup screen offered nothing, and there is no hardware TPM to reach.** The
owner cleared the administrator password — DMI type 24 now reads *Administrator Password Status:
Disabled*, where [65](65-tpm-keystore.md) recorded it enabled — and still found **no hidden menu** by
any keystroke. With the password gone the WMI surface was re-read and is unchanged (`hp-bioscfg` only
`Sure_Start`, `fwupdmgr` only a read-only `pending_reboot`), so there is no TPM attribute to write;
there is still no TCG/TPM/PPI EFI variable, only the 1404-byte Insyde `Setup` blob whose offset is
locked in the encrypted image. The attended `tpm_tis.force=1` probe then ran (karg appended, reboot,
LUKS, manual `sshd`) and the kernel read **`tpm_tis tpm_tis: TPM vid 0xFFFF, did 0xFFFF init failed
with error -19`** — a floating bus, so **nothing is wired at the standard TIS window** and there is no
discrete chip. The Management Engine is present and healthy (Wildcat Point-LP MEI `[8086:9cba]`,
`mei_me` bound, ME firmware **10.0.25.1048**, Broadwell-era), and PTT does not appear as an OS-facing
MEI client — when active it is a TPM 2.0 behind a `TPM2` ACPI table, which this machine does not have.
So the "TPM 1.2" is **Intel PTT the firmware never activates**, not a discrete part, and PTT is
switched on only in setup, which offers no such control. **No software path exists to give bigtab01 a
TPM.** The karg was dropped again afterward. This closes [65](65-tpm-keystore.md)'s open question 1:
bigtab01 is swtpm, one backend.

Secure Boot also put the kernel in **`lockdown=integrity`**, which has two consequences elsewhere in this
project. **Hibernation is refused** — this boot logged `Lockdown: systemd-logind: hibernation is
restricted` — so [41](41-battery-cutoff.md)'s suggestion of hibernate as `CriticalPowerAction` is void
while Secure Boot is on; the power key suspends rather than hibernates, so nothing in use today is
affected. And `kernel_lockdown(7)` lists **`/dev/port`**, which was [62](62-vibration-ec-owned.md)'s
one remaining avenue for the vibration motor. Not tested; the man page is the source.

## Corrections to docs/65

- **The `tss` user exists on bigtab01**, uid 59, in `/usr/lib/passwd` from tpm2-tss's `sysusers.d`.
  [65](65-tpm-keystore.md)'s stage 0 said it was absent. The boot-time `Failed to resolve user 'tss'`
  lines are the **initrd's**, which has no such user — harmless, and not this package's to fix.
- **The swtpm demonstration only worked because it stopped at two objects** — finding 3 above.
