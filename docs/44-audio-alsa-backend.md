# Audio: direct ALSA as a selectable backend

**Status: built and measured on 2026-10-04.** Added to the goal list on 2026-09-11 at the
owner's request. Everything marked *measured* below was run against bigtab01 or read out of
upstream source on 2026-09-11, or added by a second pass on 2026-09-12. Everything else was
explicitly flagged as hypothesis — and on 2026-10-04 the ALSA arm was actually built and both
arms were run with audio playing, which answered every one of those hypotheses and corrected
five claims in the scoping. **Read the A/B section before acting on anything above it**, in
particular before using the SELinux probe under "First commands to run": it asks about the
wrong domain and returns a false negative.

The question that started this was narrower — *is anyone building a native PipeWire interface for
Waydroid?* The answer is no, and chasing why not led to a better target: Waydroid's audio HAL is
already an ALSA client, and pointing it at a real card is a much smaller change than a PipeWire
port, with a much larger payoff.

## What the audio path actually is today

Verified by reading the shipped sources, not inferred:

```
AudioFlinger
  -> audio.primary.waydroid.so         snd_pcm_open(&out->pcm, "pulse", ...)
     -> alsa-lib (libasound)           /vendor/usr/share/alsa/alsa.conf
        -> pcm.pulse { type pulse }    alsa.conf line 662, hardcoded in the fork
           -> libasound_module_pcm_pulse.so -> libpulse
              -> /run/xdg/pulse/native  (bind-mounted host socket)
                 -> pipewire-pulse on the host
                    -> PipeWire -> ALSA -> hw:1,0
```

Three compatibility shims between Android and a sound card that the container could open itself.

Two details make the rest of this cheap:

- The HAL passes the **name** `"pulse"` to `snd_pcm_open()`, and that name is just an alsa-lib
  config alias, defined inline at line 662 of
  [alsa.conf](https://github.com/waydroid/android_external_alsa-lib/blob/lineage-17.1/src/conf/alsa.conf)
  in Waydroid's alsa-lib fork, installed by `android/Android.mk` to
  `$(TARGET_OUT_VENDOR)/usr/share/alsa` — i.e. `/vendor/usr/share/alsa/alsa.conf` inside the image.
- That file's `@hooks` block loads `/etc/alsa/conf.d`, `/etc/asound.conf` and `~/.asoundrc`
  **after** its own definitions. Inside Android `/etc` is a symlink to `/system/etc`.

So `pcm.!pulse` can be redefined from an overlay file with no HAL rebuild at all. **Confirmed in
this image on 2026-09-12**, by reading `/var/lib/waydroid/rootfs` — which needs no sudo and no
`waydroid shell`, and is the better probe:

- `pcm.pulse { type pulse ... }` is at line **662** of `/vendor/usr/share/alsa/alsa.conf`, exactly
  where upstream puts it;
- the `@hooks` block at lines 11-15 loads `/etc/alsa/conf.d`, `/etc/asound.conf` and `~/.asoundrc`,
  and alsa-lib runs those hooks after parsing the file, so a later definition wins;
- `/etc` is a symlink to `/system/etc`;
- and **`/system/etc/asound.conf` does not exist**, so the override is a new overlay file with
  nothing to merge against.

## Nobody is building a native PipeWire client, and probably nobody will

Searched on 2026-09-11: the `waydroid` GitHub org has `android_external_pulseaudio`,
`android_external_alsa-lib` and `android_external_alsa-plugins`, and no pipewire repo of any kind.
Seventeen issues across `waydroid/waydroid` mention PipeWire; every one is a bug report against the
pulse compatibility layer ([#1683](https://github.com/waydroid/waydroid/issues/1683),
[#1976](https://github.com/waydroid/waydroid/issues/1976),
[#2333](https://github.com/waydroid/waydroid/issues/2333)) — no PR, no feature request, no design
discussion. PipeWire upstream has zero issues mentioning Waydroid and no Android/bionic port MRs.

Adjacent work exists but all of it runs the other way — PipeWire on the Linux side consuming
Android audio:

| project | what it is |
|---|---|
| [misc-de/furios_pipewire](https://github.com/misc-de/furios_pipewire) | SPA plugin: PipeWire talks to the Android audio HAL on FuriOS. Created 2026-09-10 |
| [NEURAX-FX/pw-aaudio-sink](https://github.com/NEURAX-FX/pw-aaudio-sink) | SPA sink over AAudio, Termux / Linux-on-Android |
| [sugerpersion/pipewire](https://github.com/sugerpersion/pipewire) | PipeWire built for aarch64 Android (Termux) |

The structural reason not to bother: `pipewire-pulse` terminates the PulseAudio protocol natively,
so a PipeWire host already works, and the PulseAudio wire protocol is a stable version-independent
contract in a way PipeWire's native protocol is not. A container image vendoring its own
libpipewire against whatever the host runs is a coupling nobody wants to own.

Where upstream's energy actually goes instead:
[PR #80](https://github.com/waydroid/android_hardware_waydroid/pull/80) (*audio: honour the format
and rate AudioFlinger requests*, open 2026-09-07) and
[issue #64](https://github.com/waydroid/android_hardware_waydroid/issues/64) (*HI-res audio
support*) — fixing rates inside the ALSA path rather than replacing it.

## ALSA multi-client does not reach across the container boundary

The intuition that "ALSA already handles multiple clients" is half true and does not help here.

**Kernel-level multi-open needs more than one substream.** Measured on bigtab01 — every PCM on the
machine has exactly one:

```
 0 [HDMI]: HDA-Intel - HDA Intel HDMI
 1 [PCH ]: HDA-Intel - HDA Intel PCH
00-03/07/08: HDMI 0/1/2        : playback 1     subdevices_count: 1
01-00: ALC3227 Analog          : playback 1 : capture 1   subdevices_count: 1
```

A second opener of `hw:1,0` gets `EBUSY`.

**The multi-client behaviour people mean is dmix/dsnoop**, which is pure userspace: alsa-lib
clients rendezvous through a SysV shared-memory segment plus a semaphore and mix in software into
one `hw:` handle. Two reasons that cannot bridge host and container:

1. **The container has its own IPC namespace.** `data/configs/config_base` sets no
   `lxc.namespace.share.ipc`, so LXC unshares it by default — a dmix instance inside Android and
   one on the host would never find each other's `shmget`/`semget` keys.
2. **PipeWire does not use dmix.** It opens `hw:` directly (node
   `alsa_output.pci-0000_00_1b.0.analog-stereo`). Measured: every substream currently reads
   `hw_params: closed`, because WirePlumber suspends idle nodes — so the device *is* free between
   host sounds. That makes it a race, not coexistence.

**Conclusion: direct ALSA means dedicating a device to Android, not sharing one.** Which is the
[Stage 4 second-radio answer](34-wifi-second-radio.md) again — a USB interface for Android, a
WirePlumber rule telling the host to ignore it, and the PCH card stays the host's. For the DAW case
below, exclusive ownership is the point rather than a concession.

## What is missing in Waydroid — three things, all small

**1. The sound nodes are not in the container.** `generate_nodes_lxc_config()` in
[tools/helpers/lxc.py](https://github.com/waydroid/waydroid/blob/main/tools/helpers/lxc.py) globs
`/dev/video*`, `/dev/fb*`, `/dev/dma_heap/*` and a long list of fixed nodes. There is no `/dev/snd`.
Only the pulse socket is bind-mounted, at lines 207-210.

Measured, and useful: `set_lxc_config()` — which writes `config` and `config_nodes` — is called
**only** from `initializer.py` (i.e. `waydroid init`). Container start only regenerates
`config_session`. That is why the hand-edited `lxc.net.0.name = wlan0` survived the 2026-09-10
reboot, and it means a hand-added mount entry in `/var/lib/waydroid/lxc/waydroid/config_nodes`
persists until the next `waydroid init` or upgrade:

```
lxc.mount.entry = /dev/snd dev/snd none bind,create=dir,optional 0 0
```

No device-cgroup entry is needed: LXC 6.0.6 here, and the generated config carries no
`lxc.cgroup2.devices.*` rules at all — same as the camera nodes.

**2. Permissions, and the camera shows why it works there and not here.** Measured:

```
crwxrw-rwx+ 1 root video system_u:object_r:v4l_device_t:s0   81, 0 /dev/video0
crw-rw----+ 1 root audio system_u:object_r:sound_device_t:s0 116, 4 /dev/snd/pcmC1D0p
```

`/dev/video0` is world-accessible, which is the only reason the camera HAL can open it — there is
no idmap, so Android's uids are the host's raw uids and Android's `video`/`audio` group ids do not
match Fedora's. The `+` on the sound nodes is a udev ACL for `jmelanso` only; the container gets
nothing. A udev rule on the chosen card is the fix.

**A probe run as root will lie about this.** Root opens `/dev/snd/*` regardless. Any
availability check has to ask whether the mode bits or ACL grant a non-root, non-`audio`-group
uid. **Corrected 2026-10-04: the uid named here was the wrong one.** The process that opens the
PCM is `/vendor/bin/hw/android.hardware.audio.service` at **uid 1000 / gid 1041**, not
`audioserver` at uid 1041 — `audioserver` never touches the node. An ACL granting uid 1041 grants
it to a process that does not want it. See correction 3 in the A/B section, which also records
why `setfacl` is not a usable mechanism here at all.

**3. SELinux is unknown here.** `sound_device_t` versus the `v4l_device_t` that works today. Ask
`selinux.selinux_check_access()` directly rather than waiting for an audit record —
[docs/42](42-backlight-selinux.md) and [docs/40](40-binder-nice.md) both record denials that are
`dontaudit`ed and therefore invisible to `ausearch`.

**Answered 2026-10-04: SELinux is not a gate, in either direction.** The container's audio
process runs as `container_runtime_t`, which is allowed `open`/`read`/`write`/`ioctl`/`map` on
`sound_device_t`, and Android's own SELinux inside this image reports `Disabled`. The domain
guessed in "First commands to run" — `waydroid_t` — is denied `sound_device_t` *and*
`v4l_device_t`, while the camera works, so a probe keyed on it answers a question about the wrong
process.

## The upstream shape: an audio backend CLI option

The goal is `waydroid --audio-backend {auto,alsa,pulse,none}`, probed before Android boots, so
`waydroid in cage` ([docs/25](25-waydroid-in-cage.md)) can take a dedicated interface and any other
user keeps today's behaviour. Every hook this needs already exists.

**The probe belongs exactly where `waydroid.stub_sensors_hal` is decided.** In
[tools/helpers/images.py](https://github.com/waydroid/waydroid/blob/main/tools/helpers/images.py)
`make_prop()` already does a host capability probe and turns it into an Android property:

```python
if which("waydroid-sensord") is None:
    props.append("waydroid.stub_sensors_hal=1")
```

`make_prop()` is called from `mount_rootfs()`, which `container_manager.py:214` calls on **every
container start**, immediately after `generate_session_lxc_config()` at line 205 and before LXC
boots init. "Check before booting LineageOS" is not a new hook; it is the line above the one that
already does it for sensors — the same seam [docs/14](14-sensors.md) exploited.

**Three touch points:**

| where | change |
|---|---|
| `tools/helpers/arguments.py`, `tools/config/__init__.py` | `--audio-backend` / `--audio-device`; persist in `waydroid.cfg` beside `suspend_action` and `mount_overlays` (`defaults`, line 31), override per-run through `session_defaults` (line 57) — already the channel that carries `pulse_runtime_path` to the container over DBus |
| `tools/helpers/lxc.py` `generate_session_lxc_config()` | branch the mount: `alsa` -> `make_entry("/dev/snd", "dev/snd", options="rbind,create=dir,optional 0 0")`; `pulse` -> today's socket entry; `none` -> neither. Rewritten every container start, so the choice is per-session |
| `audio/audio_hw.c` | `property_get("waydroid.audio_device", device, "pulse")` feeding `snd_pcm_open()`. The HAL already reads `waydroid.pulse_runtime_path` the same way (line 1039). Three lines, and it sits next to what PR #80 is already touching |

`waydroid status` should print the **resolved** backend, since auto-probing makes the outcome
non-obvious. For upstream acceptance `auto` should keep today's behaviour (pulse) and `alsa` should
be the opt-in that falls back with a log line.

**Known limitation of this design:** it is a boot-time decision with no runtime fallback. If
something takes the PCM between the probe and the HAL's open, `PCM_OPEN_RETRIES 100 x 20 ms` spins
for two seconds and Android is silent until the container restarts. Hotplug does not reach it
either.

## The DAW ceiling — the architecture is not the limit, the HAL is

The owner's target is using the machine as an Android DAW, which makes the interesting question
"how low can latency go and how many channels", not "does sound come out".

LXC adds **nothing** to the audio path: same kernel, same ALSA, same interrupt timing. A
class-compliant USB interface at small period sizes is physically reachable from inside the
container. What is in the way is about 1100 lines of C in
[audio_hw.c](https://github.com/waydroid/android_hardware_waydroid/blob/lineage-20/audio/audio_hw.c),
read on 2026-09-11:

| | shipped HAL |
|---|---|
| Playback | hardcoded 48 kHz; **stereo only** — line 827 rejects any other channel count and rewrites the mask |
| Buffer | `PLAYBACK_PERIOD_SIZE 1024` x `PLAYBACK_PERIOD_COUNT 4` -> `out_get_latency()` reports **85 ms** |
| Capture | hardcoded **16 kHz**, 320-frame periods x 2 — voice-recognition grade, useless for tracking |
| AAudio | no `create_mmap_buffer`, so the MMAP/EXCLUSIVE low-latency path never engages |

So direct ALSA gets the *device* — any interface, any rate, bit-perfect, exclusive. Multichannel
and low latency mean replacing that HAL.

The build path is already proven here: `audio.primary.waydroid.so` is a vendor `.so` exactly like
`libgbm_mesa_wrapper.so`, which [docs/08](08-camera-fixed.md) rebuilt **with the NDK alone, no AOSP
tree**, and deployed through the vendor overlay for both ABIs.

Three supporting pieces, all **measured on 2026-09-12** from the mounted rootfs:

**The policy XML is the tightest gate in the stack, tighter than the HAL.**
`/vendor/etc/audio_policy_configuration.xml` is the generic AOSP file (4829 bytes; there is no
`/system/etc` copy), and its primary module offers apps exactly one output profile:

```xml
<mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY">
    <profile name="" format="AUDIO_FORMAT_PCM_16_BIT"
             samplingRates="48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
</mixPort>
```

Input is `AUDIO_CHANNEL_IN_MONO` across the usual rate ladder. So a perfectly rewritten HAL still
offers apps nothing beyond 48 kHz 16-bit stereo until this file changes too, and there is no
`AUDIO_OUTPUT_FLAG_DIRECT` mixPort — on Android 13 that is the only way to reach the card at a rate
the mixer is not already running at. It is under `/vendor/etc`, so it is overlay-able.

**AOSP's USB audio HAL is already in the image, and it is the multichannel path.** In both ABIs'
`hw/` directories, `audio.usb.default.so` ships alongside `audio.primary.waydroid.so`, and
`usb_audio_policy_configuration.xml` is already `xi:include`d by the file above. Its
`usb_device output` and `usb_device input` mixPorts carry **no static profile at all** — AOSP's
dynamic-profile mechanism, filled in from the real device at attach time, so rates, formats and
channel counts come from the hardware instead of from XML.

What gates it is a feature flag, not code. `/system/etc/permissions/` contains
`android.hardware.wifi.xml` — our own Stage 0 file — and **no `android.hardware.usb.host.xml`, no
`android.hardware.midi.xml`**. AOSP's `UsbAlsaManager`/`UsbAlsaDevice`/`UsbMidiDevice` read
`/dev/snd/pcmC%dD%d` and `/dev/snd/midiC%dD%d` directly, but are driven by UsbManager hotplug,
which Waydroid does not wire up. So the ingredients are: the feature XML (one overlay file), the
`/dev/snd` mount, node permissions, and something to deliver an attach event — the same
one-overlay-file lever that woke the whole Wi-Fi framework up in
[Stage 0](32-wifi-stage3.md). **This is a genuinely different route to multichannel from rewriting
`audio_hw.c`, and it should be costed before that rewrite is started.**

**Corrected 2026-09-29: three ingredients, not four — `usb.host` is already declared, by the
image.** The paragraph above measured `/system/etc/permissions` and stopped there. `/vendor/etc/`
`permissions/` holds `android.hardware.usb.host.xml` and `android.hardware.usb.accessory.xml`, so
`pm list features` does report `android.hardware.usb.host` on this device and `UsbManager` has its
feature flag already. Nothing here added it; our overlay's permissions directory contains exactly
one file, the Stage 0 `android.hardware.wifi.xml`. So that ingredient is spent, and the shopping
list is `/dev/snd`, node permissions, and the attach event.

`android.hardware.midi.xml` really is absent, from **both** directories — checked by `ls` on each
path and corroborated by `pm list features`, which reports no MIDI feature and no MIDI system
service. So the MIDI half of the conclusion stands exactly as written; only the USB half was
measured a directory short. Worth knowing when grepping for this: `pm list features | grep midi`
matches `android.hardware.sensor.relative_hu`**`midi`**`ty`, which is not a MIDI feature.

**The guest's alsa-lib install is complete enough to matter, with one gap.**
`/vendor/usr/share/alsa/` holds `alsa.conf`, `cards/` and `pcm/` — the full plugin config set
(`dmix.conf`, `dsnoop.conf`, `iec958.conf`, `surround*.conf`, …) — so `hw:`, `plughw:` and format
conversion all resolve inside the container with nothing added. `libasound.so` and the three pulse
plugins (`libasound_module_{pcm,ctl,conf}_pulse.so`) are present in **both** ABIs under
`/vendor/lib{,64}/hw/`. There is **no `ucm2/`**: irrelevant for HDA, fatal for a modern SOF codec
that needs UCM to unmute and route. The mitigation is that mixer state is kernel-global — set the
card up host-side with `alsactl`/UCM before handing it over and the container inherits it.

## The latency budget, and why native PipeWire is the wrong axis

Asked directly on 2026-09-12: *would a native PipeWire client in the guest beat today's
ALSA-over-PulseAudio path?* Theoretically yes; in practice it is the second-smallest term in the
budget, and it forecloses the one thing the DAW goal actually needs.

A framing correction first, because it matters: nothing here "emulates ALSA". The HAL is a real
alsa-lib client. It is the *pulse* end that is the shim — alsa-lib's ioplug converting to the
PulseAudio wire protocol.

**Sharpened 2026-10-04, by comparing the two HALs in this image.** Stock Android does not want a
sound server at all, and the proof is shipped alongside Waydroid's HAL:

| | links | audio API |
|---|---|---|
| `audio.usb.default.so` (AOSP's own) | `libtinyalsa.so`, `libalsautils.so` | tinyalsa — ioctls straight at `/dev/snd/pcmC*D*` |
| `audio.primary.waydroid.so` | `libasound.so`, and **no libpulse** | alsa-lib `snd_pcm_*`, opening the *name* `"pulse"` |

`libtinyalsa.so` is present in `/system/lib`, `/system/lib64` and the VNDK apex, so the stock
direct-ALSA client library is in the image already. The entire PulseAudio dependency is therefore
**one config alias in Waydroid's alsa-lib fork** — not a library, not a protocol the HAL speaks,
and not anything Android requires. Overriding `pcm.!pulse` does not bypass a sound server so much
as decline to introduce one.

Measured proof that the override really does remove it, taken from the running HAL process in the
ALSA arm: the only alsa library mapped is `libasound.so`; `libasound_module_pcm_pulse.so` and
`libpulse` have **zero** mappings, so the ioplug plugin is never even `dlopen`ed; the process's
only sound file descriptor is `12 -> /dev/snd/pcmC1D0p`; no process anywhere on the host holds the
PulseAudio socket; and `pactl` reports zero Waydroid sink-inputs. The socket is still
bind-mounted into the container and still exists — inert, opened by nothing, and the reason
stopping PipeWire would break container startup (see below).

The budget, host numbers measured 2026-09-12 (`pw-metadata -n settings`, PipeWire 1.6.8):

| term | cost |
|---|---|
| HAL buffer — `PLAYBACK_PERIOD_SIZE 1024` x `PLAYBACK_PERIOD_COUNT 4` @ 48 kHz | **85 ms** |
| alsa-lib pulse ioplug -> libpulse -> unix socket | one extra copy, one extra IPC hop, PA-protocol buffer negotiation |
| `pipewire-pulse` -> graph — `clock.quantum` **1024** @ `clock.rate` 48000 | **21.3 ms** |
| ALSA sink node -> `hw:1,0` | card period x count |

A native PipeWire client deletes the second row outright, and lets the guest ask for
`node.latency = 256/48000` directly instead of expressing the wish as PA `tlength`/`fragsize` for
`pipewire-pulse` to reinterpret under its own `pulse.min.*` clamps. **The host graph is not the
obstacle**: `clock.min-quantum` is 32 — 0.67 ms — against `max-quantum` 2048. The 1024 sitting
there is a default nobody has had a reason to lower.

Measured since, and it qualifies that last sentence and corrects the row above it — see docs/56.
`force-quantum` was set to 32 on this host and Android's audio became unusable. `min-quantum` is
what PipeWire will *accept*, not what the machine will hold, so the graph is not the obstacle but it
is load-bearing: lower it for host-side clients with short paths of their own, not for Android.

**The 21.3 ms in the table is the setting, not the running graph.** `clock.quantum` is 1024, but
`pw-top` on 2026-09-26 showed the graph running at `QUANT 256` with nothing forced, because the
Waydroid stream node negotiates 256 and PipeWire follows the smallest request any client makes. So
this hop costs **5.33 ms** while Android is playing, and the 1024 is only what the graph falls back
to when nothing asks for less — which makes this row a smaller term in the budget than it appears,
and the HAL's 85 ms an even more dominant one. Forcing the graph *below* what the client negotiated
is what broke the audio: the sink followed to 32 while the stream stayed at 256, and PipeWire
resampled across the mismatch.

But the HAL's own 85 ms dwarfs everything downstream. Rewriting the period constants alone, over
today's unchanged pulse transport, captures most of the available win.

**The decisive argument is structural: AAudio's low-latency path cannot work over any socket
transport.** `create_mmap_buffer` hands an app a shared ring buffer that the *hardware* DMAs out
of. Neither the PulseAudio protocol nor PipeWire's native one can produce that, and proxying it
with a thread reintroduces exactly the copy the exercise was meant to remove. MMAP requires `hw:`
opened directly. Hence the ordering:

| | |
|---|---|
| 1. today | 85 ms plus two hops |
| 2. rewrite the HAL's buffering, keep pulse | biggest win per unit of work; keeps host mixing, per-app volume, Bluetooth and hotplug |
| 3. native PipeWire client | a few ms better than 2, and inherits the coupling problem above — vendoring libpipewire and SPA for bionic against whatever the host happens to run, where the PA protocol is stable precisely because it is frozen |
| 4. direct ALSA `hw:`, exclusive | the only route to AAudio EXCLUSIVE; floor is the card's own period x count |

PipeWire-native answers a question about the *desktop* experience, and `pipewire-pulse` already
answers that one for a handful of milliseconds. For the DAW goal, 3 is a detour and 4 is the
destination.

## Bluetooth: bluealsa answers the question, and it is still the wrong trade

Also asked on 2026-09-12: *can BlueZ A2DP go over ALSA instead of PipeWire?* Yes. BlueZ 5 removed
its own audio handling; it exposes A2DP as `org.bluez.MediaEndpoint1`/`MediaTransport1` over D-Bus
and hands the endpoint an fd. Something has to register as that endpoint and do the SBC/AAC/aptX
encoding, and [bluez-alsa](https://github.com/arkq/bluez-alsa) is exactly that daemon — it exposes
`bluealsa:DEV=XX:XX:XX:XX:XX:XX` PCMs through an alsa-lib plugin, with a ctl plugin for volume.
Not installed here (`rpm -q bluez-alsa`), which on an Atomic host means a layered package and a
reboot.

**Measured 2026-10-04, and it is worse than "a layered package": there is no package.**
`rpm-ostree install --dry-run bluez-alsa` against all four enabled repos — `fedora`, `updates`,
`updates-archive`, `fedora-cisco-openh264` — answers `error: Packages not found: bluez-alsa`. The
host is Fedora 44 Sericea and ships no `dnf`. So the host half is a source build on an ostree
system, not `rpm-ostree install`, and it is layering plus a reboot on a machine that needs a LUKS
passphrase and a manual `sshd` start at the console afterwards ([docs/02](02-ssh-access.md)).

Three more measurements, all of which make the guest half heavier than reason 2 below suggests:

- **The image ships three alsa plugins and they are all pulse.**
  `libasound_module_{conf,ctl,pcm}_pulse.so`, in both ABIs, and nothing else. So the slot is
  real — but it is the only occupant.
- **There is no `libdbus` anywhere in the image.** A `find` over the whole rootfs returns
  nothing. bluez-alsa's alsa plugin is a D-Bus client, so the bionic build is not one library but
  a dependency chain: `libdbus-1` first, then `libasound_module_pcm_bluealsa.so` and its ctl
  counterpart, each for both ABIs. [docs/08](08-camera-fixed.md)'s NDK-only precedent applies, but
  to four or six objects rather than one, and
  [no-vendored-binaries](54-no-vendored-binaries.md) means they get built, not shipped.
- **Nothing is paired that could test it.** `bluetoothctl devices` lists a phone, a Dell PN7522W
  pen and an HP Bluetooth keyboard — no headset, no speaker, no A2DP sink of any kind. And
  `dumpsys audio` reports `mBluetoothName=null`. So the whole chain could be built and there
  would be no way to tell whether it worked.

**And reason 1 is confirmed rather than inferred:** `pw-dump` shows a live `bluez5` node, i.e.
WirePlumber's monitor is loaded and holding `org.bluez`'s media endpoint right now. Adopting
bluealsa means taking that away from the host.

**So the conclusion hardens.** The payoff is A2DP out of Android — which already happens, by the
host routing the primary output to a headset sink — at an unchanged 100-200+ ms, in exchange for a
source build on the host, a four-to-six-object bionic cross-compile for the guest, the D-Bus
system bus exposed into the container, and the host losing Bluetooth audio through its own stack.
**The alternative that actually serves "direct ALSA and Bluetooth" is `snd-aloop`**, which is
in-tree on this kernel (`/lib/modules/7.1.13-200.fc44.x86_64/kernel/sound/drivers/snd-aloop.ko.xz`,
not currently loaded) and needs no cross-compile, no package and no reboot — see below.

### The third arm nobody costed: `snd-aloop`

Not built, proposed 2026-10-04 on the strength of the A/B above. The A/B treated this as a binary
choice — PipeWire's socket or the bare card — and it is not. `snd-aloop` is a kernel loopback
soundcard: a writer on `hw:Loopback,0,0` is readable on `hw:Loopback,1,0`. Point the HAL's
`pcm.!pulse` at the playback end and let PipeWire capture the other, and Android becomes a
**real alsa-lib client talking to a real `/dev/snd` node** while the host keeps the graph.

What that buys over today's default: `pipewire-pulse` leaves the path entirely — the measured
3.70% of a core, the PA wire protocol, the ioplug conversion and the protocol-level buffer
negotiation all go — while routing, per-app volume, [docs/56](56-pipewire-control.md)'s patchbay
and **Bluetooth** all keep working, because the graph is still there. It needs `modprobe
snd-aloop`, the same one-line `asound.conf` override, and a link from the loopback capture to the
real sink.

**The honest risk, stated before measuring: two clocks.** `snd-aloop` has no hardware clock of its
own — its timing comes from whoever writes to it — so the loopback and the real card are
unsynchronised, and PipeWire will reconcile them with adaptive resampling. That trades a socket
and a protocol shim for a kernel copy and a resampler, and it is **not obvious that it wins**: the
pulse path today resamples nothing, because the stream and the graph are both at 48 kHz. So this
is a third arm to measure with [bin/alsa-vs-pulse.sh](../bin/alsa-vs-pulse.sh), not a
recommendation yet. The instrument already reports what would settle it — the card's `hw_params`,
HAL write jitter, xrun and delayed-write rates, and the per-process CPU of the graph.

Four reasons it is a worse path than what runs today, worst first:

1. **Only one process can be BlueZ's media endpoint**, and WirePlumber's bluez5 monitor holds it.
   Measured: `hci0` present and unblocked, `bluetooth.service` active, PipeWire 1.6.8 serving the
   PA socket. Adopting bluealsa means disabling PipeWire's Bluetooth module, and the *host* losing
   Bluetooth audio through its normal stack. That is the dedicate-the-device trade from
   [the second radio](34-wifi-second-radio.md) again — except what gets given up here is the
   host's own, not a spare.
2. **A bluealsa PCM is a userspace alsa-lib plugin, not a `/dev/snd` node**, so mounting `/dev/snd`
   into the container reaches none of it. Using it from Android needs
   `libasound_module_pcm_bluealsa.so` built for bionic in both ABIs, plus the daemon's D-Bus
   connection and per-stream sockets reachable across the container's namespaces. The slot and the
   precedent exist — the pulse plugins already live at
   `/vendor/lib{,64}/hw/libasound_module_*_pulse.so` — but this is another three-shim stack, not
   fewer.
3. **A2DP costs 100-200+ ms regardless**: encoder, link buffering, sink jitter buffer. Choosing
   ALSA over PipeWire changes none of it, and none of it is relevant to the DAW goal.
4. **The image has no Bluetooth audio HAL at all.** Measured: `a2dp_audio_policy_configuration.xml`
   is `xi:include`d by the policy config, but there is no `audio.a2dp.default.so` and no
   `android.hardware.bluetooth.audio` service anywhere in `/vendor/lib64`. Android has no native
   Bluetooth audio path here; Bluetooth "works" today only in the sense that the primary output
   lands on a sink `pipewire-pulse` happens to route to a headset.

The scenario bluealsa would serve is "I chose `--audio-backend alsa` for a dedicated interface and
still want Bluetooth" — and the per-session backend switch above already serves it better: keep
pulse for general use, take direct ALSA only for the interface being tracked to.

## Built and measured: the ALSA/PipeWire A/B, 2026-10-04

**Everything above this heading was read out of sources and probes. This section is
the arm actually built on bigtab01 and run with audio playing, and it corrects five
things the scoping got wrong.** Both arms were measured with the same instrument,
[bin/alsa-vs-pulse.sh](../bin/alsa-vs-pulse.sh), which detects which arm is live by
asking who holds the PCM rather than by reading config, and reports every counter as
a delta over a window rather than as a total. [bin/alsa-arm.sh](../bin/alsa-arm.sh)
builds and reverts the ALSA arm; [bin/audio-tone.sh](../bin/audio-tone.sh) is the
headless signal source.

The signal was a 1 kHz sine at -6 dBFS, 48 kHz / 16-bit / stereo — deliberately the
exact format the HAL asks the PCM for and the only one `audio_policy_configuration.xml`
lets an app have, so nothing in the guest resamples or converts and anything that
happened to it happened on the host side.

### The numbers

| | pulse arm (today's default) | direct ALSA arm (`pcm.!pulse` → `hw:1,0`) |
|---|---|---|
| holder of `hw:1,0` | `pipewire`, on the host | `/vendor/bin/hw/android.hardware.audio.service`, in the container |
| card access | `MMAP_INTERLEAVED` | `RW_INTERLEAVED` |
| card format | `S32_LE` — converted up from the HAL's S16 | **`S16_LE` — the HAL's own format, unconverted** |
| card period | 1024 frames, 21.33 ms | **256 frames, 5.33 ms** |
| card buffer | 32768 frames, 682.7 ms (32 periods) | **1024 frames, 21.3 ms (4 periods)** |
| frames actually queued | 296-376 (6.2-7.8 ms) | 575-831 (12.0-17.3 ms) |
| hops between HAL and DAC | socket → `pipewire-pulse` → Waydroid node → eq6 filter-chain → ALSA sink | **none** |
| host CPU for the path | **5.95% of a core** (`pipewire` 2.25 + `pipewire-pulse` 3.70) | **0.03-0.05% of a core** |
| `audioserver` CPU | 0.85% | 0.97% |
| PipeWire xruns | 0/s | 0/s |
| AudioFlinger delayed writes | 0/s (1 in 11839 lifetime) | 0/s (0 lifetime) |
| **HAL write jitter, std** | **0.145 ms** | **0.347-0.371 ms** |
| HAL write jitter, extremes | -1.97 / +2.08 ms | -1.80 / +2.13 ms (one sample -5.84 / +6.71) |
| AudioFlinger process time | ave 0.159 ms, max 0.58 ms | ave 0.186-0.195 ms, max 1.97-6.45 ms |
| timestamp errors | 47.95/s | 49.13/s |
| HAL frame count / format / rate / channels | 1024 / S16 / 48 kHz / stereo | **identical** |
| a listener, at the machine | heard it | **"clean sine wave"** |

### What the A/B actually says

**Direct ALSA buys CPU and buys the card. It does not buy latency that Android can
use, and it costs timing stability.** Three findings, in order of how much they
matter.

**1. The host-side cost of the pulse path is 5.95% of a core, and it goes to zero.**
That is the largest unambiguous win and it was not in the scoping at all. 3.70% of it
is `pipewire-pulse` — the protocol shim — and 2.25% is the graph that carries one
48 kHz stereo stream through two filter-chain nodes to a card. In the ALSA arm the
whole graph idles at 0.03%. On a 9.6 W four-core box that is real.

**2. The card's buffer gets 32x shorter and bit-exact, and Android cannot tell.**
PipeWire was running `hw:1,0` at 1024x32 = 682.7 ms of buffer in `S32_LE`; the HAL
runs it at 256x4 = 21.3 ms in `S16_LE`, which is the format it was handed. So the
samples now reach the DAC unconverted and with 1/32 of the buffering behind them.
**And none of it reaches an app**: `HAL frame count` is 1024, `HAL format` is
`PCM_16_BIT`, the rate is 48000 and the channel count is 2, in *both* arms,
identically. The HAL's own buffering and the policy XML are unchanged, so an app sees
exactly what it saw before. This is the measured form of what the scoping argued from
source: **the HAL and the policy XML are the gate, not the transport.**

**3. It makes the timing worse, and there is a mechanism.** HAL write jitter — how
regularly `snd_pcm_writei()` returns, i.e. how steady the clock downstream of the HAL
is — went from **0.145 ms std to 0.347-0.371 ms**, consistently across two samples, a
factor of 2.4. AudioFlinger's own process time degraded with it (max 0.58 ms → 1.97
and 6.45 ms). Neither arm dropped a sample at idle: zero xruns and zero delayed
writes in both, and a listener called the ALSA arm a clean sine.

The mechanism is scheduling, measured directly. The HAL's writing thread is
`/vendor/bin/hw/android.hardware.audio.service`'s thread named `writer`, and it runs
**`SCHED_OTHER` at nice -19** — not `SCHED_FIFO`, and not any realtime policy. On the
host side `rtkit-daemon` is active, `/usr/share/pipewire/pipewire.conf` asks for
`rt.prio = 60` / `nice.level = -11`, and **`pipewire-pulse`'s `data-loop.0` was measured
at `SCHED_RR` priority 20** — so the pulse path has a genuinely realtime thread in it
and the ALSA path has none.

The shape of the difference is therefore: in the pulse arm the HAL's non-realtime thread
only had to keep a socket fed, with a realtime loop and 682.7 ms of card buffer
downstream absorbing its variance. In the ALSA arm that same non-realtime thread *is*
the one with the deadline, against 21.3 ms. Shorter buffer plus non-realtime writer is
exactly the combination that xruns under load, and the A/B did not load it — which is
why [bin/alsa-load-ab.sh](../bin/alsa-load-ab.sh) exists.

**One honest gap in that measurement.** `pipewire`'s own `data-loop.0` read `SCHED_OTHER`
when sampled, not realtime — but it was sampled *during the ALSA arm*, with the graph
idle and no client attached, so that reading says nothing about what it runs at while
carrying audio. The realtime claim above rests on `pipewire-pulse`'s loop, which was
measured directly, on rtkit being active, and on the configured `rt.prio`. Re-sample
`pipewire`'s loop during the pulse arm before treating it as realtime too.

**That is fixable, and the scoping expected it not to be.** `/proc/<pid>/limits` for
the HAL service reports **`Max realtime priority 10`** — so `SCHED_FIFO` up to
priority 10 is permitted inside the container already. The HAL simply never asks. See
the correction below.

### Load-tested 2026-10-04: the jitter regression does not become dropouts

Finding 3 above predicted that a 21.3 ms buffer behind a non-realtime writer would
fail under load, and said nothing had loaded it. [bin/alsa-load-ab.sh](../bin/alsa-load-ab.sh)
loaded it — three arms, 45 s each, four spinners at nice 0 inside Android, the same load
[docs/43](43-app-freezer.md) used to close goal 7. **The prediction is wrong on this
hardware with this load.**

| arm | host busy | PSI stall / 45 s | delayed writes | timestamp disc | HAL writes/s | jit_std | signal |
|---|---|---|---|---|---|---|---|
| idle | 4% | 0.1 s | **0** | 0 | 46.96 | 0.364 | -41.6 dBFS |
| **loaded** | **100%** | **4.2 s** | **0** | **0** | **47.09** | 0.426 | -41.6 dBFS |
| recovered | 4% | 0.1 s | **0** | 0 | 46.93 | 0.351 | -41.6 dBFS |

Zero delayed writes and zero timestamp discontinuities in every arm, across **three
independent runs**. The HAL write rate did not sag — 47.09/s under load against a
theoretical 48000/1024 = 46.875/s, i.e. it kept the card fed exactly on time while the
machine was pinned. Write jitter rose about 17% under load (0.364 → 0.426) and came
back down afterwards (0.351), reproducibly, but it never turned into a lost buffer.

**Two things make this a real result rather than a lucky one.** The load is measured,
not assumed: host busy went 4% → 100% and `/proc/pressure/cpu` accumulated 4.2 s of
stall in 45 s, so the box genuinely was saturated — an earlier version of the script
proved only that four spinner *processes* existed, which is not the same claim. And
signal power held at -41.6 dBFS in all three arms, so no arm was silently measuring a
stopped tone, which is a mistake this exercise already made twice.

**The honest limits.** The spinners run at **nice 0 and the HAL's writer runs at nice
-19**, so under CFS the writer has a very large weight advantage over exactly this
competition — which is probably *why* it survives, and means the result is "survives
nice-0 competition on a saturated CPU", not "survives anything". Untested: competition
at negative nice, I/O or memory pressure rather than CPU, a period smaller than 256
frames, and any load while the host's own PipeWire graph is also running (it is idle in
this arm by construction). Also note `jit_min/max` is identical in all three arms
because it is a ratcheting lifetime extreme, not a per-arm figure — see the script
header.

**So the ordering in "Where this leaves the roadmap" softens on one point.** "Step 4
without step 2 is a downgrade in timing" is still true of the jitter number, but the
downgrade is not costing audio on this machine: direct ALSA at 21.3 ms is usable as it
stands. Asking for `SCHED_FIFO` — which the container permits, `Max realtime priority
10` — remains the right fix for the jitter and the prerequisite for going *below* this
buffer, rather than a prerequisite for using it at all.

### The latency accounting, 2026-10-04 — and the 85 ms figure is wrong for this image

**Android cannot report its own output latency here.** AudioFlinger's per-track dump has a
`Latency` column and it reads **`unavail`**, because that number is derived from the HAL's
presentation timestamp and this HAL supplies none — `Timestamp stats` shows `err` equal to 100% of
writes, in *both* arms. So no app can query it, `AudioTrack.getTimestamp()` has nothing to return,
and A/V sync has no basis. That is a HAL omission and direct ALSA does not change it.

What *is* exactly readable is every buffer in the chain, and in the ALSA arm there is nothing
between them — which is the point of removing the hops, and it makes the accounting the
measurement rather than an estimate:

| stage, ALSA arm | frames | ms | how known |
|---|---|---|---|
| app's `AudioTrack` buffer (VLC's own choice) | 8208 | 171.0 | `FrmCnt` in the track dump |
| AudioFlinger mixer | 1024 | 21.3 | `Normal frame count` |
| card, actually queued | **896** | **18.7** | mean of 12 samples of `delay`, range 809-1053 (16.9-21.9 ms) |
| **platform only** (mixer + card, no app) | **1920** | **40.0** | |
| total, as VLC ran it | ~10128 | **~211** | |
| a minimum-buffer app (2x the 1024-frame sink) | ~3968 | **~83** | derived, not measured |

**The surprise is how little of that direct ALSA recovers.** The same accounting for the pulse arm,
downstream of the HAL: graph quantum 256 = 5.33 ms, plus the `eq6` filter-chain node at another
5.33 ms, plus the card's measured queue of 296-376 frames = 6.2-7.8 ms — about **17.7 ms of
measurable downstream**, against the ALSA arm's **18.7 ms** of card queue. Those are the same
number. The only term direct ALSA definitely removes is `pipewire-pulse`'s own buffer, and that is
exactly the one nothing will report: `pactl list sink-inputs` gives the Waydroid stream
`Buffer Latency: 0 usec` and `Sink Latency: 0 usec`.

So **direct ALSA is not a latency win of any size this measurement can see.** Its wins are the
5.95% of a core and the bit-exact S16 path. Anyone adopting it for latency is adopting it for the
wrong reason.

**And the dominant term named in "The latency budget" is wrong for this image.** That section puts
the HAL's own buffer at **85 ms**, from upstream's `PLAYBACK_PERIOD_SIZE 1024` x
`PLAYBACK_PERIOD_COUNT 4` = 4096 frames, and calls it the term that "dwarfs everything
downstream". Two independent measurements say this image's HAL is **256 x 4 = 1024 frames = 21.3
ms**:

- the card's `hw_params` under the ALSA arm reads `period_size: 256`, `buffer_size: 1024` — and
  with `type plug` over a card that accepts `BUFFER_SIZE [32 1048576]`, a HAL asking for 4096
  frames would have got 4096, not 1024;
- AudioFlinger independently reports `HAL buffer size: 4096 bytes` = 1024 frames at 4 bytes/frame,
  where 1024 x 4 periods would have been 16384 bytes.

`delay` hovering at 896-1053 against a 1024-frame buffer corroborates it a third time: AudioFlinger
writes one full card buffer per `write()`.

**Flagged as inference, not reading:** the HAL's constants were deduced from what it asks the PCM
for, because `out_get_latency()`'s return value is unreadable here — the track `Latency` is
`unavail`. Reading `audio_hw.c` for this image's branch, or the `.so`, would settle it. But the
practical consequence stands either way: **the HAL's buffering is 21.3 ms, not 85 ms, and the
large terms are the app's buffer and AudioFlinger's mixer** — neither of which any backend choice
touches.

**A hard number is still available and needs no cable.** The built-in microphone is on the *same
card*, `hw:1,0` has separate playback and capture substreams, the capture substream is free, and
`/dev/snd/pcmC1D0c` is already mode 0666 from the arm's udev rule. So a chirp played from Android
and recorded on the host gives a true acoustic round trip, against which the accounting above can
be checked. Not done yet.

### Removing PipeWire entirely: an upstream bug blocks it, and so does our own package

Asked 2026-10-04. "Remove PipeWire" turns out to be three different changes with very different
costs, and the interesting one is blocked by a Waydroid bug that `--audio-backend none` would have
to fix anyway.

**Level 1 — out of the audio path. Already done.** The ALSA arm is exactly this: card 1's
PipeWire profile is Off, Android holds `hw:1,0` exclusively, and `pipewire-pulse` measures
**0.00% of a core**. Nothing PipeWire does can reach the device — one substream per PCM means any
other opener gets `EBUSY`. If the goal is "PipeWire can never touch my audio hardware", it is
already true and nothing further is needed.

**Level 2 — stop the daemons. Cheap, reversible, and it breaks Android's startup.** Waydroid
bind-mounts the PulseAudio socket into the container **unconditionally and non-optionally**.
From `tools/helpers/lxc.py`:

```python
# generate_session_lxc_config's inner make_entry -- note the default options
def make_entry(src, dist=None, mnt_type="none", options="rbind,create=file 0 0"):
    if dist is None and (not os.path.exists(src) or ...):   # <-- skipped when dist is given
        return False
    return add_node_entry(nodes, src, dist, mnt_type, options, check=False)
...
pulse_host_socket = os.path.join(session["pulse_runtime_path"], "native")
make_entry(pulse_host_socket, pulse_container_socket[1:])   # dist IS given; return unchecked
```

and

```python
def add_node_entry(nodes, src, dist, mnt_type, options, check):
    if check and not os.path.exists(src):
        return False        # check is False here, so this never fires
    ...
    nodes.append(entry)     # the entry is appended whether the source exists or not
```

Three guards and **none of them apply**: the existence test in `make_entry` is bypassed because
the pulse call passes `dist`; `add_node_entry`'s test is bypassed by `check=False`; and the return
value is discarded, unlike the Wayland socket and userdata entries either side of it, which both
`raise OSError`. The result is written every session start:

```
lxc.mount.entry = /run/user/1000/pulse/native run/xdg/pulse/native none rbind,create=file 0 0
```

No `optional`. `create=file` creates the *destination*, not the source. So with no
`pipewire-pulse` there is no `/run/user/1000/pulse/native`, LXC fails a mandatory mount, and the
container does not start — and `config_session` is regenerated on every session start, so editing
it out does not persist. **Worth contrasting with `generate_nodes_lxc_config`, whose `make_entry`
defaults to `bind,create=file,optional 0 0` with `check=True`**: the device nodes are both checked
*and* optional, the session mounts are neither. That asymmetry is the bug, and it is why the
hand-added `/dev/snd` entry in `config_nodes` is safe while this one is not.

Two ways round it, neither tested:

| | |
|---|---|
| a placeholder file | an empty regular file at `/run/user/1000/pulse/native` satisfies the rbind — bind-mounting a regular file is legal, and nothing opens it any more because `pcm.!pulse` no longer resolves to the pulse plugin. `/run/user/1000` is logind's tmpfs, so it needs recreating per session; `~/.config/user-tmpfiles.d/` is the declarative place (`d %t/pulse` + `f %t/pulse/native`), since the cage session is launched by SDDM and is not a systemd user unit to order against |
| patch `lxc.py:204` | add `optional` to the options, or skip the entry when the socket is absent. This *is* the `--audio-backend none` branch this document already scopes, so it belongs upstream rather than as a local patch that a package upgrade will revert |

**Level 3 — remove the packages. Blocked, by this project's own work.** Measured:

```
$ rpm-ostree override remove pipewire --dry-run
error: Could not depsolve transaction; 1 problem detected:
 Problem: package waydroid-ext-pwd-1.3.0-1.noarch from @commandline requires pipewire,
          but none of the providers can be installed
```

`waydroid-ext-pwd` is [docs/56](56-pipewire-control.md)'s Patchbay backend. So PipeWire cannot be
removed without first removing our own package, and PipeWire is in the Sericea base image anyway,
making this an `rpm-ostree override remove` plus a reboot — on a machine that needs a LUKS
passphrase and a manual `sshd` start at the console afterwards ([docs/02](02-ssh-access.md)).

**What it would actually cost, and what it would save.** The saving is the whole point and it is
small: `pipewire` 9.6 MB RSS + `pipewire-pulse` 9.1 MB + `wireplumber` 23.8 MB = **~42 MB of a
7.8 GB machine**, and ~0.03% of a core, because the ALSA arm already took PipeWire out of the
path. Against that:

- **[docs/56](56-pipewire-control.md) dies entirely** — `waydroid-pwd`, the Patchbay app, the
  whole control plane. It is active right now.
- **No Bluetooth audio anywhere on the box.** WirePlumber's `bluez5` monitor holds BlueZ's media
  endpoint and bluez-alsa is not packaged for Fedora (see the Bluetooth section).
- **The `eq6` filter-chain goes**, and any future host-side audio with it.
- **Android's camera is NOT affected** — worth stating, because `wpctl` lists the webcam and that
  invites the opposite conclusion. Waydroid's camera HAL opens `/dev/video0` directly; PipeWire
  only enumerates it. Host-side camera consumers that go through PipeWire would break.

**Conclusion: level 1 is the configuration worth having, and it is the one already in place.**
Level 2 buys 42 MB for a startup landmine and the loss of docs/56. Level 3 is blocked. The useful
output of this question is the bug: **`generate_session_lxc_config` should pass `optional` on the
pulse mount, or skip it when the socket is absent** — one line, it is a prerequisite for
`--audio-backend none`, and it belongs in [docs/57](57-upstream-queue.md).

### Weaving stock AOSP back in: two of three ingredients landed today

Asked 2026-10-04: *does stock AOSP support this, and can the stock pieces just be woven back
in?* The answer splits by device, and for USB it is better than the earlier scoping thought —
because building the ALSA arm satisfied two of the three prerequisites as a side effect.

**For the built-in PCI card there is nothing stock to weave — confirmed by measuring the stub.**
The question "does AOSP support PCI sound cards" splits across three layers, and only the middle
one is missing:

| layer | state |
|---|---|
| kernel / ALSA | **complete, and in use right now.** Android's kernel is Linux; card 1 is `snd_hda_intel` + `snd_hda_codec_alc269`/`realtek` at PCI `0000:00:1b.0`, exposed as `/dev/snd/pcmC1D0p`. Nothing AOSP-specific is involved |
| AOSP HAL | **no generic one exists.** All four audio HALs in the image were measured, below |
| AOSP discovery / routing | **USB only.** There is a `UsbAlsaManager` and no PCI equivalent; the policy XML's attached devices are abstract (`Speaker`, `Wired Headset`, `Aux Digital`) and carry no card numbers |

Every audio HAL in the image, and what it actually is:

| module | size | links | verdict |
|---|---|---|---|
| `audio.primary.default.so` | 10 KB | `libc`, `libc++`, `libdl`, `liblog`, `libm` — **no audio library at all** | AOSP's **stub** (`Default audio HW HAL`); accepts writes and discards them |
| `audio.primary.waydroid.so` | 18 KB | `libasound.so` | Waydroid's — the one repointed at `hw:1,0` |
| `audio.usb.default.so` | 29 KB | `libtinyalsa.so`, `libalsautils.so` | real, generic by card/device, discovered only via USB |
| `audio.r_submix.default.so` | 26 KB | `libnbaio_mono`, `libmedia_helper` — no PCM | in-memory pipe for cast/record, not hardware |

So the honest framing is the reverse of the question: **what was built today already *is* the
stock arrangement.** Waydroid's HAL pointed at `hw:` is a direct kernel ALSA client issuing the
same ioctls tinyalsa would, one fd on `/dev/snd/pcmC1D0p`, no sound server anywhere. The stock
generic HAL would be a downgrade to silence.

**But there is a stock component genuinely worth weaving in: `libalsautils.so`.** This is AOSP's
`alsa_device_profile` / `alsa_device_proxy` — the dynamic profile reader that gives the USB path
its freedom from the policy XML's static profile. Measured, its strings are **card/device
addressed**, not USB-specific: `card:%d, device:%d - %s`. The USB flavour is naming and one
property (`No USB Profile`, `ro.audio.usb.period_us`), not mechanism. It ships in both ABIs
already.

That reframes "rewrite `audio_hw.c`" — [the roadmap's step 2](#the-latency-budget-and-why-native-pipewire-is-the-wrong-axis)
— as something smaller than it looked: a primary HAL built on `libtinyalsa` + `libalsautils`,
both already in the image, pointed at a card number, inherits AOSP's own profile negotiation
instead of hardcoding 48 kHz / 16-bit / stereo. On this card that would expose the full
44.1-192 kHz, S16/S32 range the hardware advertises. It is still an NDK build of a vendor `.so`
for both ABIs — the [docs/08](08-camera-fixed.md) pattern — but it is assembling stock parts
rather than writing a HAL from scratch.

**For a USB audio interface, stock AOSP has the whole thing, and it is already in the image.**
Measured:

| ingredient | state |
|---|---|
| `audio.usb.default.so` | present, **both ABIs**, links `libtinyalsa.so` + `libalsautils.so` |
| `libtinyalsa.so` | present in `/system/lib`, `/system/lib64` and the VNDK apex |
| `usb_audio_policy_configuration.xml` | `xi:include`d at line 90 of `audio_policy_configuration.xml` |
| its mixPorts | `<mixPort name="usb_device output" role="source"/>` — **self-closing, no static profile**, i.e. AOSP's dynamic-profile path: rate, format and channel count come from the hardware at attach time |
| `android.hardware.usb.host` | declared, and `pm list features` reports it |
| `UsbManager` + its ALSA manager | live — `dumpsys usb` shows `alsa_manager={ cards_parser=-1 }` |
| **`/dev/snd` in the container** | **done today** — all 11 nodes visible. `UsbAlsaDevice` reads `/dev/snd/pcmC%dD%d` directly |
| **`/proc/asound` in the container** | **already true** — `cards`, `card0`, `card1`, `pcm` all visible. `UsbAlsaManager`'s cards parser needs exactly this to map a USB device to a card number |
| **node permissions** | **done today**, though the udev rule is scoped to card 1 and would need widening to a hotplugged card |
| **the attach event** | **MISSING, and it is the only thing left** |

So [the DAW ceiling section](#the-daw-ceiling--the-architecture-is-not-the-limit-the-hal-is) listed
three remaining ingredients — `/dev/snd`, node permissions, and an attach event — and **two of
them are now satisfied.**

**What the missing one needs.** `dumpsys usb` reports `host_manager={ num_connects=0 }` and
`alsa_manager={ cards_parser=-1 }`: `UsbHostManager` has never seen a device and the cards parser
has never run. The reason is measured and simple — **`/dev/bus/usb` does not exist inside the
container**, Waydroid has no mount entry for it in any config file, and `lxc.py` never mentions
`usb` at all. AOSP's `UsbHostManager` drives libusbhost, which inotify-watches `/dev/bus/usb`; a
bind mount shares the underlying inode, so inotify events should propagate. That makes this
plausibly **one more mount entry**, in the same place the `/dev/snd` one went.

Worth knowing before trying: the host's `/dev/bus/usb/*/*` nodes are `crw-rw-r--` root:root with
**no udev ACL**, so uid 1000 gets read but not write. Read is likely enough for enumeration and
descriptor parsing, because **the audio itself never goes through usbfs** — it flows through
`/dev/snd/pcmC*D*` via the kernel's `snd-usb-audio` driver, which the container already has.
Untested.

**Two honest limits on how far this gets.**

**It does not deliver AAudio's low-latency path.** Checked directly: `audio.usb.default.so`
contains **zero `mmap` strings**, so it does not implement `create_mmap_buffer` either. The stock
USB route buys multichannel and high sample rates by escaping the policy XML's static profile; it
does not buy MMAP/EXCLUSIVE, which still needs HAL work on whichever HAL is in use.

**And it does not fix latency**, because [the latency accounting](#the-latency-accounting-2026-10-04--and-the-85-ms-figure-is-wrong-for-this-image)
showed the dominant terms are the app's own `AudioTrack` buffer and AudioFlinger's mixer — neither
of which changes with the device or the HAL.

**None of it can be verified today: no USB audio interface is attached**, and `bluetoothctl` aside,
the machine has never had one during this work. Everything above is image and framework state, not
a working path.

**One clearly-labelled speculation, because it is cheap to test later.**
`audio.usb.default.so` is addressed by *card and device numbers*, not by anything USB-specific —
its error strings are `failed to open device(card: %d device: %d)`, `failed to parse card and
device`, and `address card:%d device:%d doesn't match existing profile`. That is a generic tinyalsa
HAL with a dynamic profile reader. So pointing it at the **built-in** card is conceivable, and
would bring dynamic profiles — up to the 192 kHz / S32_LE the ALC3227 advertises — to hardware the
primary HAL caps at 48 kHz / 16-bit. What gates it is the policy XML, which routes the
`usb_device` mixPorts only to USB device ports. Untested, and not obviously worth it against
simply rewriting the primary HAL's constants.

### Where the ~100 ms actually comes from: AudioFlinger's normal mixer, and a one-mixPort policy

Asked 2026-10-04, after the A/B showed the backend does not matter: *if it is not PipeWire and not
Waydroid's customisations, what is it?* Traced to four terms, every one measured, and a single
architectural cause.

| term | frames | ms | why it is that size |
|---|---|---|---|
| app's `AudioTrack` buffer | 2048 floor (VLC took 8208) | **42.7** floor (VLC: 171) | Android requires a normal track to be at least 2x the mixer's sink buffer |
| AudioFlinger normal mixer | 1024 | **21.3** | `Normal frame count` == `HAL frame count`, measured identical |
| HAL -> card | (same buffer) | — | the HAL hands AudioFlinger one 1024-frame buffer per write |
| card, actually queued | 896 | **18.7** | mean of 12 `delay` samples |
| **floor for a minimal app** | **~3968** | **~83** | |

**The architectural cause is that there is no low-latency path to ask for.** Two measurements say
so:

```
$ dumpsys media.audio_flinger | grep -i fast
  Fast track availMask=0xfe
  No FastMixer                       <-- there is no fast mixer thread at all
```

```
$ grep 'mixPort name' /vendor/etc/audio_policy_configuration.xml
  <mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY">
  <mixPort name="primary input" role="sink">
```

**One output mixPort, carrying only `AUDIO_OUTPUT_FLAG_PRIMARY`.** No `FAST`, no `DEEP_BUFFER`, no
`DIRECT`. On an ordinary phone a latency-sensitive app requests `AUDIO_OUTPUT_FLAG_FAST` and
AudioFlinger's FastMixer serves it at 96-256 frames — 2-5 ms — bypassing the normal mixer
entirely. Here there is nothing to request, so **every** track lands on the 1024-frame normal
mixer, including an AAudio `LOW_LATENCY` request.

`Fast track availMask=0xfe` is a trap worth naming: it reads as "seven fast-track slots free" and
means nothing while `No FastMixer` holds.

Corroborating this, `audio.deep_buffer.media=true` is set but there is **no `DEEP_BUFFER`
mixPort**, which is exactly why logcat carries
`createTrack_l(): mismatch between requested flags (00000008) and output flags (00000002)` —
`0x8` is `DEEP_BUFFER` asked for, `0x2` is `PRIMARY` granted. The property requests a path the
policy does not declare.

**So the ~100 ms is Android's own normal-mixer architecture, and the A/B's result follows from it
rather than being a surprise.** Removing PipeWire entirely moved nothing because PipeWire was
never a large term: the measurable downstream of the two arms differs by about a millisecond.

**What would actually move it, in order of leverage:**

1. **A `FAST` mixPort in the policy XML.** This is the real lever and it is an overlay file, the
   same class of change as the `asound.conf` that built the ALSA arm. It enables the FastMixer and
   gives apps that ask a 96-256 frame path.
2. **Shrinking the HAL's period constants — and this needs care, because the answer differs for
   the two mixers.** For the **normal** mixer it is probably not a lever: AudioFlinger is believed
   to clamp its normal sink buffer to roughly 20-24 ms regardless of the HAL, so dropping the HAL
   to 256 frames would see the normal mixer coalesce back up rather than follow it down. For the
   **fast** mixer it is *the* lever: the FastMixer's period IS the HAL's reported buffer, with no
   such clamp, so a fast track behind a 1024-frame HAL buffer still waits 21.3 ms and is not
   low-latency at all.

   **So items 1 and 2 are complementary and neither works alone.** A FAST mixPort by itself
   removes the app-buffer floor and the normal mixer (~64 ms of the ~83 ms) but leaves the HAL's
   21.3 ms plus the card's 18.7 ms, landing around 40 ms. A smaller HAL buffer by itself is
   absorbed by the clamp. Together they reach single-digit milliseconds.

   **SETTLED 2026-10-05, and the answer is not a clamp — see "The FastMixer does not exist"
   below.** There is no clamp acting here: the scaling runs the other way, and the two equal
   numbers are what you get when it declines to act. The consequence is sharper than a clamp
   would have been — with `HAL frame count == Normal frame count`, AudioFlinger builds **no
   FastMixer at all**, so item 1 cannot work alone and item 2 is not merely complementary to it
   but strictly prior. The ordering below is corrected accordingly.

   **Measured, and it makes the experiment self-diagnosing:** `libaudioflinger.so` carries
   `AUDIO_OUTPUT_FLAG_FAST denied: sharedBuffer=%p frameCount=%zu mFrameCount=%zu ... hasFastMixer=%d tid=%d fastTrackAvailMask=%#x`.
   So the moment a FAST mixPort exists, that single log line reports whether a FastMixer was
   created and what buffer it got. No instrument needs building for it.

   Also measured: the FastMixer is **fully compiled in** — `FastMixer thread %p tid=%d`,
   `FastMixerState`, `sMaxFastTracks`, `FastMixerDumpState` are all present — so this is a
   configuration change, not a framework rebuild. `libaaudio.so`, `libaaudio_internal.so` and
   `libaaudioservice.so` all ship. And the primary mixPort's existing profile, 48 kHz /
   `PCM_16_BIT` / stereo, is already exactly what a fast track requires, so adding the flag
   does not require changing the profile.
3. **`create_mmap_buffer` in the HAL**, for AAudio EXCLUSIVE. Neither HAL in the image has any
   `mmap` symbol, so this is new code either way, and it is the only route below the FastMixer.

None of the three involves PipeWire, the pulse plugin, or the choice of backend — but the
**substrate** does matter once the target is single-digit milliseconds, and the honest balance has
one point on each side:

- **Pure ALSA is the only substrate for the deepest tier.** AAudio EXCLUSIVE needs
  `create_mmap_buffer`, which hands an app a ring buffer the *hardware* DMAs from. No socket
  transport can produce that, so it requires `hw:` opened directly. Neither HAL implements it
  today, so it is new code either way — but only one substrate can host it.
- **Pure ALSA's floor is readable; the pulse path's is not.** `pactl` reports the Waydroid
  stream's `Buffer Latency` and `Sink Latency` as **0 usec**, so the PA path's buffering cannot be
  measured from either end. Targeting 5 ms behind an unmeasurable buffer is not an engineering
  position.
- **Against pure ALSA, and measured:** the pulse arm had *tighter* write jitter — std **0.145 ms**
  versus ALSA's **0.35-0.43 ms** — because `pipewire-pulse`'s `data-loop.0` runs `SCHED_RR`
  priority 20 behind 682.7 ms of card buffer. That safety net is precisely what a low-latency
  configuration gives up, so it does not survive the change; but it does mean the ALSA substrate
  starts from worse timing and must earn it back. The known fix is the one the container already
  permits: the HAL's writer is `SCHED_OTHER` nice -19 while `Max realtime priority` is 10.
  Untested.

So the low-latency sequence is: **a smaller HAL buffer first, then the FAST mixPort, then
`SCHED_FIFO` on the writer thread, on the direct ALSA substrate.** Both of the first two are
overlay files — and the HAL change turned out not to need the NDK rebuild this paragraph
assumed, because the number is a single immediate in one instruction. See below.

### What direct ALSA gives up

All of this is measured in the built arm, not predicted:

- **The host loses the card completely.** Not a concession that can be designed
  around: one substream per PCM, so handing it over is the only form sharing takes.
  The host had no audio at all for the duration.
- **Android disappears from the PipeWire graph.** `pw-top` shows no Waydroid node and
  `pactl list sink-inputs` shows no Waydroid sink-input. So: no host-side per-app
  volume, nothing for [docs/56](56-pipewire-control.md)'s patchbay to route, and no
  path to a Bluetooth sink at all — Android's audio only ever reached a headset
  because `pipewire-pulse` happened to route it there, and that route is gone.
- **The card's analog gain has to be set host-side, and this bites immediately.**
  `audio.primary.waydroid.so` has **no `snd_ctl_*` and no `snd_mixer_*` symbols**, so
  nothing in Android can touch the card's mixer. PipeWire left `Master` at 64%
  (-23.25 dB) when it released the card, and the first listening test with Android's
  own volume at 4 of 15 reported **"nothing at all"** — a fully working path, provably
  running, that was simply 69 dB down. The scoping anticipated this for UCM on a SOF
  codec; it is true for plain gain on an HDA codec too.
- **Nothing falls back.** If anything takes the PCM between the probe and the HAL's
  open, `PCM_OPEN_RETRIES 100 x 20 ms` spins for two seconds and Android is silent for
  the life of the container.

### What the card can actually do, which is the DAW answer

With PipeWire's profile set to Off and before Android opened it, `aplay
--dump-hw-params -D hw:1,0` reports the hardware's real range:

```
ACCESS:      MMAP_INTERLEAVED RW_INTERLEAVED
FORMAT:      S16_LE S32_LE
RATE:        [44100 192000]
CHANNELS:    2
PERIOD_SIZE: [16 524288]
PERIODS:     [2 32]
BUFFER_SIZE: [32 1048576]
```

**192 kHz, 32-bit, periods down to 16 frames — 0.33 ms — and MMAP is available.** The
floor this card imposes is 2 x 16 frames = **0.67 ms**. What the stack delivers is
48 kHz / 16-bit / stereo at 21.3 ms of card buffer behind a HAL that reports 85 ms.
So the architecture is nowhere near the limit, exactly as the scoping argued — and now
the gap is measured rather than reasoned: three orders of magnitude of period size
sitting unused because `audio_hw.c` hardcodes its constants and the policy XML offers
one profile. It is also only two channels, so this particular card is not the
multichannel story; that remains `audio.usb.default.so` and a real interface.

**`--pcm plug` versus `--pcm hw` turned out not to be a question.** The arm was built
with `type plug`, and the card nonetheless ran `S16_LE` at 48000 with 2 channels —
i.e. precisely the HAL's request, so `plug` inserted no conversion at all — and the
capability dump above confirms the card takes that natively. `type hw` would be
bit-identical and was not worth a second session restart to prove.

### Five corrections to the scoping above

**1. "Audio has never been tested on this machine, including whether it works at all"
was already stale when written.** It works, and it worked before any of this: a
listener confirmed Android audio through the host graph during
[docs/56](56-pipewire-control.md)'s quantum work, and `bin/pw-audio-diag.sh` exists
because the owner had already heard it sound wrong. Both arms were heard today.

**2. SELinux is a non-issue, and the probe this document proposed would have killed
the goal on a false negative.** The suggested first command asks whether
`waydroid_t` may open `sound_device_t`. It may not — and it may not open
`v4l_device_t` either, while the camera demonstrably works. `waydroid_t` is the wrong
domain. The container's audio process runs as **`container_runtime_t`**, which is
allowed `open`, `read`, `write`, `ioctl` and `map` on `sound_device_t`. And Android's
own SELinux inside this image reports **`Disabled`**, so there is no second gate
either. The corrected probe is in the "First commands" block below.

**3. The process that opens the PCM is not `audioserver`, and the uid in this document
is the wrong one.** The holder of `/dev/snd/pcmC1D0p` is
`/vendor/bin/hw/android.hardware.audio.service`, running as **uid 1000 (`AID_SYSTEM`)
with gid 1041 (`AID_AUDIO`)**. `audioserver` is a different process at uid 1041 and
never touches the node. So "any availability check has to ask about uid 1041" is aimed
one process to the left, and an ACL granting uid 1041 would have granted access to
something that does not want it.

There is a consequence worth having. The opener's uid is **1000**, and the host's
session user is also uid 1000 — so udev's own `uaccess` ACL, which grants
`user:jmelanso:rw-` on all of `/dev/snd` while that user holds the active seat,
*already* grants the Android audio HAL everything it needs. On a single-user box where
the kiosk user is uid 1000 the permission problem may require no new rule at all. That
is a coincidence of uid numbering and not a design, so the durable fix is still a rule
— but it is worth knowing before writing one.

**4. `setfacl` is not a usable mechanism here, and a udev rule is not merely "the
durable form" — it is the only one that survives.** This was built with
`setfacl -m u:1041:rw` first. udev re-applies its `uaccess` ACL to `/dev/snd/*`
whenever the active seat session changes, and it **rewrites the whole ACL rather than
merging**: the added entry was gone within seconds of the first session restart,
replaced by `user:sddm:rw-` when the machine fell back to the greeter. The restart that
applies the arm is the same event that destroys the ACL. `bin/alsa-arm.sh` now installs
`/etc/udev/rules.d/99-waydroid-alsa-arm.rules` with `MODE="0666"` scoped to the one
card's nodes.

**5. `SCHED_FIFO` is available inside the container.** This document listed as
hypothesis "whether the container can obtain the `SCHED_FIFO`/`RLIMIT_RTPRIO` an
Android low-latency thread wants, given the `RLIMIT_NICE` precedent in
[docs/40](40-binder-nice.md)". Measured: the audio HAL service has **`Max realtime
priority 10`**, so it can. It runs `SCHED_OTHER` at nice -19 anyway, which is the
measured cause of finding 3 above. The limit is not the obstacle; the HAL is.

### Two operational traps, both paid for

**`systemctl restart waydroid-container` is the wrong lever and it strands the
machine.** The overlay `asound.conf` and the `config_nodes` mount entry are read by
`mount_rootfs()` and by LXC respectively, and both run at **session** start, not
container start. Restarting `waydroid-container.service` ended the cage session after
282499 s, left the rootfs unmounted, and so applied neither change while reporting
success — and under cage ([docs/25](25-waydroid-in-cage.md)) there is no autologin, so
recovering it needed someone at the keyboard. `bin/alsa-arm.sh` deliberately stops
short of restarting anything and prints instructions instead; `alsa-arm.sh verify` is
the verb that says whether the arm took.

**A listening test needs a signal longer than the measurement.** The first tone was
300 s, which outlasts one instrument run but not a run plus a question to a human. It
ran out mid-test, the card read `closed`, and the reported symptom was "nothing at
all" for an arm that was not playing. `bin/audio-tone.sh` now generates 1200 s, and
does not relaunch on a timer because each relaunch puts an audible gap in the tone
that a listener would reasonably report as a dropout.

**Android's `stat` goes stale when a file is replaced under the live mount, and it
stops playback early while every other signal says the file is fine.** Lengthening the
tone the obvious way — `rm` the old `abtone.wav` on the host, write a 1200 s file to the
same path — produced a disagreement that took a round of investigation to see:

| | |
|---|---|
| host `stat` | 230400044 bytes, mtime 22:59 — the new file |
| Android `ls -l` on the same path | **57600044 bytes, mtime 22:22 — the old file** |
| `od` of the first 48 bytes *through Android* | the **new** header, `data` chunk 230400000 |

So the container's attribute cache for that path was stale while its reads were not.
VLC bounds a WAV stream by `st_size`, took the cached 57600044, and stopped at
**exactly 300.0 s — 14400000 frames delivered** — with a clean `Program doesn't contain
anymore ES` end-of-stream on a file four times that long. During a load A/B that
presents as *playback dying under load*, which is precisely the failure the test is
looking for, and it is not that at all. The `recovered` arm of the first run was lost to
it.

This is the same class of mistake as editing an overlayfs lowerdir while it is mounted:
**do not reuse a path for new content under a live container mount.** The fix in
`bin/audio-tone.sh` is to put the duration in the filename (`abtone-<DUR>s.wav`), so a
regenerated tone is always a path the container has never stat'd, plus a `play`-time
assertion that compares **Android's** `stat -c %s` against the expected byte count
rather than the host's — because when the two disagree it is the container's number that
decides where playback ends.

### Where this leaves the roadmap

The four-step ordering in "The latency budget" survives, with step 2 now sharply
better justified and one term re-weighted:

- **The "85 ms HAL buffer" does not exist on this image** — it is 21.3 ms, measured three ways
  (see the latency accounting above). What dominates instead is the app's own `AudioTrack` buffer
  plus AudioFlinger's mixer, and no backend choice touches either. The A/B's point survives and
  sharpens: removing every hop between the HAL and the DAC changed nothing an app can observe.
- **The pulse hop's cost is 5.95% of a core**, which is a better argument for step 2
  than latency is — and after the accounting above, latency is barely an argument at all: the
  measurable downstream latency of the two arms is the same to within a millisecond.
- **Step 4 — direct ALSA, exclusive — is reachable today**, in four pieces, none of
  which needs a rebuild: an overlay file, a mount entry, a udev rule, and handing the
  card over. It is exactly as cheap as this document predicted.
- **But step 4 without step 2 is a downgrade in timing**, because the HAL's writer is
  not realtime. The correct order is: fix the HAL's buffering *and* ask for
  `SCHED_FIFO` (the rlimit allows it), and only then point it at a card.
- **`pactl` cannot see the pulse hop's latency**: the Waydroid sink-input reports
  `Buffer Latency: 0 usec` and `Sink Latency: 0 usec`. So the PA protocol's own
  latency query returns nothing useful here, which means that even a HAL that asked
  would not learn its downstream latency. Combined with timestamp errors at 100% of
  writes in both arms, Android has no path to a true presentation time on this image
  at all — and that is a HAL omission, not a transport one. Direct ALSA does not fix
  it.

One thing the scoping did not know about the host graph: the default sink is a
**six-band filter-chain** (`effect_input.eq6`, all six bands at 0.0 dB), so the pulse
arm carries Android's audio through two extra graph nodes and twelve biquads per
channel before the card. Flat, so transparent in response — but it is a hop the
latency budget above does not list, and it is part of the 2.25% that `pipewire` spends.

## The FastMixer does not exist, and the HAL's buffer is why — 2026-10-05

Goal 5's direction is now settled by decision, not just by measurement: **support ALSA.** The
deciding argument was the one in the balance above — AAudio EXCLUSIVE needs `create_mmap_buffer`,
`create_mmap_buffer` needs a `hw:` device opened directly, and no socket transport can hand an
app a ring buffer the hardware DMAs from. Everything below is on that substrate.

### The finding

`dumpsys media.audio_flinger`, with the ALSA arm live:

```
Output thread 0x..., name AudioOut_D, tid 229, type 0 (MIXER):
  Sample rate: 48000 Hz
  HAL frame count: 1024
  Normal frame count: 1024
  ...
  No FastMixer
```

**`No FastMixer`.** Not "a FastMixer that denies fast tracks" — none is constructed. That one line
invalidates the ordering this document carried until today, in which a `FAST` mixPort was step one.

AudioFlinger decides whether a `MixerThread` gets a FastMixer from the HAL's own buffer size,
before any track or any policy flag is considered:

```c
initFastMixer = (mFrameCount < mNormalFrameCount);        /* kUseFastMixer == FastMixer_Static */
```

and `mNormalFrameCount` is the HAL's frame count scaled *up* only as far as it takes to reach
`kMinNormalSinkBufferSizeMs` — 20 ms, which is 960 frames at 48 kHz:

```c
multiplier = 960.0 / mFrameCount;                 /* 960 / 1024 = 0.9375 */
if (multiplier <= 1.0) multiplier = 1.0;          /* so: 1.0 */
mNormalFrameCount = multiplier * mFrameCount;     /* 1.0 * 1024 = 1024 */
```

That arithmetic reproduces **both** observed numbers exactly, which is the evidence that this is
the live mechanism and not a plausible story: 1024 frames is 21.3 ms, already inside the 20–24 ms
window the normal sink wants, so the scaling declines to act, `mNormalFrameCount` lands equal to
`mFrameCount`, and `initFastMixer` is false.

So the earlier framing — "AudioFlinger clamps the normal sink to ~20–24 ms, so shrinking the HAL
period is less of a lever than you'd think" — had it backwards twice. There is no clamp on the
HAL buffer; the scaling only ever enlarges the *normal mixer's* buffer, never shrinks the HAL's.
And the HAL buffer is not a weak lever but **the** lever: it is the gate on the FastMixer's
existence. A `FAST` mixPort without it is denied with `hasFastMixer=0`, which is exactly what
`libaudioflinger.so`'s own `AUDIO_OUTPUT_FLAG_FAST denied:` line reports.

### The HAL, disassembled

The 1024 is a compiled-in constant, and finding it took one correction worth recording.

**Trap: the loaded HAL is the 32-bit build.** `/vendor/bin/hw/android.hardware.audio.service` is
i686 on this image, so its `/proc/<pid>/maps` shows `/vendor/lib/hw/audio.primary.waydroid.so` and
`/vendor/lib/libasound.so` — **not** the `lib64` pair. The first pass of this analysis was done
against `lib64/hw/audio.primary.waydroid.so`, which is present, loadable and never loaded.
Patching it would have changed nothing and looked like a failed experiment. Check `maps`, not the
directory listing.

`get_buffer_size()` is a standalone function at `0x31f0` in the 32-bit build, confirmed installed
at `audio_stream` vtable slot `0x8` (`lea -0x2710(%ebx),%ecx` with `%ebx == 0x5900`, then
`mov %ecx,0x8(%esi)`). It calls slot `0x10` (`get_format`), switches through a six-entry jump
table at `0x9c0`, and multiplies by `popcnt(get_channels())`:

| format | bytes/channel | stereo frames |
|---|---|---|
| `PCM_16_BIT` | `0x800` | **1024** |
| `PCM_8_BIT` | `0x400` | 1024 |
| `PCM_32_BIT`, `PCM_8_24_BIT`, `PCM_FLOAT` | `0x1000` | 1024 |
| `PCM_24_BIT_PACKED` | `0xc00` | 1024 |

**1024 frames, hardcoded for every format.** `0x800 x 2ch = 4096 bytes / 4 = 1024 frames`, which
is the `HAL frame count` in the dump.

There is no knob. The only property this HAL reads at all is `waydroid.pulse_runtime_path`
(`property_get` -> `setenv("PULSE_RUNTIME_PATH", ...)`); there is no config file and no
`parameters` key. Its entire alsa-lib surface is 20 symbols, and what is *absent* explains two
earlier mysteries:

- **no `snd_pcm_sw_params_*`, no `snd_pcm_delay`, no `snd_pcm_avail`** — so the HAL never asks
  alsa-lib where the card actually is. That is why per-track `Latency` reads `unavail` and why
  timestamp errors sit at 100% of writes in *both* arms. It is a HAL omission, confirmed from the
  symbol table rather than inferred.
- **no `snd_mixer_*`, no `snd_ctl_*`** — already known, now exact: card gain is unreachable from
  inside Android.
- `set_buffer_size` and `set_periods` are the **exact** setters, not `_near`, while rate is
  `set_rate_near`. So the HAL demands 1024 frames in 4 periods and will fail rather than
  negotiate — which is why `type plug` and not `type hw` is the working `asound.conf`.

### The change: one byte, and one XML attribute

Deployed 2026-10-05 as `bin/audio-fastpath.sh on --frames 256`. Two overlay files, both
**derived on the host from its own `rootfs`** by a deterministic transform — nothing third-party
enters this repo, and `on` refuses loudly if the input hash has moved rather than silently
skipping, which is the known flaw in `waydroid-overlay-sync`'s existing `derive` rows.

1. **`/vendor/lib/hw/audio.primary.waydroid.so`** — the single instruction `mov $0x800,%esi` at
   vaddr `0x324d` (file offset `0x224d`) becomes `mov $0x200,%esi`, so `get_buffer_size()` reports
   **256 frames**. The byte sequence `be 00 08 00 00` occurs **exactly once** in the file, so the
   transform keys on the sequence rather than a brittle offset, and still gates on
   `sha256 cac012cf…39cd2`. Verified locally before deploying: exactly **one byte** of the file
   differs.

   **The ALSA buffer is deliberately not touched.** The same arithmetic appears a second time,
   inlined where `snd_pcm_hw_params_set_buffer_size()` is called, and that copy keeps its own
   constants. So the card stays at the measured 1024-frame buffer of 4 x 256-frame periods, and
   the HAL now writes one period per call instead of the whole buffer, with three periods of
   slack. The fast path gets a 5.33 ms period without making the card any more fragile than the
   configuration already load-tested to 100% CPU with zero delayed writes.

   **Side effect, real and worth stating:** `get_buffer_size()` is one function shared by the
   input and output vtables, so capture's reported buffer shrinks too. Capture has never been
   exercised in this project, so nothing known regresses — but this is not a no-op.

2. **`/vendor/etc/audio_policy_configuration.xml`** — `AUDIO_OUTPUT_FLAG_FAST` added to the
   **existing** `primary output` mixPort, not declared as a new `fast output` mixPort:

   ```xml
   <mixPort name="primary output" role="source"
            flags="AUDIO_OUTPUT_FLAG_PRIMARY|AUDIO_OUTPUT_FLAG_FAST">
   ```

   A separate mixPort is what real devices ship, and it is wrong here: it makes
   AudioPolicyManager open a **second** HAL output stream, and this card cannot provide one —
   `/proc/asound/card1/pcm0p/info` reports `subdevices_count: 1`, so a second
   `snd_pcm_open("hw:1,0")` gets `-EBUSY`. Combining both flags on one mixPort keeps it to one
   stream, which is what the Android emulator's goldfish policy does. The flag is still
   *necessary* — without it the policy strips `FAST` before AudioFlinger sees the request — it is
   just not *sufficient*, which is the whole correction above.

The policy XML edit was dry-run and re-parsed: one substitution, still well-formed.

### Measured: it worked, first try

Session restarted 2026-10-05. `dumpsys media.audio_flinger`, primary output thread:

| | before | after |
|---|---|---|
| `HAL frame count` | 1024 (21.3 ms) | **256 (5.33 ms)** |
| `HAL buffer size` | 4096 bytes | **1024 bytes** |
| `Normal frame count` | 1024 | **768** |
| `AudioStreamOut` flags | `0x2 (PRIMARY)` | **`0x6 (PRIMARY\|FAST)`** |
| FastMixer | none constructed | **thread `tid=221`** |
| `Fast track availMask` | — | **`0xfe`** (7 slots free) |
| sink | the HAL | **a MonoPipe** |

```
FastMixer thread 0x7fc5a68e5cb0 tid=221  FastMixer command=COLD_IDLE writeSequence=1582
          framesWritten=202496 numTracks=1 writeErrors=0 underruns=0 overruns=3
Monopipe write pipe depth stats: ave=1142.8 std=550.139 min=768 max=3840
PipeSink frames written: 201984
```

**Both predicted numbers were exact** — 256 and 768 — which is the strongest available confirmation
that `multiplier = floor(960 / mFrameCount)` is the live arithmetic: `floor(960/256) = 3`, and
`3 x 256 = 768`. The normal mixer now writes into a MonoPipe and the FastMixer owns the HAL write,
which is what `PipeSink frames written` and the `Monopipe write pipe depth` stats report. Zero
write errors, zero underruns; the 3 overruns are from boot and standby transitions, not steady
state.

So the answer to "would this allow low-latency audio on Waydroid" is **yes, and it took one byte
plus one XML attribute** — no NDK rebuild, no framework rebuild, no AOSP tree, and no change to
the ALSA buffer the load test had already validated.

### The instrument reported this as a failure, and it was wrong

Worth recording because it nearly buried the result. `verify`'s first version tested for the
FastMixer with:

```sh
if echo "$D" | grep -q 'No FastMixer'; then   # WRONG
```

and the dump, with nothing playing, contains:

```
  No FastMixer statistics available currently
```

That is `FastMixerDumpState` saying it has no *samples* yet — it means the FastMixer **exists**.
The line for a genuinely absent FastMixer is exactly `  No FastMixer`. The substring match
conflated them and printed `FastMixer absent` on the very run that had worked, together with
advice to go and do a framework rebuild that was not needed.

Two things caught it. First, the dump's own internal contradiction: `Normal frame count: 768`
differing from `HAL frame count: 256` can **only** be produced inside the block that runs when
`kUseFastMixer` is `FastMixer_Static` or `_Dynamic`, so the reported diagnosis — "this build has
`FastMixer_Never`" — was refuted by the same dump that carried it. Second, reading the thread
section instead of trusting the grep, where `Fast track availMask=0xfe`, the MonoPipe stats and
`PipeSink frames written` are three independent signs of a live FastMixer.

`verify` now matches `^[[:space:]]*No FastMixer[[:space:]]*$` and prints all three corroborating
fields rather than a single boolean. **The lesson generalises past this script:** a negative
rendered as one boolean from one substring is worth less than the raw section, and "the counts
moved but the feature is absent" should always be checked against whether the moved counts were
themselves reachable without the feature.

### The app-visible answer: `LOW_LATENCY` is granted — `audio-probe`, 2026-10-05

Built `audio-probe/` to settle the one thing no host-side dump can: whether an **ordinary app**
is granted a fast track. Same no-Gradle toolchain and house style as `drm-probe` and `sensor-app`
(`aapt2` -> `kotlinc` -> `d8` -> `zipalign` -> `apksigner`), no permissions declared, because the
probe has to run with exactly an ordinary audio app's privileges or its answers are not about
ordinary audio apps. Three `AudioTrack`s built identically except for the performance mode; the
decisive field is `getPerformanceMode()` **read back** from the built track, since `AudioTrack`
silently downgrades a request it cannot honour.

| arm | requested | **granted** | buffer | underruns |
|---|---|---|---|---|
| `LOW_LATENCY` | `LOW_LATENCY` | **`LOW_LATENCY`** | 512 fr / 10.67 ms | **0** |
| `NONE` | `NONE` | `NONE` | 5390 fr / 112.29 ms | 0 |
| `POWER_SAVING` | `POWER_SAVING` | `NONE` (downgraded) | 8192 fr / 170.67 ms | 0 |

And the framework's own advertised numbers:

```
PROPERTY_OUTPUT_FRAMES_PER_BUFFER   256        <- was 1024
PROPERTY_OUTPUT_SAMPLE_RATE         48000
=> advertised quantum               5.33 ms
feature audio.low_latency           true
feature audio.pro                   false
getMinBufferSize                    5390 frames = 112.29 ms
```

So: **an ordinary app now gets a 10.67 ms buffer on the fast path with zero underruns, against a
112.29 ms ordinary floor** — a 10.5x reduction in the app-visible buffer. `PROPERTY_OUTPUT_FRAMES_PER_BUFFER`
tracking the patch from 1024 to 256 is the cleanest proof the change reached apps and not just
AudioFlinger's internals.

`POWER_SAVING` being downgraded to `NONE` is correct and expected: there is no `DEEP_BUFFER`
mixPort in the policy, only `PRIMARY|FAST`. It is reported because an unexplained downgrade in one
arm would otherwise undermine confidence in the granted result in another.

### The next lever: a ~116 ms latency the framework believes and cannot know

`getLatency()` — hidden API, reached by reflection, and it unexpectedly **worked**:

| arm | `getLatency()` | track buffer | implied output latency |
|---|---|---|---|
| `LOW_LATENCY` | 127 ms | 10.67 ms | **116.33 ms** |
| `NONE` | 229 ms | 112.29 ms | **116.71 ms** |
| `POWER_SAVING` | 287 ms | 170.67 ms | **116.33 ms** |

Subtract each arm's own buffer and the remainder is the **same ~116.3 ms** three times. A value
that does not vary with the track is a fixed one, and it now *dominates* the app-visible latency:
the fast path's 10.67 ms buffer sits in front of a 116 ms claim.

It is also a number the HAL cannot possibly know. There is no `snd_pcm_delay`, no `snd_pcm_avail`
and no `snd_pcm_sw_params_*` in its entire import table, so it never asks alsa-lib where the card
actually is — whatever it reports is computed or constant, not measured. The real downstream
latency was measured independently as ~18.7 ms of card buffer, so the reported figure is roughly
6x the truth.

**Not yet pinned to an instruction.** One attempt to locate it mis-identified `out_write` as
`get_latency` from a wrong vtable-slot derivation; the address is not claimed here. What is
established is the behaviour — a constant ~116.3 ms, independent of track and of the real buffer —
and that it is the same class of fix as the one that worked: one HAL constant. Whether it lives in
the HAL's `get_latency` or in AudioFlinger's own accounting is the first thing to settle.

This matters beyond a latency number: `getLatency()`, `getTimestamp()` and A/V sync all flow from
it, and `Timestamp stats` has read `err` on essentially every write in every arm from the start.

### Load-tested at 5.33 ms, and a correction to the jitter claim

`bin/alsa-load-ab.sh`, 4 spinners at nice 0, 60 s per arm, tone playing throughout:

| arm | busy | PSI | delayed | disc | writes | jit_std |
|---|---|---|---|---|---|---|
| idle | 4% | 0.3 s | 0 | 0 | 3755 | 0.0327 |
| **loaded** | **100%** | **6.1 s** | **0** | **0** | 3764 | 0.443 |
| recovered | 4% | 0.3 s | 0 | 0 | 3755 | 0.0396 |

**Zero delayed writes and zero timestamp discontinuities at 100% CPU, at a 5.33 ms period.** The
FastMixer's own counters agree: `underruns=0 writeErrors=0` across 52 s, with its mix cycle at
`mean=5.33 min=2.63 max=7.54 stddev=0.35 ms` and a CPU cost of 108 us per cycle, about 2% of a
core. Cycles do overshoot the period; the card's three spare periods absorb them.

**CORRECTION, and it retracts a comparison made earlier today.** The `jit_std` column above, and
AudioFlinger's `Hal write jitter`, **stop describing the HAL once a FastMixer exists.** When
`initFastMixer` succeeds the thread's `mNormalSink` is replaced by the MonoPipe, so the figure
measures the normal mixer writing into an in-memory pipe — not a write to the card. Proof from the
dump's own arithmetic: `Frames written / Total writes = 1420032 / 1849 = 768`, the *normal* frame
count, and the measured rate of 62.58 writes/s is `48000/768`, not `48000/256 = 187.5`.

So the reading "jitter improved 7x, from 0.35 ms to 0.052 ms" is **withdrawn** — it compared a
pipe write against a card write. The quantity changed identity under the change. What can be said:
the FastMixer's mix-cycle stddev is 0.35 ms, and zero dropouts occurred under full load. The
honest cross-configuration comparison is `audio-probe`'s app-side write cadence, which is measured
in the same place regardless of what the HAL is doing:

| arm | chunk | mean | sd | max |
|---|---|---|---|---|
| `LOW_LATENCY` | 512 | 11.111 ms | 5.289 | 73.289 |
| `NONE` | 1024 | 19.984 ms | 29.527 | 67.365 |
| `POWER_SAVING` | 1024 | 19.150 ms | 38.286 | 96.130 |

The fast arm's cadence tracks its 10.67 ms buffer with a fifth of the ordinary path's spread,
which is the app-side shape of the same result. The 73 ms outlier is a first-write artefact that
survived the one-sample discard and is worth a second look before being quoted.

## Items 1-4 worked through, 2026-10-06

### 1. The ~116 ms is `out_get_latency`, and it is three instructions

Located properly this time, by mechanically tracking `lea`/`mov` pairs across the whole
disassembly rather than eyeballing the compiler's pipelined interleaving -- which is what produced
the earlier misidentification of `out_write` as `get_latency`. The slot map it yields is
corroborated by `0x40 OUT.write -> 0x35a0`, the function already identified independently.

`audio_stream_out.get_latency` is slot `0x38` -> **`0x3570`**:

```
3579:  mov  $0x3e8000,%eax        ; 4096000 = 4096 frames x 1000
357e:  xor  %edx,%edx
3580:  divl 0xac(%ecx)            ; / sample rate (the field get_sample_rate returns)
```

`4096000 / 48000 = 85` ms, flat, for any track. That is upstream's `PLAYBACK_PERIOD_SIZE 1024 x
PERIOD_COUNT 4 = 4096 frames` -- **a buffer this card does not have.** The card runs 1024 frames.

**This reconciles a correction I made too broadly.** docs/44 originally derived "85 ms" from
upstream source; on 2026-10-04 I called that "wrong for this image: it is 21.3 ms". Both were
right about different things, and I should have said so: the HAL **reports** 85 ms while the card
**runs** 21.3 ms. The original figure was an accurate reading of what the HAL claims.

Why it dominates: AudioFlinger's `correctLatency_l` adds the MonoPipe's average fill (only when a
FastMixer exists -- measured `ave=1024.45` frames = 21.3 ms), and `AudioTrack::latency()` adds the
track's own buffer. That is the ~116 ms constant the three probe arms implied. It also sets the
**ordinary app's floor**, via `getMinFrameCount`:

```
minBufCount   = afLatency / ((1000 * afFrameCount) / afSampleRate)
minFrameCount = minBufCount * afFrameCount
```

At `afLatency` 116 ms and `afFrameCount` 256 that is `116/5.33 = 21` buffers = 5376 frames, and
`getMinBufferSize` measured **5390**. A second probe run measured **2310**, implying `afLatency`
~48 ms at that moment -- which is itself evidence for the MonoPipe term, since that is the part
that varies.

Patched by the same mechanism: `mov $0x3e8000,%eax` -> `mov $0xfa000,%eax`, i.e. dividend
`1024 x 1000`, so it reports **21 ms**. Byte sequence `b8 00 80 3e 00` occurs exactly once.
`--latency-frames` defaults to 1024, the card's real buffer. The HAL still is not *measuring*
anything and cannot -- but a correct constant beats a 4x-wrong one. **Deployed, pending a session
restart.** Falsifiable prediction: `getMinBufferSize` should fall from ~5390 frames to roughly
1800 (`afLatency` ~42 ms -> 7 buffers x 256).

### A bug in my own script, caught by my own gate

`on` derived its source from `$ROOTFS/vendor/lib/hw/...`. Once the overlay is applied,
`/var/lib/waydroid/rootfs` **is** the overlay-merged view, so the second `on` was reading back the
file the first `on` wrote and trying to patch an already-patched binary. The sha256 gate refused,
loudly, which is the entire argument for having it fail rather than skip.

Fixed by deriving from the stock image instead: `debugfs -R "dump /lib/hw/... $T"
/etc/waydroid-extra/images/vendor.img`, read without mounting -- the same mechanism
`waydroid-overlay-sync`'s `derive` rows use. vendor.img's root is `/vendor`, so in-image paths drop
the leading `vendor/`. Verified to reproduce the stock sha256 exactly. `debugfs`'s destination must
be created by root; a user-owned `mktemp` path fails with "Permission denied while opening ... for
dump_inode".

### 2. Capture is broken by a format mismatch, not by gain

Added an `AudioRecord` arm to `audio-probe` (and `RECORD_AUDIO` to its manifest -- the only
permission it declares, because capture cannot be probed without it). The input side had never been
exercised in this project, and the fastpath patch made it urgent: `get_buffer_size()` is **one
function shared by both vtables**, so shrinking it for playback shrank the reported capture buffer
too.

Capture opens and delivers data -- `INITIALIZED`, 72704 frames in 71 reads, 98% non-zero,
`getTimestamp` works (unlike playback). But the data is garbage: **peak 32767 of 32767, 0.0 dBFS**.

It is not gain, and it is not the card:

- Host-side `arecord -D hw:1,0 -f S16_LE -r 48000 -c 2` on the same card: **peak 7725 = -12.6
  dBFS**, 97.8% non-zero, with a large DC offset around 7600. The hardware path is healthy.
- The host mixer did have absurd gain -- `Capture` at **+30.00 dB** and `Internal Mic Boost` at
  **+36.00 dB**, 66 dB total -- and I reduced it to -2.25 dB / 0 dB. **It made no difference to the
  Android peak**, which is what ruled gain out. Worth leaving low regardless, and it is host state
  no Android process can reach, the HAL having no `snd_mixer_*`. Originals were `Capture=63`,
  `Internal Mic Boost=3`, `Mic Boost=0`.
- The HAL's own log says what it did: `adev_open_input_stream selects channels=2 rate=16000
  format=10`. `format=10` is `SND_PCM_FORMAT_S32_LE`; output logs `format=2`, S16_LE. The input
  defaults in `.rodata` at `0x8a0` are `ch=2, rate=0x3e80=16000, 320, periods=2`, so the HAL is
  using its own constants and ignoring the request.

So the HAL opens **S32_LE / 16 kHz / stereo** while `AudioRecord` reports **S16_LE / 48 kHz /
mono**. Android reads 32-bit samples as pairs of 16-bit ones. The arithmetic matches the
measurement: `type plug` resamples 48 k -> 16 k, so the low half of each S32 sample is non-zero
noise reaching full scale while the high half carries the real (<= 7725) signal -- giving a 32767
peak at ~98% non-zero. **The "clipping" is a misread, mine included: it is a format
misinterpretation, not a level problem.**

Fixing it means making the input config agree. Rate and channels are plain `.rodata` words at
`0x8a0` (16000 -> 48000, 2 -> 1); the origin of the format default has **not** been located, so no
patch is proposed yet. Properly it is HAL source work: `adev_open_input_stream` should honour the
requested config, or at minimum report back what it selected.

`AUDIO_INPUT_FLAG_FAST` was added to the `primary input` mixPort regardless -- it carried no flags
attribute at all, which is why capture was handed a 2880-frame (60 ms) buffer against a 640-frame
(13.3 ms) minimum. Same reasoning as the output flag: on the existing mixPort, because `pcm0c` has
one substream too. Deployed, pending the same restart, and it cannot help until the format mismatch
is fixed.

### 3. The fast path is 48 kHz only

The rate/format matrix, with `PERFORMANCE_MODE_LOW_LATENCY` requested every time:

| rate | PCM_16 | PCM_FLOAT | granted | buffer |
|---|---|---|---|---|
| 44100 | builds | builds | `NONE` | 2127 fr |
| **48000** | builds | builds | **`LOW_LATENCY`** | **512 fr** |
| 96000 | builds | builds | `NONE` | 4620 fr |
| 192000 | builds | builds | `NONE` | 9228 fr |

Every rate builds, which proves nothing -- AudioFlinger resamples to the output's rate. The real
column is *granted*: **a fast track must match the output rate exactly**, because it bypasses the
resampler, and the policy profile declares 48000 alone. So **44.1 kHz work loses the fast path
entirely** -- worth knowing, since plenty of DAW material is 44.1.

`PCM_FLOAT` **is** granted at 48 kHz, which is the useful half of this: an app can feed float to
the mixer (AudioFlinger mixes in float anyway) and still be fast. The card itself does 44.1-192 kHz
and `S32_LE`; none of that reaches an app. Raising it means advertising more rates in the policy
profile, and the primary output can only be opened at one of them -- so this is a trade, not a free
addition, and multichannel still wants a USB interface and the `/dev/bus/usb` mount.

### 4. AAudio EXCLUSIVE: five NULL vtable slots, so it is HAL source work

This is now a structural answer rather than a symbol-table one. The output stream's ops are
installed in one block, and it stops at slot `0x48`. Everything above is left NULL by `calloc`:

| slot | op | consequence |
|---|---|---|
| `0x4c` | `set_callback` | no callback-driven output |
| `0x50`-`0x5c` | `pause`/`resume`/`drain`/`flush` | no gapless, no offload |
| `0x60` | **`get_presentation_position`** | **the reason timestamps never work** |
| `0x64`/`0x68` | `start`/`stop` | required for MMAP |
| `0x6c` | **`create_mmap_buffer`** | **AAudio EXCLUSIVE impossible** |
| `0x70` | `get_mmap_position` | required for MMAP |

So AAudio MMAP/EXCLUSIVE is not a constant away, it is **five functions away** -- `start`, `stop`,
`create_mmap_buffer`, `get_mmap_position`, plus `get_presentation_position` for the timestamps that
make low latency usable. That is new HAL code against the stable `audio_hw_device_t` C ABI, which
the NDK can build (the [docs/08](08-camera-fixed.md) pattern), but it is a project, not a patch.
`get_presentation_position` alone is the highest-value of the five and does not need MMAP: it is
`snd_pcm_delay` plus a frame counter, and it would fix `getTimestamp` and A/V sync.

AAudio in SHARED mode already rides the FastMixer, so it gets today's 10.67 ms. EXCLUSIVE is what
would bypass the mixer entirely.

## PipeWire removed from the running process list, 2026-10-06

Goal, in the owner's words: "remove pipewire completely from the list of running processes, while
still retaining the same abilities." Done, with `bin/pipewire-off.sh off`. **Zero PipeWire
processes, no session restart, no greeter risk, and Waydroid's audio unaffected** -- verified with a
tone playing: card open at `S16_LE/48000/period 256/buffer 1024`, FastMixer in `MIX_WRITE`,
`writeErrors=0 underruns=0 overruns=0`, and `pgrep -x pipewire|wireplumber` returning 0.

### WirePlumber is PipeWire, and uninstalling is the wrong lever

WirePlumber is PipeWire's **session manager** -- a separate binary and package, part of the same
stack. Stopping it alone leaves `pipewire` and `filter-chain` running with nothing configuring
them, so it is not the whole job.

Uninstalling is worse than it looks. `pipewire` is a **base-image** package on Sericea, so removal
needs `rpm-ostree override remove` and a reboot; and `pipewire-libs` provides
`libpipewire-0.3.so.0`, which is required by **firefox, waybar, xdg-desktop-portal,
xdg-desktop-portal-wlr and uresourced**. Taking the library would take those with it. The initial
package-level query was misleading: `rpm -q --whatrequires pipewire` named only
`waydroid-ext-pwd`, our own package, because everything else depends on the *soname*, not the
package name.

Masking the units gets the stated goal exactly -- nothing running -- while every library stays in
place for those programs to keep linking. Five units, all of which *run* -- and
**not** `pipewire-pulse.service`, for the reason below:

```
pipewire.service  pipewire.socket
wireplumber.service  filter-chain.service  waydroid-pwd.service
```

### The upstream bug does not have to block it

docs/44 recorded Waydroid's unconditional pulse-socket mount entry as blocking PipeWire's removal.
It does block the obvious approach. `lxc.py:204`:

```python
pulse_host_socket = os.path.join(session["pulse_runtime_path"], "native")
make_entry(pulse_host_socket, pulse_container_socket[1:])
```

`generate_session_lxc_config`'s `make_entry` skips its existence check whenever `dist` is given,
then calls `add_node_entry(..., check=False)`, which appends regardless. Default options are
`rbind,create=file 0 0` -- **no `optional`**, unlike its sibling in `generate_nodes_lxc_config`.
The live entry, confirmed in `config_session`:

```
lxc.mount.entry = /run/user/1000/pulse/native run/xdg/pulse/native none rbind,create=file 0 0
```

A bind mount needs its **source** to exist. Remove whatever creates
`/run/user/1000/pulse/native` and the next session start dies on a fatal mount entry -- at the
SDDM greeter, with no autologin, needing someone at the keyboard.

**The way through is to notice who actually creates that socket.** `pipewire-pulse.socket` is a
*pure systemd socket unit* -- `ListenStream=%t/pulse/native`, `ConditionUser=!root`, and **no
`Requires=` on `pipewire.service`** -- so systemd binds it, and `pipewire-pulse.service` is only
socket-activated.

#### The near-miss: systemd will not start a socket whose triggered service is masked

The first version of this masked `pipewire-pulse.service` along with everything else, on the
reasoning that the *socket* is what matters. **That was wrong, and it took a logout to find out.**

At the next login `pipewire-pulse.socket` failed to start -- `systemctl --user start` returns
`Job failed`, and the unit sat `inactive (dead)` with its last `Listening on` entry from the
*previous* session. `/run/user/1000/pulse/native` was therefore never bound.

**The Waydroid session came up anyway, and that is the dangerous part.** A **stale** socket file
from the previous session was still present: `ctime 19:07:06` against a `/run/user/1000` whose own
ctime was `22:42`, so the runtime directory had not been cleaned on logout. The bind mount found a
source, the session started, and everything looked correct. On a real **reboot** that file would
not exist and the session would have died on a fatal mount entry, at the greeter -- the exact
failure this design was meant to prevent, deferred to whenever the machine next rebooted.

**And the verification missed it, because it tested the wrong thing.** `off` checked
`[ -e "$PULSE_SOCK" ]` -- that the *file existed* -- which a stale file satisfies perfectly. A
presence check cannot distinguish "systemd bound this" from "yesterday left this here".

Corrected on both counts:

- `pipewire-pulse.service` stays **unmasked**. It stays `inactive` regardless, because it is
  socket-activated and nothing connects -- the HAL resolves `"pulse"` through `asound.conf` to
  `hw:1,0`. Measured after the fix: socket `active`, service `inactive`, **PipeWire process count
  0**.
- `status` and `off` now test that the **socket unit is active**, and print the socket's `ctime`
  beside the session start time so a stale file reads as a warning rather than as reassurance.
  After the fix: socket `ctime=22:45:20` against a session that began at `22:44:42` -- bound this
  session, not inherited.

`off` rolls itself back if that check fails, rather than leaving the machine un-loginable.

A tmpfiles shim was the other candidate and is still rejected: betting a login against
`systemd-tmpfiles-setup.service` winning a race with an SDDM-launched session script is how the
greeter trap happens. A real socket, bound by systemd, has no race.

### Why nothing was lost here, specifically

Measured before masking, and this is what makes it safe on *this* host rather than in general:

- `wpctl status` had an **empty Audio section** -- card 1's profile is Off because Android owns it.
  The graph was carrying nothing.
- Of everything linking `libpipewire-0.3.so.0`, **none were running**: firefox 0, waybar 0,
  xdg-desktop-portal 0, xdg-desktop-portal-wlr 0, pavucontrol 0. This is a `cage` kiosk, not a Sway
  desktop.
- The only live PipeWire client was `waydroid-pwd`, our own bridge for driving the host graph from
  Android, which is pointless once the graph is gone and is masked with the rest.
- `waydroid-cage-session` never calls `systemctl` or touches PipeWire, so masking cannot make the
  session script fail. Checked, because a `set -e` script starting a masked unit would be another
  greeter trap.

What is genuinely given up: **host Bluetooth audio** (WirePlumber's `bluez5` monitor is what claims
BlueZ's media endpoint -- nothing is paired today, so nothing breaks yet), screencast via
`xdg-desktop-portal-wlr`, and waybar's volume module. On a kiosk running neither, the only real
loss is A2DP, which is what the bluez-alsa plan is for.

`bin/pipewire-off.sh on` reverses all of it immediately, with no restart.

## BlueALSA: built, installed and running, 2026-10-06

`bluealsa/build.sh` -- builds bluez-alsa **v5.0.0** on the dev box and deploys it to bigtab01.
**Installed and active, owning `org.bluealsa` on the system bus, with zero PipeWire processes.**
Not yet carrying audio: no A2DP sink is connected, which is the one remaining step and needs the
owner's headphones.

### Why BlueALSA and not Android's own Bluetooth stack

Giving the adapter to Android, so Fluoride does A2DP itself, is the obvious alternative and is
wrong here: **the host's HP Bluetooth keyboard is paired to that adapter.** Handing it over costs
the keyboard. BlueALSA keeps the adapter host-side and lets Android send PCM to it.

### It cross-builds from Debian onto Fedora, and that is deliberate

Per AGENTS.md all builds happen on the dev box. On bigtab01 a toolchain costs a layered install
**and a reboot**, and a reboot there needs someone at the console for the LUKS passphrase and to
start `sshd` by hand -- so it is much more expensive than it looks.

Built on Debian 13 (glibc **2.41**), runs on Fedora 44 (glibc **2.43**). That direction is
forward-compatible and was verified before anything was installed: `bluealsad --version` printed
`v5.0.0` on the host with all 16 shared-library dependencies resolved, none missing, for the daemon
*and* the ALSA plugin. Every library was already present -- `libasound`, `libdbus-1`,
`libglib-2.0`, `libsbc`, `libbluetooth`, and `libfdk-aac`, which is why **AAC is enabled** rather
than SBC alone.

### Four install traps on an immutable host, all paid for

1. **`/usr/local` is a symlink to `../var/usrlocal`.** `tar` will not extract directories through a
   symlink onto a read-only `/usr`: every entry failed with `Invalid cross-device link`. The staged
   paths are rewritten to `/var/usrlocal`. The binaries keep `--prefix=/usr/local`, which is
   correct at *runtime* because the symlink resolves -- only extraction needs the real path.
2. **A `./` member in the tarball makes `tar` try to `utime` and `chown` `/` itself**, which is
   read-only. Every file extracted correctly and `tar` still exited non-zero, so the installer's
   `set -e` skipped `chmod`, `restorecon` and `enable`. Fixed by archiving the top-level
   directories by name.
3. **`--sysconfdir=/etc` is required.** Upstream installs the real alsa snippet under
   `$prefix/share/alsa/alsa.conf.d` and **symlinks** it from `$sysconfdir/alsa/conf.d`. At the
   default that link lands in `/usr/local/etc`, which alsa-lib never reads. The host's
   `/usr/share/alsa/alsa.conf` includes `/etc/alsa/conf.d` (line 13), so pointing sysconfdir there
   puts the link where it is read with the target in writable `/usr/local`. The first attempt
   instead *moved* the file and deleted `share/`, shipping a dangling symlink -- caught by a guard
   added for it, which then had to be made DESTDIR-aware, since an absolute target is correct after
   extraction and only looks dangling inside a stage.
4. **`--localstatedir=/var`**, or the daemon warns `Couldn't create directory:
   /usr/local/var/lib/bluealsa` at every start.

Also: the dev box has `libtoolize` but **no `libtool`** binary, so checking for the latter failed a
build that worked. `autoreconf --install` needs the former.

### Group `audio` cannot be joined here

Upstream's D-Bus policy grants `own_prefix=org.bluealsa` to root and `send_destination` to group
**audio**. That group exists at gid 63 but is defined in the **base image's `/usr/lib/group`**,
which is read-only -- so `usermod -aG audio jmelanso` **exits 0 and changes nothing**; `id` still
reports only `jmelanso` and `wheel`. Shadowing it by editing `/etc/group` would work and is the
conventional ostree answer, but it is system-database surgery for one ACL and invisible to anyone
reading this directory.

Instead `build.sh` stages `/etc/dbus-1/system.d/org.bluealsa-local.conf` naming the user. This is
not cosmetic: **the Android side will connect as that uid.** The container has no idmap, so
Android's `AID_SYSTEM` (1000) *is* host uid 1000.

### Where it runs

| path | why |
|---|---|
| `/var/usrlocal/bin/` | binaries; `/usr/local` resolves here |
| `/var/usrlocal/lib/alsa-lib/` | the ALSA plugin |
| `/var/usrlocal/share/alsa/alsa.conf.d/` | the real `pcm.bluealsa` snippet |
| `/etc/alsa/conf.d/` | symlink to it, where alsa-lib reads |
| `/etc/dbus-1/system.d/` | upstream policy + our user drop-in |
| `/etc/systemd/system/bluealsad.service` | the unit |

Nothing under `/usr` is written and **no reboot is needed.** Upstream also installs
`/usr/share/dbus-1/interfaces/org.bluealsa.xml`; that path is read-only here and the file is only
D-Bus introspection metadata, so it is skipped deliberately.

`ExecStart=/usr/local/bin/bluealsad -p a2dp-source` -- the host sends *to* headphones, so the host
is the A2DP **source**. SELinux label comes out `bin_t`, so systemd can exec it; `--status` prints
the label precisely because executing from `/var/usrlocal` under Enforcing is where that would
fail.

The unit is deliberately **not** upstream's heavily sandboxed one (`ProtectSystem=strict`, `User=`).
That sandbox and an ostree `/var/usrlocal` binary under SELinux interact in ways not worth debugging
during a first bring-up. Upstream's version in `misc/systemd/bluealsa.service.in` is the right
target once A2DP is proven end to end.

### A2DP playback: where it stopped (SUPERSEDED -- root cause found, see below)

Headphones ("Earmuffs", `60:AB:D2:41:04:39`) paired and **connected**, BlueALSA exposes the PCM,
and the daemon owns its bus name. Playback still fails. Recording this honestly because the
negative result and its exclusions are worth more than a vague "needs more work".

**What works:** `bluetoothctl connect` succeeds; `Connected: yes`; the PCM appears at
`/org/bluealsa/hci0/dev_60_AB_D2_41_04_39/a2dpsrc/sink`; `bluealsactl info` reports a sane
configuration -- `Transport: A2DP-source`, `Mode: sink`, `Format: S16_LE`, `Channels: 2`,
`Rate: 48000 Hz`, `Available codecs: SBC AAC`, `Selected codec: AAC`, `Delay: 15.0 ms`.

**What fails:** `aplay -D bluealsa` gets past open and then
`aplay: set_params:1462: Unable to install hw params`, for the request
`S16_LE / 2ch / 48000 / PERIOD_SIZE 6000 / PERIODS 4 / BUFFER 24000`.

**Ruled out, each by measurement rather than reasoning:**

- *Format, rate, channels.* The PCM reports exactly `S16_LE / 2 / 48000`, which is what was
  offered.
- *Period and buffer limits.* Read out of the source rather than guessed:
  `PERIODS 2..1024` and `PERIOD_BYTES >= rate/100 * channels * width/8` = **1920** at 48 kHz
  stereo S16. The request satisfies both, and `--period-size=1024 --buffer-size=4096` fails
  identically.
- *Codec.* Forcing SBC with `bluealsactl codec ... SBC` changes nothing.
- *The profile string.* `str2profile()` accepts `a2dp`, which maps to
  `A2DP_SOURCE|A2DP_SINK`, and the lookup wants `BA_PCM_MODE_SINK` for playback -- matching the
  PCM exactly.
- *Bus mismatch.* `DBUS_BUS_SYSTEM` appears exactly once in the whole tree; daemon and plugin use
  the same bus.
- *SELinux.* `bluealsad` runs `unconfined_service_t` with no AVC denials recorded.
- *The malformed D-Bus policy I had shipped.* Real bug, fixed (below), **not this one** -- the
  failure is identical with valid XML.

**Two open leads.**

1. `--dump-hw-params` returns **generic unconstrained ALSA ranges** -- every format, `RATE
   [4000 4294967295]`, `CHANNELS [1 10000]`. The plugin's constraints are not visible at refine
   time. In the open path, `ba_dbus_pcm_codecs_get` failing only logs and continues, which would
   leave `bluealsa_set_hw_constraint` building its RATE and CHANNELS lists from an empty
   `codec->rates`/`codec->channels`. No "Couldn't get BlueALSA PCM codecs" error was emitted, so
   the fetch appears to succeed -- which leaves the empty-list theory unconfirmed.
2. `bluealsad` **intermittently** logs `E: Lost BlueALSA D-Bus name: org.bluealsa` and exits(1),
   around the time a client opens a PCM, which drops the A2DP transport and disconnects the
   headphones -- that is what "I can't connect to them" turned out to be. It is intermittent: one
   run survived the same sequence untouched, and once it dies the subsequent `PCM not found` is
   just fallout. Run in the foreground rather than under systemd it survived, which is suggestive
   but not conclusive.

**The next step is to make the plugin talk.** `snd_debug` is compiled out of a release build
(`src/asound/log.h` stubs it unless `DEBUG` is defined), so `BLUEALSA_LOG_LEVEL=debug` produced
nothing. Rebuilding with `--enable-debug` would make it name the failing constraint directly,
instead of inferring it. That is the cheapest decisive move and it has not been taken yet.

### Three bugs in this repo's own script, found by this

1. **A `--` inside an XML comment** in the generated `org.bluealsa-local.conf`, which is illegal
   and left dbus-broker unable to parse the policy. Third instance of this family in two days,
   after the Kotlin nested block comment and the Android manifest: **generated XML and KDoc must be
   validated, not eyeballed.** `build.sh` now parses the file before shipping it.
2. **`systemctl reload dbus || systemctl restart dbus-broker`.** The fallback severs every D-Bus
   connection on the machine -- far worse than the problem it papered over. Now reload-only, with a
   warning if it fails.
3. **`systemctl enable --now` does not restart an already-running unit.** Two reinstalls reported
   success while the *first* binary kept running -- which is why a `--localstatedir` fix appeared to
   work when the warning had simply not been re-emitted. Now `enable` + explicit `restart`. My
   earlier claim that the warning was gone "so the fix worked" was wrong for exactly this reason.

### Current state

`bluealsad` active, headphones connected, PCM present, **0 PipeWire processes**, Waydroid session
running with the fast path live. Bluetooth audio does not play. `bin/pipewire-off.sh on` restores
PipeWire and with it working host Bluetooth audio, if that trade is wanted before this is finished.

### ROOT CAUSE: a dontaudit'ed SELinux denial on BlueALSA's PCM pipe

**Found.** BlueALSA hands a client its PCM data channel as a **pipe**, passed as a Unix FD in the
reply to `org.bluealsa.PCM1.Open()`. Relaying that reply needs dbus-broker to touch the pipe, and
the base policy has no rule for it:

```
avc: denied { write } for pid=888 comm="dbus-broker" path="pipe:[9193844]" dev="pipefs"
     scontext=system_u:system_r:system_dbusd_t:s0-s0:c0.c1023
     tcontext=system_u:system_r:unconfined_service_t:s0
     tclass=fifo_file permissive=0
```

**The rule is `dontaudit`'ed upstream, so it is ENFORCED while logging nothing.** That is the whole
reason this took so long, and it is the same family as
[docs/40](40-binder-nice.md)/[docs/42](42-selinux.md) and `waydroid_backlight`: a denial against a
*domain*, invisible to `ausearch`, where being uid 0 does not help because SELinux denies the
domain and not the user.

The fix is one rule, in `artifacts/bluealsa/waydroid_bluealsa.cil`, CIL rather than `.te` for the
house reason -- `semodule` compiles CIL directly, so it needs no `selinux-policy-devel` and
therefore no layered install and no reboot:

```
(allow system_dbusd_t unconfined_service_t (fifo_file (write)))
```

#### Why it presented so badly

The symptom was `aplay: set_params:1462: Unable to install hw params`, preceded by
`bluealsa-pcm.c: Couldn't open PCM: Remote peer disconnected`. Three things made that misleading:

1. **The error names the wrong party.** "Remote peer disconnected" exists in neither bluez-alsa nor
   libdbus -- `grep -a -c` puts it in **`/usr/bin/dbus-broker` alone**. The broker drops the
   *sender's* connection over the denied fd and answers the waiting client with that message. So the
   client blames the peer, and the peer then logs `Lost BlueALSA D-Bus name` and `exit(1)` because
   GDBus reports a closed connection as a lost name.
2. **`set_params` was never the failure.** The debug build shows
   `bluealsa_set_hw_constraint: Setting constraints` succeeding; the failure is inside
   `bluealsa_hw_params` at the `Open()` call. `--dump-hw-params` returning generic unconstrained
   ranges was a *consequence* of the daemon being gone, not evidence of a constraint bug.
3. **No AVC anywhere**, including with `--audit` on in dbus-broker, because of the dontaudit.

What cracked it: `setenforce 0` made playback work **immediately and completely** under systemd,
and `semodule -DB` then made the denial visible. Both are cheap and should have come earlier.

#### Two further real bugs found on the way, both now fixed in `bluealsa/build.sh`

- **`Type=dbus` in the unit killed the daemon.** With `Type=dbus` and `BusName=org.bluealsa`,
  bluealsad died on every `Open()`; as `Type=simple`, or run by hand, it survives the identical
  sequence. The unit now uses `Type=simple` with a comment saying why.
- **`--keep-alive=0` (the default) SEGFAULTS bluetoothd 5.87.** Tearing the transport down the
  instant the last client closes takes this path, identically in six captured coredumps:

  ```
  #0 queue_remove  #1 media_endpoint_remove  #2 a2dp_unregister_sep
  #3 transport_a2dp_suspend  #4 service_filter  #5 message_filter
  #6 dbus_connection_dispatch
  ```

  `--keep-alive=5` avoids it. **This is an upstream BlueZ bug and is worth reporting** -- a client
  opening and closing an A2DP transport should not crash `bluetoothd`. Queue for
  [docs/57](57-upstream-queue.md).

#### A red herring worth recording, because it cost real time

The debug build logs `SBC setup: 0 Hz JointStereo ... => 0 bps`, which looks like a fatal
misconfiguration and is not. `sbc_print_internals` in `src/codec-sbc.c` does
`rate[sbc->frequency]` where the table is keyed by the **A2DP bitmask**
(`SBC_SAMPLING_FREQ_48000` = 0x01) while `sbc->frequency` holds **libsbc's enum**
(`SBC_FREQ_48000` = 3). `rate[3]` is an unset slot, so it prints 0. The encoder is configured
correctly; only the message lies. It is a bug in bluez-alsa's own diagnostic, present only in a
`--enable-debug` build, and also worth reporting upstream.

#### Excluded by measurement, not by reasoning

v5.0.0 **and** v4.3.1 fail identically, so it is not a v5 regression. Also excluded: codec (SBC and
AAC alike), format/rate/channels (the PCM reports exactly what was offered), period and buffer
limits (`PERIODS 2..1024`, `PERIOD_BYTES >= 1920`, both satisfied), the profile string, bus mismatch
(`DBUS_BUS_SYSTEM` appears once in the tree), dbus-broker restarts (PID 888 since boot), broker fd
exhaustion (**74** fds of `--max-fds 4096`), and the malformed D-Bus policy XML I had shipped --
a real bug, fixed, but not this one.

#### Honest note on how narrow the rule is

Narrower than `waydroid_backlight`, which could invent a private type because it guarded a *file*.
A pipe takes the type of the process that created it, so there is nothing to relabel: narrowing
this properly means giving bluealsad **its own domain** with a transition from `init_t` instead of
leaving it in `unconfined_service_t`. That is the correct long-term fix and is not done. What the
rule grants meanwhile is dbus-broker writing pipes owned by unconfined services -- bounded by
`unconfined_service_t` already being unconfined, and by dbus-broker being the only subject.

#### State: working, in the committed configuration

**Done and verified.** `semodule -B` restored the dontaudit rules, and
`artifacts/bluealsa/install.sh` loaded `waydroid_bluealsa`. With that in place:

```
aplay -D bluealsa     plays, no error
bluealsad             v5.0.0, active            codec: AAC
bluetoothd            active (no core dump)
SELinux               Enforcing
PipeWire              0 processes
```

Proven four ways in total: daemon by hand under Enforcing; under systemd with SELinux permissive;
and then twice under systemd with SELinux **Enforcing** and the module loaded -- once on the
v4.3.1 debug build, once on the v5.0.0 release build with AAC renegotiated.

`artifacts/bluealsa/install.sh` installs the policy and nothing else;
`bluealsa/build.sh --install` installs the daemon and nothing else. **Either alone leaves Bluetooth
audio broken**, which is why each says so in its header.

One wrinkle worth recording: **CIL takes no `(require ...)` block.** That is `.te` syntax, and
`semodule` rejects it with *Unknown keyword require / Failed to build AST*. CIL resolves type and
class names against the already-loaded policy, which is why `waydroid_backlight.cil` also names
`sysfs_t` and `udev_t` bare. The first version of the module carried a `require` block copied from
`audit2allow` output and failed to load.

Still outstanding, and unchanged by this: the **Android-to-BlueALSA bridge** is not built, so this
is host-side Bluetooth audio only. Nothing in Waydroid reaches `pcm.bluealsa` yet. The architectural
choice below is still open.

### What remains, and the open architectural choice

Nothing can carry audio until a sink is connected. After that, Android has to reach `bluealsa`, and
there are two shapes -- the choice is **not yet made**, and should be made with the host side
proven:

- **Guest plugin.** `asound.conf` points the HAL's `"pulse"` name at `pcm.bluealsa` inside the
  container. Needs `libasound_module_pcm_bluealsa.so` **and libdbus** cross-compiled for
  bionic/i686 (the image has no libdbus), the D-Bus system socket bind-mounted in, and
  `ALSA_PLUGIN_DIR` set for the HAL via an overlayed init `.rc`. Architecturally clean, no extra
  hop. Both the host's `libasound.so.2` and the image's `libasound.so` honour `ALSA_PLUGIN_DIR`,
  which is what makes the plugin placeable at all.
- **`snd-aloop` + a host bridge.** Android writes to `hw:Loopback`, a host process reads the other
  end and writes to `pcm.bluealsa`. **No cross-compiling whatsoever.** Costs a buffer hop and a
  clock-sync concern -- irrelevant against A2DP's own 100-200 ms.

The second is far cheaper and the latency argument does not favour the first, because A2DP
dominates either way. Either must be a **selectable arm**, not the default: routing all audio
through a loopback would undo the 10.67 ms fast path that this whole goal was about. Bluetooth is a
per-session choice, the same shape as `bin/alsa-arm.sh`'s existing arms.

### Still open after this

- **`SCHED_FIFO` for the FastMixer.** It wants it; the container's `Max realtime priority` is 10
  and the writer is `SCHED_OTHER` nice -19. The load test says it is not needed for correctness at
  5.33 ms — zero dropouts at 100% CPU — but the mix cycle's 2.63-7.54 ms spread is what it would
  tighten, and that spread is the headroom a smaller period would eat.
- **`create_mmap_buffer`** for AAudio EXCLUSIVE remains unwritten, and is still the only tier
  below this one.

## Verified vs hypothesis

**Verified on bigtab01 or in upstream source (2026-09-11):** every PCM has one substream; PipeWire
holds `hw:` directly and currently leaves it closed while idle; `/dev/snd` is not mounted into the
container; `config_nodes` is written only by `waydroid init`; `/dev/video0` is world-accessible
while `/dev/snd/*` is not; the HAL opens the alsa-lib name `"pulse"`; `alsa.conf` defines that name
inline and loads `/etc/asound.conf` afterwards; `make_prop()` already probes the host and runs on
every container start; the HAL's rate, channel and period constants.

**Added 2026-09-12**, all read from `/var/lib/waydroid/rootfs` or the host, none of it needing
sudo: this image does ship that fork's `alsa.conf`, with `pcm.pulse` at line 662, the full
`pcm/*.conf` plugin set and `cards/`, but no `ucm2/`; `/etc` is a symlink to `/system/etc` and
`/system/etc/asound.conf` does not exist; `audio_policy_configuration.xml` is the generic AOSP one,
offering apps only 48 kHz / 16-bit / stereo out and mono in, with no `DIRECT` mixPort;
`audio.usb.default.so` ships in both ABIs and its policy include uses dynamic profiles;
`android.hardware.usb.host.xml` and `android.hardware.midi.xml` are absent from
`/system/etc/permissions` (**scoped to that directory, and `usb.host` turns out to be declared in
`/vendor/etc/permissions` — see the correction above; `midi` is absent from both**); there is no
Bluetooth audio HAL in the image; the host graph runs
`clock.quantum` 1024 at 48 kHz with `min-quantum` 32; the host has `hci0` with `bluetooth.service`
active and PipeWire 1.6.8 serving the PA socket; `bluez-alsa` is not installed.

**Was hypothesis, all of it answered on 2026-10-04 by building the arm:**

| hypothesis | answer |
|---|---|
| whether SELinux permits `sound_device_t` from the container's domain | **yes**, for `container_runtime_t`; Android's own SELinux is `Disabled`. The domain this document guessed, `waydroid_t`, is the wrong one |
| whether a `/system/etc/asound.conf` override is honoured at runtime | **yes** — `pcm.!pulse` from the overlay redirected the HAL to `hw:1,0` with no rebuild, exactly as the config layout predicted |
| whether the container can obtain `SCHED_FIFO`/`RLIMIT_RTPRIO` | **yes** — `Max realtime priority 10`. The HAL runs `SCHED_OTHER` nice -19 anyway, and that is the measured cause of the arm's worse write jitter |
| whether audio works on this machine at all today | **yes**, and it already did before this; the claim was stale when written. Both arms were heard |

**Answered since, by [bin/alsa-load-ab.sh](../bin/alsa-load-ab.sh) on 2026-10-04:** whether the
ALSA arm survives real CPU load. **It does** — zero delayed writes and zero timestamp
discontinuities with the host at 100% busy and 4.2 s of PSI stall per 45 s, across three runs.
See [the load section](#load-tested-2026-10-04-the-jitter-regression-does-not-become-dropouts) for
the limits of that, chiefly that the competing load was nice 0 against a nice -19 writer.

**Still hypothesis:** whether the jitter regression disappears if the HAL's writer thread asks for
`SCHED_FIFO` (the rlimit allows it, nothing has tried); whether the ALSA arm survives load that is
not nice-0 CPU — negative nice, I/O or memory pressure, or a period below 256 frames; whether the
**pulse** arm survives the same load, which was never run against it; and everything about a
multichannel USB interface, which no longer needs guessing but needs hardware.

**First commands to run.** **Superseded 2026-10-04 — both of these were run, and the first one
was wrong twice over.** Kept because the shape of the mistake is the useful part:
`selinux_check_access()` takes **four** positional arguments on this host, not five, and
`waydroid_t` is not the domain that opens the device.

```bash
# WRONG, kept as a warning: wrong arity, and wrong domain -- waydroid_t is denied
# v4l_device_t too, while the camera demonstrably works.
python3 -c "import selinux; print(selinux.selinux_check_access(
    'system_u:system_r:waydroid_t:s0',
    'system_u:object_r:sound_device_t:s0', 'chr_file', 'open', None))"

# RIGHT: the domain the container's audio process actually runs in. The call returns 0
# for allowed and raises PermissionError for denied, so catch rather than compare.
python3 -c "
import selinux
for perm in ('open','read','write','ioctl','map'):
    try: selinux.selinux_check_access(
        'system_u:system_r:container_runtime_t:s0',
        'system_u:object_r:sound_device_t:s0', 'chr_file', perm); r='OK'
    except Exception: r='DENY'
    print(perm, r)"

# and the one that identifies the opener, which is not audioserver. owner_pid in
# /proc/asound is a THREAD id named for its job ("writer"), so it has to be resolved
# through Tgid before it names a program.
sudo sh -c 'T=$(sed -n "s/^owner_pid *: *//p" /proc/asound/card1/pcm0p/sub0/status);
            P=$(grep -a ^Tgid: /proc/$T/status | awk "{print \$2}");
            tr "\0" " " < /proc/$P/cmdline; echo; grep -a ^Uid: /proc/$P/status'
```

Everything else is now driven by three scripts rather than by hand. `alsa-arm.sh` deliberately
restarts nothing — see the operational traps in the A/B section:

```bash
ssh HOST 'sudo sh -s' -- status  < bin/alsa-arm.sh      # which arm, and is it wired
ssh HOST 'sudo sh -s' -- caps    < bin/alsa-arm.sh      # what the card really accepts
ssh HOST 'sudo sh -s' -- on      < bin/alsa-arm.sh      # build the ALSA arm
ssh HOST 'sudo sh -s' -- verify  < bin/alsa-arm.sh      # did it take, after a session restart
ssh HOST 'sudo sh -s' -- play    < bin/audio-tone.sh    # headless 1 kHz, 20 minutes
ssh HOST 'sudo sh -s'            < bin/alsa-vs-pulse.sh # the instrument, either arm
ssh HOST 'sudo sh -s' -- off     < bin/alsa-arm.sh      # revert
```

`audio-fastpath.sh` is the fast-path half, and restarts nothing for the same reason:

```bash
ssh HOST 'sudo sh -s' -- status             < bin/audio-fastpath.sh   # frame counts, FastMixer?
ssh HOST 'sudo sh -s' -- on --frames 256    < bin/audio-fastpath.sh   # derive + install overlay
ssh HOST 'sudo sh -s' -- verify             < bin/audio-fastpath.sh   # after a session restart
ssh HOST 'sudo sh -s' -- off                < bin/audio-fastpath.sh   # revert
```
