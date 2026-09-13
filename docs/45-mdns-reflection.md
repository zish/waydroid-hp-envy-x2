# mDNS reflection into the Waydroid container

**Status: done, and verified end to end on 2026-09-11 -- a test page was printed.** The host's
LAN mDNS services arrive inside the container, Android discovers the Canon, and a real print
job reaches paper. Getting there needed **two** changes, not one: the avahi reflector below,
and a firewalld rich rule without which any client that sends one-shot mDNS queries -- the
Mopria Print Service among them -- discovers nothing. See
[Two print services, two query modes](#two-print-services-two-query-modes-and-only-one-works).

The question was: can mDNS broadcasts received on host interfaces be forwarded to the
container, and could that even work for discovery given the container is not on the same
network? Both answers are yes, the second for a reason worth stating plainly.

## Topology

Two L2 segments with NAT between them. Nothing here changed.

```
LAN 10.42.0.0/24 -- wlp1s0 (10.42.0.137) -- [host] -- waydroid0 (192.168.240.1) -- veth -- wlan0 (container)
                     zone: public                       zone: trusted, NAT via nftables
```

The container is `192.168.240.112/24` on `wlan0` (renamed by `lxc.net.0.name = wlan0`, see
[34-wifi-second-radio.md](34-wifi-second-radio.md)). Its default route is `192.168.240.1`.

## "Forwarding" is the wrong word, and that rules out a whole family of tools

mDNS uses `224.0.0.251`, which sits in `224.0.0.0/24` -- the link-local control block that
routers **must not** forward at any TTL. RFC 6762 receivers additionally check for link-local
origin. So the packets cannot be routed, and **`smcroute`, `igmpproxy` and `pimd` are not the
tool here**, however they are configured.

What works is an application-layer relay that *re-originates* the query on the other segment.
That is what avahi's reflector does, and the packet captures below confirm it: every reflected
record arrives from `192.168.240.1` (the host's avahi), never from the original sender's
`10.42.0.x`.

Two things that are **not** obstacles, contrary to reasonable expectation:

- **The Linux bridge is not in the way.** `waydroid0` has `multicast_snooping=1` and
  `multicast_querier=0`, which normally suggests trouble. It does not apply: bridges always
  flood `224.0.0.0/24` regardless of snooping, because link-local groups are never snooped.
- **Android does not need a `MulticastLock`, and does not need a vendor HAL.** See below.

## Baseline, before any change

`bin/mdns-listen.py` was written for this (stdlib only -- `tcpdump` is not installed and
layering a package on an Atomic host costs a reboot, the same reason `bin/v4l2-*.py` exist).
It is *active*, not passive: it sends a multicast PTR query and listens, so it exercises the
whole round trip rather than just proving something is noisy.

Run inside the container's own network namespace, which is the thing that actually matters:

```bash
CPID=$(sudo lxc-info -P /var/lib/waydroid/lxc -n waydroid -pH)
sudo nsenter -t "$CPID" -n python3 /tmp/mdns-listen.py \
    -i wlan0 -q _services._dns-sd._udp.local -q _ipp._tcp.local -t 12
```

Result -- **3 packets in 12 s**, all local:

```
from 192.168.240.112:5353   ?  PTR  _services._dns-sd._udp.local
from 192.168.240.112:5353   ?  PTR  _ipp._tcp.local
from 192.168.240.112:5353   .  PTR  _services._dns-sd._udp.local -> _adb._tcp.local
```

Two findings, both load-bearing:

1. **Android's mDNS responder is alive and receives multicast on `wlan0`.** The script only
   queries and listens -- it never answers. So that `_adb._tcp` PTR came from another process
   in the namespace: Android's own responder in the Connectivity APEX. It heard an inbound
   multicast query and replied.

   This retires the concern that Android would need `WifiManager.MulticastLock` (and therefore
   `CHANGE_WIFI_MULTICAST_STATE`, and therefore a vendor HAL that this build deliberately does
   not have -- see [31-wifi-stage2.md](31-wifi-stage2.md)). On real hardware the lock toggles
   the Wi-Fi driver's multicast filter through the HAL. On a veth there is no filter to toggle,
   and the framework responder works without one. **Verified, not assumed.**

2. **The LAN is completely invisible.** The `_ipp._tcp` query -- aimed at a printer the host's
   avahi sees perfectly well on `wlp1s0` -- got zero answers.

## The change

Two lines in `/etc/avahi/avahi-daemon.conf`. avahi was **already installed, enabled and
running** on the host (`avahi-0.9~rc2-8.fc44`), so nothing was layered and nothing rebooted --
which matters on an immutable host.

```diff
 [reflector]
-#enable-reflector=no
+enable-reflector=yes
 #reflect-ipv=no
-#reflect-filters=_airplay._tcp.local,_raop._tcp.local
+reflect-filters=_ipp._tcp.local,_ipps._tcp.local,_printer._tcp.local,_googlecast._tcp.local,_airplay._tcp.local,_raop._tcp.local
```

Original preserved on the host at `/etc/avahi/avahi-daemon.conf.pre-reflector`; both files are
in [../artifacts/mdns/](../artifacts/mdns/).

`reflect-ipv` is deliberately left at its default of `no`. The container has only a link-local
`fe80::` on `wlan0` and no global IPv6, so reflecting v6 services to it would produce records
it could discover but never connect to.

**`reflect-filters` works despite the version string saying otherwise.** `avahi-daemon
--version` reports `0.8`, and `reflect-filters` is a 0.9 feature -- but it is documented in the
installed man page, the daemon started clean with it set, and it demonstrably filtered. The
version string in Fedora's `0.9~rc2` package is stale. (avahi errors on unknown config keys, so
a clean start is a real test, not a silent no-op.)

No firewall change was needed: `waydroid0` is already in firewalld's `trusted` zone, and
`wlp1s0`'s `public` zone already passes mDNS inbound -- proven empirically, since `avahi-browse`
on the host was already seeing LAN services before any of this.

## After: it works

Same command, unfiltered first -- **9 packets**, with the printer arriving complete:

```
from 192.168.240.1:5353
    .  PTR  _ipp._tcp.local     -> Canon-MF642C-643C-644C-UFR-II @ vidiot01._ipp._tcp.local
    .  SRV  Canon-... @ vidiot01._ipp._tcp.local   vidiot01.local:631
    .  TXT  Canon-... @ vidiot01._ipp._tcp.local
    .  A    vidiot01.local                         10.42.0.1
```

Three things to notice.

**The relay is application-layer.** Source is `192.168.240.1` -- the host's avahi
re-originating on `waydroid0` -- not `10.42.0.1`. This is the concrete confirmation that the
routing approach could never have worked.

**The A record is not rewritten.** Android learns `vidiot01.local = 10.42.0.1`, the real LAN
address. avahi reflects the record verbatim.

**The round trip works both ways.** Our `_ipp._tcp` query was reflected *out* to the LAN,
`vidiot01` answered, and the answer was reflected *back*. Queries from LAN devices also arrive
inbound (`_kdeconnect._udp`, `_raop._tcp` were seen as questions).

## Why it works despite the different network

This is the part worth keeping. **mDNS is discovery, not connectivity.** All it ever hands over
is a name, a port and an address. The reflector passes the address through unmodified, so
Android ends up with `10.42.0.1:631` and then makes an ordinary unicast TCP connection to it --
which routes out through the container's default gateway and the host's existing masquerade.
That path was already proven by the container having validated internet
([35-wifi-stage5.md](35-wifi-stage5.md)).

Confirmed directly from inside the container's netns:

```
IPP connect OK: ('192.168.240.112', 42554) -> ('10.42.0.1', 631)
```

So **container -> LAN discovery and connection both work end to end**. That is the direction
that matters for printers, CUPS, Chromecast, DLNA, Home Assistant, Jellyfin.

### The address Android shows is the CUPS server, not the printer

Worth stating plainly, because it looks wrong at first glance: Android reports the Canon's
address as **`10.42.0.1`**, which is the default gateway. That is correct.

Nothing here is the printer advertising itself. The service instance is
`Canon-MF642C-643C-644C-UFR-II @ vidiot01` -- a **CUPS queue shared from the host `vidiot01`**,
whose SRV record targets `vidiot01.local:631` and whose A record is `10.42.0.1`. `vidiot01`
happens to also be the router, so the print server has the most reachable address on the LAN
that it could possibly have had. Confirmed from the host:

```
$ avahi-browse -rtp _ipp._tcp | grep -i canon
=;wlp1s0;IPv4;Canon-MF642C-643C-644C-UFR-II\032\064\032vidiot01;_ipp._tcp;local;\
    vidiot01.local;10.42.0.1;631;... "rp=printers/Canon-MF642C-643C-644C-UFR-II" \
    "ty=Canon MF642C/643C/644C UFR II" "mopria-certified=1.3" "URF=V1.4,CP1,W8,PQ4,..."

$ ip route get 10.42.0.1
10.42.0.1 dev wlp1s0 src 10.42.0.137

$ curl -s http://10.42.0.1:631/printers/ | grep -o 'Canon[A-Za-z0-9_-]*'
Canon-MF642C-643C-644C-UFR-II
```

The printer's own IP never enters the picture -- Android talks IPP to CUPS, and CUPS talks to
the printer. The `mopria-certified=1.3` and `URF=` keys in that TXT record are the ones
`com.android.bips` needs, so the queue is the IPP Everywhere kind the built-in print service
can drive without a vendor plugin.

## Two print services, two query modes, and only one works

**`com.android.bips` sees the Canon; the Mopria Print Service searches forever.** The
discriminator is not the print service at all -- it is *how each one asks*. Measured from
inside the container's netns with `bin/mdns-listen.py`:

| query source port | QU bit | Canon answer |
|---|---|---|
| 5353 (proper multicast query) | no | **arrives immediately, from `192.168.240.1:5353`** |
| ephemeral (one-shot / legacy unicast) | yes | **nothing, on either socket** |

Mopria asks the second way. The container emits `_ipp`+`_ipps` PTR bursts every few seconds
from a *fresh* ephemeral port each time (46273, 60172, 51728, 36397, 43010, ...), and logcat
attributes them:

```
ActivityManager: Start proc 45197:org.mopria.printplugin/u0a205 for service
                 {org.mopria.printplugin/org.mopria.printplugin.MopriaPrintService}
```

So Mopria is installed, bound and genuinely searching; its multicast leaves the container
fine. **No `MulticastLock` and no vendor HAL are implicated** -- consistent with the baseline
finding above. RFC 6762 s6.7 says a query from a source port other than 5353 is a *one-shot*
(legacy unicast) query and **must be answered unicast back to that port**. That reply never
lands. `com.android.bips` goes through `NsdManager` and the platform mDNS stack, which queries
from 5353 and takes the multicast answer, so it is unaffected.

**In effect the reflector setup only served clients that query from port 5353.** That was ours,
not a Mopria bug -- and it is now fixed.

**Confirmed at the application layer: with the firewall rule in place, Mopria discovers the
Canon and a test page printed successfully.** That is the first real print job through this
path, so it also retires the older open question of whether discovery was merely cosmetic. The
data plane works exactly as predicted -- Android makes an ordinary unicast IPP connection to
`10.42.0.1:631`, out through the container's gateway and the host's masquerade.

### Confirmed cause: firewalld drops the unicast reply

`wlp1s0` is in firewalld's `public` zone, whose only relevant allowance is the `mdns` service
-- destination UDP **5353**:

```
public (default, active)
  interfaces: wlp1s0
  services: dhcpv6-client mdns ssh
  rich rules:
```

avahi reflects a legacy unicast query by re-originating it on the other segment **from its own
ephemeral slot port**, which was observed directly (`10.42.0.137:57943` on `wlp1s0` carrying
the container's `_ipp`/`_ipps` questions). `vidiot01` then answers unicast to that port. That
packet has destination port 57943, matches no rule, and **matches no conntrack entry either** --
the outbound tuple was `10.42.0.137:57943 -> 224.0.0.251:5353`, so a reply sourced from
`10.42.0.1:5353` is not ESTABLISHED. It is dropped.

**Proven by experiment.** Adding one runtime rich rule that accepts UDP by *source* port:

```bash
sudo firewall-cmd --zone=public \
    --add-rich-rule='rule family="ipv4" source-port port="5353" protocol="udp" accept'
```

turns the same probe from silence into a complete answer -- and note the `[unicast]` label,
which is the socket the reply arrived on:

```
[unicast] from 192.168.240.1:5353
    ?  PTR    _ipp._tcp.local
    .  PTR    _ipp._tcp.local    Canon-MF642C-643C-644C-UFR-II @ vidiot01._ipp._tcp.local
    .  SRV    Canon-... @ vidiot01._ipp._tcp.local    vidiot01.local:631
    .  A      vidiot01.local                          10.42.0.1
```

(The question echoed back inside the answer packet is the RFC 6762 s6.7 legacy-unicast reply
format, not a stray query.)

**The rule is now permanent**, in both runtime and `/etc/firewalld/zones/public.xml`, captured
in [../artifacts/mdns/](../artifacts/mdns/) as `firewalld-public.xml` with the pre-change
`firewalld-public.xml.orig` alongside. It was added with `--permanent` *after* the runtime rule
was already live, deliberately avoiding `firewall-cmd --reload`: a reload flushes and rebuilds,
and while `waydroid0`'s `trusted` assignment is permanent (checked -- so a reload would not
strand the container), the cost of being wrong is a container restart, which drops the kiosk
session to the SDDM greeter and needs a human at the machine.

Understand what the rule costs. It accepts UDP from any LAN host willing to send **from** port
5353 to **any** high port on this machine. That is a real, if small, widening of the host's
exposure. It is accepted here because it is the only way to serve one-shot mDNS clients through
a reflector -- avahi re-originates from an unpredictable ephemeral port, so there is no narrower
destination-port rule to write.

**`reflect-filters` is an alternative suspect and is considered unlikely.** The multicast query
for `_ipp._tcp` is answered *with the filters active*, so that name passes the filter; for the
filter to be the cause it would have to discriminate by query mode. Testing it by commenting
the line out was attempted and not completed.

### The meta-query is not reflected

`_services._dns-sd._udp.local` is not in `reflect-filters`, so a client that enumerates service
types before browsing them would find nothing. Nothing observed here does that -- both print
services query `_ipp`/`_ipps` directly -- but it is a trap for the next client.

### The reverse direction is broken, by design

The reflector will advertise Android's `_adb._tcp` to the LAN at `192.168.240.112`, an address
nothing on `10.42.0.0/24` has a route to and which the host does not forward inbound. The
record arrives and is useless. Fixing that would need DNAT plus record rewriting, which avahi
does not do. **The `reflect-filters` setting above is what keeps that junk off the LAN** -- it
is not only a noise control.

## The filter, measured

| | unfiltered | filtered |
|---|---|---|
| packets in 12 s | 9 | 6 |
| Canon `_ipp` record | complete | **complete** |
| `_rdlink`, `_companion-link`, `_nearbypresence`, `_FC9F5ED42C8A`, `_cache`, `_http` | present | **gone** |

One observed subtlety: **questions cross the filter regardless.** A `_kdeconnect._udp` PTR
*query* from a LAN device still arrived inbound even though `_kdeconnect` is not in the filter
list. The filter governs which services are reflected, not which questions are. Harmless, but
it means the filter is not a privacy boundary -- LAN devices still learn that something on the
other side is listening.

## What is still unverified

**Discovery is confirmed; a print job is not.** With a human at the console the Canon appears
in Default Print Service as expected. Whether a page actually comes out -- rendering,
`image/urf` conversion, the job going through CUPS on `vidiot01` -- has not been tried.

The rest of this section records how the *headless* attempt failed, which is worth keeping
because the obstacle was never mDNS and will block any future UI-dependent test.

**Headlessly, Android's built-in print service never bound.** This is an Android
print-framework lifecycle matter, orthogonal to mDNS, and the network-layer evidence above does
not depend on it.

- `com.android.bips`, `com.android.printspooler` and
  `com.google.android.printservice.recommendation` are all present in the image.
- `enabled_print_services` was `null`; it has now been set to
  `com.android.bips/com.android.bips.BuiltInPrintService`.
- Even so, `dumpsys print` still shows `is_bound=false`, `has_discovery_session=false`,
  `is_discovering_printers=false`.

The cause was found and is **not** a print problem:

```
mCurrentFocus = Window{a22f192 u0 NotificationShade}
mFocusedApp   = com.android.settings/.Settings$PrintSettingsActivity
```

The print settings activity launches and becomes the focused *app*, but the **notification
shade holds window focus on top of it**, so the fragment never resumes and never opens a
printer discovery session. `am start -n com.android.bips/.ui.AddPrintersActivity` does not help
either -- that is bips's manual-add UI and opens no session.

`cmd statusbar collapse` **did not dismiss the shade.** This is the same wall documented for
the brightness work in [37-brightness.md](37-brightness.md) and AGENTS.md: injected input and
headless UI manipulation do not take on this machine, and a full check needs a human at the
console.

**Doing it with a human at the console works**, which is how discovery was confirmed: dismiss
the shade, open Settings -> Connected devices -> Connection preferences -> Printing -> Default
Print Service, and the Canon is listed.

## Ruled out

- **IP multicast routing** (`smcroute`, `igmpproxy`, `pimd`) -- `224.0.0.251` is link-local
  scoped and must not be routed. Not a configuration problem; the wrong layer.
- **Putting the container on the host's L2 segment** (bridge or macvlan onto `wlp1s0`) -- both
  radios on this machine are Wi-Fi STA, and an AP drops frames with unexpected source MACs
  without 4addr/WDS on both ends. There is no wired NIC. The reflector is not a workaround for
  a better option that exists; it is the option.
- **`virt_wifi`** -- already ruled out for Wi-Fi Stage 1 ([29-wifi-plan.md](29-wifi-plan.md)),
  and would not have helped here anyway.
- **Pointing Waydroid's dnsmasq at avahi** (`server=/local/127.0.0.1#5353`) -- not tried,
  because it only ever gets you `.local` *name resolution*. `NsdManager` does real multicast
  service browsing, so it would not have delivered discovery. Noted only so it is not
  rediscovered as a shortcut.

## Reverting

```bash
sudo cp /etc/avahi/avahi-daemon.conf.pre-reflector /etc/avahi/avahi-daemon.conf
sudo systemctl restart avahi-daemon
```

And, if the print service should go back to its shipped state:

```bash
sudo waydroid shell -- sh -c "settings delete secure enabled_print_services"
```

## Not yet packaged, and why that needs a decision

The repo convention is that `artifacts/<topic>/install.sh` honours `DESTDIR`/`PREFIX` and
doubles as the RPM `%install` step ([36-packaging.md](36-packaging.md)). **That convention is
awkward here and was deliberately not followed yet.** The change is a two-line edit to a
*stock Fedora config file*; shipping the whole file from a package would clobber any future
Fedora change to `avahi-daemon.conf`, and avahi has no `conf.d` drop-in directory to use
instead. The options are to ship the full file and accept the clobber, or to apply the edit
idempotently at install time. That is a real decision, not an oversight -- until it is made,
this stays a documented manual change with the original preserved alongside.

## Open questions

- **Printing works via Mopria** (test page, 2026-09-11). `com.android.bips` discovers the Canon
  but has not had a job put through it specifically. Near-certain to work, since it is the same
  IPP-to-CUPS path, but not tested.
- The rich rule is permanent but has **not been watched across a reboot** -- neither has the
  avahi reflector (below). One reboot settles both.
- The firewalld rule is captured in `artifacts/mdns/` but not packaged; it has the same
  unresolved packaging question as `avahi-daemon.conf`, though a firewalld zone is the easier
  of the two since it is a whole file firewalld already owns.
- Is the shade-holds-focus state persistent or a one-off? Worth knowing generally -- it would
  block any future UI-dependent test, not just this one.
- Does the reflector survive a reboot cleanly, with `waydroid0` appearing after avahi starts?
  avahi handles interface hotplug, and the startup log shows it enumerating and joining
  `waydroid0` -- but this has **not** been watched across an actual reboot.
