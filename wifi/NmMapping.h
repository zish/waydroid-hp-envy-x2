/*
 * Pure translations from NetworkManager's vocabulary to the backend's.
 *
 * These live in a header, apart from NmBackend.cpp, for one reason: so they can
 * be unit-tested without gbinder, D-Bus or a radio.  They depend on nothing but
 * WifiBackend.h and glib's checksum, and every one of them has already been
 * wrong once in a way no integration test noticed -- rssiFromQuality() was off
 * by up to 10 dB from Stage 3 until docs/59, while every check passed.
 * tests/cpp/test_nm_mapping.cpp pins them.
 */
#pragma once

#include "WifiBackend.h"

#include <glib.h>

#include <cstdint>
#include <string>

namespace waydroid {
namespace wifi {

/* NM80211ApSecurityFlags */
#define NM_SEC_PAIR_WEP40       0x00000001
#define NM_SEC_PAIR_WEP104      0x00000002
#define NM_SEC_PAIR_TKIP        0x00000004
#define NM_SEC_PAIR_CCMP        0x00000008
#define NM_SEC_GROUP_WEP40      0x00000010
#define NM_SEC_GROUP_WEP104     0x00000020
#define NM_SEC_GROUP_TKIP       0x00000040
#define NM_SEC_GROUP_CCMP       0x00000080
#define NM_SEC_KEY_MGMT_PSK     0x00000100
#define NM_SEC_KEY_MGMT_802_1X  0x00000200
#define NM_SEC_KEY_MGMT_SAE     0x00000400
#define NM_SEC_KEY_MGMT_OWE     0x00000800
#define NM_SEC_KEY_MGMT_OWE_TM  0x00001000
#define NM_SEC_KEY_MGMT_EAP_192 0x00002000

/* NM80211ApFlags */
#define NM_AP_FLAGS_PRIVACY     0x00000001

inline int32_t
rssiFromQuality(guint32 quality)
{
    /*
     * NM reports Strength as 0..100, Android wants dBm.  This is the EXACT
     * inverse of NM's own nm_wifi_utils_level_to_quality(), which is
     *
     *     quality = 100 - (int)(100.0 * |clamp(dBm, -100, -40) + 40| / 60.0)
     *
     * so the representable range is -100..-40 dBm and the step is 3/5 dBm per
     * quality point.  Inverting it gives -100 + 3 * quality / 5, and C's
     * truncating division lands on the same value NM truncated away.
     *
     * IT USED TO BE quality / 2 - 100, WHICH IS WRONG EVERYWHERE BUT 0.
     * That mapping assumed the range was -100..-50, so its slope was 1/2
     * instead of 3/5 and it read low by quality/10 dB -- 0 dB at the bottom of
     * the range, 10 dB at the top.  Measured on bigtab01 against nl80211 by
     * pairing NM's Strength with `iw dev wlp1s0 scan dump`'s signal FROM THE
     * SAME SCAN (pairing across scans measures nothing but the signal moving):
     *
     * Both columns below are the INTEGER results, i.e. what each form of this
     * function actually returned, not the real-valued mapping:
     *
     *     NM  iw dBm   q/2-100   -100+3q/5
     *      7     -96    -97  -1     -96  +0
     *     20     -88    -90  -2     -88  +0
     *     40     -76    -80  -4     -76  +0
     *     70     -58    -65  -7     -58  +0
     *     72     -57    -64  -7     -57  +0
     *
     * 13 distinct APs, every one of them exact under this form and every one
     * wrong under the old one.  The cost of the old form was not cosmetic:
     * this machine's AP sits at about -62 dBm and Android was being told -71,
     * and `dumpsys wifi`'s ScoringParams on this image are
     * rssi2=-83:-80:-73:-60 (exit:entry:sufficient:good).  So a link 1 dB shy
     * of "good" was reported 1.5 dB above "insufficient", 11 dB from the
     * threshold at which the framework gives up on the network -- turning an
     * ordinary fade into a teardown.  See docs/59-wifi-stage5-polish.md.
     */
    if (quality > 100) {
        quality = 100;
    }
    return -100 + (int32_t) (3 * quality) / 5;
}

inline Security
securityFromFlags(guint32 flags, guint32 wpa, guint32 rsn)
{
    if (rsn & NM_SEC_KEY_MGMT_SAE) {
        /*
         * SAE alongside PSK is a WPA2/WPA3 transition-mode AP, and the two
         * cases are not interchangeable to Android: a transition AP does not
         * require management frame protection and a WPA3-only one does, which
         * is how the framework tells them apart in the scan result.
         */
        return (rsn & NM_SEC_KEY_MGMT_PSK) ? Security::Wpa2Wpa3Psk
                                           : Security::Wpa3Sae;
    }
    if ((rsn | wpa) & (NM_SEC_KEY_MGMT_802_1X | NM_SEC_KEY_MGMT_EAP_192)) {
        return Security::Wpa2Eap;
    }
    if (rsn & NM_SEC_KEY_MGMT_PSK) {
        return Security::Wpa2Psk;
    }
    if (wpa & NM_SEC_KEY_MGMT_PSK) {
        return Security::WpaPsk;
    }
    if ((flags & NM_AP_FLAGS_PRIVACY) && !wpa && !rsn) {
        return Security::Wep;
    }
    return Security::Open;
}

/*
 * NM reports the ciphers the AP advertised, so they can be passed on as
 * observation rather than guessed at higher up.  WPA-only networks are
 * described by WpaFlags and everything newer by RsnFlags; where both are
 * present the RSN half is the one the security type above refers to.
 */
inline uint32_t
ciphersFromFlags(guint32 f, bool group)
{
    uint32_t out = 0;

    if (f & (group ? NM_SEC_GROUP_WEP40  : NM_SEC_PAIR_WEP40))  out |= CipherWep40;
    if (f & (group ? NM_SEC_GROUP_WEP104 : NM_SEC_PAIR_WEP104)) out |= CipherWep104;
    if (f & (group ? NM_SEC_GROUP_TKIP   : NM_SEC_PAIR_TKIP))   out |= CipherTkip;
    if (f & (group ? NM_SEC_GROUP_CCMP   : NM_SEC_PAIR_CCMP))   out |= CipherCcmp;
    return out;
}

/*
 * The RFC 4122 version-5 UUID of `ssid` in waydroid-wifid's namespace.  This
 * is the profile's identity, not a label -- see NmBackend::connectionUuid() --
 * and artifacts/wifi/waydroid-wifi-sync recomputes it in bash to decide which
 * profiles are ours.  tests/ pins both against Python's uuid.uuid5.
 */
inline std::string
waydroidConnectionUuid(const std::string& ssid)
{
    /* Namespace for waydroid-wifid profile UUIDs.  Randomly generated once and
     * fixed forever after: changing it orphans every profile we have made. */
    static const guint8 kNamespace[16] = {
        0x7f, 0x86, 0x2e, 0xff, 0x2c, 0xb3, 0x41, 0xe0,
        0xad, 0xa9, 0x31, 0x51, 0x20, 0x0e, 0xf9, 0x7f
    };

    guint8 digest[20];
    gsize len = sizeof(digest);
    GChecksum* sha1 = g_checksum_new(G_CHECKSUM_SHA1);

    g_checksum_update(sha1, kNamespace, sizeof(kNamespace));
    g_checksum_update(sha1, (const guchar*) ssid.data(), ssid.size());
    g_checksum_get_digest(sha1, digest, &len);
    g_checksum_free(sha1);

    digest[6] = (digest[6] & 0x0f) | 0x50;  /* version 5 */
    digest[8] = (digest[8] & 0x3f) | 0x80;  /* RFC 4122 variant */

    char out[37];
    g_snprintf(out, sizeof(out),
        "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5],
        digest[6], digest[7], digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15]);
    return std::string(out);
}

} // namespace wifi
} // namespace waydroid
