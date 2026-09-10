# 42 — The brightness slider stopped working: waydroid_t cannot write sysfs

**Date:** 2026-09-10
**Status:** Fixed and installed on the host. One step of the verification is still
outstanding — see [What is verified, and what is not](#what-is-verified-and-what-is-not).

Follows [37-brightness.md](37-brightness.md), which built the feature and shipped it
believing it worked. It did work, but only in a configuration that could not survive a
container restart, and the reason is not the one docs/37 predicted.

## The symptom

Android's brightness slider moved nothing. The panel sat at 937/937 and stayed there.

Nothing looked wrong. The daemon was running. `ILight` was registered. The overlay `.rc`
that stands the guest stub down was deployed and in effect. The display policy was
`BRIGHT`, so this was not the DIM trap that `bin/brightness-test.sh` exists to navigate.
`ausearch` was completely silent.

## What it was not

Ruled out, in order, before finding the cause:

- **The DIM trap.** `mPowerRequest=policy=BRIGHT`, and the panel was pinned at 937, not at
  the dim value of 51. docs/37's documented failure mode was the first hypothesis and it
  was wrong.
- **A lost `ILight` registration.** `lshal` shows `DM,FC ? ...ILight/default N/A N/A`, which
  looks alarming, but `ISensors` shows the identical shape and sensors work. The `N/A` PID
  means the server is outside the container's PID namespace — i.e. it is us. `lshal` cannot
  distinguish "served from the host" from "not served at all", so it is not a discriminator
  here. `bin/brightness-test.sh` already encodes this.
- **The guest stub taking the name back.** No light HAL process existed in the container;
  the neutered `.rc` was working exactly as designed.
- **A dead or wedged daemon.** It was alive and answering. The proof is in logcat:
  `LightsService: Light requested not available on this device. 2` is *our own*
  `LIGHT_NOT_SUPPORTED` branch replying about the buttons LED. Something was serving.
- **The hardware, the panel or the kernel.** As unconfined root, `echo 500 > brightness`
  moved the panel and `echo 937` put it back.

## The cause

logcat named the failing call:

```
E LightsService: Unknown error setting light.
```

That string is the `Status::UNKNOWN` arm of AOSP's `LightsService`. So Android reached
`ILight`, our daemon answered, and our daemon returned an error. `Lights.cpp` returns
`STATUS_UNKNOWN` when `Backlight::SetAndroidBrightness()` returns -1, and the daemon's own
log in `/var/lib/waydroid/waydroid.log` said why:

```
[waydroid-sensors-daemon] WARNING: open(/sys/class/backlight/intel_backlight/brightness): Permission denied
```

`EACCES` on `open(O_WRONLY)`. The daemon is uid 0 and the file is root-owned `0644`, so DAC
cannot be refusing it. It is SELinux:

```
avc: denied { write } for scontext=system_u:system_r:waydroid_t:s0
     tcontext=system_u:object_r:sysfs_t:s0 tclass=file permissive=0
```

`waydroid_t` may `read`, `open` and `getattr` a `sysfs_t` file. It may not `write` or
`append` one. `Discover()` therefore succeeded — it only reads `max_brightness` — and every
single write failed.

**Being root does not help.** SELinux denies the *domain*, not the user. This falsifies
`Backlight.h`'s heading "WE ARE ROOT, SO THIS IS A sysfs WRITE AND NOT D-Bus" and benefit 2
of docs/37's list, both of which treated uid 0 as sufficient.

## Why nothing in the logs said so

`auditd` was active and had **zero** AVC records for the whole day. The rule is
`dontaudit`ed, so the kernel never emits the denial. This is the third time this project
has lost time to exactly that: [35-wifi-stage5.md](35-wifi-stage5.md) (`binder { transfer }`
to `unconfined_service_t`) and [40-binder-nice.md](40-binder-nice.md) (`capability sys_nice`,
asked for with the noaudit variant).

**The technique that ends this class of hunt** — ask the kernel directly instead of waiting
for it to tell you, which a `dontaudit` rule guarantees it never will:

```python
python3 -c '
import selinux
selinux.selinux_check_access("system_u:system_r:waydroid_t:s0",
                             "system_u:object_r:sysfs_t:s0", "file", "write")'
```

It raises `PermissionError` on a denial and prints the AVC the audit log will not. It takes
seconds, needs nothing installed, and it is how this was found. `sesearch` would also answer
but `setools-console` is not installed and layering it costs a reboot.

## Why it appeared to work before, and what changed

docs/37 verified brightness against a **hand-swapped** daemon. A daemon started by hand from
a login shell runs as `unconfined_t`, and `unconfined_t` → `sysfs_t:file write` is allowed.
A daemon spawned by `container_manager.py` runs as `waydroid_t` and is denied. Same binary,
same everything else.

So the feature never worked from a `container_manager.py`-spawned daemon. It could not have.

The irony is that **closing docs/37's durability gap is what exposed this.** While the guest
stub still held `ILight`, the working configuration was necessarily a hand-started daemon,
because only a hand start could register late enough to win the name. Deploying the overlay
`.rc` on 2026-09-09 02:50 and restarting the container at 11:06 removed the stub for good —
after which `container_manager.py`'s `waydroid_t` daemon owned `ILight` automatically, and
could not write. The fix for one problem uncovered the other.

The panel's last successful write was 11:23 on 2026-09-09, which is almost certainly
`brightness-test.sh --restore` — it runs as unconfined root, and it explains why the panel
had been sitting at exactly `max` ever since.

## The fix

A private type for one sysfs attribute, and a udev rule to apply it.
`artifacts/backlight/install.sh` installs both.

```
(type waydroid_backlight_t)
(typeattributeset file_type (waydroid_backlight_t))
(allow waydroid_backlight_t sysfs_t (filesystem (associate)))
(allow waydroid_t waydroid_backlight_t (file (getattr open read write append)))
```

**`associate` is the load-bearing line, and it is not obvious.** A first probe tried
`chcon -t device_t` on the attribute and was refused. That refusal is not sysfs rejecting
labels — sysfs supports them fine — it is policy refusing to let a type be applied to a file
on a filesystem it has no `associate` rule for. `device_t` has none. Without that one line
the udev rule fails silently and the whole approach looks impossible.

**Why not simply `allow waydroid_t sysfs_t:file write`.** One line, no udev rule, no private
type — and it would let the container runtime write anywhere in sysfs. docs/35 rejected a
policy module for the same reason and paid for the narrower option; this grants one
attribute of one device instead.

**Why the label needs a udev rule.** sysfs is rebuilt on every boot, so a `chcon` does not
persist there the way a relabel on a real filesystem does. `ACTION=="add|change",
SUBSYSTEM=="backlight"` reapplies it on every device add.

**Why CIL and not a `.te` module.** `semodule` compiles CIL directly. A `.te` needs
`selinux-policy-devel`, which on this rpm-ostree host is a layered install and a reboot.
The module loads into `/etc`, so nothing about the fix touches the immutable `/usr`.

Only `brightness` is relabelled. The daemon reads `actual_brightness` and `max_brightness`,
and reading `sysfs_t` is already allowed, so relabelling those would buy nothing.

## What is verified, and what is not

**Verified on the host:**

- The kernel now answers `ALLOWED` for `waydroid_t` → `waydroid_backlight_t:file write`,
  by the same `selinux_check_access` query that returned `DENIED` before the module.
- The udev rule reapplies the label: reset to `sysfs_t` by hand, `udevadm trigger`, and it
  came back as `waydroid_backlight_t`.
- The daemon drives the panel end to end when it can write at all. Restarted by hand as
  `unconfined_t` it logged `brightness 102/255 -> raw 375/937` with the panel at 375, and
  logged Android's dim ramp landing step by step: `18→66, 17→62, 16→59, 15→55, 14→51`.
- `artifacts/backlight/install.sh` is what was actually run, and it self-checks the label.

**Verified by a full reboot on 2026-09-10 13:32**, which is the only thing that can exercise
the real path:

- **The udev rule fires on the real boot path**, not just under a hand-run `udevadm trigger`.
  The attribute came up labelled `waydroid_backlight_t` with nobody touching it. The risk here
  was that i915 registers the backlight in the initramfs, where `/etc/udev/rules.d` does not
  exist; `systemd-udev-trigger.service` re-emits `add` for every device once the real root is
  up, which covers it.
- **The daemon came back as `system_u:system_r:waydroid_t:s0`** — spawned by
  `container_manager.py`, i.e. exactly the configuration that was broken.
- **Zero `Permission denied` lines since boot**, against 697 in the file from before the fix.
- **It wrote the panel.** At 13:33:52 the daemon logged the panel at 937; a minute later it
  was at 51, Android's dim value. Nothing else writes that file — `systemd-backlight`'s saved
  state is stale (mtime 2026-09-09, contents 937) — so the only writer was the daemon, in
  `waydroid_t`, performing the exact `open(O_WRONLY)` that returned `EACCES` before.

- **The full sweep passes under `policy=BRIGHT`.** Run against the `waydroid_t` daemon with
  someone physically holding the display awake:

  ```
  0.2 -> raw 191 (want ~187)  OK      0.8 -> raw 750 (want ~749)  OK
  0.5 -> raw 470 (want ~468)  OK      1.0 -> raw 937 (want ~937)  OK
  BRIGHTNESS TEST PASSED (4 ok, 0 skipped)
  ```

  Within 4 raw units across the range, which also confirms the mapping is **linear**. An
  earlier reading of `0.35 -> 102/255 -> raw 375` looked like a non-linear curve and was not:
  it was a ramp waypoint caught mid-flight, the same artefact recorded under Traps below.
  Nothing verified here is now outstanding.

`runcon` cannot stand in for a container restart. `unconfined_t` → `waydroid_t` `process transition` is
allowed, but `waydroid_t` → `bin_t:file entrypoint` is **denied**, so no exec can enter that
domain. What this reveals is how the daemon gets there normally: `execute_no_trans` is
allowed, so `container_manager.py` is itself `waydroid_t` and the daemon simply **inherits**
the domain rather than transitioning into it.

## Two consequences found while verifying

### `brightness-test.sh` cannot poke user activity, and its header says it can

The script's central design claim is that it beats the DIM trap by poking user activity in
the *same* `waydroid shell` invocation as each set. **That does not work on this image.**
Measured directly:

```
before:         mLastUserActivityTime(excludingAttention)=70768
after keyevent: mLastUserActivityTime(excludingAttention)=70768
after tap:      mLastUserActivityTime(excludingAttention)=70768
```

Neither `input keyevent KEYCODE_MENU` nor `input touchscreen tap` moves it. Injected input
from `waydroid shell` does not count as user activity for `PowerManagerService`, so the
display stays DIM and every level reads back as the pinned dim value — or worse, as whatever
an external writer last left, which scores as MISMATCH rather than SKIPPED.

`svc power stayon true` does not rescue it either. The setting takes (`stay_on_while_plugged_in`
goes 0 → 7, and the machine really is on AC), but the policy stayed DIM through 18 s of
polling: `mUserActivityTimeoutOverrideFromWindowManager=10000` wins.

**So a full-range run genuinely requires a human touching the machine**, and the script should
say so rather than implying it handles it. Until then the honest automated check is the
`--verbose` mapping check, which is independent of display policy.

### Android's dim policy now drives the whole machine's panel

This is the feature working, and it is worth stating plainly because it looks like a fault.
With the write path fixed, Android owns the physical backlight — so if nobody touches
*Android* for 10 s, the real panel drops to raw 51 no matter what the person at the keyboard
is doing. That is what happened immediately after the verification reboot: the session came
up, the owner logged in at SDDM and turned to another machine, and the display went very dim
about ten seconds later. `mLastUserActivityTime` was frozen 70 s after Android booted while
Android had been up for sixteen minutes, which is the signature to look for.

## Traps recorded

- **`lshal` cannot tell "served from the host" from "not served at all".** Both print
  `? ... N/A N/A`. Compare against `ISensors`, which is known-good, before concluding.
- **`ausearch` silence proves nothing** when a `dontaudit` rule is in play. Query the kernel.
- **A daemon started by hand is not the daemon in production.** It differs in SELinux domain,
  and that difference was the entire bug. Any "verified working" claim should record how the
  daemon was started.
- **`brightness-test.sh` reports MISMATCH, not SKIPPED, when it catches a ramp mid-flight.**
  It compares against the exact dim value 51; a reading of 375 taken while the panel is
  still moving fails the comparison. Re-read the panel after it settles before believing it.
- **`pgrep -f` with a path misses the production daemon.** `container_manager.py` execs it
  with an unqualified `argv[0]`, so the running process is `waydroid-sensord /dev/hwbinder`,
  not `/usr/local/bin/waydroid-sensord ...`. A pattern like `bin/waydroid-sensord` matches a
  hand-started daemon and silently misses the real one, which reads as "the daemon did not
  start". Match on `waydroid-sensord` alone, or use `pgrep -x` — noting that the name is
  16 characters, so `pgrep -x waydroid-sensord` hits the 15-character comm limit and returns
  nothing. `ps -eo args | grep` is the reliable form.
- **Do not write the panel by hand while the daemon is serving.** `SetAndroidBrightness()`
  caches `mLastRaw` and skips writes it believes are no-ops, on the documented assumption
  that nothing else writes the file. An external `echo N > brightness` desynchronises that
  cache: Android then asks for the value the daemon *thinks* is already set, the write is
  skipped, and the panel stays where the external write left it. It self-heals as soon as
  Android requests a different value, but in the meantime it looks exactly like a broken
  daemon.
