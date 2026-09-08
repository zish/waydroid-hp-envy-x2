# Wi-Fi credentials: who owns them, and making NetworkManager the owner

**Date:** 2026-09-08. **Status:** implemented, tested end to end, **inert until something is opted
in.** Answers a direct question — does Android keep its own PSKs, is NetworkManager the source of
truth, can Android take credentials from NM, and what happens when NM is changed from outside
Android.

## Where the passphrases actually live

**In two places, independently, and Android's copy is cleartext.**

```
$ cat /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml
<string name="SSID">&quot;vidiot&quot;</string>
<string name="PreSharedKey">&quot;...&quot;</string>
```

Not `EncryptedData` — plain text at rest. The file is `0600 system:system`, so it is not
world-readable, but anything running as `system` can read it. NetworkManager holds a second copy in
the `vidiot (Waydroid)` profile (`key-mgmt sae`, `psk-flags 0`, meaning the secret is stored in the
profile rather than agent-owned).

## NetworkManager was not the source of truth — Android was

The credential path through `waydroid-wifid` is strictly one way, and each link is nameable:

1. Android pushes the passphrase down on every connect — `setPskPassphrase`,
   [Supplicant.cpp](../wifi/Supplicant.cpp).
2. `NmBackend::connect()` calls **`Update`** on the existing profile —
   `connect(%s): updating our profile`, [NmBackend.cpp](../wifi/NmBackend.cpp).
3. Nothing ever reads credentials in the other direction.

So a host-side edit to the `(Waydroid)` profile's PSK was **silently overwritten** on the next
Android connect, and NM was a write-through projection of Android's config rather than an owner of
anything.

`Bss::known` — "the host already has a profile for it", [WifiBackend.h](../wifi/WifiBackend.h) — was
the one field meant to carry host knowledge upward. It was **declared and never set or read**: dead
code marking exactly the seam that was missing.

### What used to happen when NM changed outside Android

| Change on the host | What Android did |
|---|---|
| New network joined on the host | **Nothing.** It appeared in Android's scan list as an unsaved network wanting a password. |
| PSK edited on the `(Waydroid)` profile | Overwritten on Android's next connect. |
| `(Waydroid)` profile deleted | Recreated on the next connect. |
| Host associates the radio out of band | Measured: the daemon reported `COMPLETED` and `onStateChanged(6)`/`(9)`, and Android stayed `Wifi is not connected` — it only tracks connections it initiated, so there was no `WifiConfiguration` behind it. |

## The supplicant seam cannot fix this; `cmd wifi` can

The supplicant AIDL has no "here are my saved networks" direction, and Android never asks —
`listNetworks()` concerns the supplicant's transient list, not saved config. No amount of work on
the shim would help.

Android's own shell interface does exactly the job:

```
add-network <ssid> open|owe|wpa2|wpa3 [<passphrase>] ...
    Add/update saved network with provided params
```

Proven before any code was written, with a throwaway profile and a fake SSID:

```
$ cmd wifi add-network "zz-probe-net" wpa2 "probepassword123"
Save successful
$ grep -A2 zz-probe-net WifiConfigStore.xml
<string name="PreSharedKey">&quot;probepassword123&quot;</string>
```

So the reconciliation lives on the host, in the same shape as `waydroid-wifi-nudge`:
[artifacts/wifi/waydroid-wifi-sync](../artifacts/wifi/waydroid-wifi-sync), on a five-minute timer.

## The opt-in is a file, and that was not the first choice

Importing a network copies its passphrase into that cleartext store, and a laptop accumulates
conference and coffee-shop credentials that have no business being in a container. So **nothing is
shared unless it is named** in `/etc/waydroid-wifi-share.conf` (mode `0600`), one SSID per line.

A per-profile marker was the intended design — `nmcli connection modify <c> user.data.waydroid.share
yes` — and it does not work here:

```
Error: invalid or not allowed setting 'user': 'user' not among
[connection, 802-11-wireless, 802-11-wireless-security, 802-1x, ethtool, match,
 ipv4, ipv6, prefix-delegation, hostname, link, tc, proxy].
```

Fedora's NetworkManager 1.56.1 is built without the `user` setting. The one file turns out to be the
better answer regardless: it is the audit trail. You can see every passphrase that has been copied
into Android by reading a single file, which is not true of a flag scattered across profiles.

Matching is by **SSID**, because that is the level the two sides genuinely agree on — Android keys
saved networks by SSID and security type, while NM profile *names* are renameable display strings
([34](34-wifi-second-radio.md)).

## What it does, and the three rules that make it safe

**Forget detection runs before the import, and that order is load-bearing.** With the import first,
a network forgotten in Android is re-imported by the same run that then deletes its NM profile — so
"forget" leaves the network *saved in Android and gone from NetworkManager*, the exact inverse of
what was asked for. This was measured doing precisely that before the order was swapped:

```
waydroid-wifi-sync: importing "zz-sync-net" (wpa2) into Android     <- resurrected it
waydroid-wifi-sync:   deleted NM profile "zz-sync-test"             <- ...then deleted the original
```

**It adds missing networks and never overwrites one Android already has.** `add-network` is
"Add/update", so re-running it *would* clobber the existing config. The host profile's key-mgmt is
not a reliable statement of what Android should use: on this machine the host joins `vidiot` with
`wpa-psk` over `wlp1s0` perfectly well, while Android over the T3U can only complete the handshake
with SAE ([34](34-wifi-second-radio.md)). Importing the host's `wpa-psk` over Android's working
`wpa3-sae` would break a working connection using a mapping known to be unreliable. The cost is that
a passphrase changed on the host does not reach a network Android already knows — forget it in
Android and the next sync imports it afresh.

**The state file means "confirmed present in Android", never "we tried".** The state file is what
licenses a deletion, so recording a failed import would make the next run see the network missing
from Android, read that as a forget, and delete the host's profile. A failed import leaves no trace.

### Guards on the deletion

Deleting NM profiles from inside a container is the dangerous half, so:

- **Never a profile that is active on any device.** Verified against the live host:

  ```
  vidiot uuid=60ac2496-3008-47ef-a8fa-78db3b0744d0
  active on: wlp1s0
  => guard REFUSES deletion
  ```

- **Never a profile pinned to the interface carrying the host's default route.** The second adapter
  exists so Android can never strand the host ([34](34-wifi-second-radio.md)); a sync able to delete
  the profile the host is connected through would hand that back.
- **Never the daemon's own `(Waydroid)` profiles.** Those are projections of Android's config, not
  host-owned networks; their credentials came *from* Android.
- **Mass-forget refusal.** More than `MAX_FORGETS_PER_RUN` (default 1) networks disappearing at once
  is a wiped `WifiConfigStore.xml` — a factory reset or container reinstall — not a person
  forgetting networks one at a time. It logs and deletes nothing.

## Triggered when Android enables Wi-Fi, not only on the timer

A five-minute timer means a network added on the host can be five minutes away from appearing in
Android, and enabling Wi-Fi is the moment a person actually cares. So the daemon asks for a sync
then too, from `SUPPLICANT_addStaInterface` in [Supplicant.cpp](../wifi/Supplicant.cpp):

```
19:33:05 waydroid-wifid: addStaInterface(wlan0) -> serving ISupplicantStaIface
19:33:05 waydroid-wifid: Wi-Fi came up; asked waydroid-wifi-sync to reconcile ...
19:33:05 systemd[1]: Starting waydroid-wifi-sync.service ...
```

**`addStaInterface` and not `createClientInterface`**, because scan-only mode never reaches the
supplicant at all ([31](31-wifi-stage2.md)) — so this fires when Android has real Wi-Fi up rather
than on every scan-only transition.

It goes through `systemctl start --no-block` rather than running the script directly, for three
reasons: it must not block, because this runs on a binder thread inside a transaction Android is
waiting on; systemd already serialises the unit, applies its `SELinuxContext` and puts the output in
the journal beside every other run; and repeated start jobs for one unit are merged, so the repeated
setup attempts Android makes when something goes wrong cannot pile up syncs. `g_spawn_async()`
without `G_SPAWN_DO_NOT_REAP_CHILD` double-forks, so there is nothing to wait for and no zombie.

Failure is silent by design — a host with no unit installed must still bring Wi-Fi up normally.

## `nodelete`: sharing a network without risking the host's profile

An allow-list line may be followed by `nodelete`:

```
vidiot	nodelete
```

which shares the network with Android but never lets a forget in Android remove the host's profile.

This exists because the active-profile guard is weaker than it first looks. It protects a profile
that is up *at the moment the sync runs* — and the machine's owner had `vidiot` deliberately down
for a few minutes while changing its key-mgmt to `sae`. A forget in Android during that window would
have deleted the host's own profile with nothing to stop it. `nodelete` is the right setting for any
network the host itself depends on.

## Two bugs, both mine, both silent

**A bare `exec` redirection applies to the shell, not to the `exec`.** The single-instance lock was
written `exec 9>"$LOCK" 2>/dev/null`, which set fd 9 *and* pointed stderr at `/dev/null` for the
whole script — so every run worked correctly and logged absolutely nothing. Scoping it with braces
(`{ exec 9>"$LOCK"; } 2>/dev/null`) keeps stderr intact.

**"No networks" is an answer, not a failure.** Deleting host profiles on a bad reading is the worst
thing this script can do, so it refuses to act unless it is sure it read Android's list — and the
first version tested for the `Network Id` header alone. With nothing saved, Android prints the bare
words `No networks` and no header, so an **empty** Android was indistinguishable from an unreadable
one. That made the whole thing a silent no-op in exactly the state where importing matters most:
right after the user forgot their last network. Both forms are now recognised.

Neither was caught by the round-trip test below, because that test always ran with at least one
network already saved.

## Verified round trip

With a throwaway profile and a fake SSID, against the fixed ordering:

```
RUN A   waydroid-wifi-sync: importing "zz-sync-net" (wpa2) into Android
        waydroid-wifi-sync:   imported "zz-sync-net"
        Android: 4  zz-sync-net  wpa2-psk / wpa3-sae^

(forget zz-sync-net in Android)

RUN B   waydroid-wifi-sync: "zz-sync-net" was forgotten in Android; NM is the mirror, so removing it
        waydroid-wifi-sync:   deleted NM profile "zz-sync-test"
        Android: (gone, NOT resurrected)
        NM:      (profile deleted)
```

All test artifacts were removed afterwards and the host was returned to two profiles (`vidiot`,
`vidiot (Waydroid)`) with Wi-Fi still connected.

**One parsing detail worth keeping:** Android 13 adds an SAE parameter alongside WPA2 for
auto-upgrade, so one saved network prints as *two* rows with the same id — `wpa2-psk` and
`wpa3-sae^`. And an SSID may contain spaces while a network id and a security type never do, so
`list-networks` is parsed as first-field / last-field / everything-between.

## Using it

```bash
# on bigtab01 -- opt a network in
sudo sh -c 'echo "my-network" >> /etc/waydroid-wifi-share.conf'

# ... or share it without letting Android's forget delete the host's profile,
# which is what any network the host itself depends on should use
sudo sh -c 'printf "my-network\tnodelete\n" >> /etc/waydroid-wifi-share.conf'

sudo systemctl start waydroid-wifi-sync   # or enable Wi-Fi, or wait 5 minutes
journalctl -u waydroid-wifi-sync -n 20
```

`systemctl disable --now waydroid-wifi-sync.timer` stops all syncing; emptying the allow-list does
the same thing more quietly. **Shipped with nothing opted in**, so it does nothing until someone
decides what to share.

## Still not done

- **A passphrase changed on the host does not reach a network Android already has** — by choice, see
  above. Fixing it properly needs a trustworthy NM-key-mgmt → Android-security-type mapping, which
  the transition-mode finding in [34](34-wifi-second-radio.md) says we do not have.
- **EAP/enterprise is skipped** with a log line, consistent with the seam's existing scope.
- **Nothing reconciles the reverse direction for networks Android adds**: those still create a
  `(Waydroid)` profile through the daemon, which remains a projection rather than a host-owned
  network. Whether an Android-added network should become a first-class host profile is a policy
  question nobody has answered yet.
- `Bss::known` is still dead. It could now carry "the host has a profile for this" into the scan
  result, but Android has no use for the bit, so there is nothing to spend it on.
