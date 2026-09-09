# Wi-Fi: Android drives the host's own radio

**2026-09-09.** Android's Wi-Fi is now driven by `wlp1s0`, the machine's internal Intel radio,
instead of the TP-Link Archer T3U that [34-wifi-second-radio.md](34-wifi-second-radio.md) added.
This inverts a decision that three earlier documents rest on, so the reasoning is recorded here
rather than left to be inferred from a one-line config change.

**Status: in service, under observation.** The host was rebooted into this configuration on
2026-09-09 and is being used normally to see whether it holds up. Stability has *not* been
established — it is being monitored as it is used, and this document should be revisited with
what that shows. `--verbose` stays on for exactly that reason.

## The reported symptom, and why it was not a contradiction

> Wi-Fi shows down in Android but I can verify that Wi-Fi is up in a Linux virtual console.

Both observations were correct and they were about **different radios**. The console showed
`wlp1s0` associated with `vidiot`, holding `10.42.0.137` and the default route. Android was
driving the T3U (`wlp0s20u1`), pinned by factory MAC in `/etc/waydroid-wifid.conf`, and never
touched `wlp1s0` at all. A healthy host link says nothing about Android's Wi-Fi in that topology,
which is a diagnostic trap worth naming: **the two radios have to be checked separately, and
`nmcli device` output is per-device for a reason.**

Android's radio was genuinely dead:

- `wlp0s20u1` sat in NM state `disconnected` with **zero** access points, while `wlp1s0` could see
  `vidiot` at 67% and eight other networks.
- Its last association attempt, 23:00, failed in the kernel:
  `send auth to 76:BD:71:0F:A5:C2 (try 1/3 … 3/3)` → `authentication … timed out`. The daemon
  logged the matching `host failed to associate with "vidiot"`.
- Consequently Android logged `AllSingleScanListener: No candidates` on **every** scan cycle from
  01:05 to 02:01. With no candidate there is no connect attempt, and Wi-Fi reads as down.

This is consistent with [the T3U's known inability to associate with this AP](34-wifi-second-radio.md)
and with commit `9dbb8de`, which established that the AP is fine and `rtw88_8822bu` is not.

### One thing left unexplained

At 01:40 the daemon reported `getScanResults() -> 10 access points`; at 01:42 NM showed the T3U
holding **none**. Two candidate explanations, neither confirmed:

1. NM aged the list out as scans stopped returning results.
2. The `nmcli … list ifname wlp0s20u1` run during diagnosis forced a rescan that came back empty
   and pruned the stale entries.

Recorded rather than guessed at. It does not change the conclusion — the T3U was not delivering
usable scan results — but it is not settled.

## Why the swap, and what it costs

The owner's reason is the decisive one, and it is about what the machine is *for*:

> If I am 100% inside Android, then being able to manipulate NetworkManager directly is what I want
> anyway.

The T3U was introduced so Android could never strand the host. That guard only buys anything while
somebody administers the host from **outside** Android. On a machine used entirely from inside the
Android session, Android owning NetworkManager is the feature, and a spare radio Android cannot
reach is dead weight. The T3U stays plugged in as a back door for the human, not as Android's radio.

**What this gives up**, stated plainly: Android's Wi-Fi toggle, a disconnect, or a failed
association now act on the link the machine is administered over. Trap 5 of
[33-wifi-stage4.md](33-wifi-stage4.md) is no longer hypothetical — it is the accepted operating
mode. The mitigations that survive are the two that were always the right ones, and they are
unchanged: profiles we create are named `"<ssid> (Waydroid)"` and nothing else is ever read,
written or deleted, and `forget()` deletes only ours. A password mistyped in Android still cannot
overwrite the host's own profile.

## The code change: the routing guard had to become conditional

`NmBackend::buildSettings()` hardcoded `never-default=TRUE` and `route-metric=1000` into every
profile the daemon creates. Its comment stated the assumption it was built on — *"The radio Android
drives is a second adapter; the host reaches the world over its own."*

Once Android drives `wlp1s0`, that assumption inverts into the fault it was written to prevent.
NM allows one active connection per device, so activating our profile **displaces the host's own**,
and `never-default` means nothing supplies a default route afterwards. The host loses its route off
the machine, and because Waydroid NATs `waydroid0` out of that route, **Android loses connectivity
too, while reporting itself connected.**

This is not theoretical. Verification below shows `wlp1s0` did end up carrying
`"vidiot (Waydroid)"` rather than the host's `vidiot`. Under the old code that is the exact moment
both would have gone offline.

### The predicate

The question is **not** "which adapter is this" but "is somebody **else** carrying the host's
default route". NM's `PrimaryConnection` answers it directly:

| state | answer |
|---|---|
| another device holds it | yield, exactly as before |
| this device holds it | keep supplying it; we are the lifeline |
| nothing holds it | there is no route to protect |

`NmBackend::yieldDefaultRouteToHost()` reads `PrimaryConnection`, then its `Devices` array, and
compares against our own device path.

Two details that are load-bearing:

- **It asks NM rather than comparing against our own `--device` argument.** That is what makes it
  stable across re-activation: once our profile *is* the default route, the device carrying it is
  ours, so the answer does not flip back and strand the host on the next reconnect. A predicate
  written as "am I the T3U?" would have been correct once and wrong forever after.
- **Every failure path returns `true`**, the cautious answer. Yielding costs Android a default
  route it does not use today anyway (`wlan0` is a veth onto `waydroid0`); wrongly *taking* the
  route costs the host the link it is administered over. The asymmetry picks the default.

`carriesHostDefaultRoute()` already existed but is used only for **auto-selection**, and was left
alone. It answers a different question and is called from `init()`.

The branch is logged either way — [35-wifi-stage5.md](35-wifi-stage5.md)'s lesson was that the one
handler which logged nothing was the one quietly breaking Wi-Fi.

## The second blocker: a wedged IpClient, and it was not ours

Repointing the radio fixed scanning and selection immediately, and revealed a completely separate
fault that had been masked by "no candidates". Android now chose a network and called
`connectToNetwork` — and nothing happened:

```
02:02:27.592  WifiClientModeImpl[wlan0]: Start makeIpClient ifaceName = wlan0
02:02:27.594  44147/44161  Binder: Caught a RuntimeException from the binder stub implementation.
02:02:27.594  44147/44161  Binder: DeadSystemException: The system died; ...
02:02:29.592  WifiClientModeImpl[wlan0]: disconnectedstate enter        <- 2.000 s timeout
02:02:31.182  WifiClientModeImpl[wlan0]: IpClient is not ready, START_CONNECT dropped
```

`ClientModeImpl` drops every `START_CONNECT` **before the supplicant**, which is why
`waydroid-wifid` logged nothing at all for any of them — a useful signature in its own right:
**if Android says it is connecting and the daemon is silent, the call is not reaching the daemon,
and the fault is above it.**

The cause: `makeIpClient` was landing on `com.android.networkstack.process` **44147**, an orphan of
a `system_server` that had already died. It threw `DeadSystemException` instead of creating the
IpClient, and the live NetworkStack never saw the request. Five networkstack processes were
running, four of them reparented to init.

Correlation confirmed on both attempts — same PID, same thread, 2 ms after the call, twice.

What was **ruled out** on the way:

- **Android having disabled the network** after the T3U's repeated auth failures. Wrong: the config
  read `NetworkSelectionStatus NETWORK_SELECTION_ENABLED` and `hasEverConnected: true`.
- **The NetworkStack service being dead.** Wrong: `dumpsys network_stack` answered normally with
  exit 0. But its `Recently active IpClient logs:` and `Other IpClient logs:` sections were both
  **empty**, which is what pointed at the call going somewhere else rather than failing.
- **A transient binder hiccup.** An Android Wi-Fi off/on toggle re-entered `ConnectableState` and
  issued a fresh `makeIpClient`, which failed identically. The toggle is not a fix.

Worth noting this was the root blocker for *all* Android networking, not just Wi-Fi: inside the
container `wlan0` had no address and there was no interface but `lo`. IpClient is what does the
DHCP.

### The fix, and what it cost

Killing the four orphans (`724 35065 39420 44147`) cleared it. **This restarted `system_server`**:
killing the binder servicemanager had registered as `network_stack` trips AOSP's own recovery path,
in which `system_server` deliberately restarts itself when the network stack dies. Lineage reloaded
to the lock screen.

That cost was **not predicted before running the kill**, and should have been. The container itself
did not restart, so the kiosk session did not drop to the SDDM greeter — but a
`systemctl restart waydroid-container.service` would have been the honest way to ask for a restart
that was going to happen anyway.

After the restart, a fresh `system_server` (57186) and `network_stack` (57445) came up parented to
zygote, and enabling Wi-Fi connected on the first attempt.

## Verification

Daemon, taking the new branch and updating the profile it already owned:

```
connect(vidiot): this radio is the host's own path off the machine -- letting our profile carry the default route
connect(vidiot): updating our profile /org/freedesktop/NetworkManager/Settings/2
```

The resulting profile — note `interface-name`, which NM's `Update` rewrote from `wlp0s20u1`
because `Update` replaces the whole settings dict:

```
connection.interface-name:  wlp1s0
802-11-wireless-security.key-mgmt:  sae
ipv4.never-default:  no          <- the change
ipv4.route-metric:   -1          <- unset; NM's own default applies
```

Android:

```
Wifi is connected to "vidiot"   BSSID: 76:bd:71:0f:a5:c2   Security type: 4 (SAE)
Supplicant state: COMPLETED     RSSI: -65   Link speed: 130Mbps
wlan0: 192.168.240.112/24
NetworkCapabilities: [ Transports: WIFI Capabilities: ... INTERNET ... VALIDATED ... ]
```

Host, unaffected:

```
ip route get 1.1.1.1  ->  via 10.42.0.1 dev wlp1s0 src 10.42.0.137
wlp1s0: connected: vidiot (Waydroid)
```

That last line is the point. Android's profile **is** the active connection on the host's own
radio, and the host still has its route.

## Incidental finding: the AP is the dev box

While tracing the return path, `/proc/net/fib_trie` on the dev box showed it holding **`10.42.0.1`**
— bigtab01's gateway — on `wlp0s20f3`, with a link route for `10.42.0.0/24`. The dev box's hostname
is `vidiot01` and the SSID is `vidiot`.

So the AP that Android connects to, and that the T3U has never managed to authenticate against, is
**the development machine's own hotspot**. AP mode could not be confirmed directly (no `iw`,
`nmcli` or `/proc/net/wireless` visibility from the build sandbox), so this is strong circumstantial
evidence rather than proof. Two consequences if it holds:

- The rtw88_8822bu association failure is against an AP that is fully controllable, which makes it
  far more tractable than it looked.
- bigtab01 and the dev box are on the same L2 segment, so the dev box's ssh access does not depend
  on bigtab01's default route. That is why the swap was safe to perform remotely.

## What is not done

- **The T3U is no longer a back door.** Its only profile was `vidiot (Waydroid)`, and our
  `connect()` retargeted that profile's `interface-name` to `wlp1s0`. The adapter now has **no NM
  profile at all**, `autoconnect` or otherwise, and it has never completed an association with this
  AP. Making it a genuine rescue path is separate work — most likely a WPA2-PSK profile of its own
  with `autoconnect=yes` and a route metric that loses to `wlp1s0`.
- **One orphaned `network_stack` (49518) remains.** It became an orphan when `system_server`
  restarted. If `system_server` dies again the same wedge can recur, and killing that orphan would
  restart `system_server` again. The clean break is a container restart at a convenient moment.
- **`AGENTS.md` goal 4 still describes the T3U topology.** Deliberately not updated in this commit:
  the file has uncommitted work from another session referencing `docs/36-packaging.md` and
  `docs/37-brightness.md`, which are themselves untracked, so committing it would cite files that
  do not exist. It needs a pass once that work lands.
- **`/etc/waydroid-wifid.conf` on the host has the new value but the old commentary.** The installer
  writes that file only when absent, so updating the repo template does not propagate to a host that
  already has one.
- **Signal and state fidelity in Android's UI remains unreviewed**, unchanged from
  [35-wifi-stage5.md](35-wifi-stage5.md).
