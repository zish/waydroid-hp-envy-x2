# Wi-Fi Stage 4 — the supplicant, and the Wi-Fi toggle that stays on

**Date:** 2026-09-08. **Status:** the supplicant shim is built, deployed and working; the master
toggle stays on and Android reaches `ConnectModeState` with `ROLE_CLIENT_PRIMARY`. Association
reached NetworkManager with a real password and then failed, for reasons now diagnosed and fixed
but **not yet re-tested**. Read ["What is not done"](#what-is-not-done) before believing anything
here is finished.

> **Superseded in part by [34-wifi-second-radio.md](34-wifi-second-radio.md).** A second Wi-Fi
> adapter was added, which is what "Retesting safely" below asked for. Association now completes
> end to end and `wlan0` takes a DHCP lease. Traps 4 and 5 are verified fixed by observation. Three
> further bugs were found in the process, one of which — a malformed `getConnectionCapabilities`
> reply — was killing `system_server` on **every** successful association, which is why nothing
> here could ever have worked as written. Read 34 alongside this.

## What now works

The Wi-Fi master toggle turns on and **stays** on. That was impossible in Stages 2 and 3 — not for
want of trying, but because `WifiNative.setupInterfaceForClientInConnectivityMode()` calls
`startSupplicant()` *before* it ever reaches wificond, so a wificond-only shim could reach
`ScanOnlyModeState` and no further.

```
Wi-Fi is enabled
current StateMachine mode: ConnectModeState
mRole: ROLE_CLIENT_PRIMARY
WifiNative: Successfully switched to connectivity mode on iface=Iface:{Name=wlan0,Id=1,Type=STA_CONNECTIVITY}
```

`bin/wifi-test.sh` passes end to end, including the three new Stage 4 checks. And the association
path is proven to work as far as the host: a password typed into Android's Wi-Fi dialog arrived at
`setPskPassphrase()` in the clear and reached NetworkManager, which began associating.

```
[waydroid-wifid] select() -> connecting to "vidiot"
[waydroid-wifid] connecting: ssid="vidiot" security=wpa3-sae passphrase=yes
[waydroid-wifid] connect(vidiot): updating our profile /org/freedesktop/NetworkManager/Settings/11
[waydroid-wifid] NM device state 30 -> 40 (reason 0) = associating
```

That is the goal sentence of [29-wifi-plan.md](29-wifi-plan.md) Stage 4, minus its ending.

## What was built

`wifi/Supplicant.{h,cpp}` — `ISupplicant`, `ISupplicantStaIface` and `ISupplicantStaNetwork` served
over libgbinder as AIDL on `/dev/binder`, registered as
`android.hardware.wifi.supplicant.ISupplicant/default`, plus the two callback interfaces called in
the other direction.

167 method slots across the three interfaces, of which the load-bearing set is small. The rest are
slots with honest refusals, and the slots are not optional: transaction codes are positional, so a
mis-numbered table corrupts every later call. Codes came from
[30-wifi-aidl-surface.md](30-wifi-aidl-surface.md), read out of this image's own bytecode.

Which methods are load-bearing was settled by reading `SupplicantStaIfaceHalAidlImpl` and
`SupplicantStaNetworkHalAidlImpl` from AOSP `android-13.0.0_r75`, not by guessing:

| Interface | Must succeed |
|---|---|
| `ISupplicant` | `addStaInterface` |
| `ISupplicantStaIface` | `registerCallback`, `addNetwork`, `listNetworks`, `removeNetwork` |
| `ISupplicantStaNetwork` | `setSsid`, `setBssid`, `setScanSsid`, `setRequirePmf`, `setKeyMgmt`, `setProto`, `setAuthAlg`, `setGroupCipher`, `setPairwiseCipher`, `setPskPassphrase`/`setPsk`/`setSaePassword`, `setIdStr`, `registerCallback`, `select`, `getId` |

`saveWifiConfiguration()` returns false on the first setter that fails, and `connectToNetwork()`
returns false on that, so any one of those is fatal to a connection. Everything else can be
refused.

Also added: `NmBackend::connect()`/`forget()`, the `LinkEvent` half of the backend contract, the
vendor VINTF fragment, and `bin/wifi-wlan0.sh` rewritten to make `wlan0` a real bridged veth.

## Six traps, four of them expensive

### 1. The service-specific exception has FOUR fields, not three

The one that cost the least to find and would have cost the most to leave. A stable-AIDL failure is
reported as `EX_SERVICE_SPECIFIC`, and the obvious encoding — `int32(-8)`, message, `int32(code)` —
is wrong. `libbinder`'s `Status::writeToParcel` writes an **empty remote-stack-trace header**
between them, and `Parcel.readException(int, String)` reads it unconditionally:

```java
public final void readException(int code, String msg) {
    String remoteStackTrace = null;
    final int remoteStackPayloadSize = readInt();     // <-- this
    if (remoteStackPayloadSize > 0) {
        remoteStackTrace = readString();
    }
    Exception e = createException(code, msg);         // ...then reads the code
```

Omit it and the error code is consumed as a stack-trace payload *size*. A non-zero code therefore
sends Java off reading a string past the end of the parcel, and the exception surfaces as
`(code 0)`. Diagnosed from exactly that symptom:

```
ServiceSpecificException: not supported by the NetworkManager backend (code 0)   # before
ServiceSpecificException: not supported by the NetworkManager backend (code 10)  # after
```

Stages 2 and 3 never hit this because `writeNoException()` is the same function's zero case, and
`readException()` returns early on 0. Every reply they wrote was a success.

### 2. An XML comment may not contain a double hyphen

The VINTF fragment was written with a comment full of `--` used as dashes. `xml.etree` rejected it
instantly; `libvintf` would have rejected the whole manifest, and **a rejected manifest declares
nothing**, which looks exactly like the file not being deployed at all. Caught before deployment
only because the file was validated rather than eyeballed. Validate every XML that a C++ parser on
the far side has to accept.

### 3. Ethernet stops Wi-Fi from ever connecting

The big one, and it is not a bug in the shim at all.

With the toggle on and everything set up correctly, joining a network from Settings failed with:

```
WifiClientModeImpl[wlan0]: CMD_START_CONNECT but no requests and not connected, bailing
WifiNetworkFactory: mGenericConnectionReqCount 0
```

`ClientModeImpl` refuses to start a connection when no NetworkRequest wants Wi-Fi. And none did,
because **`eth0` was up and satisfied every request already** — Ethernet outscores Wi-Fi in
ConnectivityService, so the default INTERNET request is never offered to the Wi-Fi factory. Wi-Fi
had nothing to connect *for*.

This is the "EthernetService conflict" [29-wifi-plan.md](29-wifi-plan.md) predicted, and the reason
its Stage 4 wanted `wlan0` to **replace** the container's uplink rather than sit beside it. The
decision here to keep `eth0` (see below) avoided an outage risk and walked straight into this
instead. Bringing `eth0` down inside the container's netns clears it immediately and reversibly:

```bash
nsenter -t "$(lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH)" -n -- ip link set eth0 down
```

### 4. `NM_DEVICE_STATE_NEED_AUTH` is not an authentication failure

State 60 reads like "the password was wrong". It is not — it means "I am about to need the
secret", and NM passes through it on the way into a perfectly ordinary association. The successful
association that recovered this machine went

```
50 -> 60 -> 40 -> 50 -> 70 -> 80 -> 90 -> 100
```

straight through it. Mapping it to `LinkEvent::AuthFailed` made the shim tell Android "wrong
password" *while NM was still busy succeeding*. A credential rejection is `FAILED` (120) with
reason `NO_SECRETS` (7), and nothing else is.

### 5. `Device.Disconnect()` strands the host, and that is by design

The expensive one: it took the machine off the network and **kept it there**, requiring physical
console access to recover.

`Device.Disconnect()` does not mean "drop this association". It means "the user wants this device
down", and NM honours it by **blocking autoconnect** until something explicitly activates a
connection. The device state said so exactly — `110 -> 30, reason 39, user-requested`.

So the fallback that was the entire safety net — NM autoconnecting back to the host's own `vidiot`
profile — was disabled by our own disconnect call. On a machine whose only network interface is the
radio Android is driving, that is the difference between a blip and a trip to the console.

Combined with trap 4 this was a complete causal chain: NEED_AUTH was reported as a wrong password →
Android aborted the connection and called `disconnect()` → the device was disconnected and pinned
→ the host went offline while the association had been progressing normally.

`disconnect()` now deactivates *the connection*, not the device, and only ever one we activated.

### 6. Android must not be able to disconnect what it did not connect

Discovered while fixing trap 5, and it generalises. `wlp1s0` is this machine's **only** network
interface ([28-wifi-feasibility.md](28-wifi-feasibility.md)), so anything Android can do to it is
something Android can do to the machine's only route off itself.

Two rules now hold, both in `NmBackend`:

- **Profiles we create are named `"<ssid> (Waydroid)"`, and nothing else is ever read, written or
  deleted.** An earlier version matched on SSID and updated whatever profile it found, so that
  Android and the host's desktop would share one profile per network. Tidy, and a way to brick the
  machine: a password mistyped in Android would overwrite the psk of the host's working profile.
  This rule is what made recovery a one-liner — `nmcli connection up vidiot` used a profile that
  had never been touched.
- **`forget()` deletes only ours**, so "forget this network" in Android does not silently unsave a
  network from the host's desktop.

The cost is a duplicate profile per network. That is a fair price.

## Decisions taken, and one reversed

### `wlan0` is a bridged veth, not the renamed uplink — for now

[29-wifi-plan.md](29-wifi-plan.md) proposed `lxc.net.0.name = wlan0`, renaming the container's uplink.
That is still the tidy end state but a bad way to *get* there: it needs a container restart, drops
the kiosk session to the greeter, and leaves Android with no network at all in the window where the
Wi-Fi path does not yet work — so a bug in the shim would look identical to a bug in the cutover.

`bin/wifi-wlan0.sh up` now makes `wlan0` a second veth onto `waydroid0` instead. `eth0` keeps
working, `wlan0` is independently routable, nothing restarts, and `down` removes every trace.

**Trap 3 is the cost of that choice**, and it is a real one: with `eth0` up, Wi-Fi can never
connect. The veth is right for developing the shim and wrong as an end state. The cutover is now a
Stage 5 item with a clear justification rather than a guess.

The veth is also **not persistent** — the netns is recreated with the container, so
`bin/wifi-wlan0.sh up` must be re-run after every container restart.

### The AIDL path, via one VINTF fragment

`SupplicantStaIfaceHal.initialize()` picks AIDL over HIDL by asking
`ServiceManager.isDeclared("android.hardware.wifi.supplicant.ISupplicant/default")`, which reads the
VINTF manifest and **does not check whether anything registered the service**. So registering the
object without the fragment leaves Android taking the HIDL path to a HIDL service that does not
exist, with no symptom beyond the toggle refusing to stay on.

`artifacts/overlay/vendor/etc/vintf/manifest/manifest_android.hardware.wifi.supplicant.xml`, same
mechanism as the widevine fragment. Deploying it needs `systemctl restart
waydroid-container.service`, not `waydroid container restart` — see
[32-wifi-stage3.md](32-wifi-stage3.md).

### Refusals are refusals

Methods that describe policy the host genuinely owns — power save, country code, suspend mode, BT
coexistence — are accepted, because NetworkManager and the kernel really do apply them, just for
the whole machine rather than for Android's session. Methods that would require inventing data or
performing an action we cannot perform — WPS, DPP, TDLS, ANQP, Hs20, EAP-SIM, RX filters, external
SIM — return `FAILURE_UNSUPPORTED`. The framework logs these at `E` with a full stack trace and
carries on; the noise is loud and harmless.

WEP is refused rather than accepted-and-ignored: nothing carries the key across, so accepting would
produce an attempt guaranteed to fail with no explanation.

## Things that were checked rather than assumed

- **The supplicant AIDL version and hash** come from the frozen `aidl_api/…/1/` snapshot at
  `android-13.0.0_r75`, not from a guess: version 1, hash `5b8bcab6b43177dffdec5873e84205b04757cc9d`.
- **Both callback interfaces are `oneway`**, confirmed from the `.aidl` files, so they use the same
  `transact_sync_oneway` path Stage 2 proved for `IScanEvent`.
- **SELinux inside the container is `Disabled`**, so registering a new service name has no policy
  obstacle. Checked before writing the code, not after it failed.
- **The LXC config is not regenerated at container start** — only `config_session` is — so the
  eventual `lxc.net.0.name` edit will persist.
- **The daemon survives a container restart** and re-registers both service names from its
  servicemanager presence handler. Watched again here, for two names rather than one.
- **NM's `vidiot` profile has autoconnect enabled**, which is what makes the fallback in trap 5
  possible at all. Checked before relying on it — and it still was not enough, because of trap 5.

## What is not done

- ~~**Association has not succeeded end to end.**~~ **Done** — see
  [34](34-wifi-second-radio.md). Traps 4 and 5 are both verified fixed by observation.
- ~~**DHCP on `wlan0` is unproven.**~~ **Done** — `192.168.240.113/24` from Waydroid's dnsmasq.
  Android still has no default route, though, which is now the open item.
- **The wrong-password path is unproven.** The FOURWAY_HANDSHAKE + `onDisconnected` sequence that
  makes Android render "Wrong password" is written and reasoned from AOSP source, never observed.
- **Callback transaction codes remain runtime-unverified** for everything except `onStateChanged`
  — which did fire, since Android reacted to the false AuthFailed. That is one code confirmed by
  its consequences; [30](30-wifi-aidl-surface.md)'s open question is narrowed, not closed.
- **EAP/enterprise and WEP are not carried across the seam**, by choice.
- **`getConnectionCapabilities` reports all-unknown.** NM publishes a bitrate but not PHY mode,
  bandwidth or spatial streams. It was also **malformed** and killed `system_server` on every
  association until fixed; see [34](34-wifi-second-radio.md).
- **The daemon still has no systemd unit** — it does not survive a reboot. Stage 5.

## Retesting safely

The outage above is repeatable, and worth not repeating. Either:

- **Add a second Wi-Fi adapter** and point the daemon at it — `waydroid-wifid --device wlan1`.
  `WifiBackend` was written for this ("multiple host radios are resolved HERE, below the contract")
  and needs no code change. The host keeps SSH on `wlp1s0` and nothing Android does can strand it.
  A VRF is not needed; if both land on one subnet, `ipv4.never-default` on the Android-driven
  profile is the lightweight answer. The honest caveat is that this tests the **control** path
  while Android's traffic still flows over the host's primary link.
- **Or accept the single-radio risk** with someone at the console, knowing that the host's own
  profile is never modified and `nmcli connection up <ssid>` is the one-line recovery.

## Running it

```bash
# dev box
wifi/build.sh --install

# bigtab01 -- once, needs a container-service restart and drops the kiosk to the greeter
sudo install -D -m 0644 manifest_android.hardware.wifi.supplicant.xml \
     /var/lib/waydroid/overlay/vendor/etc/vintf/manifest/
sudo systemctl restart waydroid-container.service

# bigtab01 -- every time
sudo waydroid-wifid --verbose &
sudo bin/wifi-wlan0.sh up          # not persistent; re-run after a container restart
sudo waydroid shell -- cmd wifi set-wifi-enabled enabled
bin/wifi-test.sh
```
