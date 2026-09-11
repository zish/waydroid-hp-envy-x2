# The battery cut out at ~18%, and nothing warned anyone

**Date:** 2026-09-09. **Status: investigation only. Nothing on the host was changed.** All commands
run for this note were read-only. Three follow-ups are proposed at the end and **none has been
done**.

Written in answer to "I got a black screen instead of a low battery warning — does Waydroid have
them, and did I miss it?". Short answers: Android's warning exists, is configured, and almost
certainly fired about two minutes before the machine died; the host had no way to show a warning at
all; and the machine did not perform an auto-shutdown — the power was cut.

## Summary

- **It was not a clean shutdown.** The journal for that boot ends mid-message, with **zero**
  `systemd-shutdown`, `Reached target Power-Off` or `Journal stopped` records, and no
  `PM: suspend entry` either. Hard power loss.
- **UPower's critical action never ran and could not have.** It is set to fire at 2%; the machine
  died at roughly 17–18%.
- **The gauge is uncalibrated and reads high.** `energy-full` equals `energy-full-design` exactly on
  a 2014 pack, and the reported full capacity has wandered between 23 and 27 Wh across sessions.
  The pack delivered about a quarter of the energy it claimed to still hold.
- **Android's low-battery warning is present and was live** — `mLowBatteryReminderLevels=[20, 10]`,
  channel `BAT` at `IMPORTANCE_HIGH`, sound file present, no Do Not Disturb, stream unmuted. The 20%
  crossing happened around 08:39:40, roughly **2 min 15 s** before the cut.
- **The host has no notification daemon at all.** `dunst` is the only registered
  `org.freedesktop.Notifications` provider and it aborts on every session start. Nothing host-side
  could have alerted anyone — not UPower, not the `notify-send` brightness and volume bindings.

## The timeline

Boot `525ca4d4` ran 06:51:19 → 08:41:56. Power restored manually at 11:06:42.

UPower's own history, `/var/lib/upower/history-charge-Primary-25-03721_2014_09_06.dat`, is the only
durable record of the discharge:

| time | level | rate |
|---|---|---|
| 08:10:38 | 52% | — |
| 08:33:59 | 26% | 12.502 W |
| 08:35:47 | 24% | 16.819 W |
| 08:37:46 | **22%** | — |
| 08:37:58 | — | 18.156 W |
| 08:41:56 | — | **power cut** |

Drain was steady at ~57 s per percentage point (26% → 22% took 227 s), under a load of **12.5–25 W
from a 23 Wh pack**. The file's mtime is 08:41, so UPower wrote it again just before the end; the
appended samples did not survive the crash, which is itself consistent with an unflushed page cache
at hard power loss.

## It was not a shutdown

```
$ journalctl -b -1 | grep -cE 'Reached target (Power-Off|Reboot|Shutdown)|systemd-shutdown'
0
```

For contrast, the deliberate reboot that ended the *previous* boot leaves an unmistakable trail:

```
systemd-shutdown[1]: Syncing filesystems and block devices.
systemd-shutdown[1]: Sending SIGTERM to remaining processes...
systemd-journald[635]: Journal stopped
```

None of that is present, and the final line of boot -1 is a truncated kernel message. Nor is there
any `PM: suspend entry`, so the machine did not sleep either.

Worth noting for future reference: `upower -d` reports `critical-action: Sleep`, resolved from
`CriticalPowerAction=Auto` with `AllowRiskyCriticalPowerAction=false`. Had the threshold ever been
reached, this machine's response would have been to sleep — on a host whose s2idle is already known
to be unreliable ([19-sensor-hub-suspend-wedge.md](19-sensor-hub-suspend-wedge.md)).

## The gauge is lying

```
energy-full:         22.9824 Wh
energy-full-design:  22.9824 Wh
capacity:            100%
serial:              03721 2014/09/06
```

A twelve-year-old pack reporting itself at exactly 100% of design capacity means the EC never
learned a real capacity, so percentage is computed against the design figure. Corroborating this,
UPower keeps *five* separate history files for this battery — `Primary-23` through `Primary-27` —
because the reported full capacity has drifted between 23 and 27 Wh across sessions.

The arithmetic at the end:

```
claimed remaining at 08:37:46:  22% x 22.9824 Wh  =  5.06 Wh
at the measured 18.16 W, that is                  ~16.7 minutes
actually survived                                  ~4.2 minutes  ->  ~1.27 Wh
```

The pack delivered roughly **a quarter** of what the gauge promised. Under load the cells reach
cutoff voltage while the gauge still reads in the high teens, which is why no threshold below ~20%
can be relied on here.

## 2026-09-10: the gauge re-estimated by 18 points on plug-in

A second discharge, measured live, refines the section above. **The rate is accurate; the zero
point is not.** Those are separate faults and only the second one matters.

**The coulomb counting is sound.** The machine idled at a measured 3.4 W (panel dimmed) for 100
minutes while the gauge fell from 81% to 59%:

```
energy actually consumed   3.4 W x 1.667 h           = 5.67 Wh
energy the gauge claims    22% x 3282 mAh x ~7.7 V   = 5.56 Wh
```

Agreement within 2%. Over this range the gauge tracks real energy leaving the pack correctly, which
is *not* what "delivered roughly a quarter of what it promised" above would lead you to expect. That
finding was drawn from the final minutes of the 2026-09-09 discharge and applies to the tail, not to
the curve as a whole.

**The absolute reading is not sound, and plugging in proves it in one step.** At an indicated 59%,
discharging at 450 mA, the charger was connected. Immediately:

| | indicated | `charge_now` | `voltage_now` |
|---|---|---|---|
| unplugged | **59%** | 1929000 µAh | 7.504 V |
| plugged in, seconds later | **41%** | 1439000 µAh | 7.982 V |

**490 mAh and 18 percentage points vanished with no energy transferred.** The EC simply produced a
different estimate once the load dropped and the terminal voltage recovered. The pre-plug voltage
corroborates the lower figure: 7.504 V is 3.75 V/cell against the 4.28 V/cell seen at full, which on
this chemistry is roughly 30-40% state of charge, not 59%.

Note also that `charge_full` drifted from `3272000` to `3282000` within this single session — more
of the same wandering that produced five separate UPower history files.

**The working model, then:** the pack discharges linearly and reports it honestly, against a total
capacity it does not have. It therefore reads high by a margin that grows as it empties, and it
reaches true cell cutoff while still indicating something in the high teens — which is exactly the
hard cut on 2026-09-09. Under load the indicated figure should be treated as an upper bound with
roughly 15-20 points of overstatement, not as a measurement.

## Android's warning: present, configured, and almost certainly fired

`dumpsys activity service com.android.systemui`, PowerUI section:

```
mLowBatteryAlertCloseLevel=25
mLowBatteryReminderLevels=[20, 10]
```

So the first warning fires at exactly 20%, the second at 10%. Everything that would gate it checks
out:

- Notification channel `BAT` ("Battery"), `mImportance=5` (HIGH, so it heads-ups), not blocked, not
  deleted.
- Its sound `/product/media/audio/ui/LowBattery.ogg` exists in the image, 47,903 bytes.
- `mZenMode=ZEN_MODE_OFF`; `ringer mode muted streams = 0x0`; `STREAM_NOTIFICATION` at index 3.
- Android was reading real host battery values, not the old hardcoded fakes — today's `dumpsys
  battery` reports `voltage: 8502` against UPower's `8.502 V`, so the
  [10-battery-fixed.md](10-battery-fixed.md) patch was in effect.

Extrapolating the measured 57 s/point from the 22% sample, 20% was crossed at about **08:39:40**,
which is 2 min 16 s before the cut. The 10% reminder never came close.

## The host could not have warned anyone

```
dunst[1508]: WARNING: Cannot open X11 display.
dunst[1508]: CRITICAL: [get_x11_output:0077] Couldn't initialize X11 output. Aborting...
dunst.service: Failed with result 'exit-code'.
```

`dunst` is the sole provider of `org.freedesktop.Notifications` on the bus — D-Bus activatable, and
it fails immediately on every session start, in a pure-Wayland Sway session. It was still in
`failed` state during this investigation, having last tried at 11:12:05.

So UPower's own `PercentageLow=20.0` transition (crossed around 08:38:45) had nowhere to go, and
neither do the `notify-send` brightness and volume bindings in `~/.config/sway/config.d/`. This is
not a battery-specific gap: the host has had no working desktop notifications at all.

## Verified vs. inferred

**Verified on the host:** the journal truncation and the absence of every shutdown and suspend
record; the clean-shutdown trail in the preceding boot for contrast; `UPower.conf` and
`critical-action: Sleep`; the battery's identical full/design energy and the five history files; the
charge and rate samples through 08:37:58; dunst being the only Notifications provider and being in
`failed` state; Android's PowerUI levels, the `BAT` channel, the sound file, zen mode and stream
volume.

**Inferred.** The ~17–18% level at the cut and the ~08:39:40 crossing of 20% are extrapolations from
the measured 57 s/point trend across the last four durable samples, not measurements — the samples
after 08:37:46 were lost with the power. That Android's notification actually rendered is likewise
inference: logcat lives in the container's volatile ring buffer, the host journal carries only
Android's `init:` lines, and `/var/lib/waydroid/waydroid.log` is Waydroid's own Python log with
nothing battery-related. Every precondition is satisfied; the event itself was not observed.

## Proposed, not done

1. **Fix dunst.** It is the host's only notification path and it is broken for everything, not just
   battery. Likely the unit starting before `WAYLAND_DISPLAY` is imported into the systemd user
   environment, given it fell back to X11.
2. **Move UPower's thresholds above the gauge's unreliable region.** 20/5/2 is meaningless on a pack
   that dies at 18. Something like `PercentageLow=40`, `PercentageCritical=25`,
   `PercentageAction=20` would at least act while the reading still means something.
3. **Reconsider `CriticalPowerAction`.** There is a 16 GB `/var/swapfile` against 7.7 GB of RAM, so
   hibernate is genuinely available and is a better answer than `Sleep` on a machine that cannot be
   trusted to wake.

Android's own 20% threshold would also need raising to be useful here, but that lives in SystemUI's
`config_lowBatteryWarningLevel` and would need an RRO; it is not worth doing before the host side
works.
