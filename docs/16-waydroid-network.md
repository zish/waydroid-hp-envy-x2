# Waydroid lost internet access — a stale NetworkStack deadlocks EthernetService

**Date:** 2026-09-06. **Status: fixed on the host, but the fault will recur.**
The trigger is an Android `system_server` restart, which this machine does occasionally.

## Symptom

Every app inside Waydroid reported no connectivity. `waydroid status` showed
`IP address: UNKNOWN` while the container was `RUNNING`.

## Everything on the host was correct — ruled out first

None of the usual suspects were at fault. All of this was verified before looking inside Android:

| Checked | Result |
|---|---|
| `waydroid0` bridge | up, `192.168.240.1/24` |
| veth pair | `vethSZbQbl` present and enslaved to `waydroid0` |
| dnsmasq | running, `--dhcp-range 192.168.240.2,192.168.240.254`, bound to `192.168.240.1` |
| firewalld | active, **`waydroid0` in the `trusted` zone** (the usual Waydroid trap — not it) |
| nftables | `nat_POSTROUTING_POLICIES` has `iifname "waydroid0" oifname "wlp1s0"` |
| `net.ipv4.ip_forward` | `1` |
| host uplink | fine — the host itself had working internet throughout |

The one host-side oddity, a **zero-byte** `/var/lib/misc/dnsmasq.waydroid0.leases`, was a
*symptom*, not a cause: no DHCP client ever asked for a lease.

## Root cause

`system_server` had restarted ~38 minutes earlier. The **previous**
`com.android.networkstack.process` survived that restart, was reparented to init, and kept the
`NetworkStack` binder service registered:

```
  PID   PPID USER            ELAPSED NAME
    74     1 root           03:28:43 zygote
 10127     1 network_stack  01:18:38 com.android.networkstack.process   <- stale, orphaned
 17219     1 root              38:17 zygote64
 17235 17219 system            38:15 system_server                      <- restarted
 17506 17219 network_stack     38:13 com.android.networkstack.process   <- current
```

The new `system_server` bound to that stale registration instantly — `InitNetworkStackClient
took to complete: 0ms`, which a genuinely fresh NetworkStack cannot do. It then asked for an
IpClient and blocked forever, because `awaitIpClientStart()` waits on an **untimed**
`ConditionVariable`:

```
"EthernetServiceThread" prio=5 tid=81 Waiting
  at android.os.ConditionVariable.block(ConditionVariable.java:97)
  at com.android.server.ethernet.EthernetNetworkFactory$NetworkInterfaceState
        $EthernetIpClientCallback.awaitIpClientStart(EthernetNetworkFactory.java:340)
  at ...NetworkInterfaceState.start(EthernetNetworkFactory.java:516)
  at ...EthernetNetworkOfferCallback.onNetworkNeeded(EthernetNetworkFactory.java:406)
```

Get that trace with `kill -3 <system_server_pid>` inside the container, then read
`/data/anr/trace_00`.

Everything else follows from that one blocked thread:

| Observation | Caused by |
|---|---|
| `dumpsys ethernet` handler messages overdue by 36 min | the looper never advances |
| `dumpsys connectivity`: `Current Networks:` empty, `Active default network: none` | no NetworkAgent was ever registered |
| `ip route show table eth0` — no IPv4 route at all | netd created netId 100, but IpClient never populated it |
| `ping 192.168.240.1` → "Network is unreachable" *from the same subnet* | Android policy routing: rule `16000 lookup eth0` finds an empty table, falls through to rule `32000 unreachable` |
| lease file empty | IpClient is what runs DHCP, and it never started |
| `eth0` still held `192.168.240.112` | leftover address from the previous working generation; only Android's routing tables were rebuilt |

**Not caused by `waydroid-sensord`.** Three ANR traces from 14:25–14:28 were checked; a
case-insensitive grep for `sensor` across all three returns nothing. They are Chrome's
`BackgroundTaskJobService` and a `GameManager` service lookup.

## The fix

Killing the stale process alone is **not** sufficient — verified on the host. PID 10127 was
killed, and the Ethernet table stayed empty with `Active default network: none`, because the
blocked thread has no timeout and nothing reopens its ConditionVariable.

What worked:

```bash
sudo waydroid container restart      # Android is up ~20 s later
```

The session itself did not need restarting, so this can be done over ssh without a Wayland
environment.

## Verified after the fix

```
table eth0:  default via 192.168.240.1 dev eth0 proto static
             192.168.240.0/24 dev eth0 proto static scope link
lease:       1788732834 00:16:3e:f9:d3:03 192.168.240.112 BigTab01
ping 1.1.1.1:  3 packets transmitted, 3 received, 0% packet loss, rtt avg 19.2 ms
connectivity:  NetworkAgentInfo{network{100} ni{Ethernet CONNECTED}
               ... everValidated lastValidated ... Capabilities: INTERNET&VALIDATED
```

`VALIDATED` means Android's own captive-portal probe reached the internet, not just that a route
exists.

## If it happens again

One command tells you whether it is this fault rather than a host-side problem:

```bash
sudo waydroid shell -- sh -c "ip route show table eth0"
```

Empty, or missing the `default via 192.168.240.1` line, means the Ethernet stack is wedged —
go straight to `sudo waydroid container restart` and do not bother re-checking firewalld, NAT or
dnsmasq. Confirm the diagnosis with the process listing above: **two**
`com.android.networkstack.process` entries, one with `PPID 1`, is the signature.

The underlying defect is upstream Android's, not Waydroid's configuration: an orphaned
NetworkStack can keep its binder registration across a `system_server` restart, and
`EthernetNetworkFactory.awaitIpClientStart()` blocks on it with no timeout and no recovery path.
