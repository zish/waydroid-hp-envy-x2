/*
 * Unit tests for wifi/BeaconIes.cpp -- the 802.11 elements synthesised so
 * Android can read a scan result's security.
 *
 * sources: wifi/BeaconIes.cpp
 *
 * The expected bytes are not this code's output pasted back in.  They are the
 * ones artifacts/wifi/stage3/ie-synthesis-check.txt recorded at Stage 3, which
 * were decoded through a reimplementation of AOSP 13's InformationElementUtil
 * (artifacts/wifi/stage3/decode.py) into the capability strings in the
 * comments below, and then confirmed on the device by `cmd wifi
 * list-scan-results`.  So a byte that changes here changes what the Wi-Fi
 * picker shows, and the decoded string says what it used to show.
 */
#include "BeaconIes.h"

#include <cstdio>
#include <cstdlib>
#include <string>

using namespace waydroid::wifi;

static int failures;
static int checks;

static std::string
hex(const std::vector<uint8_t>& v)
{
    static const char digits[] = "0123456789abcdef";
    std::string out;
    for (uint8_t b : v) {
        out += digits[b >> 4];
        out += digits[b & 0xf];
    }
    return out;
}

static void
expect(const char* label, Security sec, uint32_t pairwise, uint32_t group,
    const char* ssid, unsigned wantCap, const char* wantIes)
{
    Bss b;
    b.ssid = ssid;
    b.security = sec;
    b.pairwiseCiphers = pairwise;
    b.groupCiphers = group;

    ++checks;
    std::string got = hex(buildBeaconIes(b));
    if (got != wantIes) {
        ++failures;
        std::fprintf(stderr, "%s: IEs\n  got  %s\n  want %s\n",
                     label, got.c_str(), wantIes);
    }
    ++checks;
    if (beaconCapability(b) != wantCap) {
        ++failures;
        std::fprintf(stderr, "%s: capability 0x%04x, want 0x%04x\n",
                     label, beaconCapability(b), wantCap);
    }
}

int
main()
{
    const uint32_t C = CipherCcmp, T = CipherTkip;

    /* [ESS] */
    expect("open", Security::Open, 0, 0, "vidiot",
           0x0001, "0006766964696f74");
    /* [WEP][ESS] -- WEP has no element; the privacy bit alone says it */
    expect("wep", Security::Wep, 0, 0, "vidiot",
           0x0011, "0006766964696f74");
    /* [WPA-PSK-TKIP][ESS] */
    expect("wpa-psk-tkip", Security::WpaPsk, T, T, "vidiot",
           0x0011, "0006766964696f74"
                   "dd160050f20101000050f20201000050f20201000050f202");
    /* [WPA2-PSK-CCMP][RSN-PSK-CCMP][ESS] */
    expect("wpa2-psk-ccmp", Security::Wpa2Psk, C, C, "vidiot",
           0x0011, "0006766964696f74"
                   "30120100000fac040100000fac040100000fac02");
    /* [WPA2-PSK-CCMP+TKIP][RSN-PSK-CCMP+TKIP][ESS] -- group is the weakest */
    expect("wpa2-psk-mixed", Security::Wpa2Psk, C | T, T, "vidiot",
           0x0011, "0006766964696f74"
                   "30160100000fac020200000fac04000fac020100000fac02");
    /* [RSN-SAE-CCMP][ESS][MFPR][MFPC] -- WPA3-only requires MFP */
    expect("wpa3-sae", Security::Wpa3Sae, C, C, "vidiot",
           0x0011, "0006766964696f74"
                   "301a0100000fac040100000fac040100000fac08c0000000000fac06");
    /* [WPA2-PSK+SAE-CCMP][RSN-PSK+SAE-CCMP][ESS][MFPC] -- capable, not required */
    expect("wpa2/wpa3", Security::Wpa2Wpa3Psk, C, C, "vidiot",
           0x0011, "0006766964696f74"
                   "301e0100000fac040100000fac040200000fac02000fac0880000000000fac06");
    /* [WPA2-EAP/SHA1-CCMP][RSN-EAP/SHA1-CCMP][ESS] */
    expect("wpa2-eap", Security::Wpa2Eap, C, C, "vidiot",
           0x0011, "0006766964696f74"
                   "30120100000fac040100000fac040100000fac01");
    /* A backend that reported no ciphers gets the protocol default, CCMP. */
    expect("wpa2-nociphers", Security::Wpa2Psk, 0, 0, "vidiot",
           0x0011, "0006766964696f74"
                   "30120100000fac040100000fac040100000fac02");
    /* A hidden network still beacons the SSID element, zero-length. */
    expect("hidden-open", Security::Open, 0, 0, "",
           0x0001, "0000");

    /* boottimeUsec() is CLOCK_BOOTTIME, so it moves forward and is non-zero. */
    ++checks;
    uint64_t a = boottimeUsec(), b = boottimeUsec();
    if (a == 0 || b < a) {
        ++failures;
        std::fprintf(stderr, "boottimeUsec: %llu then %llu\n",
                     (unsigned long long) a, (unsigned long long) b);
    }

    std::printf("test_beacon_ies: %d checks, %d failed\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
