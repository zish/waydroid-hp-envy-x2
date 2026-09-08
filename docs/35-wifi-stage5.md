# Wi-Fi Stage 5 — surviving a reboot, and the SELinux rule that made it impossible

**Date:** 2026-09-08. **Status: partially complete.** The daemon now runs under systemd and comes
back on its own; the reason it could not have worked before is the interesting part and is recorded
in full below. Items still open are listed under ["What is still
open"](#what-is-still-open).

Stage 5 is the hardening list from [29-wifi-plan.md](29-wifi-plan.md) and the "what is still broken"
section of [34-wifi-second-radio.md](34-wifi-second-radio.md). This session took the first two
items: a systemd unit, and the framework not coming back after the daemon restarts.

## The headline: the daemon only ever worked because it was started by hand

Installing the unit and starting the service worked — both names registered, no errors, zero AVC
denials. Android then failed to bring Wi-Fi up, in a way that pointed nowhere:

```
E WifiNl80211Manager: Failed to refresh wificond scanner due to remote exception
E JavaBinder: !!! FAILED BINDER TRANSACTION !!!  (parcel size = 152)
E SupplicantStaIfaceHalAidlImpl: ISupplicantStaIface.registerCallback failed with remote exception:
E SupplicantStaIfaceHalAidlImpl: android.os.DeadObjectException: Transaction failed on small parcel;
    remote process probably died, but this could also be caused by running out of binder buffers
```

`DeadObjectException` says the remote died. The remote had not died — it was running, and the
daemon's own journal showed it *serving the very transactions either side of the failing ones*:

```
17:30:23.232 createClientInterface(wlan0) -> serving IClientInterface
17:30:23.233 getWifiScannerImpl()
17:30:23.234 addStaInterface(wlan0) -> serving ISupplicantStaIface
17:30:23.235 unsubscribeScanEvents()
17:30:23.235 tearDownClientInterface(wlan0)
```

That log is what breaks the case open, because it makes the pattern visible:

| Call | Carries a binder? | Result |
|---|---|---|
| `createClientInterface(wlan0)` | no | **works** |
| `getWifiScannerImpl()` | no | **works** |
| `addStaInterface(wlan0)` | no | **works** |
| `subscribeScanEvents(IScanEvent)` | **yes** | fails |
| `ISupplicantStaIface.registerCallback(cb)` | **yes** | fails |

Every transaction that passes a binder reference fails and every transaction that does not succeeds.
That is not what a dead process looks like. It is what an SELinux rule looks like.

### The rule

`binder` is an SELinux class with four permissions, and `call` and `transfer` are different ones.
`transfer` governs passing a binder *reference* through a transaction. Querying the host's own
policy, with `container_runtime_t` as the domain Waydroid's `system_server` runs in:

```
binder call      unconfined_u:unconfined_r:unconfined_t:s0      : ALLOW
binder transfer  unconfined_u:unconfined_r:unconfined_t:s0      : ALLOW
binder call      system_u:system_r:unconfined_service_t:s0      : ALLOW
binder transfer  system_u:system_r:unconfined_service_t:s0      : DENY      <---
```

The query prints the denial itself:

```
avc: denied { transfer } for scontext=system_u:system_r:container_runtime_t:s0
     tcontext=system_u:system_r:unconfined_service_t:s0 tclass=binder permissive=0
```

And the direction matters — the reverse is allowed, which is why the daemon could return
`IClientInterface` and `ISupplicantStaIface` to Android perfectly well:

```
daemon->android  binder transfer  from unconfined_service_t : ALLOW
```

`systemd` runs a `bin_t` executable as `unconfined_service_t`. An interactive ssh login is
`unconfined_t`. **Every part of Stages 2, 3 and 4 was verified against a daemon started by hand from
an ssh session**, which is the one domain in which this works. Nothing about the code was ever
right or wrong here; the daemon had simply never been run the way it will be run.

Reproduce the query with no privilege at all:

```bash
python3 -c '
import selinux
ss = "system_u:system_r:container_runtime_t:s0"
for tgt in ["unconfined_u:unconfined_r:unconfined_t:s0",
            "system_u:system_r:unconfined_service_t:s0"]:
    for perm in ["call", "transfer"]:
        try:
            selinux.selinux_check_access(ss, tgt, "binder", perm); r = "ALLOW"
        except PermissionError: r = "DENY"
        print(f"binder {perm:9s} {tgt:46s}: {r}")'
```

### Why nothing was logged

`sudo ausearch -m avc -ts today` returned nothing, before and after. The rule is `dontaudit`ed, so
the kernel refuses the transfer and records no denial. This is the trap within the trap: the
standard first move on an SELinux-enforcing host — check for denials — actively produces the wrong
answer here, and did. **`setenforce 0` would have settled it in one command and was never reached,
because there was no reason to suspect SELinux with a clean audit log.** The evidence that
eventually pointed at it came from the daemon's own log, not from the security subsystem.

### The fix, and the fix that was rejected

One line in the unit:

```ini
SELinuxContext=system_u:unconfined_r:unconfined_t:s0
```

`system_u` is authorized for `unconfined_r` in the targeted policy (`semanage user -l`), so this is
a valid context and needs no policy change at all. It puts the daemon back in exactly the domain
every prior stage was verified in.

**A policy module was considered and rejected as the weaker option.** Granting
`container_runtime_t -> unconfined_service_t : binder transfer` would let Android pass binder
references to *every* unconfined service on the host, forever, to fix one daemon. `SELinuxContext=`
grants nothing to anything and is reverted by deleting a line.

Verified after the change:

```
$ ps -eZ | grep waydroid-wifid
system_u:unconfined_r:unconfined_t:s0 442283 ? waydroid-wifid

$ cmd wifi status
Wifi is enabled
ConcreteClientModeManager{id=107201960 iface=wlan0 role=ROLE_CLIENT_PRIMARY}
Wifi is connected to "vidiot"
NetworkCapabilities: [ Transports: WIFI Capabilities: ...&INTERNET&...&VALIDATED... ]
```

Association, DHCP and Android's own connectivity validation, from a daemon systemd started.

## The unit

[artifacts/wifi/waydroid-wifid.service](../artifacts/wifi/waydroid-wifid.service), installed by
`wifi/build.sh --install --unit`. Three decisions in it are load-bearing.

**It does not depend on the container.** `Requires=dev-binderfs.mount` and nothing else, and
`ExecStart` names `/dev/binderfs/binder` rather than `/dev/binder`. `/dev/binder` is a symlink
created by `waydroid-container.service`'s `ExecStartPre`, so using it would have quietly made the
container a startup dependency — and the daemon is deliberately built to *outlive* the container,
waiting for the guest's servicemanager and re-registering from its presence handler. Ordering it
after the container would throw that away. Verified: `[gbinder] Opened /dev/binderfs/binder
version 8`, then it waits, then both names register.

**No start rate limit.** `StartLimitIntervalSec=0`, because a `--device` that does not resolve is
fatal by design and an absent USB adapter must present as "keep trying", not as "give up after
five". At `RestartSec=5` that is one journal line every five seconds while the adapter is genuinely
gone.

**Not sandboxed, deliberately, and both obvious directives are wrong here.** `PrivateTmp=yes` would
break the single-instance guard — `/tmp` is the last of the daemon's three lock-file locations, so a
private `/tmp` would let a systemd instance and a hand-started one each hold a lock and both
register services. `NoNewPrivileges=yes` can suppress the SELinux domain transition, which after the
above is the one thing that must not happen.

Arguments live in [/etc/waydroid-wifid.conf](../artifacts/wifi/waydroid-wifid.conf), which
`--install --unit` will not overwrite once it exists.

## Radio identity: a MAC, not an interface name

[34](34-wifi-second-radio.md) recorded that `wlp0s20u1` encodes the USB port and renames when the
adapter moves, and that "anything unattended should key off something stable". The unit *is* the
unattended thing, so `--device` now takes either an interface name or a factory MAC:

```
WAYDROID_WIFID_ARGS=--device 34:E8:94:F8:61:70 --verbose
```

Told apart by shape, which is unambiguous rather than lucky: a MAC is 17 characters and an interface
name can never be, since `IFNAMSIZ` is 16 including the terminator.

**It has to be the factory MAC, not the current one.** NetworkManager randomizes the address in use
— on this host `wlp1s0`'s permanent `60:57:18:0A:E8:B7` was answering as `DE:FA:B4:68:D3:C7`, and
the T3U's permanent `34:E8:94:F8:61:70` as `86:CA:08:B0:52:94`. So `HwAddress` identifies nothing
across a reconnect and `PermHwAddress` is the property to read. `NmBackend::macAddress()`, which
tells *Android* the MAC, deliberately still reports `HwAddress`: that one is about what is on the
air, not about which adapter this is, and confusing the two is easy.

Two further properties fall out of pinning:

- **Selection by name now pins to hardware too.** The name resolves the radio once, and the factory
  MAC is remembered from that point. Otherwise `--device wlp0s20u1` would follow whatever wears the
  name next, which after a re-plug can be a different adapter — possibly the host's own.
- **A rename is survivable.** When the name stops resolving, `wifiDevicePath()` looks the hardware up
  by MAC and adopts the new name, logging `radio X is now Y (factory MAC Z)`. This is the same move
  `waydroid-sensord` makes after an ITE8350 reprobe
  ([19](19-sensor-hub-suspend-wedge.md)), and it means `bin/wifi-radio-reset.sh` costs the daemon
  nothing even if the reprobe renames the interface. That script's closing advice was corrected
  accordingly.

### `init()` now chooses the radio, and that retires a trap

Selection used to be a separate `selectDevice()` call after `init()`. [34](34-wifi-second-radio.md)
change 3 records what that cost: called *before* `init()` it validated nothing at all for as long as
it existed, and called *after*, the backend auto-selected a radio it was about to be told not to use
— visible as the same "using host radio" line twice in the log.

`init(spec)` takes the requested radio, so there is no order to get wrong. A non-empty spec that does
not resolve is fatal; an empty one auto-selects as before. `--devices` still lists what the host has
even when the named radio is missing, since that is exactly when the list is wanted —
`waydroid-wifid --devices --device <mac>` is now the way to check a MAC before writing it into the
conf file.

## Why Android does not come back by itself

[29](29-wifi-plan.md) predicted the daemon's half of this and asked for the other half: "provoke the
framework into retrying afterwards", suggesting an `IWificondEventCallback` might be the clean
trigger. **No callback is needed, because the framework is not failing to notice.** It notices
perfectly:

```
E WifiNl80211Manager: Wificond died!
I WifiNative: wificond died. Cleaning up internal state.
I WifiNative: wpa_supplicant died. Cleaning up internal state.
E WifiActiveModeWarden: One of the native daemons died. Triggering recovery
E WifiSelfRecovery: Triggering recovery for reason: WifiNative Failure
E WifiSelfRecovery: Already restarted wifi 2 times in last 1 hour. Disabling wifi
```

The last line is the whole answer. AOSP's `SelfRecovery` permits
`MAX_RESTARTS_IN_TIME_WINDOW = 2` per hour. **Our two services live in one process, so a single
daemon restart delivers two binder deaths — sometimes three — and every one is counted.** The first
restart in any hour therefore spends the entire budget, and each one after it lands on "Disabling
wifi" and stops. From the framework's point of view Wi-Fi is then simply off, so of course nothing
retries.

Observed firing two and three times per restart, at 17:25:30, 17:35:30, 17:37:11 and 17:40:53.

Spending less of that budget would mean splitting the daemon in two, which trades this for the worse
problem [29](29-wifi-plan.md) deliberately avoided: two lifetimes that can get out of step, giving
Android two ways to end up half-connected. So the framework is left to do its thing and Wi-Fi is
switched back on afterwards, by
[artifacts/wifi/waydroid-wifi-nudge](../artifacts/wifi/waydroid-wifi-nudge), run as `ExecStartPost`.

It is careful about three things:

- **It never overrides the user.** `Settings.Global wifi_on` survives self-recovery — measured: still
  `1` while the framework reported `Wifi is disabled` — so it is a faithful record of what the user
  last chose, and the script does nothing unless it reads `1`.
- **It does nothing at boot.** If `sys.boot_completed` is not `1` then this is a fresh start rather
  than a restart, and Android will enable Wi-Fi from its own saved state; a nudge would only race it.
- **It cannot fail the daemon.** Every path exits 0, and the unit invokes it with a leading `-`.

Verified live, end to end, in 1.5 seconds:

```
17:40:53.954  WifiSelfRecovery: Already restarted wifi 2 times in last 1 hour. Disabling wifi
17:40:54.806  waydroid-wifi-nudge: Wi-Fi is off but wifi_on=1 -- self-recovery gave up, switching it back on
17:40:55.410  waydroid-wifi-nudge: Wi-Fi is back on
```

with `ROLE_CLIENT_PRIMARY` restored.

**Also worth knowing:** before the SELinux fix, recovering from a daemon restart needed the
`set-scan-always-available disabled/enabled` dance that [29](29-wifi-plan.md) documents, and even
that only got as far as `Failed to register death notification for wificond`. Afterwards, a plain
`cmd wifi set-wifi-enabled enabled` recovers on the first try. **That dance is obsolete**; it was
compensating for the SELinux denial, not for anything about registration.

## Android saw no networks at all, and the cause was a channel list

After the reboot Android had Wi-Fi enabled, a client interface, a healthy radio — and
`results=0` on every single scan since boot, with `WificondScannerImpl: Filtering out 8 scan
results` each time. The daemon was delivering all eight; Android was discarding all eight.

[32](32-wifi-stage3.md) had established that `tsf` is load-bearing, so the timestamps were the
obvious suspect and two real defects were found and fixed there. **Neither was the cause**, and
chasing them first cost the most time in this session. What settled it was giving up on recall and
disassembling the filter out of this image, the same way [30](30-wifi-aidl-surface.md) got the
transaction codes:

```
$ dexdump -d sw/classes.dex   # com.android.server.wifi.scanner.WificondScannerImpl
0031: iget-wide v6, v5, Landroid/net/wifi/ScanResult;.timestamp:J
0035: iget-wide v9, v8, LastScanSettings;.startTimeNanos:J
0037: const-wide/16 v11, #int 1000
0039: div-long/2addr v9, v11
003a: cmp-long v6, v6, v9
003c: if-ltz v6, 0054                 <- filter if timestamp < startTime
003e: iget-object v6, v8, LastScanSettings;.singleScanFreqs:ChannelCollection;
0040: iget v7, v5, Landroid/net/wifi/ScanResult;.frequency:I
0042: invoke-virtual {v6, v7}, ChannelCollection;.containsChannel:(I)Z
0046: if-nez v6, 0050
004a: invoke-static {v6}, Landroid/net/wifi/ScanResult;.is6GHz:(I)Z
004e: if-eqz v6, 0054                 <- filter if the channel was not asked for
0054: add-int/lit8 v4, v4, #int 1     <- the SAME counter for both
```

There are **two** filters, not one, and they increment the same counter — so "Filtering out N" is
ambiguous between a stale timestamp and an unwanted channel, and reading it as the timestamp is a
trap. `dumpsys wifiscanner` shows the scan is requested by band with no explicit channels:

```
ScanSettings { type:HIGH ACCURACY band:24Ghz & 5Ghz (DFS incl) & 6Ghz ... channels:[  ] }
```

A band-based `ChannelCollection` resolves a frequency to a band using the channel lists
`WificondChannelHelper` cached at driver-load time — from **our** `getAvailable*Channels`. So that
reply decides whether any scan result is ever shown, and it was the one handler in `Wificond.cpp`
that logged nothing at all. Adding a line to it answered the question immediately:

```
getAvailable2gChannels() -> 13 channels
getAvailable5g-non-dfsChannels() -> 9 channels
getAvailable5g-dfsChannels() -> 15 channels
getAvailable6gChannels() -> 0 channels
```

Android queries these **on every driver load**, which happens on each Wi-Fi enable. Before the
SELinux fix the enable never completed, so the lists were never fetched, the helper could place no
frequency in any band, and `containsChannel()` was false for everything. Once the enable worked,
the query happened and the results appeared — with `vidiot` carrying the right transition-mode
flags:

```
76:bd:71:0f:a5:c2  2412  -63  vidiot  [WPA2-PSK-CCMP][RSN-PSK+SAE-CCMP][ESS][MFPC]

Wifi is connected to "vidiot"
Active default network: 100  ni{WIFI CONNECTED}  INTERNET&VALIDATED&NOT_METERED
  Routes: [ 192.168.240.0/24 -> 0.0.0.0 wlan0, 0.0.0.0/0 -> 192.168.240.1 wlan0 ]
```

**The lesson worth keeping is the logging one.** Every other handler in `Wificond.cpp` logs what it
answered; this one did not, and its answer has consequences several layers away with nothing
pointing back. It now logs.

### Two real timestamp bugs, found on the way

Both were genuine and both are fixed, even though neither was the cause of the blank list.

**NM truncates `LastSeen` to whole seconds.** An AP reading 202 was last seen somewhere in
[202.000, 203.000), and taking the bottom of that interval biases every timestamp up to a full
second into the past, against a filter that compares with the instant Android asked. Measured:
request at 202445 ms, scan completed at 202945 ms, `LastSeen` 202 → 202000 ms. The daemon now uses
`+999 ms`, the latest instant consistent with what NM actually said, which removes the bias without
ever claiming a sighting NM has ruled out.

**A scan is a sweep, not an instant.** NM reports the sweep's end in `LastScan` (milliseconds) and
each AP's own sighting in `LastSeen`, and an AP found early in the sweep is dated seconds before the
scan completes — and therefore before a request that arrived mid-sweep. An AP whose sighting falls
within 8 s below `LastScan` is now dated at `LastScan`, which is the accurate answer to the question
being asked: was this AP present in the scan that just finished. Genuinely stale APs keep their real
age and still filter correctly.

### One thing that did not work, recorded as such

A settle delay was added before announcing results, on the theory that NM publishes `LastScan` and
the per-AP `LastSeen` as separate property changes and we were announcing a round trip too early.
The symptom was a low yield — `results=1, Filtering out 7` repeatedly, while reading the same AP
list by hand seconds later showed six freshly dated. **The settle did not change the yield.** It is
kept because the ordering concern is real and it costs one poll, and its comment says plainly that
it fixed nothing — the same treatment [34](34-wifi-second-radio.md) gave its own false trail.

The better hypothesis, untested: those measurements were taken while the radio was **associated**,
and an associated station cannot leave its operating channel for long, so its background scans
re-see its own channel every time and other channels only occasionally. Before the association the
same code returned all eight APs. If that is right there is nothing here to fix. Test it by
comparing yields associated against idle.

## A false trail, and the test that cut it short

Late in the session Android stopped seeing any scan results at all —
`WificondScannerImpl: Filtering out 5 scan results` for every batch, meaning it received all five and
discarded all five on the `tsf` check [32](32-wifi-stage3.md) describes. The daemon's own scan mode
agreed something was wrong:

```
$ waydroid-wifid --scan
WARNING: no scan from NetworkManager after 12000 ms
scan: did not complete
8 access points
  vidiot   76:bd:71:0f:a5:c2  2412 MHz  -66 dBm  wpa2/wpa3-psk  seen  85s
```

Every AP 82–92 seconds stale, so Android's filter was behaving correctly on stale input. This is
the exact signature [34](34-wifi-second-radio.md) gives for the rtw88 wedge, and `nmcli device wifi
list` showing `vidiot` at full signal throughout is the exact way that fault misleads.

**It was not the wedge.** [34](34-wifi-second-radio.md) prescribes one test before touching the
driver, and it is worth its weight:

```
$ sudo nmcli connection up "vidiot (Waydroid)"
Connection successfully activated                       # 4.5 s
```

The radio associates fine, so nothing below the driver is implicated and a reprobe would only have
hidden a higher-up fault — which is precisely what that doc warns cost an afternoon last time. **No
reprobe was run.** The state had followed four daemon restarts in ten minutes, and whether it is
restart churn or a real reconciliation gap after a restart is not yet distinguished.

One thing was learned from it: when the host associates out of band, the daemon reports `COMPLETED`
to Android (`onStateChanged(6)`, then `(9)`) and **Android does not believe it** — `cmd wifi status`
stayed on "Wifi is not connected" while the host held the association. Android only tracks
connections it initiated, so an unsolicited association has no `WifiConfiguration` behind it. That
is a sharper version of the control-plane/data-plane disagreement [34](34-wifi-second-radio.md)
names.

## What is still open

Stage 5 items not yet done, from [29](29-wifi-plan.md) and [34](34-wifi-second-radio.md):

- **Scan staleness after repeated daemon restarts** — the false trail above. Not the radio;
  not diagnosed further.
- **The rtw88 wedge still has no automatic trigger.** This session did not observe it, and the one
  candidate turned out to be something else. `bin/wifi-radio-reset.sh` remains manual, and the
  `nmcli connection up` discriminator remains mandatory before running it.
- Signal strength and state transitions that Android's UI believes.
- **Saved networks synced both ways — and the obvious wiring for it is probably wrong.**
  `NmBackend::forget()` is fully implemented and **nothing calls it**, so a network forgotten in
  Android leaves its `"<ssid> (Waydroid)"` profile — PSK included — sitting in NetworkManager. The
  tempting fix is to call it from `ISupplicantStaIface.removeNetwork`, and that looks wrong on
  inspection: the shim holds one network at a time, and Android clears the supplicant's network list
  as part of the ordinary connect cycle, so `removeNetwork` fires on every connection rather than on
  a forget. Wiring it there would delete the saved profile every time Wi-Fi is used.
  **Test before building anything:** connect, disconnect and reconnect with `--verbose` and count
  `removeNetwork()` lines in the journal. If it fires outside a forget, the signal does not exist at
  this seam and the answer is a host-side reconciler comparing `cmd wifi list-networks` against the
  `(Waydroid)` profiles — the same shape as the nudge. A leftover PSK on the host after the user
  said "forget" is the part that makes this worth doing rather than deferring.
- **P2P, SoftAP, RTT and NAN may already be handled** and need checking rather than building: the
  Stage 0 overlay declares only `android.hardware.wifi`, so `android.hardware.wifi.direct`,
  `.rtt` and `.aware` are absent and Android should already consider them unsupported. Confirm with
  `pm list features | grep wifi` before writing code.
- The wrong-password path is still unproven, `getConnectionCapabilities` still reports all-unknown,
  and `Wpa2Wpa3Psk` still maps to `wpa-psk` — all unchanged from [34](34-wifi-second-radio.md).

## `bin/wifi-test.sh`

Three Stage 5 checks were added, and the domain check is placed **first** because everything after
it fails confusingly when it is wrong:

```
OK   running in unconfined_t, which can accept binder references from Android
OK   waydroid-wifid.service is enabled, so it survives a reboot
OK   waydroid-wifi-nudge is installed
```

[34](34-wifi-second-radio.md) noted the script still suggested `bin/wifi-wlan0.sh up` after the
uplink rename retired it. **That is no longer true** — the advice was already corrected, and the
note in [34](34-wifi-second-radio.md) is stale rather than the script.

## Running it

```bash
# dev box -- binary only; the host's start method is untouched
wifi/build.sh --install

# dev box -- binary, unit, conf and nudge; enables and restarts the service
wifi/build.sh --install --unit

# bigtab01
systemctl status waydroid-wifid
journalctl -u waydroid-wifid -f
```

Changing radios is an edit to `/etc/waydroid-wifid.conf` and `systemctl restart waydroid-wifid`;
the unit never needs touching. Check a MAC before writing it in with
`waydroid-wifid --devices --device <mac>`.
