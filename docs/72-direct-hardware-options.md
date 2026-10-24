# 72 — Direct hardware for Waydroid: optional passthrough backends

**Date:** 2026-10-21. **Status:** scoping only — nothing built. Opened at the owner's request as a
roadmap direction: let Waydroid **directly own** host hardware — USB peripherals, network
interfaces, Bluetooth, removable storage, some audio — instead of reaching it through a host daemon
and NAT. The explicit framing from the owner, which shapes the whole note: **these are options, not
replacements.** Nothing already built is torn out. Each capability ships as its own RPM (and
eventually `.deb`), and a user picks what Waydroid controls by choosing which packages to install.

Everything measured here was read off bigtab01 ([00](00-host-baseline.md)) or the CS9711 libfprint
project on the dev box on 2026-10-21. What is hypothesis is marked as such.

## The one fact that decides all of it: a container, not a VM

Waydroid runs Android in an **LXC container**. It shares the host's single running kernel through
namespaces and cgroups; there is no guest kernel and no hypervisor. Every answer below follows from
that:

- **There is no IOMMU/VFIO device passthrough**, because that is a virtual-machine mechanism. You do
  not "assign" a PCI device to the container the way you would to a KVM guest.
- **Kernel drivers always run host-side**, in the one shared kernel. "Giving Android a device" never
  means loading an Android driver; it means one of two host-side moves:
  1. **Move it into a namespace** — a network interface into the container's *network* namespace, so
     Android's own stack configures it.
  2. **Allow it through the cgroup device controller and bind-mount the node** — a character or block
     device (`/dev/bus/usb/*`, `/dev/sdX`, an ALSA node, an HCI socket), which a userspace program
     *inside* Android then opens.
  In both cases you also **mask the host userspace** that would otherwise own the resource
  (NetworkManager, BlueZ, udisks2, PipeWire on that device), or the two fight over it.

### VT in the BIOS is irrelevant here — record it so it is not re-asked

VT-x and VT-d/IOMMU are virtualization features. They matter to KVM/QEMU running a real guest, and
to PCI passthrough *into a VM*. **LXC never touches them.** Re-enabling VT gives Waydroid-on-LXC
exactly zero new capability. The only thing it would unlock is a different architecture entirely —
Android in a KVM VM (Cuttlefish, or an AOSP guest) with real IOMMU passthrough — which discards
every host-daemon integration this project has built and is the parked AOSP track
([AGENTS.md](../AGENTS.md), secondary track). Leave VT off unless that pivot is ever made.

## SELinux cannot be "containerized"

There is **no per-container or namespaced SELinux** in the mainline kernel. SELinux policy is one
kernel-global thing; "hand SELinux to Waydroid to manage" is not a capability the kernel offers.
Two facts bound the real options:

- **Inside the container, SELinux is already effectively `Disabled`** — measured for goals 8 and 9
  ([50](50-bluetooth.md), [55](55-appfuse.md)). A MAINLINE Waydroid does not load Android's own
  sepolicy; the Android side runs unconfined, which is why the AppFuse fix was a *host* CIL module,
  not an Android one.
- So the only knobs are the ones already in use: **host Enforcing plus targeted CIL modules** (the
  binder, AppFuse and backlight modules — [42](42-backlight-selinux.md), [55](55-appfuse.md)), or
  **host Permissive/Disabled globally**, which throws away the host's own protection for no
  containment benefit. There is no middle path that scopes SELinux to Waydroid.

Practical consequence for the packages below: a direct-hardware package that needs a new host access
right is one more small CIL module, not a policy regime change.

## Per-subsystem feasibility

| Capability | Verdict | The catch |
|---|---|---|
| Network interface into the container (skip NAT) | **Feasible on a multi-NIC host; strands bigtab01** | Single radio, managed over SSH on that radio — handing it to Android cuts the host off ([28](28-wifi-feasibility.md)) |
| Waydroid manages the firewall | **Reframe: isolate, don't disable** | Firewall rules are per network namespace; Android's `netd` owns its namespace, the host firewall governs what's left. Globally disabling firewalld/nftables strips host protection for no gain |
| Direct USB (fingerprint, Yubikey, …) | **Feasible, device by device** | Userspace-claimable devices are clean; kernel-driver devices are driven host-side and you pass the resulting node |
| Removable storage to Android's `vold` | **Feasible but redundant** | Block device appears host-side regardless; [46](46-removable-media.md) already solves this more cheaply. Direct-`vold` is an alternative backend, not an upgrade |
| Bluetooth to Android (skip BlueZ) | **Feasible, not namespace-isolated** | HCI devices are global; it is "mask host BlueZ, Android opens `hci0`". Only one controller, and the keyboard pairs to it ([50](50-bluetooth.md)) |
| USB/BT audio to Android, PCI card to PipeWire | **Feasible — this is goal 5** | [44](44-audio-alsa-backend.md)'s device *dedication*; BT-audio also needs Android to own the controller |
| Boot straight into Waydroid, no display manager | **Feasible** | A systemd unit starts the session at boot and masks SDDM/NM/BlueZ; you cannot drop systemd as PID 1 on an ostree host |

### Network interface, and ADB-over-network as its management model

Moving `wlp1s0` into the container's network namespace (`iw phy <phy> set netns <pid>` for the
wiphy, or `ip link set <dev> netns` for a plain netdev) lets Android's own stack own the interface
and an IP on it. The **firewall question answers itself**: rules live per network namespace, so once
the device is in Android's netns, `netd` manages that namespace and the host firewall is simply not
in that path — there is no reason to disable firewalld/nftables host-wide, and doing so would only
remove the host's own protection.

**Wi-Fi is harder than a wired NIC.** The wiphy-to-netns move works, but then the host's
NetworkManager and `wpa_supplicant` lose the radio, and Android needs a wifi HAL that drives the phy
**directly over nl80211** — which is a *different* backend from goal 4's `waydroid-wifid`, whose
`NmBackend` deliberately goes through NetworkManager and whose nl80211 use today is read-only stats
([29](29-wifi-plan.md), [31](31-wifi-stage2.md), [34](34-wifi-second-radio.md),
[35](35-wifi-stage5.md), [60](60-wifi-nl80211.md)). So "direct Wi-Fi" is a new `WifiBackend` that
*owns* the phy, not a tweak to the existing one.

**ADB over the network is the clean management payoff, with two caveats.** If Android holds a
routable IP on the physical interface, enabling adbd-over-TCP (`service.adb.tcp.port`) lets
`adb connect <ip>:5555` from any LAN machine manage Android directly — it replaces the
"SSH to host + `waydroid shell`" path ([00](00-host-baseline.md) / AGENTS.md) with a single native
channel. But:

1. On a **single-radio** host the *host itself* is then off the network — no SSH, no remote
   `rpm-ostree`, no reaching the daemons — only the console remains. That is right for an appliance
   and wrong for a machine still under active development.
2. **ADB-over-TCP authentication is weak** (per-key RSA accept on first connect, trivially widened).
   An Android-owns-the-LAN device is a real exposure surface and wants its own hardening story.

So ADB-over-network belongs with the **appliance** profile (boot straight into Waydroid, Android
owns the NIC), not with the development profile.

### USB — and the passthrough is already proven in a sibling container

Allowing USB is a cgroup device-controller rule plus a bind-mount of `/dev/bus/usb` (and
`/run/udev`). A userspace program inside Android then claims the interface with libusb. Devices split
two ways:

- **Userspace-claimable** — the CS9711 fingerprint reader (vendor-specific class, no kernel driver
  bound, confirmed 2026-10-21) and the Yubikey (HID/CCID). These are clean: nothing host-side owns
  them, Android claims them directly.
- **Kernel-driver** — USB mass storage (`usb-storage` → `/dev/sdX`) and the USB Bluetooth adapter
  (`btusb` → `hci0`). The driver binds host-side in the shared kernel regardless; you pass the
  *resulting* node into the container and mask the host consumer.

**This is not hypothetical.** The CS9711 libfprint project's dev rig (`scripts/fprint-dev.sh`, dev
box) already runs the unmodified upstream `enroll`/`verify`/`img-capture` examples **inside a
rootless podman container that is given `--device /dev/bus/usb`**, and a userspace libfprint driver
claims the reader and captures images there — a full enroll on 2026-10-06, 15/15 stages. podman and
Waydroid's LXC use the **same** kernel cgroup device-controller mechanism, so the one unknown left
for Waydroid is whether its config applies an arbitrary USB node at session start (see Open
questions), not whether userspace-USB-in-a-container works at all. It does.

### Boot straight into Waydroid

A systemd unit launches `cage` and the Waydroid session on a seat at boot, and SDDM/NM/BlueZ are
masked to the extent the installed direct-hardware packages replace them. Note you **do not skip
systemd** — it is PID 1 and the init system, foundational on an ostree host; you skip *specific
services*. bigtab01 is already most of the way here, running `waydroid-cage` as the session rather
than a general desktop ([AGENTS.md](../AGENTS.md), app-mode vs cage).

## The package family

The vision maps onto a set of independent, reversible RPMs, each declaring which host service it
masks and carrying any small CIL module it needs:

| Package | Hands Android | Masks on the host | Safe on bigtab01? |
|---|---|---|---|
| `waydroid-direct-usb` | the USB bus (cgroup allow + `/dev/bus/usb`) | — (foundation for the rest) | **yes** |
| `waydroid-direct-fingerprint` | the CS9711 (needs direct-usb) | — | **yes** |
| `waydroid-direct-audio` | a dedicated USB/BT audio device | PipeWire *on that device only* | yes |
| `waydroid-direct-bt` | `hci0` | BlueZ | **no** — only controller, keyboard pairs to it |
| `waydroid-direct-net` | a network interface | NetworkManager on that device | **no** — single radio, SSH-managed |
| `waydroid-boot-kiosk` | the seat at boot | SDDM | yes (appliance profile) |

This is the project's existing philosophy, not a new one: the pluggable `WifiBackend`
([29](29-wifi-plan.md)), the selectable audio backend ([44](44-audio-alsa-backend.md)), and the
StrongBox *instance* that does not displace `default` ([65](65-tpm-keystore.md)) are all the same
"add an option, do not replace the default" shape. The `.deb` story later is a second packaging
front end over identical artifacts, because the mechanism is kernel + Waydroid config and
distro-agnostic. It is a **distant** roadmap item by the owner's direction.

## How this meets the fingerprint HAL (goal 11)

The in-Android fingerprint HAL the owner chose over a host daemon (2026-10-21) is the **first
concrete consumer of `waydroid-direct-usb`**:

- `waydroid-direct-usb` passes the CS9711 into the container; a native AIDL
  `android.hardware.biometrics.fingerprint.IFingerprint` service at `/vendor/bin/hw/`, built with
  the NDK and dropped in through the vendor overlay ([08](08-camera-fixed.md)), claims it.
- **Lift two GLib-free pieces from the owner's fork**, do not port libfprint: the CS9711 USB capture
  protocol, and the matcher — **SIGFM, plain C, OpenCV dropped** (`libfprint-goodix-538d-redhat`
  commit `af739b3`, per-sensor settings in `8856cb0`). Porting GLib/gusb/libfprint to bionic is the
  thing this project exists to avoid.
- **An in-Android HAL sidesteps the binder-`transfer` trap entirely** ([35](35-wifi-stage5.md),
  [66](66-fingerprint-hal.md)): with no host daemon injecting binders into the container,
  `createSession()`'s two-way binder crossing is in-process and the `dontaudit`ed denial never
  arises. This is the strongest technical argument for the in-Android direction on this goal.
- Unchanged by any of this: the sensor still needs the stage-0 feature XML + VINTF to wake the
  dormant biometric framework ([31](31-wifi-stage2.md), [66](66-fingerprint-hal.md)), and the
  owner's vault app's **verifiable `HardwareAuthToken`** still pulls in `computeSharedHmac`
  (goal 10 stage 5, [65](65-tpm-keystore.md)) and is still **software-grade on bigtab01** — the
  container is not a TEE, so matching in Android is more defensible than host-side but not
  hardware-rooted, and attestation remains impossible on either host.

## The hard constraint to keep pinned

bigtab01 has **one radio and is managed over SSH on that radio** — the memory note
"Android owns the host Wi-Fi" and [28](28-wifi-feasibility.md). `waydroid-direct-net` and, to a
lesser degree, `waydroid-direct-bt` are the two options that can lock the operator out of their own
machine. They stay **available but not installed on bigtab01** — which is precisely what a
pick-and-choose model is for: they are the right fit for a desktop with spare interfaces and the
wrong fit for this tablet.

## Next action (deferred to a later session by the owner)

**The USB-passthrough probe**, which is the gate under the fingerprint HAL and every other USB
option:

1. Add the CS9711 (`2541:0236`, bus-id `1-2`, device node under `/dev/bus/usb/001/`) to the
   container's device set — the `generate_nodes_lxc_config()` / `config_nodes` seam, the same one
   [44](44-audio-alsa-backend.md) needs for `/dev/snd`.
2. Restart the **session** (not the container, not the service) to apply it — on bigtab01 that is a
   console logout/login of the `waydroid-cage` session, costing the LUKS prompt and a manual `sshd`
   ([02](02-ssh-access.md), [63](63-second-host-and-android-16.md)). The owner must be at the
   machine.
3. From inside Android, confirm a process can open the device and complete one bulk transfer.

Proven feasible in principle by the podman dev rig above; what the probe settles is the
Waydroid-specific config path.

## Open questions

1. **Does `generate_nodes_lxc_config()` accept an arbitrary `/dev/bus/usb` node**, or only the
   device classes Waydroid already enumerates? Read the function before the probe; [44](44-audio-alsa-backend.md)
   locates the same seam for `/dev/snd`.
2. **Raw usbfs to our HAL, or Android's `UsbManager`?** The HAL wants exclusive, boot-time access, so
   usbfs via libusb is the likely answer, but confirm Android's USB permission model does not need a
   foreground grant.
3. **Does a wiphy moved into the container's netns survive a Waydroid session restart**, which tears
   down and recreates namespaces? If not, `waydroid-direct-net` needs a reattach hook.
4. **ADB-over-TCP hardening** for an Android-owns-the-LAN device — the auth model is weak and needs a
   story before the appliance profile is recommended to anyone.
5. **Does masking PipeWire on a single dedicated device** (rather than the whole daemon) work cleanly,
   or does PipeWire reclaim it on hotplug? Relevant to `waydroid-direct-audio`.
