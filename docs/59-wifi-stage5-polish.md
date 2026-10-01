# 59 — Wi-Fi Stage 5 polish: a 10 dB RSSI error, and the forget nobody was listening for

*2026-09-30. Works the open list at the end of [docs/35](35-wifi-stage5.md), carried forward
through [docs/38](38-wifi-primary-radio.md). **Four items closed, all verified on hardware**: the
RSSI conversion was wrong by up to 10 dB and is now exact; `NmBackend::forget()`'s missing caller
turned out not to belong at the seam everybody expected, and the reconciler that replaces it is
built and tested; P2P/RTT/NAN/SoftAP are confirmed already-unsupported rather than missing; and
`getConnectionCapabilities`' `technology` field is now a closed question rather than an open one.*

## One-paragraph summary

The headline is a **signal-strength bug that had been live since Stage 3 and that every test
passed**. `NmBackend` converted NetworkManager's 0..100 `Strength` to dBm with `quality/2 - 100`,
which assumes NM's range is −100..−50 dBm. It is −100..−40. The error is zero at the bottom of the
scale and **10 dB at the top**, and at this machine's actual signal level it was 8.5 dB — Android
was being told −71 dBm on a link nl80211 measured at −62. That is not cosmetic: this image's
`ScoringParams` are `rssi2=-83:-80:-73:-60`, so a link 1 dB shy of *good* was being reported 1.5 dB
above *insufficient* and 11 dB from the threshold at which the framework abandons a network. The
correct inverse is `-100 + 3*quality/5`, which is **exact** — not a better approximation.
Separately, `NmBackend::forget()` had no caller, and the seam that looked like its home,
`ISupplicantStaIface.removeNetwork`, fires on every reconnect rather than on a forget; that was
measured from the journal before any code was written, and wiring `forget()` there would have
deleted the profile the host is administered over every time Wi-Fi was used. The reconciliation
went into `waydroid-wifi-sync` instead.

## The RSSI conversion, and why nothing caught it

[NmBackend.cpp](../wifi/NmBackend.cpp)'s two conversion sites both did this:

```c
bss.rssiDbm = (int32_t) (quality / 2) - 100;   /* 0 -> -100, 100 -> -50 */
```

The comment states the assumption plainly, and the assumption is wrong. NM's
`nm_wifi_utils_level_to_quality()` is

```
quality = 100 - (int)(100.0 * |clamp(dBm, -100, -40) + 40| / 60.0)
```

so the range is −100..−40 and the step is 3/5 dBm per quality point, not 1/2.

**Nothing caught it because every check only ever asked whether the number was a plausible negative
one.** `bin/wifi-test.sh` verified that scan results arrived with RSSI values; `dumpsys wifi` showed
−70 and −76 moving around like a real signal; docs/32's Stage 3 verification confirmed "the right
names, signal strengths and security flags" against NM's `SIGNAL` column — which is the quality
percentage, the input to the broken function, not an independent measurement. Every one of those
passes just as happily with a 10 dB offset.

### How it was measured

Pairing NM's `Strength` against `iw dev wlp1s0 scan dump`'s `signal` has one trap: read them
seconds apart and you measure the signal moving, not the mapping. The first attempt did exactly
that and produced a −5 dB "error" on a single AP, which is noise. **Both views have to come from
the same scan** — so ask NM to rescan, wait for it to finish, and only then read both, since NM's
AP objects and the kernel's scan cache are built from the same sweep.

Three rounds, 31 paired observations, 13 distinct APs:

```
  NM  iw dBm  q/2-100    err  -100+3q/5    err  SSID
   7     -96    -96.5   -0.5      -95.8   +0.2  TheSeid-Admin
  12     -93    -94.0   -1.0      -92.8   +0.2  AdventurousEagle
  20     -88    -90.0   -2.0      -88.0   +0.0  OffToDisney
  27     -84    -86.5   -2.5      -83.8   +0.2  Verizon_NRQ6V4
  37     -78    -81.5   -3.5      -77.8   +0.2  wifi5
  57     -63    -71.5   -8.5      -65.8   -2.8  vidiot        <- the connected AP
  70     -58    -65.0   -7.0      -58.0   +0.0  my-wifi-can-beat-up-your-wifi
  72     -57    -64.0   -7.0      -56.8   +0.2  my-wifi-can-beat-up-your-wifi

  q/2-100 : mean -2.95 dB  stdev 2.42  max|err| 8.5
 0.6q-100 : mean -0.05 dB  stdev 0.74  max|err| 2.8
least-squares fit: dBm = 0.616*q - 100.42   (q=0 -> -100.4, q=100 -> -38.8)
```

That table is the real-valued mapping, which is why the columns carry halves. The code does integer
division, so the shipped form returned −97 where the table says −96.5 — slightly *worse* than the
real-valued version, never better. The integer results are the ones in the comment on
`rssiFromQuality()` and in the round-trip below.

The fit lands on NM's documented clamp range. The only rows with any error at all are `vidiot`, the
**connected** AP, whose signal NM polls continuously and which therefore moves between the scan and
the read — which is itself a finding, recorded below.

In integer arithmetic the inverse is not merely close, it is exact, because C's truncating division
lands on the same value NM truncated away:

```
over all 61 dBm values NM can represent:
  q/2-100        : 58 wrong, worst error 10 dB
  -100+(3q)/5    : 0 wrong
against the 13 field observations:
  q/2-100        : 13 of 13 wrong, worst 7 dB
  -100+(3q)/5    : 0 of 13 wrong
```

### What it cost, in this image's own numbers

`dumpsys wifi` on this image reports `ScoringParams: rssi2=-83:-80:-73:-60` — exit, entry,
sufficient, good for 2.4 GHz. The machine's AP sits at about −62 dBm. So:

| | true | as reported |
|---|---|---|
| RSSI | −62 | −71 |
| versus *good* (−60) | 2 dB below | 11 dB below |
| versus *sufficient* (−73) | 11 dB above | **1.5 dB above** |
| versus *exit* (−83) | 21 dB above | 11.5 dB above |

The reported value sat 1.5 dB above the point where the framework stops considering the network
sufficient. An ordinary fade — the kind the score history shows happening every few seconds, −70 to
−76 and back — was enough to cross it. This is a plausible contributor to
[docs/35](35-wifi-stage5.md)'s unexplained "host's link dropped twice for ~10 minutes while Android
sat in its failed-validation retry loop", though nothing here proves that and the item stays open.

### The fix

One helper, so the two call sites cannot drift apart again —
[NmBackend.cpp](../wifi/NmBackend.cpp)'s `rssiFromQuality()`, called from `scanResults()` and
`state()`. The measurement table lives in the comment above it, because the next person to read
`quality / 2` and think it looks about right deserves the numbers rather than an assertion.

### Verified in service

Before and after, on the same AP, reading NM's `Strength` and Android's `WifiInfo` together:

```
before:  NM_strength=58   android=-71   old formula -71   exact inverse -66
after:   NM_strength=59   android=-65                     exact inverse -65
```

Android's value now *is* the exact inverse. The score history moved with it — `rssi=-67, s1=56`
where the same link had been logging `rssi=-70/-71, s1=52/53` — and the network stayed
`VALIDATED` with working internet across the daemon restart.

A regression check went into [bin/wifi-test.sh](../bin/wifi-test.sh), and **the first version of it
was wrong in the way this whole document is about**: it read one `(Strength, RSSI)` pair and FAILed
on a disagreement over 3 dB. It promptly FAILed on a correctly working daemon by 6 dB — because NM's
`Strength` for the connected AP lags, which is the finding two sections down. Measuring once is what
produced the bogus −5 dB during calibration too.

The shipped version samples four times, two seconds apart, and the discriminator is **not** whether
the values differ. It is whether Android's value equals `quality / 2 - 100` *exactly, every time* —
a deterministic formula, which drift cannot keep hitting. One sample agreeing within 3 dB passes;
all four matching the old form FAILs and says why; anything else WARNs, because a false FAIL here is
worse than silence. The exact-match test is also skipped where the two formulas coincide, at the
bottom of the scale, since agreement there proves nothing. All five paths were exercised with
synthetic pairs:

```
old binary        FAIL  all 3 samples exactly quality/2-100
fixed binary      OK    3 of 3 agreed
fixed + NM lag    WARN  no agreement, but not the old form either
bottom of scale   OK    both formulas coincide, no false FAIL
no samples        WARN  not associated
```

Against the live host after the fix: `OK Android -71 dBm, host Strength 49 means -71 dBm (4 of 4
samples agreed)`.

## Saved networks: the forget signal does not exist where it looks like it should

[docs/35](35-wifi-stage5.md) left `NmBackend::forget()` fully implemented with **nothing calling
it**, so a network forgotten in Android kept its `"<ssid> (Waydroid)"` profile — PSK included — in
NetworkManager. It also said what to do before writing any code: count `removeNetwork()` lines in
the journal and find out whether that transaction fires outside a forget.

**It does, and the journal had already answered it.** The daemon runs with `--verbose` from boot, so
one boot's worth of log was enough — on `vidiot`, a network that was never forgotten and was still
connected at the end:

```
20:45:56 removeNetwork(1)
20:46:51 addNetwork() -> id 2      <- 55 s later, same SSID
20:47:14 removeNetwork(2)
20:47:22 addNetwork() -> id 3
21:50:20 removeNetwork(3)
21:50:28 addNetwork() -> id 4
23:34:13 removeNetwork(4)
23:34:22 addNetwork() -> id 5
```

Four calls, every one part of an ordinary reconnect: the shim holds one network at a time, so
Android clears the supplicant's list as a routine step. **Wiring `forget()` there would have deleted
the saved profile every time Wi-Fi was used** — and under
[docs/38](38-wifi-primary-radio.md)'s primary-radio configuration that profile is the one the host
is administered over. The predicted trap was real, and the prediction cost nothing to check because
the evidence was already on disk.

So the reconciliation happens on the host, in
[artifacts/wifi/waydroid-wifi-sync](../artifacts/wifi/waydroid-wifi-sync), which already had the
right shape for it.

### Ownership is by UUID, and the existing script had this wrong

The reap must know which profiles are the daemon's. The script already made that distinction in two
places and made it by name:

```sh
case "$cid" in
*" (Waydroid)") continue ;;   # the daemon's own; not ours to reap
esac
```

[NmBackend.cpp](../wifi/NmBackend.cpp)'s `connectionId()` carries a long comment explaining why
that is not safe: `connection.id` is a display string, the desktop GUI can rename it, and NM does
not require it to be unique — so *"somebody naming a profile `coffeeshop (Waydroid)` would hand us
write access to it"*. The daemon therefore identifies its own profiles by a deterministic
**RFC 4122 v5 UUID** over a fixed namespace and the SSID, reproducible from nothing but the SSID.

The script now reproduces that derivation in bash and compares UUIDs. It was checked against the
C++ on five SSIDs including one with a space and the empty string, and against the two live profiles
on the machine:

```
vidiot   14921b3a-4895-5fcb-8d38-a71863bef507   matches the live profile
wifi5    35bb2cb7-38e2-5a00-8979-04ae0149c43b   matches the live profile
```

Both pre-existing name-based tests were switched to the UUID predicate too. That is a fix and not
just tidying: by name, a *host* profile somebody happened to call `foo (Waydroid)` was being spared
from a deletion its owner had opted into, and one of ours that somebody renamed was being handled
by the wrong half of the script under the wrong rules.

### The script had to be reordered, and the reason is the default

The allow-list in `/etc/waydroid-wifi-share.conf` governs **host-owned** profiles, because those
belong to the machine's owner and sharing them is opt-in. The daemon's own projections are ours
outright. The script used to exit at the top when the allow-list was absent or empty — which is the
default state — so a reap placed after that gate would never run on a stock host.

The order is now: Android-booted check → read Android's saved networks → **reap stale projections**
→ opt-in gate → host forget → import. The allow-list is still *parsed* before the reap, because
`nodelete` has to be able to protect an SSID in both halves.

### The guards, and the one that was deliberately left out

| guard | why |
|---|---|
| UUID must be the one we would derive | ownership, per the above |
| Android must no longer have the SSID saved | that is what "forgotten" means |
| never a profile active on any device | deleting the live one strands the host |
| never `autoconnect=yes` | somebody has adopted it; it is no longer a projection |
| never more than `MAX_REAPS_PER_RUN` (1) at once | see below |

`canDelete()`'s **default-route guard is deliberately not applied here.** It refuses to delete a
profile pinned to the interface carrying the host's default route — and under
[docs/38](38-wifi-primary-radio.md) every profile of ours is pinned to exactly that interface, so
applying it would refuse every reap there is. The feature would have installed, logged nothing, and
done nothing, on the machine it was written for. It is safe to drop because the active-profile guard
already covers the live case and our projections are `autoconnect=no`: NM will never raise one by
itself, so a profile that is not up right now is not something the host is relying on.

The **mass-reap refusal gets its own budget** rather than sharing `MAX_FORGETS_PER_RUN`, and it
matters more than the host-side one. A wiped `WifiConfigStore.xml` makes every projection look
forgotten at once — and once Android has lost a passphrase, our profile holds **the last copy of
it**. The host-side mass-forget refusal protects against unsharing a network; this one protects
against destroying the user's passwords.

### Tested, with synthetic networks

Five cases, using `zz-reap-test` and `zz-reap-two` so no real credential was ever at risk. The
machine finished byte-for-byte where it started.

| | scenario | expected | result |
|---|---|---|---|
| T1 | saved in Android, our profile exists | no reap | **pass** — silent |
| T2 | forgotten in Android | reaped | **pass** — `deleted NM profile "zz-reap-test (Waydroid)"` |
| T3 | named `(Waydroid)`, foreign UUID | survives | **pass** — name is not ownership |
| T4 | our UUID, `autoconnect=yes` | survives | **pass** — logged as adopted |
| T5 | two stale at once | refuses both | **pass** — and both reaped at `MAX_REAPS_PER_RUN=2` |
| T6 | stale profile, **no allow-list at all** | reaped anyway | **pass** — this is the case the reorder exists for, and the default state of a stock host |

T1 also exercised the duplicate-row case for free: Android listed `zz-reap-test` twice, as
`wpa2-psk` and `wpa3-sae^`, and the existing dedupe handled it. T6 caught two consequences of the
reorder that the first draft had wrong: the allow-list is now read *before* anything has checked the
file exists, so the read needed its own `-r` guard or every stock host would emit a redirection error
on every run; and `wanted_contains()` could now be reached with an empty `WANTED` under `set -u`,
which the `${a[@]+...}` guard its sibling already had now covers too.

**The active-profile guard is verified by predicate only, not end to end.** Reaching it needs one of
our profiles to be live *and* its SSID absent from Android, and the only live one is `vidiot`,
which is also `nodelete` and is the link this machine is administered over. The predicate was
checked against it directly:

```
vidiot (Waydroid)   active=wlp1s0   -> REFUSE
wifi5 (Waydroid)    active=(none)   -> allow
```

The query is the same one `canDelete()` uses and which [docs/36](36-wifi-credential-sync.md)
verified live. That is weaker than the other five and is recorded as such.

A standing invariant check went into [bin/wifi-test.sh](../bin/wifi-test.sh): any profile of ours
whose SSID Android no longer has saved is a FAIL, with `sudo waydroid-wifi-sync` as the remedy.

## P2P, SoftAP, RTT and NAN: already handled, as suspected

[docs/35](35-wifi-stage5.md) said to confirm rather than build. Confirmed:

```
$ pm list features | grep -i wifi
feature:android.hardware.wifi
```

One line. `android.hardware.wifi.direct`, `.rtt` and `.aware` are absent, so Android already
considers Wi-Fi Direct, RTT and NAN unsupported — the Stage 0 overlay declares only the base
feature and that was the right call. SoftAP is not a `pm` feature, so it was checked separately:
`cmd wifi get-softap-supported-features` returns nothing at all, i.e. an empty feature set.

**Nothing to build. The item is closed by measurement.**

## `getConnectionCapabilities`: `technology` is a closed question now, not an open one

The handler answered all-unknown, which [docs/34](34-wifi-second-radio.md) and
[docs/35](35-wifi-stage5.md) both carried as an open item. It stays UNKNOWN, and that is now a
conclusion.

`technology` wants the PHY the station **negotiated** — HT, VHT, HE, EHT. NetworkManager does not
have it. The only candidate it exposes is `AccessPoint.MaxBitrate`, and that is the AP's advertised
*capability*, not a rate on this link. Measured across every AP in range:

```
freq=2422  bw=20  MaxBitrate=1170000   NTGRBH_E0C2500D818B
freq=2462  bw=20  MaxBitrate=1170000   f48fc5
freq=2412  bw=20  MaxBitrate= 540000   Harpoapt
freq=5180  bw=80  MaxBitrate=1170000   wifi5
```

**1170 Mb/s on a 20 MHz channel at 2.4 GHz is not optimism, it is impossible.** The number is the
AP's best case across all its radios and widths, and it cannot be inverted into a PHY. Nor would
the AP's capability answer the question if it could: the technology is the *minimum* of the AP's and
the station's, and this machine's card is a 2×2 HT/VHT Broadwell-era part that will negotiate VHT
against the HE AP above. Reporting HE from the beacon would be wrong on exactly the networks where
the field matters.

Leaving it UNKNOWN is also the *safer* wrong answer: `ThroughputPredictor.predictThroughput()` falls
back to a floor, visible in `dumpsys wifi` as a flat `txTput=10,rxTput=10`, whereas a wrong standard
makes it predict confidently and wrongly. The value is available from nl80211 —
`NL80211_STA_INFO_TX_BITRATE`'s rate-info flags are what `iw link` prints as `MCS 15 short GI` — so
this is a few hundred lines of netlink the daemon does not link today, not missing information.

**`channelBandwidth` is different and is now reported**, from NM's `AccessPoint.Bandwidth` (added in
NM 1.44), which is the operating width out of the HT/VHT/HE operation IE and a real property of the
channel in use. It carries through `LinkState::channelWidthMhz`.

### The framework's side was read out of the image, not assumed

`ConnectionCapabilities.channelBandwidth` is typed as a bare `int` in the AIDL, so its encoding had
to come from somewhere. Both mappings were disassembled from this image's own `service-wifi.jar`
with `dexdump`:

```
SupplicantStaIfaceHalAidlImpl.getWifiStandard(t):
    1 -> 1 (LEGACY)   2 -> 4 (11N)   3 -> 5 (11AC)   4 -> 6 (11AX)   5 -> 8 (11BE)   else 0
SupplicantStaIfaceHalAidlImpl.getChannelBandwidth(cb):
    1 -> 1   2 -> 2   3 -> 3   4 -> 4   7 -> 5 (CHANNEL_WIDTH_320MHZ)   else 0 (20 MHz)
```

So the wire value is `WifiChannelWidthInMhz`: 0 = 20 MHz, 1 = 40, 2 = 80, 3 = 160, 4 = 80+80,
7 = 320. The daemon maps NM's MHz onto those. The same disassembly settled one more thing: the
framework reads `legacyMode` only to test `== 2` for `is11bMode`, so nothing else in that enum is
load-bearing.

The parcel **layout is unchanged** — still the non-null marker, the size, and five ints. That
matters: this is the handler whose missing marker killed `system_server` on every association in
Stage 4, and changing values is safe in a way that changing layout is not.

```
[waydroid-wifid] getConnectionCapabilities() -> technology UNKNOWN, channelBandwidth 0
```

### The obvious way to fetch the width is a data race, and two already exist

The first version of this read `mBackend->state().channelWidthMhz` straight from the handler. That is
wrong, and the daemon's own comment on `requestCredentialSync()` says why without connecting it:
**transaction handlers run on a binder thread**, while link events arrive on the GLib main loop.
`NmBackend::state()` goes through `wifiDevicePath()`, which *writes* `mDevPath` and can rewrite
`mIfname` when the radio has been renamed underneath it — so calling it from a handler races two
`std::string`s against the main loop.

It is cached from `onHostLinkEvent` instead, in an `std::atomic<int32_t>`. The event already carries
the value and always arrives first, because the `COMPLETED` the daemon sends from that same event is
what makes Android ask.

**Two instances of this race already exist and were not introduced here**:
`STAIFACE_getMacAddress` calls `mBackend->macAddress()`, and the connect and disconnect handlers call
`mBackend->connect()` / `disconnect()` — all of which reach `wifiDevicePath()` from a binder thread.
They have never been observed to misbehave, and the window is small: `mDevPath` is only rewritten
when NM's revalidation fails or the interface has been renamed. Recorded as open rather than fixed,
because fixing it properly means deciding whether the backend gets a lock or whether handlers post
work to the main loop and wait — a design question, not a patch.

## `Wpa2Wpa3Psk` → `wpa-psk` is correct, and the flag can come off it

[docs/34](34-wifi-second-radio.md) and [docs/35](35-wifi-stage5.md) both listed
"`Wpa2Wpa3Psk` still maps to `wpa-psk`" as an open item, implying a downgrade. **It is not one.**
NM's own man page on this host says so:

```
"wpa-psk" (WPA2 + WPA3 personal), "sae" (WPA3 personal only)
```

`wpa-psk` covers both legs and `sae` would refuse the WPA2 one, so the mapping in `buildSettings()`
is the right choice and its comment was already correct. No change. The related mapping in
`waydroid-wifi-sync`, NM `wpa-psk` → Android `wpa2`, is fine for the same reason from the other
side: Android auto-upgrades a saved WPA2 network to SAE, which T1 showed directly — one saved
network printing as both `wpa2-psk` and `wpa3-sae^`.

## Two smaller findings

**NM's `Strength` for the connected AP lags.** It was the only AP with any error in the 31-sample
calibration, and it showed up again afterwards: NM reporting 69 while `iw` read −62, where 69 means
−59. NM polls the associated AP's signal on its own schedule and the scan-derived value can be
seconds stale. This puts a floor under how closely Android's RSSI can track the radio, independent
of the conversion, and it is another thing reading nl80211 directly would fix.

**`dumpsys wifi`'s Wi-Fi timestamps are three weeks and three hours off, and both are illusions.**
The score history prints `8-30 16:36` on a host whose clock reads `Sep 30 19:38 EDT`, which looks
like a wedged clock of exactly the kind [docs/48](48-battery-frozen-and-netd-stale.md) is about. It
is not: `java.util.Calendar`'s `MONTH` is **0-based**, so `8` is September, and the time is
`America/Los_Angeles` where the host is `EDT`. The host and container clocks agree to the second.
Worth writing down because the next person to see it will reach for docs/48 first.

## What is still open

**Worked through on 2026-10-01 — see [60](60-wifi-nl80211.md).** Four of the items below are
closed and annotated in place, and one of them closed differently than this document expected: the
packet counters cannot be fixed at the wificond seam at all, because Android never calls the one
wificond method that carries them. docs/60 also found what made the whole list worth doing — a
`getDeviceWiphyCapabilities` stub returning null, which makes the framework's throughput predictor
return 0 before it reads any of the values below.

Unchanged from [docs/35](35-wifi-stage5.md) and [docs/38](38-wifi-primary-radio.md):

- ~~**The rtw88 wedge still has no automatic trigger**~~ **CLOSED AS OUT OF SCOPE. The T3U was a
  back-door management link to bigtab01 during Wi-Fi connectivity testing, not a radio this project
  intends to drive**, and it is not plugged in any more. The wedge is a fault in a driver for an
  adapter that is not a supported configuration here. `bin/wifi-radio-reset.sh` stays, scoped to
  that adapter, and the `nmcli connection up` discriminator stays mandatory before running it. The
  multi-radio machinery — `--device`, factory-MAC pinning, `carriesHostDefaultRoute()` — is
  unaffected and still load-bearing. See [60](60-wifi-nl80211.md).
- **The host's two ~10-minute link drops of 2026-09-18 are still uninvestigated.** The RSSI error
  above is a plausible contributor and nothing more; it is not evidence.
- **Scan staleness after repeated daemon restarts** — docs/35's false trail, still not diagnosed.
- **The wrong-password path is still unproven.**
- ~~**Packet counters and link-layer stats are all zero**~~ **PARTLY CLOSED, AND THIS WAS REALLY
  TWO ITEMS.** `IClientInterface.getPacketCounters` now reports `NL80211_STA_INFO_TX_PACKETS` and
  `TX_FAILED` instead of a hardcoded `{0, 0}` — but **Android never calls it on this host**:
  that call is tied to a link probe and `SendMgmtFrame` has never fired in the daemon's entire
  journal, so the fix is latent. The `tx_good`/`tx_retry`/`tx_bad`/`rx_pps` columns are the other
  item and **cannot** be fixed here: they come from `IWifiStaIface.getLinkLayerStats`, which is the
  vendor HAL this daemon does not serve. See [60](60-wifi-nl80211.md).
- ~~**Rx link speed is reported as Tx**, because NM exposes one `Bitrate`.~~ **DONE.**
  `NL80211_STA_INFO_RX_BITRATE` is a separate attribute, so the two are now independent — Android
  read 144 Mb/s tx against 1 Mb/s rx where it had reported 130 for both. See
  [60](60-wifi-nl80211.md).
- ~~**`technology` needs nl80211**, per above — now scoped rather than vague.~~ **DONE, and the
  scoping was right about the mechanism and wrong about the payoff.** The PHY comes from which MCS
  attribute the driver sends on `TX_BITRATE`; Android's "Wi-Fi standard" now reads 4 (11N) instead
  of 0. But reporting it changes nothing on its own, because `getDeviceWiphyCapabilities` was
  returning null and the predictor gives up on that first. See [60](60-wifi-nl80211.md).
- **The active-profile guard on the reap is verified by predicate, not end to end.**
- ~~**`NmBackend` is called from binder threads in three places and is not thread-safe**~~
  **DONE.** `mIfname`, `mDevPath` and `mSelectorMac` are guarded by a `std::recursive_mutex`, and
  the nl80211 path shares no mutable state at all — it is keyed by an ifindex in a
  `std::atomic<int>` rather than by a name. A mutex rather than posting work to the main loop,
  because the main loop itself calls into Android and waiting on it from a binder thread is a cycle
  with no timeout. See [60](60-wifi-nl80211.md).

## Packaged and deployed, and the shadowing nobody had written down

Built the same day: **`waydroid-ext-wifid` 1.0.1** (patch digit — the fixes are internal and no
interface moves), **`waydroid-ext-wifi-sync` 1.1.0** (minor digit, because the reap is new behaviour
that *deletes* something), and **`waydroid-ext-wifi-hostd` 1.0.1** rebuilt unchanged to confirm the
RPM matches the tree.

The packaged daemon is **byte-identical to the binary runtime-tested above** — one sha256 across the
RPM, `build/wifi/daemon/` and the copy that served Wi-Fi on the host all session — and the packaged
reconciler is byte-identical to the tree's. That is the check worth doing; a version bump proves
nothing about what is inside.

### ostree compliance

| check | result |
|---|---|
| payload outside `/usr` and `/etc` | **none** — nothing in `/var`, `/opt`, `/usr/local`, `/home`, `/root` |
| scriptlets | `wifid` and `wifi-sync` have **none at all**; `wifi-hostd`'s is `waydroid-overlay-sync --quiet \|\| :` |
| unit activation | enable symlinks shipped inside `/usr/lib/systemd/system/<target>.wants/`, never `systemctl enable` from `%post` |
| `packaging/test-install.sh` | 18 checks, 0 failures |
| `rpmlint` | only `no-signature` and `invalid-url Source0`, both inherent to unsigned local builds |

The scriptlet and symlink rules are not style: `%post` runs against the *compose*, not the booted
system, which is how `waydroid-ext-backlight` once installed with its SELinux half doing nothing and
nothing anywhere reporting a problem (see [packaging/README.md](../packaging/README.md)).

### docs/53's "SRPM only" was stale, and the real blocker was a dependency

[docs/53](53-release-readiness.md) listed `wifid` and `wifi-hostd` as having no binary RPM.
**All four Wi-Fi packages had one.** What was actually blocking the install was that `wifi-hostd`
requires `waydroid-ext-overlay-sync >= 1.1.0` and the host had 1.0.0 — a three-package transaction,
not a packaging gap. Corrected in place.

### The derive pre-flight, which is the one that could have gone wrong quietly

`battery` 2.0.0 and `camera-hal` 2.0.0 are **derive** rows: they carry no bytes and reconstruct
their file from the user's own `vendor.img` at boot, refusing if the stock hash has moved. A refusal
is silent in the sense that matters — the overlay file simply would not appear, and the battery
would go back to Waydroid's hardcoded 85%/charging. So all three stock hashes were checked against
this host's images with `debugfs` *before* the transaction, and all three matched.

Checked again afterwards, against the staged manifests: **8 of the 9 files the manifests will own
are byte-identical to what is hand-placed in the overlay today**, including both derive results. The
ninth is `wificond.rc`, where the only difference is one comment word — `CLAUDE.md` where the
packaged copy says `AGENTS.md`, from before that file was renamed. The service stanza is identical.

Overlay files owned by a package goes **4 of 13 to 9 of 13**. The four left are Widevine's, and
`waydroid-overlay-sync` leaves them alone: it only removes what its own `deployed.list` records.

### 16 packages, and 7 of them would have installed inert

The transaction was one `rpm-ostree install` with 3 replacements and 13 additions. `dexopt` was
excluded because it declares `SHIPPED=no`. Adding local packages re-resolves the whole layer, so it
also pulled the host's 33 layered Fedora packages current — 191 packages total, 167 from repos,
which is inherent to rpm-ostree layering and was seen on the first migration too.

**Then the thing worth the whole section.** Seven of the newly installed packages would have had no
effect at all, because a hand-placed unit in `/etc/systemd/system` **shadows** the packaged one in
`/usr/lib/systemd/system`, and those hand units exec `/usr/local/bin/…`:

| package | shadowed by | packaged vs hand-placed |
|---|---|---|
| `wifid` | `/etc/systemd/system/waydroid-wifid.service` | **byte-identical** |
| `wifi-sync` | its `.service` and `.timer` | **byte-identical** |
| `android-power` | `waydroid-android-lock.service` | differs only in the `/usr/bin` vs `/usr/local/bin` prefix |
| `cage` | binary only | prefix only |
| `graceful-exit` | binary only | prefix only |
| `hw-ite8350` | `ite8350-resume-check.service`, `ite8350-sleep.service` | **packaged is better** — it adds a "not this machine" guard the hand copy lacks, which stops a reprobe failing on every resume on hardware with no hub |
| `media` | `waydroid-mediad.service` | **packaged is a REGRESSION** — 1.0.0 predates the `lan.syshlt` → `com.systemhalted` rename, so it would broadcast to a package name the app no longer has |

Only the Wi-Fi three were migrated, because only they were built today from this tree and proved
byte-identical. Backed up to `~jmelanso/waydroid-handplaced-wifi-2026-09-30.tar.gz` (8 entries: three
units, two enable symlinks, three binaries) and removed. The running daemon kept going from its
deleted inode, which is harmless precisely because the packaged binary is identical.

`/etc/waydroid-wifid.conf` needs no merge: the pristine copy in the new deployment's `/usr/etc` and
the live one are already identical, because the stale-commentary fix earlier the same day had
brought the host's file to the repo template.

**Left open deliberately**: the other five packages stay shadowed. Four are equivalent or better and
migrating them is a small job plus a post-reboot check each; `media` must not be migrated until it is
rebuilt from current source, and until then the shadowing is the only thing keeping removable media
working. That the protection is accidental is the point — nothing would have reported it.

## After the reboot: everything landed, and three test scripts were lying

The deployment booted clean. All **24** `waydroid-ext` packages are installed, the **packaged units
are the ones in effect** (`/usr/lib/systemd/system/...`, not `/etc`), and `waydroid-wifid` runs as
`/usr/bin/waydroid-wifid` owned by `waydroid-ext-wifid-1.0.1-1.x86_64`. The only failed unit is
`systemd-remount-fs`, which has failed since 2026-09-12 and is ordinary read-only-root behaviour.

The overlay reconciled to **exactly** what was predicted: 9 of 9 owned files at the expected hashes,
**both derive rows included** — so `battery` 2.0.0 and `camera-hal` 2.0.0 really did reconstruct
their binaries out of `vendor.img`, patch them, and land on the hashes the hand-placed copies had.
The four Widevine files came through unchanged and nothing was lost. Confirmed from *inside* the
container, which is the only place that counts: the health HAL there hashes to `a8401c14…`, the
derive's recorded result.

`bin/wifi-test.sh` passes end to end, and the RSSI check agreed **4 of 4 samples** running from the
packaged binary. The battery poll timer is armed on the mechanism docs/48 demands —
`clockid: 7`, `it_interval: (60, 0)` out of `/proc/<pid>/fdinfo` — and the `RLIMIT_NICE` spam
docs/40 is about is 4 lines this boot against the ~1,000,000 it was.

### Three test scripts reported a working machine as broken

This is the part worth carrying forward, because none of the three failures was in the thing being
tested and two of them had been silently wrong for days.

**`bin/battery-test.sh` had `PATCHED_MD5` pinned to the three-byte patch.** docs/48 added two more
bytes on 2026-09-18 and nobody updated the constant, so from that day the script's *first* check
declared a correctly patched machine broken and `exit 1`ed — which meant every check below it
stopped running, and the message blamed the overlay not being live. Proved by reconstruction: all
five patches against the stock image give the md5 the machine actually has, and the pinned value is
reproduced by applying only the three at `0x6730`, `0x6731`, `0x6732`.

The fix is not a new constant. A hash of a patched binary cannot be maintained by hand — it moves
whenever the patch set does — and the thing that knows the patch set is `waydroid-ext-battery`'s
manifest, which records the result hash the reconciler itself verifies against. The script now reads
the expected hash from there and only falls back to a pinned value on a host with no package.

**`bin/sensors-test.sh` pointed at `/usr/local/bin/waydroid-sensord`**, a path the 2026-09-24
migration deleted. Section 4 ran a non-existent command with stderr sent to `/dev/null`, printed
nothing at all, set `FAIL=1` from the exit status, and the script closed with `FAILURES -- see above`
with no failure above it. Every sensor check passed throughout. Resolved with `command -v` now, and
it says so loudly if the daemon cannot be found. With that fixed the suite reports **ALL PASS**,
self-test included.

**`bin/wifi-test.sh` tested survival-across-reboot with `systemctl is-enabled`**, and this one is
*our* doing — it broke the moment the packaged unit took over. `is-enabled` defines "enabled" as a
symlink under `/etc`, and these packages deliberately ship theirs inside
`/usr/lib/systemd/system/<target>.wants/` because a `%post` running `systemctl enable` on an ostree
host executes against the compose. So the script warned that the daemon would not survive a reboot
while reading that off a daemon which just had. It now asks whether a target *wants* the unit, which
is true for both layouts. Its sibling check was pinned to `/usr/local/bin/waydroid-wifi-nudge`,
which this session's own migration moved.

**The common shape: a check that cannot distinguish "the thing is broken" from "I am looking in the
wrong place."** All three failed in the safe-looking direction — a false alarm rather than a false
pass — but a suite that cries wolf stops being read, and `battery-test.sh` exiting 1 on its first
check hid eleven real comparisons behind it.

### Still shadowed, on purpose

`media`, `cage`, `graceful-exit`, `android-power` and `hw-ite8350` still run their hand-placed
copies. Verified that this is working as intended: `waydroid-mediad.service` resolves to
`/etc/systemd/system/` and is active, so removable media is unaffected by the stale `media` 1.0.0
sitting inert beside it.

One tidy left: `nice-limit.conf` now exists twice, hand-placed in
`/etc/systemd/system/waydroid-container.service.d/` and packaged in
`/usr/lib/systemd/system/waydroid-container.service.d/`. They are byte-identical and drop-ins merge,
so `LimitNICE=40` is applied either way; the `/etc` copy is simply redundant now.

### I ended the session with a test script, and two scripts now refuse to let that happen

The verification sweep above finished with `bin/camera-test.sh`, run over ssh alongside the other
`*-test.sh` scripts. **Its line 12 is `waydroid session stop`.** That killed the cage compositor; the
`waydroid session start` on line 14 then failed with

```
Wayland socket '/run/user/1000/wayland-1' doesn't exist; are you running a Wayland compositor?
```

because the compositor it needed was the one just stopped. SDDM went back to the greeter on tty1 and
only a physical login recovered it. [AGENTS.md](../AGENTS.md) warns about precisely this, and the
warning had been read earlier the same session — the mistake was assuming a file named
`*-test.sh` was a read-only check like its four siblings.

Nothing was damaged: the packages, the overlay, `waydroid-wifid` and every host-side daemon were
untouched, and the container came back with the session. The cost was a trip to the machine.

`bin/camera-test.sh` and `bin/sensor-hub-reset.sh --restart` now **refuse with exit 2** when there is
no compositor socket at `$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY`, with `--force` for a host where losing
the session genuinely costs nothing. The test is the socket rather than "am I on a tty", because the
socket is the thing the restart actually needs: if it is absent before the stop it will be absent
after, so the restart cannot succeed and the only question is whether anyone is there to notice.
`sensor-hub-reset.sh` also now says that the reprobe already happened and only the restart was
skipped, so a refusal does not read as "nothing was done".

Those two are the only scripts in `bin/` that perform the disruption — swept rather than fixed
one-off. The rest only mention it in comments. **Safe over ssh**: `wifi-test.sh`,
`battery-test.sh`, `sensors-test.sh`, `brightness-test.sh`.

### Two session losses, one of them mine, and a duplicate session entry

The second loss is not explained and is recorded here unfinished rather than
guessed at.

`waydroid-cage-session` logs every start and end, and this boot has three events:

```
21:15:41  starting Waydroid on wayland-0
21:15:43  Android is up (container: RUNNING)
21:24:54  session ended after 553s      <- bin/camera-test.sh, my fault
21:45:31  starting Waydroid on wayland-0
21:45:33  Android is up (container: RUNNING)
21:47:46  session ended after 135s      <- unexplained
```

The 135 s one was **not** the cage script's decision. It printed only
`session ended after 135s`, and both of the lines that precede its `kill -TERM`
— `Android has shut down; releasing the session` and `ending the session` — are
absent, which means the `kill -0 "$child"` guard failed: the
`waydroid session start` session manager **had already exited on its own**. The
`Stopping container` the container service logged at 21:47:45 is it reacting, not
causing. So the loop ended on its `while kill -0 "$child"` condition and the
script wound up correctly after its child died.

What killed the session manager is unknown. The one correlation: it exited about
230 ms after an ssh login for uid 1000, and `/etc/pam.d/sshd` carries
`pam_namespace.so` — `/run/user/1000` seen over ssh contains `bus`, `pipewire-0`
and `systemd` but **no `wayland-0`**, so an ssh session genuinely gets a
different mount namespace than the compositor's. That is a lead and not a
finding; the 21:15 session survived nine minutes of far heavier ssh traffic.

**The actionable part is a duplicate session entry, which this install created:**

```
/usr/share/wayland-sessions/waydroid-cage.desktop   Exec=... /usr/bin/waydroid-cage-session
    rpm: waydroid-ext-cage-1.0.0
/etc/wayland-sessions/waydroid-cage.desktop         Exec=... /usr/local/bin/waydroid-cage-session
    rpm: unowned (hand-placed)
```

Two entries for one session, so the greeter can offer it twice and which script
runs depends on which is picked. Both logins this boot took the packaged
`/usr/bin` one, and the 553 s session proves that script works — the hand-placed
and packaged copies differ only by the install prefix. The hand-placed
`.desktop` is the one to remove, but **not while the 135 s death is unexplained**:
it is the only remaining route to the previously-known-good path, and deleting
the fallback before understanding the failure is the wrong order.

### A latent bug in the guard above, found by the restart

The session came back on **`wayland-0`**, where it had been `wayland-1`.
`camera-test.sh` had `export WAYLAND_DISPLAY=wayland-1` hardcoded, and the guard
added earlier in this document inherited it — so the guard would have refused
even from inside a healthy session, and the script could not have reached the
compositor either. Both scripts now honour an inherited `WAYLAND_DISPLAY`, then
look for whatever `wayland-[0-9]*` socket actually exists, and only fall back to
a literal for the error message. The number is just the order cage got its
socket; nothing guarantees it.

## Running it

```bash
# dev box
wifi/build.sh --install               # the RSSI and channelBandwidth fixes
scp artifacts/wifi/waydroid-wifi-sync bigtab01:/tmp/ # the reaper

# bigtab01
sudo install -m 0755 /tmp/waydroid-wifi-sync /usr/local/bin/waydroid-wifi-sync
sudo systemctl restart waydroid-wifid
sudo waydroid-wifi-nudge                # only if Android does not come back
bash bin/wifi-test.sh                   # both new checks are in here
```

The reaper needs no unit change — `waydroid-wifi-sync.timer` and the daemon's Wi-Fi-enable trigger
already run it. Note that `/etc/waydroid-wifid.conf` is written by the installer **only when
absent**, so [docs/38](38-wifi-primary-radio.md)'s stale-commentary item needed a hand copy; that is
done, with the previous file kept as `/etc/waydroid-wifid.conf.bak-20260930`. The value line was
confirmed identical before overwriting.
