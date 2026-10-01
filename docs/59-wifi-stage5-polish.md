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

Unchanged from [docs/35](35-wifi-stage5.md) and [docs/38](38-wifi-primary-radio.md):

- **The rtw88 wedge still has no automatic trigger**, and the T3U is not even plugged into this
  machine any more, so there was nothing to observe. `bin/wifi-radio-reset.sh` stays manual and the
  `nmcli connection up` discriminator stays mandatory before running it.
- **The host's two ~10-minute link drops of 2026-09-18 are still uninvestigated.** The RSSI error
  above is a plausible contributor and nothing more; it is not evidence.
- **Scan staleness after repeated daemon restarts** — docs/35's false trail, still not diagnosed.
- **The wrong-password path is still unproven.**
- **Packet counters and link-layer stats are all zero** — `tx_good`, `tx_retry`, `tx_bad`, `rx_pps`
  and `bcnCnt` in the score history, against 782 tx / 864 rx packets that `iw station dump` can
  see. These come from `IWifiStaIface.getLinkLayerStats`, which needs a vendor HAL, so the score is
  driven by RSSI alone. Newly written down rather than newly true.
- **Rx link speed is reported as Tx**, because NM exposes one `Bitrate`. Ground truth on the live
  link was 130 Mb/s tx and 5.5 Mb/s rx.
- **`technology` needs nl80211**, per above — now scoped rather than vague.
- **The active-profile guard on the reap is verified by predicate, not end to end.**
- **`NmBackend` is called from binder threads in three places and is not thread-safe**, per the
  section above. `getConnectionCapabilities` was kept out of that set; `getMacAddress`, `connect`
  and `disconnect` are still in it.

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
