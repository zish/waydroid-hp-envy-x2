# What the Wi-Fi shim has to implement, exactly

**Date:** 2026-09-07. **Status:** reference. Answers the "answer these first" questions in
[29-wifi-plan.md](29-wifi-plan.md), all of it offline on the dev box with **no host changes**.

## How this was obtained

The `com.android.wifi` APEX is a flattened directory in `system.img`, so the jars come straight out
of the read-only image without mounting it or running a container:

```bash
debugfs -R "dump /system/apex/com.android.wifi/javalib/service-wifi.jar /tmp/service-wifi.jar" \
        /etc/waydroid-extra/images/system.img
unzip -q service-wifi.jar -d sw && strings sw/classes.dex | ...
```

Raw output kept in `artifacts/wifi/interface-surface/aidl-surface.txt`.

## Finding 1 — both HIDL and AIDL supplicant paths ship; we may choose

`service-wifi.jar` contains **both** implementations:

```
SupplicantStaIfaceHalAidlImpl      SupplicantStaIfaceHalHidlImpl
SupplicantStaNetworkHalAidlImpl    SupplicantStaNetworkHalHidlImpl
```

together with HIDL descriptors for `@1.0` through `@1.4`, and the AIDL parcelables
(`AnqpData`, `BssTmData`, `ConnectionCapabilities`, …). So Android 13 here can be served either way.

Selection is by **service declaration**, evidenced by these literals in the dex:

```
AIDL service declared:
AIDL interface version: 1 (initial)
Successfully triggered start of supplicant using HIDL
```

`isDeclared()` is satisfied by a **VINTF manifest entry**, not merely by registering the service.
That is a mechanism this repo already uses — see the widevine fragment already sitting in
`/var/lib/waydroid/overlay/vendor/etc/vintf/manifest/`. So selecting the AIDL path means shipping
one more small XML file through the vendor overlay.

**The supplicant AIDL is version 1.**

## Finding 2 — the AIDL wire descriptors are *unshaded*, despite jarjar

This is the trap worth recording. The mainline Wi-Fi module is jarjar-shaded: the AIDL Java classes
appear in the dex as

```
Lcom/android/wifi/x/android/hardware/wifi/supplicant/ISupplicant;
```

A naive reading says the shim must advertise the `com.android.wifi.x.…` descriptor. **It must not.**
AIDL's Java backend deliberately emits the descriptor as a `$`-separated literal with a
`.replace('$', '.')` at runtime, precisely so that jarjar cannot rewrite it. The dex therefore holds:

```
android$hardware$wifi$supplicant$ISupplicant
android$hardware$wifi$supplicant$ISupplicantStaIface
android$hardware$wifi$supplicant$ISupplicantStaNetwork
android$hardware$wifi$supplicant$ISupplicantStaIfaceCallback
android$hardware$wifi$supplicant$ISupplicantStaNetworkCallback
android$hardware$wifi$supplicant$ISupplicantP2pIface          (not needed)
android$hardware$wifi$supplicant$ISupplicantP2pIfaceCallback  (not needed)
android$hardware$wifi$supplicant$ISupplicantP2pNetwork        (not needed)
```

so the on-the-wire names are the ordinary `android.hardware.wifi.supplicant.*` ones. Grepping the
dex for the dotted form finds nothing and would wrongly suggest the AIDL path is absent — it is the
`$` form or nothing.

## Finding 3 — wificond is a platform interface, also AIDL

The service name registered in `servicemanager` is the bare string **`wifinl80211`**, present in
`service-wifi.jar`. The types are referenced unshaded:

```
Landroid/net/wifi/nl80211/WifiNl80211Manager;
Landroid/net/wifi/nl80211/NativeScanResult;
Landroid/net/wifi/nl80211/NativeWifiClient;
Landroid/net/wifi/nl80211/PnoSettings;   PnoNetwork;   RadioChainInfo;
Landroid/net/wifi/nl80211/DeviceWiphyCapabilities;
```

The classes themselves are in **neither** jar — `IWificond` and friends live in the platform boot
classpath, not in the mainline module, so they are not shaded and their descriptor is plainly
`android.net.wifi.nl80211.IWificond`. Their AIDL definitions come from AOSP 13 source rather than
from this image.

## Consequence: Path U is one binder dialect end to end

Both halves of the shim are **AIDL on `/dev/binder`**, talking to `servicemanager`:

| Service | Descriptor | Instance |
|---|---|---|
| wificond replacement | `android.net.wifi.nl80211.IWificond` | `wifinl80211` |
| supplicant | `android.hardware.wifi.supplicant.ISupplicant` | `default` (VINTF-declared) |

No HIDL, no `hwservicemanager`, one marshalling style. That is a real simplification over the mixed
design assumed in [29](29-wifi-plan.md), and it is a direct consequence of choosing Path U — had we
kept stock wificond, only the supplicant would have been ours and HIDL would have been the easier
choice there, since `waydroid-sensord` already proves HIDL-over-libgbinder in this repo.

`/dev/binder` is bind-mounted from the host by `config_nodes` exactly as `/dev/hwbinder` is, so a
host daemon can serve both. That was verified while writing [29](29-wifi-plan.md).

## What must be implemented

**wificond side** — `IWificond` plus the objects it hands out:
`IClientInterface`, `IWifiScannerImpl`, `IScanEvent`, and for completeness `IPnoScanEvent`.
`IApInterface`, `ISendMgmtFrameEvent` and `IInterfaceEventCallback` can be stubs that fail cleanly,
since SoftAP is out of scope.

**supplicant side** — `ISupplicant`, `ISupplicantStaIface`, `ISupplicantStaNetwork` and the two
callback interfaces. The P2P trio is not needed; Wi-Fi Direct is explicitly out of scope.

**Not needed at all:** any vendor Wi-Fi HAL. Verified in Stage 0 — the framework logs
`Vendor Hal not supported, ignoring createStaIface` and carries on.

## Finding 4 — transaction codes, obtained and then verified against this image

Binder transaction codes are positional: `code = FIRST_CALL_TRANSACTION + declaration index`, and
`FIRST_CALL_TRANSACTION` is 1. Get the order wrong and every call lands on the wrong method, so this
was not taken on trust.

Sources fetched from AOSP tag **`android-13.0.0_r75`**, both as subdirectory tarballs, which avoids
cloning either repo:

```bash
curl -O https://android.googlesource.com/platform/system/connectivity/wificond/+archive/refs/tags/android-13.0.0_r75/aidl.tar.gz
curl -O https://android.googlesource.com/platform/hardware/interfaces/+archive/refs/tags/android-13.0.0_r75/wifi/supplicant/aidl.tar.gz
```

**Verification, and it is the point of this section.** `framework.jar` was pulled off the image the
same way as the module jars, and `IWificond$Stub$Proxy` disassembled out of `classes2.dex`. Each
proxy method loads its transaction code as a literal before calling `transact()`, so the image
states its own answer:

```
createApInterface = 1        GetClientInterfaces = 6      RegisterCallback = 13
createClientInterface = 2    GetApInterfaces = 7          UnregisterCallback = 14
tearDownApInterface = 3      getAvailable2gChannels = 8   registerWificondEventCallback = 15
tearDownClientInterface = 4  …5gNonDFS = 9, DFS = 10      unregisterWificondEventCallback = 16
tearDownInterfaces = 5       …6g = 11, 60g = 12           getDeviceWiphyCapabilities = 17
                                                          notifyCountryCodeChanged = 18
```

All eighteen match the AOSP r75 declaration order exactly. **LineageOS has not diverged here**, so
upstream AIDL can be used directly. Tables in `artifacts/wifi/interface-surface/`.

The same check was run across the supplicant: for all six interfaces the frozen
`aidl_api/android.hardware.wifi.supplicant/1/` snapshot and the live source declare methods in
identical order, so either can be used. Sizes are worth knowing before committing to the work:

| Interface | Methods |
|---|---|
| `ISupplicant` | 13 |
| `ISupplicantCallback` | 2 |
| `ISupplicantStaIface` | 61 |
| `ISupplicantStaNetwork` | **93** |
| `ISupplicantStaIfaceCallback` | 29 |
| `ISupplicantStaNetworkCallback` | 5 |
| **total** | **203** |

That corrects the "~80 methods, maybe 25 real" estimate in [29](29-wifi-plan.md): the supplicant
side alone is 203 method slots. Most are stubs returning "unsupported", but every one still needs
its slot, because a wrong count shifts every code after it.

## Finding 5 — only 13 of `IWificond`'s 18 methods are ever called

Disassembling `WifiNl80211Manager` from `framework.jar` shows which methods the framework actually
invokes:

```
createApInterface           getAvailable2gChannels          registerWificondEventCallback
createClientInterface       getAvailable5gNonDFSChannels    tearDownApInterface
getDeviceWiphyCapabilities  getAvailableDFSChannels         tearDownClientInterface
notifyCountryCodeChanged    getAvailable6gChannels          tearDownInterfaces
                            getAvailable60gChannels
```

Never called: `GetClientInterfaces`, `GetApInterfaces`, `RegisterCallback`, `UnregisterCallback`,
`unregisterWificondEventCallback`. Those need a slot but no behaviour.

Of the thirteen, only **`createClientInterface`** is load-bearing at first — it returns the
`IClientInterface` that everything else hangs off. The two AP ones can fail cleanly, since SoftAP is
out of scope.

## Finding 6 — the supplicant matches AOSP too, for the interfaces we call

The same bytecode cross-check was run against `service-wifi.jar`, and **147 proxy methods match
AOSP `android-13.0.0_r75` declaration order exactly**:

| Interface | Proxies in image | AIDL methods | Result |
|---|---|---|---|
| `ISupplicant` | 6 | 13 | match |
| `ISupplicantStaIface` | 56 | 61 | match |
| `ISupplicantStaNetwork` | 85 | 93 | match |

R8 strips proxy methods the framework never calls, which is why the counts are short of the AIDL
totals — but the **highest code in each interface is exactly the AIDL method count** (13, 61, 93),
so nothing has been renumbered. LineageOS has not touched this package.

### Two extraction traps worth recording

Both cost time and would silently produce plausible-but-wrong tables:

1. **`IBinder.transact` is `invoke-interface`, not `invoke-virtual`.** A regex expecting the latter
   matches nothing and looks like "no transactions found".
2. **"The last constant before `transact`" is the wrong constant.** `transact(code, data, reply,
   flags)` loads `flags` last, so that heuristic returns 0 for every two-way call and 1 for every
   one-way one. The code lives in **register\[1\] of the invoke's register list** — resolve that
   register against the last constant written to it.

The extractor was validated by reproducing the already-known `IWificond` table (18 methods, codes
1..18, no duplicates) before being pointed at anything unverified. Worth doing again for any future
interface: check the tool against a known answer first.

### What this check could not cover

The two **callback** interfaces — `ISupplicantStaIfaceCallback` (29 methods) and
`ISupplicantStaNetworkCallback` (5) — are unverified by this method, and the distinction matters:
the framework *implements* those, so it holds their `Stub`, not a `Proxy`, and there are no
`transact()` call sites to read codes from. Their `onTransact` uses a `sparse-switch` keyed partly
on the AIDL meta-codes (`0x00ffffff` `getInterfaceVersion`, `0x00fffffe` `getInterfaceHash`), and
the case blocks are **not** laid out in declaration order, so layout cannot be used to infer codes
either.

These are precisely the interfaces **our shim will call into**, so they are not academic. What
supports them anyway: three interfaces in the same package and version match exactly; frozen
`aidl_api/…/1/` and live source agree for all six; and the presence of stock stable-AIDL meta-codes
shows the codegen is unmodified. That makes divergence very unlikely but not proven.

Cheapest way to settle it is at runtime rather than statically: a wrong callback code shows up
immediately as the framework not reacting to an event, and it can be bisected in Stage 4 when
callbacks first fire. Parsing the `sparse-switch` payload is the static alternative if that turns
out to be painful.

## Still open

- Callback interface transaction codes — see above. Deliberately deferred to runtime.
- Which `config_wifi*` resources in `com.android.wifi.resources` would need an RRO.
