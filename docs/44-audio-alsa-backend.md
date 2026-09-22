# Audio: direct ALSA as a selectable backend

**Status: scoped, nothing built.** Added to the goal list on 2026-09-11 at the owner's request.
Everything marked *measured* below was run against bigtab01 or read out of upstream source on
2026-09-11, or added by a second pass on 2026-09-12. Everything else is explicitly flagged as
hypothesis.

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

**A probe run as root will lie about this.** Root opens `/dev/snd/*` regardless; Android's
audioserver runs as uid 1041. Any availability check has to ask whether the mode bits or ACL grant
a non-root, non-`audio`-group uid.

**3. SELinux is unknown here.** `sound_device_t` versus the `v4l_device_t` that works today. Ask
`selinux.selinux_check_access()` directly rather than waiting for an audit record —
[docs/42](42-backlight-selinux.md) and [docs/40](40-binder-nice.md) both record denials that are
`dontaudit`ed and therefore invisible to `ausearch`.

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
`/system/etc/permissions`; there is no Bluetooth audio HAL in the image; the host graph runs
`clock.quantum` 1024 at 48 kHz with `min-quantum` 32; the host has `hci0` with `bluetooth.service`
active and PipeWire 1.6.8 serving the PA socket; `bluez-alsa` is not installed.

**Still hypothesis:** whether SELinux permits `sound_device_t` from the container's domain; whether
a `/system/etc/asound.conf` override is honoured at runtime (the config layout is confirmed, the
behaviour is untested); whether the container can obtain the `SCHED_FIFO`/`RLIMIT_RTPRIO` an
Android low-latency thread wants, given the `RLIMIT_NICE` precedent in
[docs/40](40-binder-nice.md); and whether audio works on this machine at all today — it has never
been tested, because no goal needed it.

**First commands to run.** The rootfs reads above answered every image question without sudo; what
is left needs the container running, or the host:

```bash
# does the container's domain get the sound nodes at all? ask the kernel, do not wait for an
# audit record — docs/40 and docs/42 both record dontaudit'ed denials that ausearch never shows
python3 -c "import selinux; print(selinux.selinux_check_access(
    'system_u:system_r:waydroid_t:s0',
    'system_u:object_r:sound_device_t:s0', 'chr_file', 'open', None))"

# what AudioFlinger thinks it has, and whether anything works today
sudo waydroid shell -- sh -c "dumpsys media.audio_flinger | head -40"
```
