# Hybrid sleep: periodic wake windows for Waydroid, and what the machine actually draws

**Date:** 2026-09-06. **Status: timer built, deployed and guard-tested. All three power figures
measured, the s2idle one only to within a wide bound. **The S3 comparison is scoped, smoke-tested
and deferred — see "S3 versus s2idle" below.** The end-to-end sync cycle is NOT yet proven; see
"Still untested" at the end.**

## What was asked for, and the correction that shaped it

The goal was phone-like behaviour: display off, low power, but notifications and calls still
arriving. Two corrections had to come first, because they change what is buildable.

**s2idle does not let background apps run.** Suspend-to-idle freezes all userspace, the container
included, and then idles the CPUs. Android background apps stop exactly as dead as they would in
S3. What s2idle buys is cheap, fast wakeups — not background execution. There is also no ACPI
S-state to observe any more: s2idle keeps the platform in **S0**, so nothing can read a
transition, and `/sys` is mounted `sys:ro` in the container anyway
(`lxc.mount.auto = cgroup:ro sys:ro proc`).

**The phone model needs hardware this machine does not have.** On a phone the application
processor suspends too; what stays alive is a separate always-on radio — a cellular modem with its
own CPU holding the paging channel, and WiFi firmware that keeps the push socket alive and wakes
the host only when data lands on it. bigtab01 has neither:

| Requirement | bigtab01 |
|---|---|
| cellular modem | **none.** `mmcli -L` -> "No modems were found", no `/sys/class/wwan` |
| WiFi socket/TCP offload | **absent.** Intel Wireless 7265 WoWLAN offers magic packet, pattern match, disconnect, GTK rekey, EAP identity, 4-way handshake, net detect — and no connection offload |
| usable wake pattern | pattern match caps at **`maximum packet offset 0 bytes`**, so patterns must match from the first byte of the frame; an FCM payload inside a TCP segment cannot be matched |

On top of that `wlp1s0 power/wakeup` reads `disabled` and NetworkManager tears the association
down on suspend (`state change: activated -> deactivating (reason 'sleeping')`). So push-while-
asleep is not reachable by configuration. What *is* reachable is a periodic wake window, which is
what got built.

## The other blocker: Waydroid freezes Android by itself

Worth knowing even when the host is wide awake. `waydroid.cfg` carries `suspend_action = freeze`,
and when Android's PowerManager decides to suspend (screen off, no wakelock) it calls out to the
host, where `tools/services/hardware_manager.py` runs:

```python
def suspend():
    cfg = tools.config.load(args)
    if cfg["waydroid"]["suspend_action"] == "stop":
        tools.actions.session_manager.stop(args)
    else:
        tools.actions.container_manager.freeze(args)
```

There are only two outcomes — `stop`, or freeze. **There is no "do nothing" value**: anything
other than `"stop"` lands in the `else`. So keeping background apps alive on an awake host means
stopping Android from *asking* to suspend (a held wakelock), not changing this setting.

## What was built

| File | Purpose |
|---|---|
| `/usr/local/bin/waydroid-sync` | one sync window: thaw Android, wait, refreeze, re-suspend |
| `/usr/local/bin/waydroid-bt-restore` | ends the cycle and restores bluetooth |
| `/usr/local/bin/waydroid-sync-sleep` + `/etc/systemd/system/waydroid-sync-sleep.service` | writes the cycle marker; arms the deferred bluetooth restore. **Was `/etc/systemd/system-sleep/50-waydroid-sync` until 2026-09-07, and in that form it never ran** — systemd 259 scans only `/usr/lib/systemd/system-sleep`, empty and read-only here, so `/run/waydroid-sync.cycle` had never once existed. The logic is unchanged; only what invokes it. See [27](27-android-power-button.md) |
| `/etc/systemd/system/waydroid-sync.{timer,service}` | fires `OnCalendar=*:0/15` with `WakeSystem=true` |

Sources kept in [artifacts/power/](../artifacts/power/).

### Deciding when it is safe to re-suspend

This was the hard part. Two guards, and both must hold:

1. **the cycle marker** `/run/waydroid-sync.cycle`, written by the sleep hook at `pre suspend` and
   removed on a user-initiated resume. A locked screen alone is *not* sufficient evidence — a
   laptop can sit locked and awake, and suspending it then would be wrong.
2. **swaylock still running.** `swayidle` is configured with `before-sleep swaylock -f`, so
   swaylock exiting means the user came back and unlocked. This covers the 15 s gap before the
   marker clears.

**logind's `IdleHint` is useless here** — it reads `no` on an active sway session even when idle.
That was checked, not assumed.

There is deliberately **no AC check**. The marker preserves whatever the user chose: suspend on AC
and it syncs and goes back to sleep, rather than silently leaving the machine awake.

### Keeping bluetooth off across the wakes

By cancellation rather than guesswork. Every resume arms a deferred `waydroid-bt-restore`;
`waydroid-sync` **cancels** it when the wake turns out to be a sync window. So bluetooth stays
blocked for the whole automated cycle, every periodic wake included, and returns only on a resume
the user asked for, with the original rfkill state restored.

## Measuring the power, and why it was harder than expected

**There is no instantaneous power source on this machine.** `current_now` reads **ENODEV for the
entire time the battery is discharging** — it works while charging — there is no `power_now`, and
the hwmon `curr1_input` fails identically. The EC simply does not report a present rate on
discharge. Every figure below is therefore a `charge_now` delta.

**`charge_now` moves in 1% steps.** `charge_full / 100` = 31640 µAh, matching observed steps of
31000 and 35000 µAh. This caused a real error worth recording: a naive fixed-window measurement
reported **5313 mW** for screen-on idle, because the window ran 90 s past the last step and that
drain had not yet registered. Measuring **edge to edge**, between step transitions, gives
**7.2 W** for the same state. Edge-to-edge removes the quantisation error rather than averaging it
down, and is the right technique whenever the state can be held.

**s2idle cannot use that technique**, because nothing can observe a step while the CPU is frozen.
It starts on an edge (so the baseline is exact) and ends on a mid-step read, leaving a one-sided
0..1 step undercount. Hence three logged figures: raw (a lower bound), +half a step (the best
estimate, since the phase is uniform), and +one step (upper bound).

That also settles a question worth stating generally: **for a fixed-magnitude quantisation error,
one long run beats two short ones.** Two 90-minute runs average the error down by √2; a single
180-minute run halves it outright. Repeating a run is for checking that a result is
*representative*, not for precision.

## Results

| Regime | Draw | Runtime on ~25.5 Wh | Method |
|---|---|---|---|
| screen on, idle | **7.2 W** | ~3.5 h | edge to edge, 140 s |
| screen off, awake | **2.14 W** | **~12 h** | edge to edge, 861 s, 63000 µAh |
| **s2idle** | **~0.6 W** (0.37–0.83) | **~43 h** | 33 min, edge-started, bounded |

The screen-off figure is the surprise, and it matters: at 2.14 W the machine can keep Android
**fully live** — real-time notifications, no sync-window latency — for about twelve hours. The
periodic-wake machinery is therefore worth having for multi-day standby, but is not needed to get
through a working day.

**The ratio that decides the design is only ~3.5x**, screen-off-awake against s2idle — not the 10x
assumed when the hybrid was sketched. Waking every 15 minutes for a 30 s window spends roughly 3%
of the s2idle budget on sync time alone, before counting the wake and re-sleep transitions, to buy
notification latency that twelve hours of screen-off-awake gives for nothing. So the honest
conclusion is that the timer earns its place for **multi-day standby**, not for a working day.

### How the s2idle figure was obtained, and why the bound is wide

The 90-minute nap was cut short at 33 min 15 s when the machine was woken by hand. That did not
waste it: the journal timestamps both ends exactly, so the sample is clean, just short.

```
Sep 06 19:30:50  PM: suspend entry (s2idle)
Sep 06 20:04:05  PM: suspend exit
```

Baseline `charge_now=2647000` was taken exactly on a step edge, so it is exact; the end reading of
`2616000` is mid-step, and exactly one 1% step registered across 1995 s. The figure is corrected
for the 63 s the machine was awake before the charge was read (~4745 µAh at the measured 2.142 W).
Hence 374 mW as a lower bound, 825 mW as an upper, and 600 mW as the best estimate.

**Only one step in 33 minutes is exactly the quantisation problem described above** — this is the
±40% result that a longer run would tighten. An overnight run would bring it inside ±5%.

## S3 versus s2idle — started, deferred 2026-09-06

Worth settling because the measured s2idle figure (~0.6 W) is high for standby, and because the
kernel's own default on this machine was **`deep`**: `/sys/power/mem_sleep` read `s2idle [deep]`
before we overrode it. Broadwell-Y is early-generation S0ix, and Linux cannot report S0ix residency
for it at all — `intel_pmc_core` covers Skylake and later — so measurement is the only evidence.

First, a correction to a natural assumption: **wake intervals are not a property of the sleep
state.** RTC alarm wake works from S3 and s2idle alike, because the RTC is on always-on power in
both. `rtcwake` and systemd's `WakeSystem=true` program that same alarm, so `waydroid-sync.timer`
works unchanged either way. What actually differs:

| | S3 (`deep`) | s2idle (`freeze`) |
|---|---|---|
| ACPI state | genuine S3 | stays in **S0** — not an ACPI sleep state |
| firmware on resume | yes | none |
| resume latency, measured | **0.630 s** | **0.147 s** |
| wake sources | fixed hardware set | broader — anything that can raise an interrupt |
| power floor | fixed by hardware | emergent; depends on actually reaching S0ix |

The last row is the catch: S3's draw is a hardware guarantee, while s2idle's is emergent, and if one
device fails to enter its low-power state you silently get "idle with the screen off" instead of
standby, with nothing to tell you.

### The smoke test passed, but not cleanly

Switching is additive — a `20-s3-test.conf` in `sleep.conf.d/` sorting after `10-s2idle.conf`
(kept in [artifacts/power/](../artifacts/power/)). A 90-second nap confirmed the override took
effect and that resume works:

```
Sep 06 20:22:11 kernel: PM: suspend entry (deep)     <- S3, not s2idle
Sep 06 20:23:41 kernel: PM: suspend exit
Sep 06 20:23:41 kernel: xhci_hcd 0000:00:14.0: xHC error in resume, USBSTS 0x411, Reinit
```

**S3 resume reinitialises the USB controller. s2idle does not** — its resumes in this session were
clean. That is a behavioural mark against S3 independent of power, and it has two consequences
worth chasing:

- the **bluetooth controller is USB** (`1-4`), so BT-as-wake-source is likely less reliable under
  S3 than under s2idle;
- the **webcam is USB**, so it is re-enumerated on every S3 resume. Possibly relevant to the
  unexplained spurious camera removals in [docs/12](12-v4l2-frame-errors.md), which were never
  reproduced.

### Deferred

The 7-hour run was launched and cancelled before it suspended. `20-s3-test.conf` was **removed**,
so the machine is back on validated s2idle; re-adding that one file is the whole switch. Redo with:

```bash
sudo install -m 0644 artifacts/power/20-s3-test.conf /etc/systemd/sleep.conf.d/
/var/tmp/power-standby.sh 420 "S3 overnight"      # runs as the user; elevates internally
```

`power-standby.sh` reads the mode back out of the kernel log rather than trusting the config, and
self-corrects for an early wake by subtracting the awake seconds at 2.142 W and dividing by the
time genuinely asleep. It re-suspends when done rather than leaving the machine awake.

## Bluetooth as a wake source — plausible, untested, **deferred by request 2026-09-06**

The controller is `Intel 8087:0a2a` on USB `1-4`. The wake chain is half-armed:

```
0000:00:14.0 (xHCI PCIe)  = enabled
usb1         (root hub)   = disabled
1-4          (bluetooth)  = disabled
```

`1-4/power/wakeup` **existing at all** is the signal: the kernel only creates that attribute for
devices advertising USB remote wakeup. So the hardware is capable and it is merely switched off at
the two USB levels. To try it:

```bash
echo enabled | sudo tee /sys/bus/usb/devices/1-4/power/wakeup /sys/bus/usb/devices/usb1/power/wakeup
```

Two conflicts to weigh first. Enabling remote wake on a radio is a common source of **spurious
wakeups**, which would need the standby figure re-measured. And it is directly at odds with the
"bluetooth off during periodic wakes" behaviour built above — an rfkill-blocked controller cannot
wake anything, so BT-as-wake-source and BT-off-for-power are mutually exclusive.

## Still untested

- **the end-to-end sync cycle.** Both guard paths were exercised and correctly did nothing, which
  is the safe half. A real cycle — marker present, screen locked, machine actually asleep, Android
  thawed and refrozen, machine re-suspending itself with bluetooth staying off — has not run yet.
- a precise s2idle figure. The bound above is wide enough that 0.4 W and 0.8 W are both
  consistent with it, which changes a standby estimate from ~64 h to ~32 h. An undisturbed
  overnight run would settle it.
- whether freezing the container mid-binder-transaction can wedge it. Waydroid freezes routinely
  when idle, so this is likely fine, but it has not been deliberately stressed.

## Incidental findings

- **Volume-up wakes the machine from s2idle**, so the `intel-vbtn` (`INT33D6`) buttons are wake
  sources. Relevant to [docs/15](15-power-button.md), where the open question is whether that same
  device reports a *held* press.
- A charge reading taken shortly after resume needs correcting for the awake seconds, or it
  inflates the sleep figure. At 2.142 W awake against ~0.6 W asleep, one awake minute costs as
  much as three and a half asleep.

## Trap worth remembering

`pkill -f power-run.sh` killed the ssh session that issued it — the pattern matched that very
command line. Kill long-running host-side helpers **by PID**.
