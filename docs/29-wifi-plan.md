# Plan — Android Wi-Fi settings driving NetworkManager

**Date:** 2026-09-07, updated 2026-09-08. **Status:** Stages 0 and 2 done, Stage 1 blocked and
routed around, Stages 3–5 outstanding. Findings it rests on are in
[28-wifi-feasibility.md](28-wifi-feasibility.md); read that first, then
[31-wifi-stage2.md](31-wifi-stage2.md) for what is actually running.

## Goal

A user opens **Settings ▸ Network & internet ▸ Wi-Fi** inside Waydroid, sees the access points the
host can actually see, taps one, types the password, and **NetworkManager connects `wlp1s0`**.
Android's stock Wi-Fi framework throughout — no framework patches, no forked Settings app.

Second goal, and the reason to build it properly rather than narrowly: **make the host side
pluggable**, so that NetworkManager is one backend among several and somebody running iwd or
connman can add theirs without touching the Android-facing half.

## Shape

```
  ┌─ container (Android 13, stock) ───────────────────────────┐
  │   Settings ▸ Wi-Fi   →   WifiManager                      │
  │                          WifiService  (com.android.wifi)  │
  │                              │                 │          │
  │                        wificond           supplicant      │
  │                     (stock, then ours)      (ours)        │
  │                              │ nl80211         │          │
  │                       wlan0 (virt_wifi)        │          │
  └──────────────────────────────┼─────────────────┼──────────┘
              /dev/binder (AIDL) ┘   /dev/hwbinder (HIDL) ┘
                     both bind-mounted from the host by config_nodes
  ┌──────────────────────────────┼─────────────────┼──────────┐
  │   waydroid-wifid — host daemon, C++ + libgbinder          │
  │                    ┌─────────┴─────────┐                  │
  │                    │  WifiBackend API  │  ← the framework │
  │              ┌─────┴─────┬───────┬─────┴────┐             │
  │              │    nm     │  iwd  │ connman  │ …           │
  │              └─────┬─────┘                                │
  └────────────────────┼─────────────────────────────────────-┘
                NetworkManager D-Bus → wlp1s0 / phy0
```

This is the [14-sensors.md](14-sensors.md) pattern again — **keep the interface Android expects,
replace the data source** — and it works for the same verified reason: `config_nodes` bind-mounts
`/dev/binder`, `/dev/vndbinder` and `/dev/hwbinder` from the host into the container, all three
world-readable/writable, so a host process shares the guest's binder domains and can register
services in them. The sensors daemon proves this for HIDL; `/dev/binder` being shared the same way
means the AIDL side (wificond's `wifinl80211`) is reachable too.

## The framework: the backend contract

This is the extension point, and the thing worth getting right early even though only one backend
will exist at first. Everything Android-facing lives above it; everything host-specific below.

```cpp
enum class Security { Open, Wep, WpaPsk, Wpa2Psk, Wpa3Sae, Wpa2Eap };

struct Bss {
    std::string ssid;
    uint8_t     bssid[6];
    int32_t     freq_mhz;
    int32_t     rssi_dbm;
    Security    security;
    bool        known;        // NM already has a profile for it
};

struct NetworkRequest {
    std::string ssid;
    Security    security;
    std::string passphrase;   // arrives in the clear from setPskPassphrase()
    std::string identity;     // EAP, later
};

struct LinkState {
    bool        associated;
    std::string ssid;
    uint8_t     bssid[6];
    int32_t     freq_mhz;
    int32_t     rssi_dbm;
    std::string ipv4;
};

class WifiBackend {
public:
    virtual ~WifiBackend() = default;
    virtual bool             init()                          = 0;
    virtual bool             setEnabled(bool on)             = 0;   // rfkill / NM WirelessEnabled
    virtual bool             startScan()                     = 0;
    virtual std::vector<Bss> scanResults()                   = 0;
    virtual bool             connect(const NetworkRequest&)  = 0;
    virtual bool             disconnect()                    = 0;
    virtual bool             forget(const std::string& ssid) = 0;
    virtual LinkState        state()                         = 0;
    virtual void             onStateChanged(std::function<void(LinkState)>) = 0;

    // Multiple host radios are resolved HERE, below the contract. Android sees exactly one
    // interface and has no adapter picker -- verified in Stage 0, see above.
    virtual std::vector<std::string> devices()                        = 0;
    virtual bool                     selectDevice(const std::string&) = 0;
};
```

Fourteen methods. `NmBackend` implements them against NetworkManager's D-Bus API —
`RequestScan`, the `AccessPoint` objects under each wireless device, `AddAndActivateConnection`,
and `StateChanged` signals. Nothing in the Android-facing half ever learns which backend it has.

*As built (`wifi/WifiBackend.h`) this grew a fifteenth, `frequencies(Band)`: `IWificond` has five
`getAvailable*Channels()` calls and the answer is a property of the host radio, which is exactly
what lives below the line.*

## Stages

Ordered so that the two things that could sink the whole idea are answered first, for almost no
effort, before anything substantial is written.

### Stage 0 — does the framework even switch on? — **DONE, 2026-09-07**

One file, through the system overlay:

```
/var/lib/waydroid/overlay/system/etc/permissions/android.hardware.wifi.xml   0644 root:root
```

staged in the repo at `artifacts/overlay/system/etc/permissions/`, then
`waydroid container restart`. Reversible by deleting it. Evidence in `artifacts/wifi/stage0/`.

**It worked, and it over-delivered.**

- `pm list features` now reports `feature:android.hardware.wifi`.
- `WifiService` starts and completes every boot phase.
- **`wificond` starts by itself** and registers `wifinl80211`; `wifiscanner` registers too.
- Settings actively tried to turn Wi-Fi on — `RequestorWs: WorkSource{1000 com.android.settings}`.

It then failed at exactly one place, and only one:

```
E wificond: Can't get wlan0 index: No such device
E wificond: Failed to get wiphy index
   -> CMD_STA_START_FAILURE -> DisabledState
```

**The no-vendor-HAL question is answered, and favourably.** `dumpsys wifi` reports
`HalDeviceManager: mWifi: null` — the vendor HAL is absent, exactly as the VINTF finding predicted —
and the framework *proceeded past it anyway*, went straight to wificond, and failed only on the
missing interface. That was the largest risk in this plan and it is retired a stage early.

Two more things fell out of the same dump:

- The interface the fallback path wants is literally **`wlan0`**, which confirms the property
  default rather than leaving it as an assumption.
- `STA + STA Concurrency Supported: false` and `STA + AP Concurrency Supported: false` — now
  **verified on the host**, not inferred. With no HAL there is nothing to declare interface
  combinations, so Android sees exactly one radio no matter what the host has. Multiple host radios
  must therefore be resolved **below** the backend contract; asking Android to enumerate adapters is
  not a path that exists.

Inside the container there is only `lo` and `eth0`. **Everything now hinges on producing a
`wlan0`** — which is Stage 1, and nothing else stands in front of it.

### Stage 1 — a real nl80211 phy in the container — **ATTEMPTED 2026-09-07, BLOCKED**

The device creates cleanly and Android finds it:

```bash
modprobe virt_wifi
nsenter -t <container-init-pid> -n ip link add wlan0 link eth0 type virt_wifi
nsenter -t <container-init-pid> -n ip link set wlan0 up
```

`wlan0@eth0` appears in the container and wificond's complaint *changes* — real progress. It also
produced the framework's own words on the no-vendor-HAL path:

```
WifiNative:  Vendor Hal not supported, ignoring start.
WifiNative:  Vendor Hal not supported, ignoring createStaIface.
wificond:    No wiphy is found
wificond:    Failed to get wiphy index
WifiNative:  Failed to setup iface in wificond=wlan0
```

**The blocker: `virt_wifi` puts the netdev in the container's netns but leaves its wiphy in the
host's.** `iw dev` inside the container shows nothing, while the host shows `phy#1 / Interface
wlan0` carrying the container's `ifindex 4`. nl80211 is scoped by wiphy namespace, so wificond —
running inside the container — cannot see it.

The canonical fix is refused:

```
$ iw phy phy1 set netns <container-init-pid>
command failed: Operation not supported (-95)
```

`-EOPNOTSUPP` is `cfg80211_switch_netns()` declining because **stock `virt_wifi` never sets
`WIPHY_FLAG_NETNS_OK`**; nor does it call `wiphy_net_set()`, so the wiphy is pinned to `init_net`
regardless of which namespace the link is created from. Evidence in `artifacts/wifi/stage1/`.

*Harmless while it sits there:* `virt_wifi`'s rx handler returns `RX_HANDLER_PASS` while the fake
link is disconnected, so `eth0` kept working and the container held its DHCP lease throughout. The
`EthernetService` conflict this stage anticipated never arose, because association never happened.
Nothing persists across a reboot; `ip link del wlan0` removes it.

### The fork this forces — decide before going further

Getting a wiphy the container can see is now a choice between two paths — and it is the *same*
choice the plan had deferred to Stage 4, arriving three stages early:

| | **Path K — patch `virt_wifi`** | **Path U — replace `wificond`** |
|---|---|---|
| Kernel work | ~2 lines: set `WIPHY_FLAG_NETNS_OK`, add `wiphy_net_set(wiphy, src_net)` | none |
| Userspace work | none yet; stock wificond throughout | implement `wifinl80211`, ~10 AIDL interfaces |
| Scan results (Stage 4) | same module gains BSS injection — one artifact solves both problems | synthesized from NM directly |
| Needs a wiphy at all | yes | **no** — `wlan0` only has to be a netdev for IpClient |
| Survives a kernel update | **no** — out-of-tree rebuild every time, on a host that updates often | yes |

Secure Boot is disabled and in Setup Mode, so an unsigned out-of-tree module will load and Path K is
genuinely open. But Path U's case got stronger rather than weaker: if wificond is going to be
replaced in Stage 4 anyway to show real SSIDs, then **the wiphy problem disappears entirely** and
the netdev already sitting in the container is all that is needed.

**DECISION, 2026-09-07: Path U.** No kernel work. The stages below are restructured accordingly,
and the exact interface surface is now pinned in
[30-wifi-aidl-surface.md](30-wifi-aidl-surface.md).

Two consequences of that choice, both worth stating plainly:

- **The prebuilt-supplicant shortcut is dead.** A stock `wpa_supplicant` drives nl80211 against a
  real phy; with no phy it has nothing to talk to. There is no borrowed-binary baseline to bisect
  against, so the first green light only comes once our own services exist.
- **Everything is AIDL on `/dev/binder`.** Both halves speak one dialect to `servicemanager` — see
  [30](30-wifi-aidl-surface.md). Simpler than the mixed HIDL/AIDL design this plan first assumed.

### Stage 2 — `waydroid-wifid` skeleton, and a client interface that stays up — **DONE, 2026-09-08**

Host daemon, C++ over libgbinder on `/dev/binder`, registering **`wifinl80211`** and implementing
`IWificond`, `IClientInterface` and `IWifiScannerImpl`. A netdev named `wlan0` must exist for netd's
observer, but at this stage it carries no traffic — `bin/wifi-wlan0.sh up` adds a `dummy` inside the
container's netns.

**It worked, and the target evidence is exactly the inverse of Stage 1's failure:**
`Successfully setup Iface:{Name=wlan0,Id=5,Type=STA_SCAN}`, `entering ScanOnlyModeState`,
`mClientInterfaceName: wlan0`, and no `Failed to setup iface in wificond`. Full writeup in
[31-wifi-stage2.md](31-wifi-stage2.md); evidence in `artifacts/wifi/stage2/`; verify with
`bin/wifi-test.sh`.

**One thing in this stage's framing was wrong and is corrected there: the toggle does *not* turn
on yet, and could not have.** Switching Wi-Fi on puts `ActiveModeWarden` into `ROLE_CLIENT_PRIMARY`,
which runs `setupInterfaceForClientInConnectivityMode()` — and that calls `startSupplicant()`
*before* it ever reaches wificond, so it fails with `Failed to start supplicant`. A wificond-only
shim can reach **scan-only mode** and no further, which is what Stage 3 below already said. The
toggle belongs to Stage 4.

Two things fell out of doing it:

- **A host process registering a service in the container's servicemanager is no longer an
  assumption.** Waydroid does it already — `tools/interfaces/IUserMonitor.py`, `IClipboard.py`,
  `INotifications.py` and `IHardware.py` are host-side python-gbinder objects in the guest's
  `/dev/binder` domain. The SELinux risk below is retired by the running system, not by our code.
- **`IScanEvent.OnScanResultReady` at code 1 is confirmed at runtime**, which is the first answer to
  [30](30-wifi-aidl-surface.md)'s one unverifiable question — callback transaction codes. The same
  technique settles the supplicant's two callbacks in Stage 4.

### Stage 3 — real SSIDs from the host, in Android's scan results — **DONE, 2026-09-08**

The `NativeScanResult` parcelable layout was disassembled out of this image's `framework.jar`, the
same way the transaction codes were, and Android now lists the host's real access points with the
right names, signal strengths and security flags. Writeup in [32-wifi-stage3.md](32-wifi-stage3.md);
evidence in `artifacts/wifi/stage3/`; verify with `bin/wifi-test.sh`.

**This stage's framing was one thing short, and it was the expensive half.** The layout was the
known job; two others were not:

- **Android has no "security type" field to fill in** — it parses the beacon's information elements
  and derives everything from them. NM keeps the conclusions and discards the beacon, so the IEs
  have to be *rebuilt* from those conclusions or every network shows up as open. That is now
  `wifi/NativeScanResult.cpp`, checked offline against a reimplementation of Android's own parser.
- **`tsf` is load-bearing.** `WificondScannerImpl` silently discards every result older than the
  scan it asked for, so a zero timestamp — or announcing completion before the host has really
  scanned, which is what Stage 2 did — empties the list with nothing in the log to explain it.
  `WifiBackend` gained `onScanComplete()` and `NmBackend` now watches NM's `LastScan`.

Doing it properly also **corrected a Stage 2 bug**: `securityFromFlags()` reported any AP offering
SAE as WPA3-only, when one offering PSK *and* SAE is a WPA2/WPA3 transition AP — a distinction
Android draws by the MFPR bit. There is now a `Security::Wpa2Wpa3Psk`.

**Proves the backend contract end-to-end**, which was the point of aiming at this stage. One
correction to the heading it used to carry: the results are what apps and `cmd wifi
list-scan-results` see, **not yet the Settings picker**, which needs the master toggle — and the
toggle needs the supplicant. That is Stage 4, exactly as [31](31-wifi-stage2.md) said.

`SingleScanSettings` is still not parsed; the condition this plan attached to it — a backend that
can act on a channel list or a hidden-SSID list — has not been met.

### Stage 4 — supplicant shim, credentials, and a `wlan0` that carries traffic

Add `ISupplicant` / `ISupplicantStaIface` / `ISupplicantStaNetwork` plus the two callbacks
(AIDL **v1**), declared through a VINTF fragment in the vendor overlay so `isDeclared()` selects the
AIDL path over HIDL — the same mechanism the widevine fix already uses.

Then `wlan0` has to become real, because `IpClient` will run DHCP on it. The cheapest answer is to
**rename the container's uplink**: `lxc.net.0.name = wlan0` in the Waydroid LXC config. That also
disposes of the `EthernetService` conflict for free, since `config_ethernet_iface_regex` will no
longer match. Expect a window where the container has no network until the Wi-Fi path works —
plan the cutover, do not stumble into it.

**Proves the actual goal:** a password typed into Android's Wi-Fi dialog reaches
`setPskPassphrase()` in the clear and NetworkManager associates `wlp1s0` with that AP.

### Stage 5 — hardening *(before calling it done)*

- **Survive a `system_server` restart.** [16-waydroid-network.md](16-waydroid-network.md) is a
  direct warning here: a stale binder registration surviving a restart deadlocked the network stack
  for 38 minutes. `waydroid-wifid` must detect the restart and re-register rather than leaving a
  dead service name behind.
- Signal strength and state transitions that Android's UI believes.
- Saved networks synced both ways — forget in Android should forget in NM.
- Cleanly report P2P, SoftAP, RTT and NAN as unsupported rather than letting them fail oddly.
- SELinux, autostart ordering, packaging, and a `bin/wifi-test.sh` in the style of
  `bin/sensors-test.sh` and `bin/battery-test.sh`.

## Deliberately out of scope

Wi-Fi Direct / P2P, SoftAP and tethering, RTT, NAN/Aware, WPA3-Enterprise, 6 GHz, and MAC
randomization semantics. Each is a feature Android can be told it does not have. If someone wants
them later, the backend contract is where they would land.

## Risks, and where each is resolved

| Risk | Resolved at |
|---|---|
| ~~Feature XML alone does not start `WifiService`~~ | **resolved 2026-09-07 — it does** |
| ~~No-vendor-HAL path does not exist in Android 13~~ | **resolved 2026-09-07 — `mWifi: null` and the framework carried on regardless** |
| Which supplicant interface T binds — HIDL 1.4 vs AIDL v1/v2 | before Stage 3, offline (below) |
| No usable prebuilt supplicant for x86_64 A13 | moot — Path U killed the prebuilt shortcut |
| ~~SELinux blocks a host daemon serving these particular services~~ | **resolved 2026-09-08 — `wifinl80211` registered from the host; Waydroid's own `IUserMonitor`/`IClipboard` were doing this all along** |
| Kernel-module maintenance burden | avoided if the Path K/U fork goes userspace |
| **`virt_wifi` pins its wiphy to `init_net`** — netdev is namespaced, wiphy is not | **found 2026-09-07**; forces the Path K/U fork above |
| Waydroid image updates wiping assumptions | overlay files survive; image contents may not |

## Answered — see [30-wifi-aidl-surface.md](30-wifi-aidl-surface.md)

1. ~~Which supplicant interface does Android 13 bind?~~ **Both ship.** Selection is by VINTF
   declaration (`AIDL service declared:` in the dex), and the AIDL is **version 1**. We choose AIDL.
2. ~~Does `WifiNative` have the no-vendor-HAL branch?~~ **Yes** — proven at runtime in Stage 0, not
   just in the bytecode: `Vendor Hal not supported, ignoring createStaIface`.
3. **Trap found while doing it:** the module is jarjar-shaded to `com.android.wifi.x.…`, but the
   AIDL *wire descriptors are unshaded* — AIDL emits them `$`-separated with a runtime
   `.replace('$','.')` specifically to defeat jarjar. Grepping for the dotted form finds nothing and
   would wrongly suggest the AIDL path is missing.

Still open, and both need AOSP 13 source rather than this image:

- The exact `android.net.wifi.nl80211.*` AIDL definitions — binder transaction codes are positional,
  so method *order* matters, not just signatures.
- Which `IWificond` methods `WifiNl80211Manager` actually calls, so everything else can be a cheap
  stub. Needs the platform `framework.jar`, which has not been pulled yet.
- Which `config_wifi*` resources in `com.android.wifi.resources` would need an RRO.

## Repo layout

`wifi/` alongside `sensors/`, same shape: sources, a `build.sh` with the reasoning in its header
comment, and the backend contract in its own header so the extension point is obvious to anyone
arriving cold.
