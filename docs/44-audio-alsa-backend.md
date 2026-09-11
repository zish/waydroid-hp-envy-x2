# Audio: direct ALSA as a selectable backend

**Status: scoped, nothing built.** Added to the goal list on 2026-09-11 at the owner's request.
Everything marked *measured* below was run against bigtab01 or read out of upstream source on
2026-09-11. Everything else is explicitly flagged as hypothesis.

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

So `pcm.!pulse` can be redefined from an overlay file with no HAL rebuild at all. Unverified on
this host — see the open questions at the end.

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

Two supporting pieces, both hypothesis until checked:

- `audio_policy_configuration.xml` in the image declares which rates and channel masks Android will
  offer apps at all. It is **not** in Waydroid's device or vendor tree, so it is presumably the
  generic AOSP one; it lives under `/vendor/etc` and is therefore overlay-able.
- Android's own USB-audio and MIDI framework paths (`UsbAlsaManager`, `UsbAlsaDevice`,
  `UsbMidiDevice`) read ALSA nodes directly, but are driven by UsbManager hotplug, which Waydroid
  does not wire up. The feature gates are XML files in `/system/etc/permissions` — the same
  one-overlay-file lever that woke the whole Wi-Fi framework up in
  [Stage 0](32-wifi-stage3.md).

## Verified vs hypothesis

**Verified on bigtab01 or in upstream source (2026-09-11):** every PCM has one substream; PipeWire
holds `hw:` directly and currently leaves it closed while idle; `/dev/snd` is not mounted into the
container; `config_nodes` is written only by `waydroid init`; `/dev/video0` is world-accessible
while `/dev/snd/*` is not; the HAL opens the alsa-lib name `"pulse"`; `alsa.conf` defines that name
inline and loads `/etc/asound.conf` afterwards; `make_prop()` already probes the host and runs on
every container start; the HAL's rate, channel and period constants.

**Hypothesis, not yet checked:** that this image actually ships
`/vendor/usr/share/alsa/alsa.conf` from that fork branch; that `/system/etc/asound.conf` is read
inside the container; what `audio_policy_configuration.xml` declares; whether SELinux permits
`sound_device_t` from the container's domain; and whether audio works on this machine at all today
— it has never been tested, because no goal needed it.

**First commands to run** (inside the container, so they need sudo):

```bash
sudo waydroid shell -- sh -c "ls -l /vendor/usr/share/alsa/ /system/etc/asound.conf"
sudo waydroid shell -- sh -c "grep -n 'pcm.pulse' -A3 /vendor/usr/share/alsa/alsa.conf"
sudo waydroid shell -- sh -c "find /vendor/etc /system/etc -name 'audio_policy_configuration*.xml'"
sudo waydroid shell -- sh -c "dumpsys media.audio_flinger | head -40"
```
