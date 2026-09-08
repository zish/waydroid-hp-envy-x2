# Wi-Fi Stage 2 — `waydroid-wifid`, and Android's wificond replaced from the host

**Date:** 2026-09-08. **Status:** done and verified on bigtab01. Plan:
[29-wifi-plan.md](29-wifi-plan.md). Wire format: [30-wifi-aidl-surface.md](30-wifi-aidl-surface.md).
Evidence: `artifacts/wifi/stage2/`.

## What now works

Android's Wi-Fi framework brings up a client interface, keeps it up, and asks it to scan — and
every one of those calls is answered by a **Linux daemon running on the host**, not by anything
inside the container.

```
09-07 23:34:46.664 D WifiNl80211Manager: Setting up interface for client mode: wlan0
09-07 23:34:46.665 I WifiNative:  Interface state changed on Iface:{Name=wlan0,Id=5,Type=STA_SCAN}, isUp=true
09-07 23:34:46.665 I WifiNative:  Successfully setup Iface:{Name=wlan0,Id=5,Type=STA_SCAN}
09-07 23:34:46.665 D WifiClientModeManager[wlan0]: entering StartedState
09-07 23:34:46.665 D WifiClientModeManager[wlan0]: entering ScanOnlyModeState
09-07 23:34:46.665 V WifiClientModeManager[wlan0]: ClientModeManager started in role: ROLE_CLIENT_SCAN_ONLY
```

That is the exact inverse of Stage 1, which died at `Failed to setup iface in wificond=wlan0`.
`dumpsys wifi` now reports `mClientInterfaceName: wlan0` against a live manager rather than `null`.

The daemon's own log for the same window shows the framework walking wificond's object hierarchy
end to end:

```
[waydroid-wifid] Registered "wifinl80211"
[waydroid-wifid] registerWificondEventCallback()
[waydroid-wifid] createClientInterface(wlan0) -> serving IClientInterface
[waydroid-wifid] getWifiScannerImpl()
[waydroid-wifid] subscribeScanEvents()
[waydroid-wifid] subscribePnoScanEvents()
[waydroid-wifid] scan() -> true
[waydroid-wifid] -> IScanEvent.OnScanResultReady
```

Verify any time with **`bin/wifi-test.sh`**, which checks positively for the client interface and
for the absence of the Stage 1 failure lines rather than for silence.

## What this does *not* do yet, and why

**The Wi-Fi master toggle still does not stay on.** This corrects the plan, which put "Wi-Fi that
turns on" in Stage 2. Turning the toggle on puts `ActiveModeWarden` into `ROLE_CLIENT_PRIMARY`,
which goes through `WifiNative.setupInterfaceForClientInConnectivityMode()`, and that calls
`startSupplicant()` **before** it ever reaches wificond:

```
09-07 23:34:40.353 I WifiService: setWifiEnabled ... enable=true
09-07 23:34:40.354 E WifiNative: Failed to connect to supplicant
09-07 23:34:40.354 E WifiNative: Failed to start supplicant
```

So the honest ceiling for a wificond-only shim is **scan-only mode**, which is precisely what the
plan's own Stage 3 says (`ROLE_CLIENT_SCAN_ONLY` needs no supplicant at all). Stage 2 and Stage 3
are therefore the same milestone approached from two sides; the toggle belongs to Stage 4 with the
supplicant. Nothing is broken by this — it is a boundary that was drawn one stage too early.

**Scan results are still empty.** `IWifiScannerImpl.getScanResults()` returns a zero-length array.
The host half is already done — `waydroid-wifid --scan` prints the real AP list through the backend
contract, with no container involved:

```
backend: networkmanager, radio: wlp1s0, enabled: yes
15 access points
  vidiot                           76:bd:71:0f:a5:c2   2412 MHz   -71 dBm  wpa3-sae
  my-wifi-can-beat-up-your-wifi    a4:2b:8c:16:5d:0e   2427 MHz   -74 dBm  wpa2-psk
  ...
link: associated to vidiot
```

What is missing is only the `NativeScanResult` parcelable layout, which has to be read out of
`framework.jar` the same way the transaction codes were. That is Stage 3 and it is now the whole of
Stage 3.

**Done on the same day — [32-wifi-stage3.md](32-wifi-stage3.md).** Two things in this section turned
out to be understatements. The layout was the easy half: Android has no security field and derives
everything by parsing beacon information elements, which a host backend has to synthesise; and the
scan-completion notification below is wrong — announcing results before the host has really scanned
delivers them straight into a stale filter. Both are corrected there.

## What was built

`wifi/`, alongside `sensors/` and in the same shape:

| File | |
|---|---|
| `WifiBackend.h` | the pluggable host-side contract. No Android or binder type appears in it |
| `NmBackend.{h,cpp}` | NetworkManager over the system D-Bus — devices, radio enable, scan, AP list, link state |
| `AidlParcel.h` | the handful of AIDL body conventions libgbinder does not cover |
| `Wificond.{h,cpp}` | `IWificond` + `IClientInterface` + `IWifiScannerImpl`, and the `IScanEvent` client |
| `service.cpp` | registration, single-instance lock, servicemanager presence handling |
| `build.sh` | builds on the dev box, links against .so files copied off the host |

Plus `bin/wifi-wlan0.sh` (the container netdev) and `bin/wifi-test.sh` (verification).

The backend contract gained one method beyond the plan's fourteen: `frequencies(Band)`. `IWificond`
has five `getAvailable*Channels()` calls and the answer is a property of the host radio, which is
exactly what lives below the line.

## Things that were checked rather than assumed

**A host process really can register a service in the container's servicemanager.** The plan called
this "sensors is precedent but not proof", since sensors uses hwbinder and HIDL. It is proof now,
and there was a closer precedent all along: **Waydroid itself does this**. `tools/interfaces/`
contains `IUserMonitor.py`, `IClipboard.py`, `INotifications.py` and `IHardware.py`, each a
host-side python-gbinder local object registered into the container's `/dev/binder` domain. So the
SELinux question was already answered by the running system before we wrote a line.

**`wifinl80211` is in the image's `service_contexts`** (`u:object_r:wifinl80211_service:s0`), which
matters because servicemanager refuses to add a name it cannot label. Read straight out of
`system.img` with `debugfs`, no mount.

**The protocol is `aidl3`, and it must be passed explicitly.** Android 13 is API 33; Waydroid's own
`tools/helpers/protocol.py` maps that to `binder_protocol = aidl3` / `service_manager_protocol =
aidl3` and cached exactly those values in `/var/lib/waydroid/waydroid.cfg`. libgbinder's *built-in*
default for `/dev/binder` is the much older `"aidl"`, whose RPC header is one `int32` shorter (no
`'SYST'` word) and which does not write the binder stability marker at all. Taking the default
would have desynchronised every parcel.

**One of doc 30's open questions is now answered at runtime.** That doc could not verify the
transaction codes of *callback* interfaces, because the framework holds their `Stub` and there is
no `Proxy` bytecode to read; it deferred the question to runtime. `IScanEvent.OnScanResultReady` at
code 1 is now confirmed working — the daemon sent it and `WifiNl80211Manager: Scan result ready
event` came back. The same method (call it and watch) will settle the supplicant's two callback
interfaces in Stage 4.

## Traps hit

- **`ctl.stop wificond` does not necessarily stop wificond.** `getprop init.svc.wificond` sat at
  `stopping` indefinitely — init had asked, the process had not gone. A `kill -9` from the host
  finished it, and init then reported `stopped` and did **not** restart it, because the ctl.stop
  request was still honoured. Do not read "the stop command returned" as "the service is gone";
  check `init.svc.<name>` and the process list.
- **Both wificonds want the same name.** `addService()` overwrites, so whichever registered last
  owns `wifinl80211`. That is a race, not a design. `artifacts/overlay/system/etc/init/wificond.rc`
  is the stock rc with `disabled` added, which stops init auto-starting it; the original is beside
  it. **Not deployed yet** — it needs a `waydroid container restart`. Nothing else starts wificond:
  the wifi module's dex contains no `ctl.start` string at all.
- **`gbinder_reader_read_nullable_object()` returns `gboolean` and writes through an out-param**,
  unlike `gbinder_reader_read_object()` which returns the object. Both hand back a reference the
  caller owns.
- **An empty array and a null array are different to Java.** `gbinder_writer_append_byte_array()`
  writes `-1` (i.e. null) for a zero-length array, which `Parcel.createByteArray()` reads back as
  `null`. `AidlParcel.h` writes the zero by hand for that case.

## Why wlan0 is a dummy

Android's `WifiNative` registers a netd observer on the interface and calls `isInterfaceUp()`, so
`wlan0` has to exist as a netdev before the framework will finish. It does **not** have to be a
real 802.11 device, because Path U means nothing in this design talks to nl80211 — that is the
whole point of replacing wificond rather than patching `virt_wifi`.

`bin/wifi-wlan0.sh up` creates `wlan0` as a `dummy` inside the container's network namespace;
`down` removes it. Nothing survives a reboot. Stage 4 replaces this by renaming the container's
real uplink (`lxc.net.0.name = wlan0`), which also disposes of the `EthernetService` conflict for
free — but that costs a window with no container network, so it is deliberately not done yet.

## Running it

```bash
# dev box
wifi/build.sh --install

# bigtab01
sudo bin/wifi-wlan0.sh up
sudo waydroid shell -- setprop ctl.stop wificond     # then confirm it actually died
sudo pkill -x wificond
sudo waydroid-wifid --verbose &
bin/wifi-test.sh
```

To revert completely: kill the daemon, `bin/wifi-wlan0.sh down`, and `waydroid container restart`
brings stock wificond back. Delete `/usr/local/bin/waydroid-wifid` to remove the binary. No overlay
file, no image change, no layered package, no reboot.

There is **no autostart yet** — unlike `waydroid-sensord`, the name `waydroid-wifid` means nothing
to Waydroid, so nothing launches it. Packaging is Stage 5.

## Still open at the end of Stage 2

- `NativeScanResult` marshalling — all of Stage 3.
- The supplicant, and with it the master toggle and any actual connection — Stage 4.
- `SingleScanSettings` is not parsed. Nothing below the contract can act on a channel list or a
  hidden-SSID list yet, so reading it would be ceremony.
- `getDeviceWiphyCapabilities()` returns null, which `WifiNative` accepts.
- The channel lists are the standard regulatory-agnostic sets, not the radio's real capability —
  NetworkManager does not publish that. Harmless while scan results come from NM regardless of what
  Android asks for.
- **Written but not exercised:** the servicemanager presence handler that re-registers after a
  `system_server` restart. [16-waydroid-network.md](16-waydroid-network.md) is the reason it exists
  — a stale binder registration once deadlocked Android's network stack for 38 minutes — but it has
  not been provoked yet. That is Stage 5's first item.
- `Bss.known` is always false and `onStateChanged()` is stored but never fires. Both are Stage 4/5
  work; the contract carries them so the call sites above the line can already be written.
