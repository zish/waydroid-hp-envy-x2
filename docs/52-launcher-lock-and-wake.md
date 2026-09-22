# The black screen was the launcher locking it, and the power button was already the cure

**2026-09-21.** Reported as "the screen on bigtab01 went black and is still that way — the caps-lock
key light turns on and off on the HP Bluetooth keyboard, and I can SSH in." Nothing had crashed.
Fossify Launcher called `lockNow()` through a device admin, Android went to sleep, and the panel
went dark with its power still on. The recovery already existed and was simply not known at the
time: **press the power button, then wake the machine.** That is
[docs/27](27-android-power-button.md)'s `waydroid-android-lock.service` doing exactly what it was
built to do.

## One-paragraph summary

Fossify Launcher (`org.fossify.home`) registers a device-admin receiver so it can offer a
**double-tap-to-lock-screen** gesture. Dragging the last icon out of a folder landed on the empty
desktop as a double-tap, the launcher called `DevicePolicyManager.lockNow()`, and Android went to
`Asleep`. Because [docs/37](37-brightness.md)/[docs/42](42-backlight-selinux.md) gave Android's
`ILight` the real panel backlight, "screen off" here is literally
`intel_backlight/brightness = 0` — the panel stays powered and displays black. The host never
suspended: SSH, Wi-Fi scans and DHCP renewals ran throughout. Keyboard input cannot undo this
(docs/27 measured it), but a suspend/resume cycle can, because
`waydroid-android-lock`'s post leg injects a wakeup unconditionally on every resume. Over SSH,
`waydroid shell -- input keyevent KEYCODE_WAKEUP` does the same thing directly; it restored the
panel to 735/937 in about three seconds.

---

## Diagnosis: `mLastSleepReason` names the culprit in one line

The whole diagnosis is four fields out of `dumpsys power`:

```
mWakefulness=Asleep
mLastSleepTime=390922007 (358472 ms ago)
mLastSleepReason=device_admin
mScreenOffTimeoutSetting=1800000
```

`device_admin` is the load-bearing word. Android records *why* it went to sleep, and three reasons
matter here:

| `mLastSleepReason` | Means |
|---|---|
| `timeout` | the idle screen-off timer expired |
| `power_button` | someone pressed the button |
| `device_admin` | an app with device-admin rights called `lockNow()` |

The idle timeout is 30 minutes (`mScreenOffTimeoutSetting=1800000`) and the screen had been dark for
six, so a timeout was ruled out arithmetically before the reason field was even read. The crash
buffer (`logcat -b crash`) was **empty**, which rules out the intuitive theory that the drag killed
SystemUI or the launcher.

`dumpsys device_policy` then names the one registered admin:

```
Enabled Device Admins (User 0, provisioningState: 0):
  org.fossify.home/.receivers.LockDeviceAdminReceiver:
```

That receiver exists for exactly one feature. Fossify Launcher cannot turn the screen off without
device-admin rights, so the gesture and the admin are the same thing: if the admin is registered,
the gesture is live.

**It fired twice in 25 minutes.** After the first recovery at 16:51, `mLastSleepTime` moved again to
~17:16:30 with the same `device_admin` reason — four seconds *before* the owner pressed the power
button. This is not a freak one-off; it is a gesture that a normal drag can trigger.

### Why this is worth writing down

The symptom — black screen, machine otherwise alive, SSH works — is **identical** to a compositor
crash, a SurfaceFlinger wedge, a backlight regression, or the
[docs/51](51-pid-namespace-32bit-cliff.md) boot loop with the animation off-screen. Check
`mLastSleepReason` *first*: it is one field, and it separates "somebody asked for this" from
"something broke" before any time goes into the display stack.

The host-side reads that establish "the host is fine" are cheap and come first:

```bash
# panel powered, backlight zero == Android decided the screen is off
cat /sys/class/backlight/intel_backlight/{brightness,actual_brightness,bl_power}
# host is alive and unsuspended
journalctl --since "30 min ago" | grep -c waydroid-wifid
```

A flat `brightness=0` sampled over several seconds, with `bl_power=0` and the connector still
`enabled`, means the panel is fine and something *chose* black. A backlight fault would not hold
`actual_brightness` at exactly 0 while the host keeps scanning Wi-Fi.

## Recovery: two routes, and the good one needs no SSH

### At the machine — press the power button, then wake it

This is the correct answer and it was already built. Observed end to end:

```
17:16:34 systemd-logind: Power key pressed short.
17:16:35 kernel: PM: suspend entry (s2idle)
17:16:37 kernel: PM: suspend exit
17:16:38 Android mWakefulness -> Awake
17:16:40 systemd: Stopped waydroid-android-lock.service - Lock Android before suspend, wake it after resume
```

`HandlePowerKey=suspend` in `/etc/systemd/logind.conf.d/10-power-button.conf` sends the host to
s2idle, and `waydroid-android-lock.service` — ordered `Before=sleep.target` so it runs ahead of the
`user.slice` freeze — locks Android on the way down and, on the way back up, **injects a wakeup
unconditionally**. Its own header says so plainly: *"The post leg injects a wakeup unconditionally,
which makes any suspend/resume cycle a recovery from that state."*

So the power button is a general-purpose "un-stick Android" control on this machine, whatever put
Android to sleep. That is worth knowing before reaching for a laptop and an SSH key.

The cycle is cheap and its known casualties are already handled — verified on this very cycle:

```
17:16:46 ite8350-resume: accelerometer live after resume, nothing to do
17:17:10 waydroid-sync: user resume - bluetooth restored, cycle ended
```

[docs/19](19-sensor-hub-suspend-wedge.md)'s sensor-hub reprobe checked and found nothing to do, and
Bluetooth — which [docs/50](50-bluetooth.md) lists as not surviving s2idle — was restored
automatically. Neither is a reason to avoid the button.

### Over SSH — inject the wakeup directly

```bash
sudo waydroid shell -- input keyevent KEYCODE_WAKEUP
```

Verified: backlight 0 → 735 (of 937) and `mWakefulness` `Asleep` → `Awake` within three seconds,
with no container restart and therefore **no drop to the SDDM greeter**. The keyguard is showing
afterwards (`KeyguardServiceDelegate: showing=true`, not occluded, no PIN configured), so it needs a
swipe at the machine — or `wm dismiss-keyguard` over the same shell.

## Why the keyboard could not fix it

The caps-lock LED toggling was real and it was misleading. It proves the host is alive and BlueZ is
delivering — the LED is driven entirely by the host's input stack — but it says nothing whatever
about Android.

docs/27 already measured the two halves of this, and both are worth repeating because each one alone
would be enough:

- **Ordinary keys do not wake Android.** `KEY_SPACE` injected while asleep left it `Asleep` for 13 s;
  `KEY_WAKEUP` woke it in under 4 s. Android ignores input while non-interactive except from keys
  flagged as wake sources.
- **`KEY_POWER` never arrives.** It is *"dropped by the guest hwcomposer before Android sees it"* —
  so even the one key that would ordinarily wake a device is unavailable in-band here.

Hence docs/27's conclusion, which this incident is a clean instance of: a sleeping Android under
cage has **no in-band way back**, and the suspend/resume hook is what supplies one out-of-band.

## Byproduct: `systemd-backlight` fails on every brightness change

Not a cause of anything, but it turned up while reading the journal and it is a consequence of
[docs/42](42-backlight-selinux.md) that was not written down there:

```
audit: AVC avc: denied { write } for comm="systemd-backlig" name="brightness"
  scontext=system_u:system_r:init_t:s0
  tcontext=system_u:object_r:waydroid_backlight_t:s0 tclass=file permissive=0
systemd-backlight[…]: intel_backlight: Failed to write system 'brightness' attribute: Permission denied
```

`systemd-backlight@backlight:intel_backlight.service` saves and restores panel brightness across
boots. It runs as `init_t`. docs/42 relabelled that one attribute to the private type
`waydroid_backlight_t` precisely so that only `waydroid_t` may write it, and `init_t` is not on the
list — so systemd's restore is denied, the unit fails, and systemd retries until it hits
`Start request repeated too quickly`. Observed as a burst of five failures at 16:23 and another at
16:45, each burst coinciding with the backlight actually moving.

**This is harmless and arguably correct.** Android owns the brightness here; there is nothing for
systemd to usefully restore, and a successful restore would fight `ILight` at boot. The only real
cost is journal noise — and the bursts are a usable *side channel* for "the backlight moved at this
timestamp" when logcat has already rolled, which is how the 16:45 lock was timestamped before
`dumpsys power` was read.

Left as-is deliberately. If the noise ever matters, mask the unit
(`systemctl mask systemd-backlight@backlight:intel_backlight.service`) rather than widening the
policy, since granting `init_t` write access would undo the point of the private type.

---

## Double-tap-to-wake: cheap here, but it must be host-side

The natural follow-up is "can we have double-tap-to-*un*lock, and would it cost battery?" On a phone
the honest answer is "it costs real power." **Here it does not — and the reason is specific.**

### Why the phone answer does not apply

Double-tap-to-wake on a phone is a *firmware* feature. The whole SoC suspends, and the touch
controller must stay in a special low-power gesture-scanning mode, watching the digitizer on its own
and raising an interrupt when it sees the pattern. That standby scanning is where the battery goes.

None of that structure exists in the case that actually bit us. When Android sleeps but the host does
**not**, nothing suspends:

- The host Linux stays fully awake — verified during this incident, with `waydroid-wifid` running
  scans and dnsmasq renewing DHCP leases for the entire six minutes the screen was dark.
- The touchscreen is `SYNA7500:00 06CB:0E1B`, an i2c-HID Synaptics panel on **event5**, and it
  reports `power/runtime_status = unsupported` — it has no runtime PM at all. It is powered and
  scanning continuously whether or not anyone is looking at it.
- `cage` already holds `/dev/input/event5` open and is already reading that stream.

The digitizer is already scanning, the events are already being produced, and something is already
reading them. Detecting two taps is **pure software over data that exists regardless**. The marginal
cost is one process blocked in `read()`, waking only when a finger touches the glass — not a poll,
and not a new power draw.

### It cannot be done inside Android

This is the trap, and docs/27 already recorded the evidence without framing it this way. When
Android's display group powers off, InputReader tears the touchscreen down:

```
InputReader: Disabling wayland_touch (device 4) because the associated
             viewport is not active
```

So there is no touch input *inside* Android to double-tap on. Any in-guest gesture detector — an
accessibility service, a launcher setting, a framework patch — is dead on arrival, because the
events stop at the guest's input device before any of them could see them.

A **host-side** watcher is upstream of all of that. It reads the SYNA7500's evdev stream directly,
which is unaffected by anything Android does to `wayland_touch`, and injects `KEYCODE_WAKEUP` the
same way the suspend hook already does.

### What it would look like

`bin/stylus-watch.py` is already the template: a stdlib-only evdev reader written for this exact
panel, for an immutable host with no pip. The daemon would be the same shape:

1. Read `/dev/input/event5` as root.
2. Arm only when `intel_backlight/brightness == 0` — cheap, and exactly the "screen is dark"
   condition, so it can never interfere with normal touch use.
3. Detect two `BTN_TOUCH` down/up pairs inside ~400 ms and within a small radius.
4. `waydroid shell -- input keyevent KEYCODE_WAKEUP`, which is proven above and is the same
   injection `waydroid-android-lock post` already performs.

### Two caveats, one unverified

**The s2idle case is not covered and cannot be, from userspace.** `/proc/acpi/wakeup` has **no**
entry for the touchscreen, so the panel cannot wake the machine from a genuine system suspend. A
host-side watcher buys back "Android asleep, host awake" — precisely today's failure — and nothing
more. A real suspend still needs the lid or the power button, which already works.

**Unverified: whether `cage` takes an `EVIOCGRAB` on event5.** If it grabs the device exclusively, a
second reader opens the file successfully but receives no events, and the design is inert. libinput
does not normally grab, and `fuser` shows `systemd`, `systemd-logind` and `cage` all holding the fd,
which is suggestive but not proof — `EVIOCGRAB` blocks other readers' *events*, not their `open()`.
This is a one-command empirical test (run a reader on event5 while cage is up, then touch the
screen) and it should be the **first** thing checked, before any daemon is written.

### Is it worth building?

Marginal, and that is the honest assessment. The power button already recovers this state, costs
nothing, and is one press. Double-tap-to-wake would be a convenience — a tablet-shaped gesture on a
tablet-shaped machine — not a fix for an outage. It is cheap enough to be worth doing if the
`EVIOCGRAB` test passes and someone wants it; it is not load-bearing.

## Resolution

**The owner turned the gesture off** the same day, in Fossify Launcher's own settings
(*Double tap to lock screen*), on the grounds that it bought nothing on this machine and cost two
lock-outs in under half an hour. That is the cleaner of the two available fixes: it leaves
`LockDeviceAdminReceiver` registered but idle, so nothing prompts to re-enable it and no device-admin
state changes.

The alternative, not taken, was to deactivate the admin outright with

```
dpm remove-active-admin org.fossify.home/.receivers.LockDeviceAdminReceiver
```

which is more durable against the setting being toggled back, but invites the launcher to prompt for
the permission again.

Note what this does **not** change: Android can still be put to sleep by its own 30-minute idle
timeout, and docs/27's measurements still hold, so the power button remains the way back in. Turning
the gesture off removes the *accidental* trigger, not the underlying condition — which is why the
recovery routes above stay worth knowing.

## Traps

- **An empty `logcat -b crash` is a result, not a dead end.** It ruled out the entire
  crash-of-SystemUI family in one command and pointed straight at "this was deliberate."
- **The caps-lock LED proves the host, not the guest.** It is driven entirely host-side. Reading it
  as "input is reaching Android" is wrong and sends the investigation toward the input bridge.
- **`brightness=0` with `bl_power=0` is Android's screen-off, not a backlight fault.** Sample it a
  few times; a fault does not sit at exactly 0 while everything else on the host keeps running.
- **Do not reach for a container restart.** It would have "fixed" this, destroyed the evidence, and
  dropped the kiosk session to the SDDM greeter, which needs someone at the machine. One injected
  keyevent was the whole repair.
- **Check what the repo already built before declaring something unrecoverable.** The first draft of
  this note concluded "SSH was the only route back in." That was wrong: docs/27 had shipped the
  power-button recovery months of work earlier, and the owner found it by pressing the button. The
  mechanism was in the journal the whole time, one `systemctl cat` away.
