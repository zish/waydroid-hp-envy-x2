# 55 — AppFuse: every `openDocument` failed, and the host's SELinux policy is why

**Date:** 2026-09-24 (diagnosed), 2026-09-25 (fixed and verified)
**Status:** **Fixed, packaged and verified**, on the probe and on a real third-party app.
`waydroid-ext-appfuse` 1.0.0 builds clean; not yet layered on bigtab01 — see
[What is left](#what-is-left).

Goal 9. `StorageManager.openProxyFileDescriptor()` did not work in this container, and
nothing that depends on it could work either.

## Why anyone cares

AppFuse is how an Android app hands out a **real file descriptor for bytes that have no
file behind them**. `vold` mounts a FUSE filesystem at `/mnt/appfuse/<uid>_<mountId>`, and
the *app itself* answers the protocol through a `ProxyFileDescriptorCallback`.

Every `DocumentsProvider` that synthesises content goes through it: cloud storage clients,
archive and zip browsers, MTP hosts, encrypted vaults. Such an app can be installed, can
serve `queryRoots` and `queryChildDocuments` perfectly, and appear to work — right up to
the moment anything tries to *open* one of its documents.

This is **not** the FUSE that goal 6 uses. That one is MediaProvider serving
`/storage/emulated/0` from a lower directory on the host ([46](46-removable-media.md)), and
it has always worked here. Three of its mounts are live at any time, which is part of why
this fault misleads: FUSE demonstrably works on this machine.

## The symptom

Found in a real project rather than constructed. `../crippy` is an encrypted-vault
`DocumentsProvider`; it browses correctly in this container and fails **every**
`openDocument`:

```
app :  java.lang.IllegalStateException: Failed to mount
         at com.android.server.StorageManagerService.mountProxyFileDescriptorBridge(
                StorageManagerService.java:3697)
vold:  Failed to mount /mnt/appfuse/10218_24: Invalid argument
```

Its instrumented suite split exactly along that line — proxy-fd tests 0 of 6, SAF tests 6
of 10, the four failures being precisely the ones that open a document. Nothing hung, and
every failure was the same clean exception rather than a timeout or a crash.

That project recorded it as a dead end, correctly for its own purposes: Waydroid is not one
of its targets, and nothing an app can do will fix this. Here it is the goal.

## What it was not

- **Not `/dev/fuse`.** Present, `crw-rw-rw-`, and the probe stats it successfully.
- **Not a missing `vold`.** `vold` runs. Goal 6 predicted it absent and was wrong
  ([46](46-removable-media.md)); that correction is what made this diagnosis quick.
- **Not `persist.sys.fuse`.** It is `true`.
- **Not FUSE support in general.** Three FUSE mounts are already live for emulated storage.
- **Not the app.** The same suite passes on two real OEM ROMs (an LG G6 at API 28 and a
  Galaxy S9 at API 29).
- **Not an AVC denial.** `ausearch` is *completely clean* for this fault. See
  [Why the logs were silent](#why-the-logs-were-silent) — this is the trap.

## The cause

`vold` asks `mount(2)` for an SELinux context that **Fedora's policy cannot parse**. A
MAINLINE Waydroid runs against the *host's* policy, not Android's.

The option string, read out of this host's own copy of the image at
`/var/lib/waydroid/rootfs/system/bin/vold`:

```
fd=%i,rootmode=40000,default_permissions,allow_other,user_id=0,group_id=0,
context="u:object_r:app_fuse_file:s0",fscontext=u:object_r:app_fusefs:s0
```

**Three identifiers in that string are unknown to Fedora, not one.** This is the part that
is easy to get half right. Measured with `security_check_context()`, unprivileged:

| context | result | what it proves |
|---|---|---|
| `u:object_r:app_fuse_file:s0` | INVALID | what vold actually asks for |
| `system_u:object_r:app_fuse_file:s0` | INVALID | the **type** `app_fuse_file` is Android-only |
| `u:object_r:fusefs_t:s0` | INVALID | the **user `u`** is Android-only — with a type Fedora has |
| `system_u:object_r:fusefs_t:s0` | VALID | control: the probe itself is sound |

So `app_fuse_file`, `app_fusefs` **and** the SELinux user `u` all have to exist. Fedora
ships `system_u`, `unconfined_u`, `staff_u`, `sysadm_u`, `guest_u` and `root`; Android's
entire policy uses the single letter `u`, and nothing on a Fedora host has ever needed it.
**Declaring the two types alone still returns `EINVAL`.**

### Declaring an SELinux user sounds worse than it is

A user in an *object* context is only ever a name to be looked up. The kernel's
`policydb_context_isvalid()` special-cases the `object_r` role: for object contexts it
checks that user, role and type all **exist** and that the MLS level is valid, and it does
**not** check that the user is authorised for the role. So `u` needs no roles, no
privileges and no login mapping, and no process will ever run as it — only inodes on this
one mount carry it. It grants nothing by existing.

## Why the logs were silent

**`ausearch` is clean, and that is not a clue that SELinux is innocent — it is the
fingerprint of this particular fault.** A context that cannot be *parsed* never becomes an
AVC, because there is no SID to deny anything to. The audit subsystem has nothing to say.

The kernel does say it, in `dmesg`:

```
SELinux: security_context_str_to_sid (u:object_r:app_fuse_file:s0) failed with errno=-22
```

`-22` is `EINVAL`. It names only `app_fuse_file`, because `mount(2)` gives up on the first
unparseable option and never reaches `fscontext=`.

This joins the list of faults in this repo that are invisible to `ausearch`: the backlight
sysfs write ([42](42-backlight-selinux.md)) and the binder `transfer` denial
([35](35-wifi-stage5.md)) are both `dontaudit`ed. This one is not `dontaudit`ed — it is
*pre-audit*. Different mechanism, same wrong first answer. **Look in `dmesg`.**

## The fix

[artifacts/appfuse/waydroid_appfuse.cil](../artifacts/appfuse/waydroid_appfuse.cil) — a host
SELinux module, installed with
[artifacts/appfuse/install.sh](../artifacts/appfuse/install.sh).

**Nothing inside the Android image is touched**, which was the point of preferring this to
the alternative (below). CIL rather than `.te` for the same reason as
[42](42-backlight-selinux.md): `semodule` compiles CIL directly, so it needs no
`selinux-policy-devel`, which on an rpm-ostree host would cost a layered install and a
reboot.

It is **declarations plus exactly one `allow` rule**:

```cil
(user u)
(userrole u object_r)
(userlevel u (s0))
(userrange u ((s0)(s0)))

(type app_fuse_file)
(roletype object_r app_fuse_file)
(typeattributeset file_type (app_fuse_file))

(type app_fusefs)
(roletype object_r app_fusefs)
(typeattributeset filesystem_type (app_fusefs))

(allow app_fuse_file app_fusefs (filesystem (associate)))
```

### Every line is load-bearing, proven by removal

Each variant was loaded with `semodule -i` and the probe re-run. The two failures are
**different from each other**, which is the useful part — the exception class says which
half is missing:

| variant | result |
|---|---|
| as written | AppFuse works; 8/8 correctness, 8/8 concurrent fds |
| minus `(typeattributeset file_type …)` | `IOException: FuseUnavailableMountException: AppFuse mount point N is unavailable` |
| minus the `(associate)` rule | back to `IllegalStateException: Failed to mount` |
| module absent entirely | `IllegalStateException: Failed to mount` + the `dmesg` parse failure |

Note the second row carefully. **Without the attribute the mount succeeds and the app still
cannot use it** — a second, quite different symptom one step further along. The `associate`
denial *is* auditable, unlike the parse failure:

```
avc: denied { associate } for pid=275211 comm="binder:31_4"
     scontext=u:object_r:app_fuse_file:s0 tcontext=u:object_r:app_fusefs:s0
     tclass=filesystem permissive=0
```

### And what was tried and proved unnecessary

So nobody adds it back. All of this was in the first draft and all of it is redundant:

```cil
(allow container_runtime_t app_fusefs (filesystem (mount unmount remount getattr relabelto associate)))
(allow container_runtime_t app_fuse_file (file (relabelto)))
(allow container_runtime_t unlabeled_t (filesystem (relabelfrom)))
(allow container_runtime_t fusefs_t (filesystem (relabelfrom)))
;; ...plus a wide dir/file access set for container_runtime_t and unconfined_t
```

`container_runtime_t` — which is the domain Android's processes run in on this host,
confirmed from `ps -eZ` — already holds every one of those permissions through the base
policy's **attribute-based** rules. Which is exactly why the two `typeattributeset` lines
matter so much: assigning `file_type` and `filesystem_type` is what makes the existing
rules apply to these brand-new types. **The attribute does the work the explicit rule set
would only have duplicated, less safely.**

### Why private types and not an alias of `fusefs_t`

Aliasing `app_fuse_file` to `fusefs_t` would also have worked and would have been two
lines. It would also have inherited every `fusefs_t` rule in the base policy, host-wide,
for a mount the container controls. Private types keep the grant where it belongs — the
argument [42](42-backlight-selinux.md) makes at length.

### The alternative, not taken

Byte-patch the option string in `/system/bin/vold` so it stops asking. It is a *shortening*
edit, the safe kind, and the same binary already carries a context-free variant a few bytes
away (`fd=%i,rootmode=40000,allow_other,user_id=0,group_id=0,` — note it also omits
`default_permissions`, so it is not byte-identical to a truncation and cannot be reused
wholesale).

Rejected because it modifies a system binary to work around a host-side problem, it needs
install-time patching machinery to honour the no-vendored-binaries rule
([54](54-no-vendored-binaries.md)), and `vold` owns *all* storage — the blast radius of
getting it wrong is much larger than a policy module that `semodule -r` reverts. Recorded
here in case the policy route ever becomes unavailable.

## What was built

- **[appfuse-probe/](../appfuse-probe)** — a probe app. Deliberately **not** a
  `DocumentsProvider`: crippy already has the SAF-shaped version of this test and it cannot
  separate "AppFuse is broken" from "something in the provider or the picker is broken".
  This calls the one API under suspicion and nothing else, so a failure has exactly one
  possible owner. Same no-Gradle four-tool build as the other probes. `minSdk` 26 because
  that is the API level `openProxyFileDescriptor` was added in.
- **[bin/appfuse-test.sh](../bin/appfuse-test.sh)** — the whole loop in one command:
  force-stop, launch, wait, print the report, then print `vold`'s line and the kernel's.
- **[artifacts/appfuse/](../artifacts/appfuse)** — the module, its loader, the loader's unit
  and the installer.
- **[packaging/mods/appfuse.mod](../packaging/mods/appfuse.mod)** — `waydroid-ext-appfuse`,
  a `noarch` host package. See [Packaging](#packaging).

## What is verified

Against this container on 2026-09-25, with the module loaded:

| check | result |
|---|---|
| `openProxyFileDescriptor` opens | yes |
| `statSize` matches `onGetSize` | PASS |
| sequential read of 1 MiB matches an offset-addressable pattern | PASS |
| `pread` at 200 pseudorandom offsets | PASS |
| read spanning EOF is short, not an error | PASS |
| read entirely past EOF returns 0 | PASS |
| `lseek` then read lands where told | PASS |
| random access on a **cold** fd reaches the callback | PASS — 46 `onRead` calls for 50 preads |
| 8 simultaneous proxy fds | PASS — 8 of 8 served correct bytes |
| largest `onRead` | **131072 bytes** (128 KiB) |

That last figure matches the LG G6 that crippy measured and differs from the Galaxy S9's
64 KiB, so the transfer granularity is a property of the build, as that project found.

**The cold-fd row exists because the first version of the probe was measuring the page
cache.** The 200 random preads ran *after* the sequential read had pulled the whole
megabyte in, so they proved the bytes were right but not that random access reached FUSE at
all — the shared-fd `onRead` count is 8, which is 1 MiB ÷ 128 KiB and nothing more. A
fresh fd with random offsets only, asserting the callback was woken, is what actually
closes it.

### Verified on a real third-party app, by A/B

The probe is ours and could in principle be wrong about what it is testing. crippy is not:

```
module loaded      content read …/document/readme  ->  4096 bytes   (== README_BYTES)
semodule -r        content read …/document/readme  ->  IllegalStateException: Failed to mount
                   vold: Failed to mount /mnt/appfuse/10216_48: Invalid argument
semodule -i        content read …/document/readme  ->  4096 bytes
```

Driven with the `content` shell command against crippy's real provider authority, so it
goes through the actual `DocumentsProvider.openDocument` path that was failing — not
through our own harness.

### Persistence

`semodule -i` writes the module to `/etc/selinux/targeted/active/modules/400/waydroid_appfuse/`,
so **once loaded it survives a reboot by itself** — nothing has to reapply it, unlike
[42](42-backlight-selinux.md), whose loader also exists because sysfs labels do not persist.

The package nevertheless ships a boot-time unit, and the distinction is worth keeping
straight: it is not there to *re*-load the policy, it is there to get the **first** load to
happen on the booted system at all, because an RPM `%post` cannot do that on rpm-ostree. See
[Packaging](#packaging).

**No container restart is needed, and none should be done.** `vold` performs the AppFuse
mount on demand, per call, so the next call already uses the new policy. Restarting the
container would drop a kiosk session to the greeter for nothing.

## Traps recorded

- **`ausearch` is clean for an unparseable mount context.** Read `dmesg`. Covered above;
  repeated here because it is the single thing most likely to send the next person the
  wrong way.
- **Two different exceptions mean two different causes.** `IllegalStateException: Failed to
  mount` is the mount being refused. `IOException: FuseUnavailableMountException` is the
  mount having *succeeded* and the app being unable to use it. Reaching the second is
  progress, and it looks like a regression.
- **A script delivered to `sh -s` on stdin can be eaten by its own commands.** `ausearch`
  reads stdin, so it consumed the remainder of `appfuse-test.sh` — and the symptom was not
  an error but the script *stopping*, mid-run, **exiting 0**. That reads as "finished", not
  "truncated", and it cost a round of debugging. Every command in that script that might
  touch stdin now has `</dev/null`.
- **`ausearch -ts today` can take minutes on this host** and looks exactly like a hang. The
  test script bounds it at 20 s and reads `dmesg` first.
- **Never `mmap` a proxy fd from the process serving it.** Not our finding — crippy's — but
  it belongs wherever AppFuse is worked on. The page fault is taken with `mmap_lock` held
  for read and can only be answered by a thread in the same address space that may need it
  for write. It took an LG G6 down hard enough that `adb reboot` hung. The probe reads with
  `read` and `pread` only, and says so in its own header.
- **`seinfo` is not installed on either machine**, and the dev box has no SELinux at all, so
  the context checks in this document were done with `security_check_context()` through
  `ctypes` — which needs no root and no setools.

## Packaging

`waydroid-ext-appfuse` 1.0.0, `noarch`, `KIND=host`. Built with
`packaging/build-mod.sh --lint appfuse`, and its rpmlint result is the
`waydroid-ext-backlight` baseline exactly — two `no-signature` errors and three warnings
(`no-manual-page-for-binary`, `invalid-url Source0`, `no-%check-section`), all three of
which [the rpmlintrc](../packaging/waydroid-ext.rpmlintrc) deliberately leaves unfiltered
because they are real and unfixed repo-wide.

Two filters were widened rather than added, both previously scoped to `backlight` alone and
both now covering either SELinux package: `explicit-lib-dependency libselinux-utils`
(`selinuxenabled` is a *command* a scriptlet calls, which nothing can infer from the
payload) and `dangerous-command-in-%postun rm` (the `rm` is of this package's own hash stamp,
a fixed literal).

### The module must not be loaded from `%post`, and that is why there is a unit

On an rpm-ostree host a scriptlet runs against the **compose**, not the booted system, so
`semodule -i` from `%post` never reaches the running machine's policy store. The package
installs, its policy does nothing, and nothing reports a problem.

That is not a prediction. `waydroid-ext-backlight` was found failing exactly that way on its
first real install (2026-09-24) — see [42](42-backlight-selinux.md) and
[packaging/README.md](../packaging/README.md). This package would have failed identically.

So the load happens at boot, from `waydroid-appfuse-policy.service`. `%post` still calls the
loader, which is right on an ordinary host — the fix lands immediately there — and is a
harmless no-op on ostree.

**Unlike backlight, nothing needs reapplying every boot.** That module's loader also exists
because sysfs labels do not persist; this one only declares policy, and `semodule -i` writes
it where it stays. The unit exists purely to get the load to happen on the booted system
once.

### The loader verifies instead of assuming

`semodule` exiting 0 is not evidence the fix is in force — the whole fault is an unparseable
context reported with nothing in the audit log. So
[waydroid-appfuse-policy](../artifacts/appfuse/waydroid-appfuse-policy) writes each context
vold needs to `/sys/fs/selinux/context`, which asks the kernel to parse it and returns
`EINVAL` if it cannot. That file is mode 0666, so the check needs no privilege and no
setools — which matters, because **`seinfo` is installed on neither machine**. Same
principle as `waydroid-backlight-policy` reading its label back.

It is idempotent **by CIL hash, not by module name**: `semodule -l` cannot tell this policy
from a differently-versioned one of the same name, and `semodule -i` rebuilds the whole
policy store, so a name check would skip a real upgrade and a blind reload would cost
seconds on every boot.

### What was tested, and the one thing that could not be

Verified on bigtab01 on 2026-09-25, by hand rather than through `rpm-ostree`:

| | result |
|---|---|
| `--verify` against a hand-loaded module with no stamp | `differs: … (loaded unknown, packaged 9d41a43…)`, exit 3 |
| load | loads, stamps, both contexts `ok` |
| second run | `already loaded and current` — no store rebuild |
| stamp contents | equals `sha256sum` of the CIL |
| `--unload` | module gone, and crippy's `openDocument` fails again |
| loader with no CIL present | `no policy to load`, exit 1 |
| `systemd-analyze verify` on the unit | silent |
| unit enabled via the shipped symlink | `enabled` |
| `systemctl restart` | `Result=success`, `ExecMainStatus=0` |

**The shadow-detection path could not be tested on this host.** The loader prefers a
`/usr/local` CIL over the packaged one — deliberately, so a hand-staged policy beats a
packaged one on an immutable host — and warns when the two differ, because that precedence
silently defeated `waydroid-ext-backlight` 1.0.2 after a migration. Exercising it needs a
file in `/usr/share/waydroid-appfuse`, and `/usr` is read-only here: only `rpm-ostree` can
put one there. The code path is carried over from the module it was learned on, and it is
untested in this package.

## What is left

- **Layer the package on bigtab01.** It has only ever been installed by hand, into
  `/usr/local` with the unit in `/etc/systemd/system`. `rpm-ostree install` plus
  `--apply-live` is the real test, and it is also what would exercise the shadow warning
  above — the hand-staged `/usr/local` CIL now on that machine is exactly the situation the
  warning exists for, so expect it to fire and mean it.
- **Write access is untested.** Everything here opened `MODE_READ_ONLY`, because that is
  what `openProxyFileDescriptor`'s read path needs and what crippy uses. `onWrite` and
  `onFsync` have never been exercised in this container.
- **crippy's own instrumented suite has not been re-run.** The A/B above drives its provider
  through `content`, which is the same code path, but the 6 proxy-fd tests it reports as
  failing have not been watched turning green. That needs adb-over-TCP enabled in the
  container (`service.adb.tcp.port` is empty; `adbd` is running), which is a change to the
  machine nobody has asked for yet.
- **Only this one container has been tested** — LineageOS 20 / Android 13 / API 33, x86_64,
  vendor type MAINLINE. Whether a `GAPPS` or a non-MAINLINE image asks for the same two
  types is unknown, though there is no reason to expect otherwise; the string is in AOSP's
  `vold`, not in Waydroid.
