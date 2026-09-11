#!/usr/bin/env python3
"""Minimal stdlib-only mDNS prober.

Written because `tcpdump` is not installed on bigtab01 and layering a package on
an Atomic host costs a reboot -- the same reason bin/v4l2-*.py exist.

Its purpose is to answer one question from *inside* the Waydroid container's
network namespace: does mDNS traffic from the host LAN actually arrive there?
Run it under `nsenter -t <container-pid> -n` to find out.

It can listen passively, but the useful mode is active: send a multicast query
and see whether answers come back.  That exercises the whole path -- query out
onto waydroid0, avahi re-originates it on wlp1s0, a LAN device answers, avahi
re-originates the answer back -- rather than just proving something is noisy.

  mdns-listen.py -i wlan0 -q _services._dns-sd._udp.local -q _ipp._tcp.local
"""

import argparse
import socket
import struct
import sys
import time

MDNS_ADDR = "224.0.0.251"
MDNS_PORT = 5353

TYPES = {1: "A", 12: "PTR", 16: "TXT", 28: "AAAA", 33: "SRV", 47: "NSEC"}


def read_name(buf, off):
    """Decode a DNS name at `off`, following compression pointers.

    Returns (name, offset-just-past-the-name-in-the-original-stream).
    """
    labels = []
    jumped = False
    resume = off
    hops = 0
    while off < len(buf):
        length = buf[off]
        if length == 0:
            off += 1
            break
        if length & 0xC0 == 0xC0:
            if off + 1 >= len(buf):
                break
            ptr = ((length & 0x3F) << 8) | buf[off + 1]
            if not jumped:
                resume = off + 2
                jumped = True
            off = ptr
            hops += 1
            if hops > 64:  # malformed / pointer loop
                break
            continue
        off += 1
        labels.append(buf[off:off + length].decode("utf-8", "replace"))
        off += length
    return ".".join(labels), (resume if jumped else off)


def encode_name(name):
    out = b""
    for label in name.rstrip(".").split("."):
        out += bytes([len(label)]) + label.encode()
    return out + b"\x00"


def parse(buf):
    """Pull the interesting bits out of an mDNS message."""
    if len(buf) < 12:
        return None
    _, _, qd, an, ns, ar = struct.unpack("!HHHHHH", buf[:12])
    off = 12
    questions, records = [], []
    try:
        for _ in range(qd):
            name, off = read_name(buf, off)
            rtype, _ = struct.unpack("!HH", buf[off:off + 4])
            off += 4
            questions.append((name, TYPES.get(rtype, str(rtype))))
        for _ in range(an + ns + ar):
            name, off = read_name(buf, off)
            rtype, _, _, dlen = struct.unpack("!HHIH", buf[off:off + 10])
            off += 10
            rdata = buf[off:off + dlen]
            detail = ""
            if rtype == 1 and dlen == 4:
                detail = socket.inet_ntoa(rdata)
            elif rtype == 28 and dlen == 16:
                detail = socket.inet_ntop(socket.AF_INET6, rdata)
            elif rtype == 12:
                detail, _ = read_name(buf, off)
            elif rtype == 33 and dlen > 6:
                port = struct.unpack("!H", rdata[4:6])[0]
                target, _ = read_name(buf, off + 6)
                detail = "%s:%d" % (target, port)
            off += dlen
            records.append((name, TYPES.get(rtype, str(rtype)), detail))
    except (struct.error, IndexError) as exc:
        records.append(("<truncated: %s>" % exc, "", ""))
    return questions, records


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("-i", "--interface", required=True,
                    help="interface to join the mDNS group on")
    ap.add_argument("-q", "--query", action="append", default=[],
                    help="send a PTR query for this name (repeatable)")
    ap.add_argument("-t", "--timeout", type=float, default=10.0,
                    help="seconds to listen (default 10)")
    args = ap.parse_args()

    try:
        ifindex = socket.if_nametoindex(args.interface)
    except OSError:
        sys.exit("no such interface: %s" % args.interface)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                        args.interface.encode())
    except PermissionError:
        print("warning: SO_BINDTODEVICE needs root; other interfaces may leak in")
    sock.bind(("", MDNS_PORT))

    # ip_mreqn: multiaddr, local addr, ifindex
    mreq = struct.pack("4s4si", socket.inet_aton(MDNS_ADDR),
                       socket.inet_aton("0.0.0.0"), ifindex)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF, mreq)
    # RFC 6762 wants 255 so receivers can verify the packet is link-local.
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 255)

    for name in args.query:
        header = struct.pack("!HHHHHH", 0, 0, 1, 0, 0, 0)
        pkt = header + encode_name(name) + struct.pack("!HH", 12, 1)
        sock.sendto(pkt, (MDNS_ADDR, MDNS_PORT))
        print("-> query %s PTR on %s" % (name, args.interface))

    print("listening on %s for %.0fs ...\n" % (args.interface, args.timeout))
    deadline = time.monotonic() + args.timeout
    seen = 0
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        sock.settimeout(remaining)
        try:
            data, addr = sock.recvfrom(9000)
        except socket.timeout:
            break
        parsed = parse(data)
        if not parsed:
            continue
        questions, records = parsed
        seen += 1
        print("from %s:%d" % addr)
        for name, rtype in questions:
            print("    ?  %-6s %s" % (rtype, name))
        for name, rtype, detail in records:
            print("    .  %-6s %-52s %s" % (rtype, name, detail))
        print()

    print("%d packet(s) in %.0fs" % (seen, args.timeout))


if __name__ == "__main__":
    main()
