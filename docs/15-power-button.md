# Power button: short press to s2idle, hold to shut down

**Date:** 2026-09-06. **Status: stage 1 done and verified on the machine. Stage 2 untested.**
Stage 3 needs no configuration. See "Verified" and "Not yet verified" below — the distinction
matters, because stage 2 may not be achievable this way at all.

## Goal

Three stages from one button:

1. short press — suspend to idle (s2idle), and nothing else
2. hold — the normal clean shutdown sequence
3. keep holding — the machine's built-in emergency power off

## What was there before

**No logind configuration existed at all.** `/etc/systemd/logind.conf` was absent and
`/usr/lib/systemd/logind.conf` is nothing but `[Login]` and comments, so the host ran pure
upstream defaults:

| Setting | Default in force | Effect |
|---|---|---|
| `HandlePowerKey=` | `poweroff` | **a single short press powered the machine straight off** |
| `HandlePowerKeyLongPress=` | `ignore` | holding did nothing until the firmware cut power |

`/sys/power/mem_sleep` reads `s2idle [deep]`, so suspend went to **S3, not s2idle**. Both halves
of stage 1 therefore needed changing.

## The hardware

Three input devices carry `KEY_POWER`, and all three are tagged `power-switch` on their `event*`
node, so logind watches all of them (the tag comes from `ID_INPUT_KEY=1` in
`70-power-switch.rules`; note it is on the `event*` node, **not** on the parent `input*` device —
checking the wrong one shows only `:seat:` and looks like a fault):

| Device | Node | Driver |
|---|---|---|
| `PNP0C0C` Power Button | `event1` | ACPI control-method button |
| `LNXPWRBN` Power Button | `event2` | ACPI fixed button |
| Intel Virtual Buttons `INT33D6` | `event7` | `intel-vbtn` — also POWER, VOLUP, VOLDOWN, META, ROTATE_LOCK |

## What was applied

Two drop-ins, staged in [artifacts/power/](../artifacts/power/) and installed mode `0644`:

`/etc/systemd/logind.conf.d/10-power-button.conf`
```ini
[Login]
HandlePowerKey=suspend
HandlePowerKeyLongPress=poweroff
```

`/etc/systemd/sleep.conf.d/10-s2idle.conf`
```ini
[Sleep]
MemorySleepMode=s2idle
```

`MemorySleepMode=` writes `s2idle` to `/sys/power/mem_sleep` immediately before
`SuspendState=mem` is used. It needs systemd ≥ 256; the host runs **259**. This was chosen over
the `mem_sleep_default=s2idle` kernel argument deliberately — the kernel argument would cost an
`rpm-ostree kargs` and a reboot on an immutable host, and this achieves the same thing from
`/etc`. Delete either file to revert.

`systemctl reload systemd-logind` was enough — `CanReload=yes`, so no session-killing restart.
All five logind sessions survived.

**Verified live** rather than by reading the file back:

```
$ busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
        org.freedesktop.login1.Manager HandlePowerKey HandlePowerKeyLongPress
s "suspend"
s "poweroff"
```

`/sys/power/mem_sleep` still reads `s2idle [deep]` and that is expected — `MemorySleepMode=` is
applied at suspend time, not at reload.

## Verified on the machine

Confirmed 2026-09-06 by the owner pressing the button, and corroborated in the journal. Two full
cycles, both clean:

```
systemd-logind[925]: Power key pressed short.
systemd-logind[925]: Suspending...
kernel: PM: suspend entry (s2idle)
kernel: PM: suspend exit
```

| Claim | Evidence |
|---|---|
| a short press suspends instead of powering off | `Power key pressed short.` -> `Suspending...` |
| it is **s2idle**, not `deep` | `PM: suspend entry (s2idle)` — the kernel names the mode |
| `MemorySleepMode=` works as intended | `/sys/power/mem_sleep` now reads `[s2idle] deep`; it read `s2idle [deep]` before the first suspend, because the setting is applied at suspend time, not at reload |
| it resumes cleanly | `PM: suspend exit`, twice |
| wifi and bluetooth survive resume | reported working by the owner after wake |

That closes the concern carried over from [docs/12](12-v4l2-frame-errors.md), where suspend/resume
had only ever been exercised in `deep`.

Note that `Power key pressed short.` does **not** settle the stage 2 question below. The ACPI
button driver emits key-down and key-up back to back regardless of how long the button is
physically held, so every press looks "short" to logind whether or not it was one.

## What is NOT yet verified — read before trusting stage 2

Stage 1 is proven. **Stage 2 — hold to shut down — has not been tested,** and two things could
still make it unreachable. Both are open questions, not findings:

**1. The ACPI buttons cannot report a hold.** The kernel's ACPI button driver emits key-down and
key-up back to back, so `event1`/`event2` carry no hold duration and logind can never see a long
press from them. `intel-vbtn` on `event7` *may* report a real held press — it has distinct
press/release event codes — but whether this HP's firmware actually emits them is **unverified**.
If it does not, stage 2 is impossible through logind and would need a small evdev handler instead.

**2. The thresholds may be in the wrong order.** logind's long-press window is hardcoded and not
exposed in `logind.conf`; it is believed to be **5 s** (unconfirmed — not stated in
`logind.conf(5)`, and the source was not read). The Intel PCH power-button override cuts power in
firmware at a conventional **4 s** (also unconfirmed on this machine). If both figures are right,
the firmware wins and `HandlePowerKeyLongPress=poweroff` can never fire. Setting it does no harm
either way.

Stage 3 needs no configuration — it is silicon and already works.

## How to settle both questions

[bin/powerbtn-probe.py](../bin/powerbtn-probe.py) (stdlib only, deployed at
`/var/tmp/powerbtn-probe.py`) watches all three nodes at once and prints the measured hold
duration for each press, labelling it `REAL HOLD` or `instantaneous, no hold reported`. Every
line is `fsync`'d, so the record survives the firmware cutting power mid-test.

Run it under an inhibitor so the press does not act on the machine:

```bash
sudo systemd-inhibit --what=handle-power-key --who=powerbtn-probe \
     --why="measuring button timing" /var/tmp/powerbtn-probe.py
```

Press briefly first. If no device reports a hold, stop — stage 2 is not achievable this way.

For the threshold question, the **non-destructive** test is to set
`HandlePowerKeyLongPress=lock` temporarily (`lock` is an accepted value), hold the button, and
watch whether the sessions lock and after how long. That answers it without discovering the
firmware's override by having the machine power off.

