# Mirrors android.net.wifi InformationElementUtil (AOSP 13) closely enough to
# tell whether the daemon's synthetic IEs produce the capability string a real
# AP would.  Parsing rules copied from parseInformationElements(),
# parseRsnElement(), parseWpaOneElement() and generateCapabilitiesString().
import struct, sys

RSN_AKM = {1:"EAP/SHA1",2:"PSK",3:"FT/EAP",4:"FT/PSK",5:"EAP/SHA256",
           6:"PSK-SHA256",8:"SAE",9:"FT/SAE",12:"EAP_SUITE_B_192",18:"OWE"}
WPA_AKM = {1:"EAP/SHA1",2:"PSK"}
CIPHER  = {0:"None",2:"TKIP",4:"CCMP",9:"GCMP-256"}   # cipherToString's cases

def parse_ies(b):
    ies, i, found_ssid = [], 0, False
    while len(b) - i > 1:
        eid, ln = b[i], b[i+1]; i += 2
        if ln > len(b) - i or (eid == 0 and found_ssid): break
        if eid == 0: found_ssid = True
        ies.append((eid, b[i:i+ln])); i += ln
    return ies

def suites(body, off, n, table):
    out = []
    for k in range(n):
        s = body[off+4*k:off+4*k+4]
        out.append(table.get(s[3], "?") if s[0:3] in (b"\x00\x0f\xac", b"\x00\x50\xf2") else "?")
    return out

def rsn(body):
    ver, = struct.unpack_from("<H", body, 0)
    if ver != 1: return None
    grp = CIPHER.get(body[5], "?")            # version 0-1, group suite 2-5
    n, = struct.unpack_from("<H", body, 6); off = 8
    pw = suites(body, off, n, CIPHER); off += 4*n
    m, = struct.unpack_from("<H", body, off); off += 2
    akm = suites(body, off, m, RSN_AKM); off += 4*m
    caps = pmk = gmc = None
    if len(body) - off >= 2:
        caps, = struct.unpack_from("<H", body, off); off += 2
        if len(body) - off >= 2:
            pmk, = struct.unpack_from("<H", body, off); off += 2 + 16*pmk
            if len(body) - off >= 4: gmc = body[off:off+4]
    return ("RSN", akm, pw, grp, caps, gmc)

def wpa(body):
    if body[0:4] != b"\x00\x50\xf2\x01": return None
    ver, = struct.unpack_from("<H", body, 4)
    if ver != 1: return None
    grp = CIPHER.get(body[9], "?")            # oui+type 0-3, version 4-5, group 6-9
    n, = struct.unpack_from("<H", body, 10); off = 12
    pw = suites(body, off, n, CIPHER); off += 4*n
    m, = struct.unpack_from("<H", body, off); off += 2
    akm = suites(body, off, m, WPA_AKM)
    return ("WPA", akm, pw, grp, None, None)

def cap_string(ies, beacon_cap):
    protos, mfpr, mfpc = [], False, False
    privacy = bool(beacon_cap & 0x0010)
    ess     = bool(beacon_cap & 0x0001)
    for eid, body in ies:
        p = rsn(body) if eid == 48 else (wpa(body) if eid == 221 else None)
        if p:
            protos.append(p)
            if p[5] is not None:
                mfpr = bool(p[4] & (1 << 6)); mfpc = bool(p[4] & (1 << 7))
    out = ""
    if not protos and privacy: out += "[WEP]"
    for name, akm, pw, grp, caps, gmc in protos:
        s = "[" + name + "".join(("-" if j == 0 else "+") + a for j, a in enumerate(akm)) \
                + "".join(("-" if j == 0 else "+") + c for j, c in enumerate(pw)) + "]"
        wpa2 = ""
        if not ("EAP_SUITE_B_192" in s) and any(x in s for x in ("RSN-EAP", "RSN-FT/EAP", "RSN-PSK", "RSN-FT/PSK")):
            wpa2 = s.replace("[RSN", "[WPA2", 1)
        out += wpa2 + s
    if ess: out += "[ESS]"
    if protos and protos[-1][5] is not None:
        if mfpr: out += "[MFPR]"
        if mfpc: out += "[MFPC]"
    return out

for line in open(sys.argv[1]):
    label, cap, hexies = line.strip().split("|")
    ies = parse_ies(bytes.fromhex(hexies))
    ssid = next((b for e, b in ies if e == 0), b"")
    print("%-16s ssid=%-8r %s" % (label, ssid.decode("utf-8", "replace"),
                                  cap_string(ies, int(cap, 16))))
