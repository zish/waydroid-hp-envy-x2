# Wi-Fi — a second radio, and the crash it exposed

**Date:** 2026-09-08. **Status: Stage 4 is complete.** Android drives a real access point over a
dedicated USB radio through NetworkManager, and has validated internet over a Wi-Fi network it
controls itself. The host's own link was never at risk and never moved. The wificond race is closed
durably. Remaining work is Stage 5 hardening — see ["What is still broken"](#what-is-still-broken).

A TP-Link Archer T3U was added to the machine. [33-wifi-stage4.md](33-wifi-stage4.md)'s "Retesting
safely" section asked for exactly this, and it did what it was supposed to do: the entire session
below includes an association failure, three `system_server` deaths and a wedged Wi-Fi stack, and
at no point did the host lose its network or need someone at the console.

## The adapter

| | |
|---|---|
| USB ID | `2357:012d` — TP-Link Archer T3U [Realtek RTL8812BU] |
| Interface | `wlp0s20u1` (name encodes the USB port — see the caveat below) |
| Driver | `rtw88_8822bu`, in-tree in the Fedora kernel, no firmware fetch needed |
| phy | `phy3`, wholly separate from the built-in `phy0`/`wlp1s0` |
| Permanent MAC | `34:e8:94:f8:61:70` |
| Bands | 2.4 + 5 GHz, HT40, full CCMP/GCMP cipher set; managed/AP/monitor/IBSS |

**This falsifies the premise recorded in [28-wifi-feasibility.md](28-wifi-feasibility.md)** that
`wlp1s0` is the machine's only network interface. That premise is load-bearing in several places —
it is the stated reason direct hardware passthrough was rejected, and the reason trap 6 of
[33](33-wifi-stage4.md) had to be so careful. It is now false, and the passthrough option is worth
re-examining on its own merits (it still costs a real vendor HAL and an nl80211 supplicant, which
is why it was not pursued here).

**Caveat on the name.** `wlp0s20u1` is derived from the USB topology, so moving the adapter to a
different port renames it. Anything unattended should key off something stable; `--device` takes a
name because NM does, but the permanent MAC is what actually identifies the hardware.

## Four changes made before touching the host

### 1. The Android-driven profile may not carry routes

`NmBackend::buildSettings()` now sets `never-default` and `route-metric 1000` on both address
families, and `WAYDROID_ROUTE_METRIC` documents why 1000.

The T3U joins the same AP as the host, therefore the same subnet (`10.42.0.0/24`). Without a guard
NM installs a second set of routes for that prefix and the host's default can land on the radio
Android is free to disconnect at any moment. **`never-default` alone is not enough** — it suppresses
only the default route, and on a shared subnet the on-link route is the one that matters: a lower
metric there sends replies to the host's own traffic out of the wrong interface, with a source
address belonging to the other one.

Verified live, with both radios associated to `vidiot` at once:

```
$ ip route show dev wlp0s20u1
(nothing)
$ ip route get 1.1.1.1
1.1.1.1 via 10.42.0.1 dev wlp1s0 src 10.42.0.137
```

The Android-driven radio held `10.42.0.209/24` and installed **no routes at all** in the main
table — only the kernel's own local/broadcast entries. Stronger than the design intended; the
subnet route at metric 1000 was expected to be present and merely lose. Unexplained, and recorded
as an observation rather than a mechanism.

### 2. Automatic device selection avoids the host's lifeline

`init()` used to take `devs[0]` — the first radio NM happened to list. Fine with one adapter, and
unacceptable with two: NM's order is neither stable nor meaningful, so a coin flip decided whether
Android drove the spare or the link the machine is administered over. Trap 5 of
[33](33-wifi-stage4.md) is what losing that flip costs.

Selection now skips any radio carrying the host's default route, asking NM for its own judgement
(`Connection.Active`'s `Default`/`Default6`) rather than inferring it. Confirmed with no flag given:

```
2 Wi-Fi devices; choosing wlp0s20u1 (not carrying the host's default route)
```

It is a guard, not a guarantee: if the host's radio is down at the moment we look, nothing carries
a default route and the first entry wins again. `--device` remains the deterministic answer.

### 3. `--device` was never actually validated

`selectDevice()` was called *before* `init()`, so it ran before the backend had a D-Bus connection
to ask over. Every invocation failed its existence check, logged `NetworkManager has no Wi-Fi
device called ...`, and then kept the name anyway — `--device` appeared to work while its
validation did nothing, and a typo would have been accepted silently.

Now applied after `init()`, and a named device that does not exist is **fatal**. By that point
`init()` has already auto-selected something, and carrying on with that after the operator named a
different radio is precisely how Android ends up on the host's only link.

### 4. Profile ownership is by UUID, not by name

Prompted by a good question mid-session: matching on `connection.id` was the weak point of trap 6's
safety rule. `id` is a display string — the user can rename any profile from the desktop GUI, and
NM does not require it to be unique. Someone naming a profile `coffeeshop (Waydroid)` would have
handed us write access to it, which is the exact failure that rule exists to prevent; renaming ours
would orphan it and accumulate duplicates.

`connection.uuid` is NM's real primary key: unique, immutable across renames. Ours is derived from
the SSID as RFC 4122 v5 under a fixed namespace, so it is reproducible from the SSID alone — the
daemon keeps no state between runs and must still recognise its own profile after a restart, which
a random UUID could not do. The `id` is still written, as a label.

Predicted before deployment and confirmed on the profile NM actually created:

```
connection.uuid:     14921b3a-4895-5fcb-8d38-a71863bef507   (== python uuid5(ns, "vidiot"))
ipv4.never-default:  yes        ipv4.route-metric: 1000
connection.interface-name: wlp0s20u1
```

A stale `vidiot (Waydroid)` profile left from the [33](33-wifi-stage4.md) outage was found pinned
to `interface-name: wlp1s0` and deleted. It had `autoconnect: no`, so it was inert, but a profile
Android can activate on the host's own radio is not something to leave lying about.

## The bug that was killing Android

**`getConnectionCapabilities` was writing a malformed parcelable, and it killed `system_server` on
every successful association.**

The symptom chain was three layers away from the cause. Wi-Fi would associate, Android would report
`COMPLETED`, and then the master toggle would switch itself off and refuse to come back on, with
`wificond` mysteriously running again. What was actually happening:

```
*** FATAL EXCEPTION IN SYSTEM PROCESS: WifiHandlerThread
android.os.BadParcelableException: Parcelable too small
	at ConnectionCapabilities.readFromParcel(ConnectionCapabilities.java:45)
	at ISupplicantStaIface$Stub$Proxy.getConnectionCapabilities(ISupplicantStaIface.java:1041)
	at ClientModeImpl.updateWifiInfoLinkParamsAfterAssociation(ClientModeImpl.java:2828)
```

An uncaught exception on a `system_server` handler thread is a `system_server` death. Every app died
with `DeadSystemException`, the restart brought `wificond` back (which then stole `wifinl80211`,
see below), and Wi-Fi could not be re-enabled afterwards. Nothing in that visible sequence points at
a parcel-encoding bug.

**The cause is the same family as trap 1 of [33](33-wifi-stage4.md): a stable-AIDL wire detail that
is invisible in the interface definition.** A parcelable *return value* is read with
`Parcel.readTypedObject()`, which reads a **non-null marker int32 first** and only then calls
`createFromParcel()`. We wrote the parcelable without the marker, so Java consumed our size field
(24) as the marker — non-zero, so it continued happily — and then read the first field,
`technology = 0`, as the parcelable's size. Zero is smaller than the four-byte size word itself,
hence "Parcelable too small".

One `int32(1)` before the size word fixes it. Verified: association now completes with zero
`FATAL EXCEPTION IN SYSTEM PROCESS` and the toggle stays on.

Three related encodings, easy to confuse, all present in this codebase:

| Shape | Leading int32 | Where |
|---|---|---|
| Parcelable return value | non-null marker (`1`) | `getConnectionCapabilities` — **was missing** |
| Parcelable array | element **count** | `listInterfaces` — correct |
| Per-element in a typed array | non-null marker | `NativeScanResult.cpp` — correct, which is why Stage 3 never hit this |

`ClientModeImpl` calls `getConnectionCapabilities()` from
`updateWifiInfoLinkParamsAfterAssociation()`, i.e. on **every** successful association. This was
never an edge case — it was the guaranteed outcome of the one thing Stage 4 exists to do, and it
went unnoticed only because no association had ever succeeded before.

## `signalPoll`'s four ints are not in the order the names suggest

`WifiInfo` came back reading `Frequency: 130MHz, Rx Link speed: 2412Mbps` — a 130 MHz channel and a
2.4 Gbps link on 802.11ac, both impossible, and each exactly the other's value.

The array is `[rssi, txBitrate, associationFrequency, rxBitrate]` — **frequency third, not last**.
The authority is wificond's own `client_interface_binder.cpp`, which pushes them in that order;
`WifiNl80211Manager.SignalPollResult` just reads positionally. Our code had rx and frequency
swapped, and the old comment asserted the wrong order confidently.

This class of bug is silent: every value is a plausible small integer, so nothing throws and nothing
logs. It is only catchable by reading the numbers and asking whether they are physically possible.
After the fix:

```
RSSI: -72, Link speed: 130Mbps, Tx Link speed: 130Mbps, Rx Link speed: 130Mbps, Frequency: 2412MHz
```

## The wificond race — why `disabled` was not enough, and what closed it

[31-wifi-stage2.md](31-wifi-stage2.md) and commit 4e7507f deploy
`artifacts/overlay/system/etc/init/wificond.rc`, which marks the stock service `disabled`. That file
**is** in effect — verified by reading it from inside the container, and the container started at
12:24 against an overlay written at 09:44, so init parsed the modified copy. And yet:

```
$ getprop init.svc.wificond
running
```

`disabled` prevents init from auto-starting the service at class main. It does **not** prevent
something asking init to start it later, and something does: `wificond` appears within 1 ms of
`WifiNl80211Manager: Setting up interface for client mode: wlan0`. The `.rc` comment's claim —
"Nothing else asks init to start wificond ... Verified on this image" — is contradicted by this
evidence. It was true of the paths Stages 2 and 3 exercised; the connectivity-mode path that only
Stage 4 reaches behaves differently.

Once started, `wificond` calls `addService("wifinl80211")`, which **overwrites**, and Android then
talks to a wificond that reports `No wiphy is found` and fails the interface setup.

Worse, init **restarts** it on death with a 5 s backoff, so killing it in a loop is actively
harmful: it leaves a registered-then-dead binder and Android reports `Failed to get reference to
wificond`, a different and more confusing failure.

The interim workaround was an ordering dance — let `wificond` settle, then start
`waydroid-wifid` **last** so its `addService` overwrites, then enable Wi-Fi so Android's start
request is a no-op on an already-running service. It worked, and it made restarting the daemon part
of the enable procedure rather than a one-time step.

**That is now fixed properly.** `artifacts/overlay/system/etc/init/wificond.rc` no longer merely
marks the service `disabled`; it points it at `/system/bin/true` and adds `oneshot`:

```
service wificond /system/bin/true
    class main
    user wifi
    group wifi
    disabled
    oneshot
```

Three deliberate parts. `/system/bin/true` execs and exits, so it can never reach `addService()` and
can never take the name — it is a toybox symlink present in this image, checked rather than assumed.
`oneshot` stops init respawning the no-op on its 5 s backoff. `disabled` is kept so it is not started
at class main either. The capabilities and `net_raw`/`net_admin` groups are dropped along with the
real binary.

Verified across a full container restart, boot, Wi-Fi enable and association:

```
$ getprop init.svc.wificond
[]                          <- empty; it never started once
$ ps -A | grep wificond
NONE
```

`waydroid-wifid` now owns `wifinl80211` from whenever it starts and nothing ever overwrites it, so
**the start-ordering requirement is gone** — the daemon may start before or after Android.

## The AP's WPA2 leg does not work; SAE does

The first association attempt failed, and `NM_REASON_NO_SECRETS` made it look like a wrong password.
It was not — the PSK was byte-identical to the host's own working profile. The journal shows what
really happened:

```
authenticated → associated (status=0) → 4way_handshake
deauthenticated from 76:bd:71:0f:a5:c2 (Reason: 15=4WAY_HANDSHAKE_TIMEOUT)
Activation: (wifi) disconnected during association, asking for new key
no secrets: No agents were available → state change: need-auth → failed (reason 'no-secrets')
```

NM had already said `secrets exist. No new secrets needed.` **`NO_SECRETS` here is NM's inference
after a 4-way handshake timeout, not a credential rejection** — a sibling of trap 4, which was about
`NEED_AUTH` not meaning a bad password. Neither NM state means what its name suggests.

`vidiot` advertises WPA2/WPA3 transition. Connecting with `key-mgmt wpa-psk` times out in the 4-way
handshake every time; `key-mgmt sae` connects immediately. Ruled out along the way, each by testing
one variable: MAC randomization (`cloned-mac-address permanent` — no change) and power save
(`wifi.powersave 2` — no change).

**Not distinguished** at the time: whether the AP's PSK leg is broken or `rtw88_8822bu` cannot
complete a WPA2 handshake. Telling them apart means trying `wpa-psk` on `wlp1s0`, which risks the
host's only working link for a question that does not change what we do. Left open deliberately.

> **Resolved 2026-09-08 — the AP's PSK leg is fine; the T3U is the side that cannot do WPA2.**
> The experiment had been running the whole time and nobody had looked: the host's own `vidiot`
> profile was `key-mgmt: wpa-psk` and **associated on `wlp1s0`** throughout, measured while checking
> something else entirely. So this AP completes a WPA2 4-way handshake perfectly well with the Intel
> radio, and the failure is specific to `rtw88_8822bu` (or that adapter).
>
> Worth noting how cheap the answer turned out to be. The test was framed as "risk the host's only
> working link", which was true when [28-wifi-feasibility.md](28-wifi-feasibility.md)'s
> one-interface premise held; once the T3U made `wlp1s0` the spare rather than the lifeline, the
> question was answerable by reading a property. The premise changed and the cost estimate attached
> to it did not.
>
> The machine's owner has since changed that profile to `sae` by hand, so the evidence is now
> historical — but it was measured, not inferred. See
> [36-wifi-credential-sync.md](36-wifi-credential-sync.md) for why the profile's key-mgmt now
> matters beyond the host: it is what the credential sync maps to Android's security type.

The practical consequence: the network must be given to Android as `wpa3`, not `wpa2`.
`cmd wifi connect-network vidiot wpa2 …` builds a `WPA_PSK | WPA_PSK_SHA256` config (`0x102`) that
this AP will not complete. Note that `KEYMGMT_SAE` is `1 << 10` (`0x400`), not `0x100` —
`WPA_PSK_SHA256` is `1 << 8` and is easy to misread as SAE.

`NmBackend` still maps `Wpa2Wpa3Psk` → `wpa-psk`, on the reasoning that NM will negotiate upward.
**That reasoning is unproven and this evidence points against it** — NM stayed on the WPA2 leg and
failed. Whether a transition-mode network should be mapped to `sae` instead is an open question; it
was not changed here because Android sent a pure-WPA2 config, so this path was never exercised.

## Making `wlan0` the real uplink is what fixed connectivity

Everything above got Android to `COMPLETED` with a DHCP lease and **still no internet**:
`NetworkCapabilities: null`, `Active default network: none`. `wlan0` had an address and an on-link
route, and no `NetworkAgent` was ever registered with `ConnectivityService`.

The fix needed no code. [29-wifi-plan.md](29-wifi-plan.md) put `lxc.net.0.name = wlan0` inside
Stage 4 and [33-wifi-stage4.md](33-wifi-stage4.md) deferred it to Stage 5 in favour of a bridged
veth beside `eth0`. **That deferral was wrong**, and this settles it: one line in
`/var/lib/waydroid/lxc/waydroid/config`, from

```
lxc.net.0.name = eth0     ->     lxc.net.0.name = wlan0
```

and Android registers a proper Wi-Fi network. The container now has no `eth0` at all, so `wlan0` is
not a second-class interface alongside the uplink — it *is* the uplink.

Two things come free with it:

- **Trap 3 is gone permanently.** There is no `eth0` for `config_ethernet_iface_regex` to match, so
  Ethernet can never outscore Wi-Fi in ConnectivityService and the INTERNET requests always reach
  the Wi-Fi factory. The `nsenter ... ip link set eth0 down` workaround is retired.
- **`bin/wifi-wlan0.sh` is obsolete.** `wlan0` exists from container start with no per-boot setup,
  and the veth's non-persistence across container restarts stops being a thing to remember.

The config file is not regenerated per session — only `config_session` is, and it carries no `net`
lines — so the edit persists. A backup is kept at `config.pre-wlan0`; restoring it and restarting
`waydroid-container.service` puts `eth0` back exactly as it was.

This is also precisely the architecture the machine's owner wanted: **the control plane goes through
NetworkManager to the T3U, and the data plane still goes over `waydroid0`.** Worth naming the
consequence — the two can disagree. If the T3U's association drops, Android's UI says "disconnected"
while traffic keeps flowing; if the host's own link drops, Android shows a healthy Wi-Fi connection
with no internet.

## The radio wedges, and every layer lies about it differently

After a container restart, associations began failing consistently. The symptoms invited three wrong
diagnoses in a row:

```
nmcli connection up ...   Error: The Wi-Fi network could not be found
NetworkManager            state change: config -> failed (reason 'ssid-not-found')
waydroid-wifid            host failed to associate with "vidiot"
Android                   Wifi is not connected
```

All four are misleading, because `nmcli device wifi list` showed `vidiot` at signal 69 throughout.
`ssid-not-found` is NetworkManager's label for its 25 s activation timeout, not an observation about
the SSID. The supplicant went `disconnected -> scanning` and never once reached
`SME: Trying to authenticate`.

**The decisive test is to bypass Android and the daemon entirely:**

```bash
sudo nmcli connection up "vidiot (Waydroid)"
```

It failed. Nothing above the driver was implicated. `modprobe -r rtw88_8822bu && modprobe
rtw88_8822bu` fixed it immediately and the same command then succeeded on the first attempt.

Same shape as the ITE8350 wedge in [19-sensor-hub-suspend-wedge.md](19-sensor-hub-suspend-wedge.md):
a device that answers some requests and silently refuses others until its driver is reloaded.
`bin/wifi-radio-reset.sh` performs the reprobe and **refuses to run against whichever interface
currently carries the host's default route**, so it cannot be used to unplug the management link.

No automatic trigger is wired up, because the provoking conditions are not understood. It has been
seen after repeated container restarts and heavy scan activity; that is a description, not a cause.

**A false trail worth recording.** Before the driver was suspected, a guard was added to
`NmBackend::startScan()` to suppress host scans during association, on the theory that Android's
disconnected-state scanning was restarting wpa_supplicant's scan cycle — the supplicant log was full
of `Reject scan trigger since one is already pending`. The next captured failure showed the guard
never firing at all, because no scan arrived during the association. **The theory was wrong.** The
guard is kept because it is defensible on its own terms, and its comment says plainly that it fixed
nothing.

## What now works

```
Wifi is connected to "vidiot"
WifiInfo: SSID: "vidiot", BSSID: 76:bd:71:0f:a5:c2, IP: /192.168.240.113,
          Supplicant state: COMPLETED, RSSI: -72, Link speed: 130Mbps,
          Frequency: 2412MHz, wpa3-sae
```

- Association end to end, through the full NM state chain `50 → 60 → 40 → 50 → 70 → 80 → 90 → 100`.
  It passes through `NEED_AUTH` (60) twice without being misreported — **trap 4's fix, verified by
  observation** rather than by reasoning for the first time.
- **Trap 5's fix verified**: `disconnect(): nothing is active`. The device was never disconnected,
  and the host stayed online throughout every failure in this session.
- **DHCP on `wlan0` works** — `192.168.240.113/24`, from Waydroid's own dnsmasq on `waydroid0`,
  since `wlan0` is still a veth onto that bridge. This closes one of
  [33](33-wifi-stage4.md)'s "not done" items.
- Auto-reconnect to the saved network on enable.
- Scan, security flags and `ROLE_CLIENT_PRIMARY` all now run against the T3U rather than the host's
  radio: `backend: networkmanager, radio: wlp0s20u1`.
- **Validated internet**, which is the whole point:

```
Active default network: 100
NetworkAgentInfo{network{100} ni{WIFI CONNECTED} ... INTERNET&VALIDATED&NOT_METERED
  Routes: [ 192.168.240.0/24 -> 0.0.0.0 wlan0, 0.0.0.0/0 -> 192.168.240.1 wlan0 ]
123 network requests bound to it

ping 8.8.8.8     -> 0% loss, 18.5 ms
ping google.com  -> resolved, 20.9 ms
```

  `VALIDATED` is Android's own connectivity check passing, not our assertion that it works.
- **The daemon survives a container restart**, re-registering both names from its servicemanager
  presence handler — watched again here, and now with `wificond` unable to race it afterwards.

## What is still broken

All Stage 5 hardening; none of it blocks Stage 4.

- **No systemd unit.** The daemon does not survive a reboot. The start-ordering constraint is gone
  now that `wificond` is neutered, so a unit is simpler than it would have been — it needs
  NetworkManager and `/dev/binder`, not a wait on another Android service.
- **The rtw88 wedge has no automatic recovery**, and no understood trigger. `bin/wifi-radio-reset.sh`
  is manual.
- **The wrong-password path is still unproven.** It is also awkward to test honestly on this AP: over
  `wpa-psk` a *correct* password fails with `FAILED`/`NO_SECRETS` too, so that oracle proves nothing.
  Over SAE the failure mode should be distinct, and that test has not been run.
- **`getConnectionCapabilities` still reports all-unknown.** Correctly encoded now, but NM publishes
  no PHY mode, bandwidth or spatial streams to fill it with.
- **EAP/enterprise and WEP are not carried across the seam**, by choice.
- **`Wpa2Wpa3Psk` still maps to `wpa-psk`.** Unexercised, and the evidence in this document points
  against the reasoning behind it.

## Running it

```bash
# dev box
wifi/build.sh --install

# bigtab01 -- no ordering dance any more; wificond can never take the name
sudo pkill waydroid-wifid
sudo sh -c "setsid nohup waydroid-wifid --device wlp0s20u1 --verbose \
            </dev/null >>/var/log/waydroid-wifid.log 2>&1 &"
sudo waydroid shell -- cmd wifi set-wifi-enabled enabled

# join a network -- wpa3, not wpa2, on a transition-mode AP
PSK=$(sudo nmcli -s -g 802-11-wireless-security.psk connection show vidiot)
sudo waydroid shell -- cmd wifi connect-network "vidiot" wpa3 "$PSK"
```

Confirm with `bin/wifi-test.sh`. Note it still warns that `wlan0` has no IPv4 before a connection
completes, and still suggests `bin/wifi-wlan0.sh up` — **that advice is obsolete** since the uplink
rename; `wlan0` is now created by LXC.

If association fails while the SSID is plainly visible in a scan, suspect the radio before the
software:

```bash
sudo nmcli connection up "vidiot (Waydroid)"    # bypasses Android and the daemon
sudo bin/wifi-radio-reset.sh                    # if that failed
```
