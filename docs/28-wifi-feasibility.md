# Wi-Fi in Waydroid — what exists, what is missing, and which seam to cut

**Date:** 2026-09-07. **Status:** investigation complete, nothing deployed. The plan that follows
from it is [29-wifi-plan.md](29-wifi-plan.md).

## The question

Can Android's own Wi-Fi settings — the real `WifiManager`, the real Settings panel — be made to
drive the host's **NetworkManager**? And would it instead be *easier* to hand Android the radio
and let it talk to the hardware directly?

Short answers: **yes**, and **no** — direct hardware access is harder here, not easier, and it
costs the machine. Both are argued below from what is actually on this host.

## What is actually in the image

All of this was read on 2026-09-07 straight out of the read-only images with `debugfs`, which
reads an ext4 file without mounting it and therefore **without sudo** — the images are
world-readable:

```bash
debugfs -R "ls /system/bin" /etc/waydroid-extra/images/system.img
debugfs -R "cat /etc/vintf/manifest.xml" /etc/waydroid-extra/images/vendor.img
```

Worth remembering as a technique: the whole Android image is inspectable from the host with no
container running and no privileges.

| Component | Present? | Where checked |
|---|---|---|
| `com.android.wifi` APEX — `framework-wifi`, `service-wifi` | **yes** | `/system/apex` |
| `wificond` | **yes** | `/system/bin/wificond` |
| `libwifi-system-iface.so`, `libnl.so`, `android.system.wifi.keystore@1.0.so` | **yes** | `/system/lib64` |
| `wpa_supplicant` / `android.hardware.wifi.supplicant@*-service` | **no** | `/system/bin`, `/system/bin/hw`, `/system/vendor/bin/hw`, `/vendor/bin`, `/vendor/bin/hw` |
| Vendor Wi-Fi HAL (`android.hardware.wifi@1.x`) | **no** | `/vendor/bin/hw`, `/vendor/etc/init` |
| Wi-Fi entry in the vendor **VINTF manifest** | **no** | `/vendor/etc/vintf/manifest.xml`, `manifest/`, `manifest.disabled/`, `compatibility_matrix.xml` — zero matches for "wifi" |
| `/system/etc/permissions/android.hardware.wifi.xml` | **no** | 22 XML files there, none of them Wi-Fi |

Build: `lineage_waydroid_x86_64-userdebug`, LineageOS 20.0, **Android 13 / SDK 33**, security patch
2026-02-01.

Two of those rows matter more than the rest.

**The entire Wi-Fi framework is present and dormant.** The mainline module is shipped; nothing
above the native layer needs to be written or patched. That is the good news, and it is what makes
this tractable at all.

**Nothing is "disabled" — it is absent.** `manifest.disabled/` holds only the two gbm_mesa entries,
so this is not a case of flipping something back on. The Waydroid image was simply built without a
Wi-Fi stack, because a container has no radio.

### Why there is no Wi-Fi UI today

**Verified on the host, 2026-09-07.** `SystemServer` starts `WifiService` only when
`PackageManager.hasSystemFeature(FEATURE_WIFI)` is true, and that feature comes from a permissions
XML this image does not ship. Adding it through the system overlay — one file, one container
restart — brought the whole framework up: `WifiService` runs, `wificond` starts by itself and
registers `wifinl80211`, and Settings immediately tried to enable Wi-Fi. Stage 0 of
[29-wifi-plan.md](29-wifi-plan.md) records the run; evidence in `artifacts/wifi/stage0/`.

(The image ships no ethernet feature XML either, yet `EthernetService` demonstrably runs —
[16-waydroid-network.md](16-waydroid-network.md) caught `EthernetNetworkFactory` deadlocked in a
stack trace. So feature XML is not the whole mechanism for ethernet. For Wi-Fi it turned out to be
exactly the mechanism.)

## What is on the hardware

```
01:00.0 Network controller [8086:095a] Intel Wireless 7265 [Stone Peak 2 AC]
        Kernel driver in use: iwlwifi          -> phy0, mac80211 (softmac)
```

Host interfaces: `lo`, `wlp1s0`, `waydroid0` (bridge, 192.168.240.1/24), one veth. **There is no
wired NIC** — this is a tablet. The container sits at 192.168.240.112 behind NAT, and its veth is
`unmanaged` by NetworkManager.

Also relevant, and slightly surprising:

- **`virt_wifi` is shipped and signed** (`kernel/drivers/net/wireless/virtual/virt_wifi.ko.xz`).
- **`mac80211_hwsim` is not** — and `kernel-modules-extra` is *already layered*, so it is not one
  `rpm-ostree install` away. Fedora keeps hwsim in the internal/debug kernel package.
- **Secure Boot is disabled, platform in Setup Mode.** Unsigned out-of-tree modules will load.

## Why direct hardware access is the worse option

It would work, technically. `iwlwifi` is a mac80211 softmac driver, so `phy0` carries
`WIPHY_FLAG_NETNS_OK` and `iw phy phy0 set netns <container-pid>` would move the whole radio into
the container's network namespace. Firmware loading is a **host-kernel** concern — `request_firmware`
reads the host's `/lib/firmware` regardless of namespace — so the container would need no firmware
of its own. That part is genuinely clean.

It fails on three counts:

1. **`wlp1s0` is the machine's only network interface.** The moment the phy moves into the
   container, SSH dies and the host has no route back. Recovery means the physical console, which
   on this machine also means the LUKS passphrase and starting `sshd` by hand. This alone
   disqualifies it as a thing to try casually.
2. **It saves almost none of the software work.** The missing pieces are the feature XML, the
   supplicant, and the no-vendor-HAL path — *all three are still required* with real hardware.
   Direct access only removes the NetworkManager backend, which is the smallest and best-understood
   part of the job.
3. **NetworkManager loses the radio permanently.** The host would have to route through Android to
   reach the network, which inverts the machine.

**It becomes reasonable only with a second radio.** A USB Wi-Fi dongle handed to the container is
a genuinely good idea, but as a *test rig*, not as the design: it would let the stock Android Wi-Fi
stack be validated end-to-end against real hardware without risking the host's connectivity, which
would de-risk the supplicant stage substantially. Recorded as an option in the plan, not a
dependency.

## Where the seam has to be

The wanted seam — "make `WifiManager` talk to NetworkManager" — does not exist at framework level.
`WifiService` reaches the radio through three native things:

| Layer | What it does | Status here |
|---|---|---|
| **Vendor HAL** | chip lifecycle, iface creation | absent, and **absent from VINTF** |
| **wificond** (`wifinl80211`, AIDL) | scans, signal polling, iface up/down, over **nl80211** | binary present |
| **wpa_supplicant** (HIDL/AIDL) | association, credentials, 4-way handshake | absent |

The vendor HAL is skippable — **verified 2026-09-07, not merely hoped for.** `HalDeviceManager`
keys off the HAL being declared in VINTF, and it is not; with the feature XML in place `dumpsys wifi`
reports `HalDeviceManager: mWifi: null` and the framework **proceeded anyway**, going straight to
wificond and failing only because no `wlan0` exists. That is `WifiNative`'s no-vendor-HAL path, the
one Android-x86 has historically run on, working here.

The same dump also settles the multi-radio question: `STA + STA Concurrency Supported: false` and
`STA + AP Concurrency Supported: false`, because with no HAL there is nothing to declare interface
combinations. Android will see exactly one radio however many the host has, and AOSP has no
user-facing adapter picker in any case — so multiple host radios belong below the backend contract.

The hard constraint is nl80211: **wificond wants a real cfg80211 phy**, and NetworkManager cannot
co-own `wlp1s0` with Android. So the radio Android sees has to be emulated. That is the whole
problem in one sentence — and after Stage 0 it is now the *only* problem in front of a working
Wi-Fi toggle, stated by wificond itself as `Can't get wlan0 index: No such device`.

## The credentials problem, and what solves it

The obvious cheap design — simulate access points, mirror NM's scan list as beacons, let Android
associate — **cannot carry a password**. A fake AP has to complete a WPA2 four-way handshake
without knowing the PSK, which is exactly what WPA exists to prevent. It cannot compute the MIC on
message 3, so the client rejects it. Make the fake APs open instead and Android never prompts for a
password, leaving nothing to hand NetworkManager for a new network.

The way out is the reason the architecture lands where it does:

> **Android hands the passphrase to `ISupplicantStaNetwork.setPskPassphrase()` in the clear.**
> Whoever implements the supplicant interface gets the credentials for free.

So the supplicant shim is not one option among several — it is the irreducible core of any design
that lets a user type a password into Android's Wi-Fi dialog and have it reach NetworkManager. Every
other component is negotiable.

## The three architectures, and the decision

**A — `mac80211_hwsim` + userspace fake APs.** Roughly the Android emulator's approach. Ruled out
twice over: hwsim is not packaged for this kernel, and it hits the credentials problem head-on.

**B — Replace `wificond` and the supplicant with NetworkManager translators.** Everything from
`WifiService` upward stays stock: real Settings panel, real `WifiManager` for apps, real
`TRANSPORT_WIFI`. Underneath, scan results are synthesized from NM's D-Bus `AccessPoint` objects and
`addNetwork`/`setPskPassphrase`/`select` become NM connection profiles plus `ActivateConnection`.
All userspace, no kernel module.

**C — `virt_wifi` + stock `wificond` + supplicant shim.** `virt_wifi` wraps an existing ethernet-like
netdev in a cfg80211 device, which is very close to what Chrome OS does for ARCVM. It hands the
container a genuine nl80211 phy named `wlan0` for free, so **stock wificond works unmodified** — a
large chunk of B's work disappears. The cost is that stock `virt_wifi` advertises exactly one fake
open network ("VirtWifi"), so showing the user real SSIDs needs either a patched module or a
wificond replacement after all.

**Decision: build toward B, but get there through C.** They share the supplicant shim, which is the
hard part and the part that carries credentials, and C reaches a *working end-to-end Wi-Fi stack*
far sooner — at which point the remaining question (where scan results come from) can be answered
with a running system instead of on paper.

The C-versus-B choice for scan results is deliberately deferred to Stage 4, because the tradeoff is
operational rather than technical: extending `virt_wifi` is a few hundred lines of kernel C against
reimplementing ~10 AIDL interfaces in userspace, but an out-of-tree module has to be rebuilt for
every kernel update on an rpm-ostree host, and this host updates often.

## Precedent

Chrome OS does this in production: ARC drives Android's Wi-Fi UI against shill, the host connection
manager. My understanding is that they patched the Android framework rather than shimming beneath
it, which is the approach this plan explicitly avoids — patching the framework is what makes a
change unshippable to anyone else.

Waydroid also already proves the pattern this depends on. `waydroid-sensord` is a **host** daemon
that registers a HIDL service into the container's binder domain with libgbinder, and the guest
consumes it as if it were a normal HAL — see [14-sensors.md](14-sensors.md). Wi-Fi is the same idea
with roughly ten times the interface surface.

## Honest scale

The framework work is zero; the plumbing is all interface surface. `ISupplicantStaNetwork` alone has
93 methods, and the supplicant side totals **203 method slots** across six interfaces — measured,
not estimated, in [30-wifi-aidl-surface.md](30-wifi-aidl-surface.md). Most return "unsupported",
but every one needs its slot, because binder transaction codes are positional and a wrong count
shifts everything after it. This is the largest single piece of work attempted in this repo — larger than the
sensors daemon — but it is mechanical rather than uncertain, and the two hardest unknowns (does the
framework switch on, does the no-vendor-HAL path work) are both answerable in the first two stages
for almost no effort.
