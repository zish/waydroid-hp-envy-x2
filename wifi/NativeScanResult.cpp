#include "NativeScanResult.h"
#include "AidlParcel.h"

#include <gutil_log.h>

#include <time.h>

#include <cstring>

namespace waydroid {
namespace wifi {

using namespace aidl;

/* ---------------------------------------------------------- 802.11 values */

/*
 * Element IDs.  ScanResult.InformationElement in the image names these
 * EID_SSID = 0, EID_RSN = 48, EID_VSA = 221.
 */
enum {
    EID_SSID = 0,
    EID_RSN  = 48,
    EID_VSA  = 221,
};

/* Capability field bits, read from this image's NativeScanResult constants. */
enum {
    BSS_CAPABILITY_ESS     = 0x0001,
    BSS_CAPABILITY_PRIVACY = 0x0010,
};

/* Suite selectors are OUI || type.  Java reads them as a little-endian int,
 * so 00-0F-AC-04 arrives as 0x04ac0f00 -- which is exactly the constant
 * InformationElementUtil calls RSN_CIPHER_CCMP.  Writing the OUI in wire order
 * is therefore correct and needs no byte swapping. */
static const uint8_t OUI_RSN[3] = { 0x00, 0x0f, 0xac };
static const uint8_t OUI_WPA[3] = { 0x00, 0x50, 0xf2 };

enum {
    SUITE_CIPHER_WEP40  = 1,
    SUITE_CIPHER_TKIP   = 2,
    SUITE_CIPHER_CCMP   = 4,
    SUITE_CIPHER_WEP104 = 5,
    SUITE_CIPHER_BIP    = 6,        /* BIP-CMAC-128, the group management one */

    SUITE_AKM_EAP       = 1,
    SUITE_AKM_PSK       = 2,
    SUITE_AKM_SAE       = 8,
};

/* RSN capabilities bits (802.11-2016 9.4.2.25.4). */
enum {
    RSN_CAP_MFPR = 1 << 6,
    RSN_CAP_MFPC = 1 << 7,
};

/* Android refuses an SSID longer than this and throws where nothing catches. */
#define MAX_SSID_LEN 32

/* --------------------------------------------------------------- helpers */

uint64_t
boottimeUsec()
{
    struct timespec ts;

    if (clock_gettime(CLOCK_BOOTTIME, &ts)) {
        return 0;
    }
    return (uint64_t) ts.tv_sec * 1000000 + (uint64_t) (ts.tv_nsec / 1000);
}

static void
putU16(std::vector<uint8_t>& v, uint16_t x)
{
    v.push_back((uint8_t) (x & 0xff));          /* little-endian on the wire */
    v.push_back((uint8_t) (x >> 8));
}

static void
putSuite(std::vector<uint8_t>& v, const uint8_t oui[3], uint8_t type)
{
    v.insert(v.end(), oui, oui + 3);
    v.push_back(type);
}

/* Append an element with its ID and length in front of the body. */
static void
putElement(std::vector<uint8_t>& out, uint8_t eid,
    const std::vector<uint8_t>& body)
{
    out.push_back(eid);
    out.push_back((uint8_t) body.size());
    out.insert(out.end(), body.begin(), body.end());
}

/*
 * Pairwise ciphers, strongest first, as an AP normally lists them.  A backend
 * that did not fill the mask in gets the default for the protocol, which is
 * flagged as an assumption rather than buried.
 */
static std::vector<uint8_t>
pairwiseSuites(uint32_t mask, bool rsn)
{
    std::vector<uint8_t> out;

    if (mask & CipherCcmp)   out.push_back(SUITE_CIPHER_CCMP);
    if (mask & CipherTkip)   out.push_back(SUITE_CIPHER_TKIP);
    if (mask & CipherWep104) out.push_back(SUITE_CIPHER_WEP104);
    if (mask & CipherWep40)  out.push_back(SUITE_CIPHER_WEP40);
    if (out.empty()) {
        out.push_back(rsn ? SUITE_CIPHER_CCMP : SUITE_CIPHER_TKIP);
    }
    return out;
}

/*
 * The group cipher is a single suite and has to be the weakest one every
 * associated station can decrypt, so where the host names more than one, the
 * weakest is the truthful pick.
 */
static uint8_t
groupSuite(uint32_t mask, bool rsn)
{
    if (mask & CipherWep40)  return SUITE_CIPHER_WEP40;
    if (mask & CipherWep104) return SUITE_CIPHER_WEP104;
    if (mask & CipherTkip)   return SUITE_CIPHER_TKIP;
    if (mask & CipherCcmp)   return SUITE_CIPHER_CCMP;
    return rsn ? SUITE_CIPHER_CCMP : SUITE_CIPHER_TKIP;
}

/* ------------------------------------------------------------- the pieces */

uint16_t
beaconCapability(const Bss& bss)
{
    /*
     * Two bits, and only two, because they are the only two the host's answer
     * supports.  ESS: NM's AccessPoint list is infrastructure APs (ad-hoc
     * cells come with NM_802_11_MODE_ADHOC, which securityFromFlags never
     * produces).  PRIVACY: set exactly when the AP is not open, which is what
     * makes a WEP network read as [WEP] -- WEP has no IE of its own, and the
     * framework infers it from "private, but no RSN or WPA element".
     */
    uint16_t cap = BSS_CAPABILITY_ESS;

    if (bss.security != Security::Open) {
        cap |= BSS_CAPABILITY_PRIVACY;
    }
    return cap;
}

static void
appendRsnElement(std::vector<uint8_t>& ies, const Bss& bss)
{
    std::vector<uint8_t> body;
    std::vector<uint8_t> akms;
    uint16_t rsnCaps = 0;
    bool mfp = false;

    switch (bss.security) {
    case Security::Wpa3Sae:
        akms.push_back(SUITE_AKM_SAE);
        /* WPA3-only requires management frame protection; that is what tells
         * Android this is not a transition-mode network. */
        rsnCaps = RSN_CAP_MFPR | RSN_CAP_MFPC;
        mfp = true;
        break;
    case Security::Wpa2Wpa3Psk:
        akms.push_back(SUITE_AKM_PSK);
        akms.push_back(SUITE_AKM_SAE);
        rsnCaps = RSN_CAP_MFPC;         /* capable, not required */
        mfp = true;
        break;
    case Security::Wpa2Eap:
        akms.push_back(SUITE_AKM_EAP);
        break;
    default:
        akms.push_back(SUITE_AKM_PSK);
        break;
    }

    putU16(body, 1);                                    /* RSNE version */
    putSuite(body, OUI_RSN, groupSuite(bss.groupCiphers, true));

    std::vector<uint8_t> pw = pairwiseSuites(bss.pairwiseCiphers, true);
    putU16(body, (uint16_t) pw.size());
    for (uint8_t c : pw) {
        putSuite(body, OUI_RSN, c);
    }

    putU16(body, (uint16_t) akms.size());
    for (uint8_t a : akms) {
        putSuite(body, OUI_RSN, a);
    }

    /*
     * Everything past here is optional in the RSNE and the parser stops
     * cleanly without it, so it is only emitted when it says something: the
     * MFP bits, which Android uses to separate WPA3 from WPA2/WPA3 transition.
     * The group management cipher has to be present for those bits to be read
     * at all -- the parser gates them on it.
     */
    if (mfp) {
        putU16(body, rsnCaps);
        putU16(body, 0);                                /* PMKID count */
        putSuite(body, OUI_RSN, SUITE_CIPHER_BIP);
    }
    putElement(ies, EID_RSN, body);
}

static void
appendWpaElement(std::vector<uint8_t>& ies, const Bss& bss)
{
    std::vector<uint8_t> body;

    body.insert(body.end(), OUI_WPA, OUI_WPA + 3);
    body.push_back(0x01);                               /* WPA type 1 */
    putU16(body, 1);                                    /* version */
    putSuite(body, OUI_WPA, groupSuite(bss.groupCiphers, false));

    std::vector<uint8_t> pw = pairwiseSuites(bss.pairwiseCiphers, false);
    putU16(body, (uint16_t) pw.size());
    for (uint8_t c : pw) {
        putSuite(body, OUI_WPA, c);
    }

    putU16(body, 1);                                    /* one AKM */
    putSuite(body, OUI_WPA, SUITE_AKM_PSK);

    putElement(ies, EID_VSA, body);
}

std::vector<uint8_t>
buildBeaconIes(const Bss& bss)
{
    std::vector<uint8_t> ies;
    std::vector<uint8_t> ssid(bss.ssid.begin(), bss.ssid.end());

    /* A hidden network beacons a zero-length SSID element, which is exactly
     * what an empty string produces here -- the element is still present. */
    putElement(ies, EID_SSID, ssid);

    switch (bss.security) {
    case Security::Open:
    case Security::Wep:
        /* Neither has an element.  WEP is carried by the privacy bit alone. */
        break;
    case Security::WpaPsk:
        appendWpaElement(ies, bss);
        break;
    default:
        appendRsnElement(ies, bss);
        break;
    }
    return ies;
}

/* ---------------------------------------------------------- the parcelable */

static void
writeScanResult(GBinderWriter* w, const Bss& bss, uint64_t nowUsec,
    bool associated)
{
    std::vector<uint8_t> ies = buildBeaconIes(bss);

    writeByteArray(w, bss.ssid.data(), (int32_t) bss.ssid.size());
    writeByteArray(w, bss.bssid, sizeof(bss.bssid));
    writeByteArray(w, ies.data(), (int32_t) ies.size());
    gbinder_writer_append_int32(w, bss.freqMhz);
    gbinder_writer_append_int32(w, bss.rssiDbm * 100);   /* dBm -> mBm */

    /*
     * A result the host cannot date is dated now.  Reporting zero would be
     * more literal but strictly worse: the reader treats anything older than
     * the scan it asked for as stale and silently drops it, so zero means the
     * network never appears and nothing says why.
     */
    gbinder_writer_append_int64(w,
        (gint64) (bss.lastSeenUsec ? bss.lastSeenUsec : nowUsec));

    gbinder_writer_append_int32(w, beaconCapability(bss));
    gbinder_writer_append_int32(w, associated ? 1 : 0);
    gbinder_writer_append_int32(w, 0);          /* radioChainInfos: none */
}

int
writeScanResultArray(GBinderWriter* w, const std::vector<Bss>& list,
    const uint8_t* assocBssid)
{
    std::vector<const Bss*> keep;
    uint64_t now = boottimeUsec();

    /*
     * Over-long SSIDs are dropped, not truncated.  WifiSsid.fromBytes() throws
     * above 32 bytes, and convertNativeScanResults() does not catch it -- the
     * throw would come out inside system_server's wifi thread.  Truncating
     * would invent a network name instead, which is worse than omitting one.
     */
    for (const Bss& b : list) {
        if (b.ssid.size() > MAX_SSID_LEN) {
            GWARN("dropping a %zu-byte SSID; Android's limit is %d",
                  b.ssid.size(), MAX_SSID_LEN);
            continue;
        }
        keep.push_back(&b);
    }

    gbinder_writer_append_int32(w, (gint32) keep.size());
    for (const Bss* b : keep) {
        bool associated = assocBssid &&
            !memcmp(assocBssid, b->bssid, sizeof(b->bssid));

        /* readTypedObject()'s per-element non-null flag. */
        gbinder_writer_append_int32(w, 1);
        writeScanResult(w, *b, now, associated);
    }
    return (int) keep.size();
}

} /* namespace wifi */
} /* namespace waydroid */
