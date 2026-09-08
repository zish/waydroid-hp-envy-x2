# Wi-Fi Stage 3 — the host's real access points, in Android's scan results

**Date:** 2026-09-08. **Status:** done and verified on bigtab01. Plan:
[29-wifi-plan.md](29-wifi-plan.md). Wire format: [30-wifi-aidl-surface.md](30-wifi-aidl-surface.md).
Stage 2: [31-wifi-stage2.md](31-wifi-stage2.md). Evidence: `artifacts/wifi/stage3/`.

## What now works

Android's Wi-Fi framework asks for a scan, a **Linux daemon on the host** asks NetworkManager for
one, and the real access points come back with the right names, signal strengths and security:

```
  BSSID              Frequency  RSSI    Age(sec)  SSID                            Flags
  76:bd:71:0f:a5:c2       2412   -60       5.254  vidiot                          [WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS][MFPC]
  a4:2b:8c:16:5d:0e       2427   -68       5.254  my-wifi-can-beat-up-your-wifi   [WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS]
  7c:7e:f9:56:19:82       2462   -81       5.254  f48fc5                          [RSN-SAE-CCMP][ESS][MFPR][MFPC]
  aa:db:48:84:e1:4e       5220   -94       5.254  xfinitywifi                     [ESS]
```

This is the milestone [29](29-wifi-plan.md) aimed at: the backend contract proven end to end, NM's
scan rendered by Android's own Wi-Fi machinery. Verify with **`bin/wifi-test.sh`**.

Nothing about the *shape* of the daemon changed. Stage 3 is two things: a parcelable layout, and a
timestamp.

## The parcelable, read out of the image rather than assumed

`NativeScanResult` is a **custom** parcelable — its whole .aidl is

```
parcelable NativeScanResult cpp_header "wificond/scanning/scan_result.h";
```

so there is no generated marshaller to copy, no self-describing header on the wire, and nothing to
diff against. The layout is exactly what the reader's `createFromParcel()` does, in order. Getting
one field wrong does not produce a wrong scan result; it desynchronises the parcel and surfaces
later as something that looks unrelated.

So it was disassembled out of **this image's** `framework.jar`, the same way
[30](30-wifi-aidl-surface.md) did the transaction codes — kept in
`artifacts/wifi/stage3/nativescanresult-layout.txt`:

| | `NativeScanResult$1.createFromParcel` | |
|---|---|---|
| `createByteArray()` | ssid | null is replaced with `byte[0]` |
| `createByteArray()` | bssid | must be exactly 6 or `WifiNative` drops the result |
| `createByteArray()` | infoElement | the beacon IEs |
| `readInt()` | frequency | MHz |
| `readInt()` | signalMbm | **mBm**, i.e. dBm × 100 |
| `readLong()` | tsf | CLOCK_BOOTTIME microseconds, despite the name |
| `readInt()` | capability | the 802.11 capability field |
| `readInt()` | associated | 0/1 |
| `readTypedList()` | radioChainInfos | two ints each; an empty list is a single `0` |

The array framing came from the same place: `IWifiScannerImpl$Stub$Proxy.getScanResults` calls
`Parcel.createTypedArray`, which calls `readTypedObject` per element — so **each element is preceded
by its own non-null int32**, which a plain "count then bodies" writer would have got wrong.

## The information elements have to be invented, and that is the interesting half

**Android never reads a "security type" field, because 802.11 has none.** `WifiNative` hands the
`infoElement` blob to `InformationElementUtil.parseInformationElements()` and derives everything —
WPA2 vs WPA3, PSK vs EAP, which ciphers, whether management frame protection is required — by
parsing the RSN and WPA elements out of what is effectively a captured beacon.

A host backend has no beacon to forward. NetworkManager parsed one and threw it away, keeping the
conclusions. So the elements are rebuilt from those conclusions in `wifi/NativeScanResult.cpp`, and
the rule followed is that **only IEs carrying something the host actually told us are emitted**:

- the SSID element, always (zero-length for a hidden network, which is what a real beacon sends);
- one RSN element, or a WPA-1 vendor element, describing the security NM reported;
- nothing else — no rates, HT, VHT or HE elements. That costs an accurate `WifiStandard` badge
  (Android shows "unknown") and is the honest trade: this host does not know the AP's radio
  generation, and inventing one would put a plausible lie in the UI.

Two things fell out of doing this properly rather than picking defaults.

**The ciphers are observation, not assumption.** NM's `WpaFlags`/`RsnFlags` name the pairwise and
group cipher suites the AP advertised, so `Bss` grew `pairwiseCiphers`/`groupCiphers` masks and the
RSN element is built from them. Where a backend leaves them empty the code falls back to CCMP (RSN)
or TKIP (WPA-1) and the fallback is marked as such in one place.

**WPA2/WPA3 transition mode is a distinct thing and this found a Stage 2 bug.** An AP offering both
PSK and SAE is a transition-mode AP; a WPA3-only one offers SAE alone and *requires* management
frame protection. Android separates them exactly by the MFPR bit. Stage 2's `securityFromFlags()`
returned `Wpa3Sae` as soon as it saw SAE, so the house AP `vidiot` was being reported as WPA3-only
when it is not. There is now a `Security::Wpa2Wpa3Psk` and the element carries both AKMs with
`[MFPC]` and not `[MFPR]` — which is what the device now shows.

The synthesis is checked **offline**, without a device, because it is the one invented part:
`buildBeaconIes()` is compiled standalone and its bytes fed back through a reimplementation of
Android's parser. See `artifacts/wifi/stage3/ie-synthesis-check.txt`; every case produces the
capability string a real AP of that type produces.

## The timestamp is load-bearing, and this is the trap

`WificondScannerImpl.pollLatestScanData()` does this to every result:

```java
if (result.timestamp >= mLastScanSettings.startTimeNanos / 1_000) { ...keep... }
else { numFilteredScanResults++; }
```

**Every result older than the scan Android asked for is silently discarded.** Two consequences that
would each have produced an empty, unexplained picker:

- `tsf` must be a real CLOCK_BOOTTIME microsecond instant, not zero and not an age. NM publishes
  `AccessPoint.LastSeen` in boottime *seconds*, which converts directly. The container shares the
  host's kernel, so the two clocks are the same clock — that is why this works at all.
- **Announcing the scan finished before it has is worse than not announcing it.** Stage 2 fired
  `OnScanResultReady` from an idle callback the moment `RequestScan` returned. That delivered the
  *previous* scan's list straight into the stale filter. `WifiBackend` therefore gained
  `onScanComplete()`, and `NmBackend` watches `Device.Wireless.LastScan` — boottime milliseconds of
  the last *finished* scan, the only completion signal NM offers, since it has no "scan done"
  signal — until it advances past where it stood when we asked.

That it is load-bearing is not a theory. The device says so:

```
D WifiNl80211Manager: Scan result ready event
D WificondScannerImpl: Filtering out 8 scan results.
```

21 access points written, 8 dropped as older than the scan, 13 delivered — the 8 being APs NM
remembered but did not see this time round. That is correct behaviour, and it is the same mechanism
that would have dropped all 21.

`LastScan` is polled at 2 Hz while a scan is outstanding rather than watched through
`PropertiesChanged`. A property read on the local system bus is nearly free, the poll runs for a few
seconds a few times a minute, and it avoids a signal subscription whose match rules and lifetime
would be more code than the thing they replace. `NmBackend::startScan()` is the only place that
would have to change.

## Things that were checked rather than assumed

- **An over-long SSID would crash system_server, so the daemon drops it.** `WifiSsid.fromBytes()`
  throws above 32 bytes and `convertNativeScanResults()` does **not** catch it — the throw would
  come out on system_server's wifi thread. `writeScanResultArray()` drops such a BSS and logs it.
  Truncating was rejected: that invents a network name.
- **`RequestScan` needs authorization.** As an ordinary user it fails with
  `org.freedesktop.NetworkManager.wifi.scan request failed: not authorized`. The daemon runs as
  root and is fine, but a future attempt to drop privileges will hit this first.
- **Empty and null byte arrays are still different to Java**, as
  [31](31-wifi-stage2.md) found; a hidden network's zero-length SSID element depends on it.
- **`getPnoScanResults()` returns an empty array and that is not the same answer as
  `getScanResults()`.** `startPnoScan()` returns false, so no PNO scan has ever run and there is no
  PNO result set. Returning the single-scan list there would be inventing one.

## What this still does not do

- **The Wi-Fi master toggle still does not stay on**, unchanged from
  [31](31-wifi-stage2.md) and for the same reason: `ROLE_CLIENT_PRIMARY` calls `startSupplicant()`
  before it ever reaches wificond. Scan-only mode is the honest ceiling for a wificond-only shim.
  So the results above are what an app calling `WifiManager.getScanResults()` sees and what
  `cmd wifi list-scan-results` prints — **the Settings Wi-Fi picker will not render them until the
  toggle stays on, which is Stage 4.** The data is real; the screen that displays it is not
  reachable yet.
- `SingleScanSettings` is still not parsed. The plan made this conditional on a backend that can
  act on a channel list or a hidden-SSID list, and that condition has not been met — NM's
  `RequestScan` takes an `ssids` hint but nothing below the contract uses one yet.
- Signal strength is still NM's 0..100 `Strength` mapped back to dBm, not a measured RSSI. It is a
  mapping, not a measurement; it would improve with a backend reading nl80211 directly.
- `WifiStandard` is unknown for every network, by choice — see above.
- `Bss.known` is still always false, and `onStateChanged()` still never fires. Stage 4/5.

## Running it

```bash
# dev box
wifi/build.sh --install

# bigtab01
sudo bin/wifi-wlan0.sh up                       # if wlan0 is not there already
sudo waydroid-wifid --verbose &
bin/wifi-test.sh
```

**If the daemon is restarted while Android is up, the framework does not come back on its own.**
`WifiNl80211Manager` logs `Failed to get reference to wificond`, `ClientModeManager` reports
`Failed to create ClientInterface. Sit in Idle`, and it stays there. Kick it with

```bash
sudo waydroid shell -- cmd wifi set-scan-always-available disabled
sudo waydroid shell -- cmd wifi set-scan-always-available enabled
```

which makes `ActiveModeWarden` restart the scan-only manager and re-resolve the service. This is a
symptom of the same gap Stage 5 has to close for `system_server` restarts, seen from the other
direction — see [16-waydroid-network.md](16-waydroid-network.md).

There is still **no autostart**; packaging is Stage 5.
