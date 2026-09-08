#include "NativeScanResult.h"
#include <cstdio>
using namespace waydroid::wifi;

static void dump(const char* label, const Bss& b)
{
    std::vector<uint8_t> ies = buildBeaconIes(b);
    printf("%s|%04x|", label, beaconCapability(b));
    for (uint8_t x : ies) printf("%02x", x);
    printf("\n");
}

int main()
{
    Bss b;
    b.ssid = "vidiot";
    b.freqMhz = 2412; b.rssiDbm = -71;

    b.security = Security::Open;       b.pairwiseCiphers = 0; b.groupCiphers = 0; dump("open", b);
    b.security = Security::Wep;                                                    dump("wep", b);
    b.security = Security::WpaPsk;  b.pairwiseCiphers = CipherTkip; b.groupCiphers = CipherTkip; dump("wpa-psk-tkip", b);
    b.security = Security::Wpa2Psk; b.pairwiseCiphers = CipherCcmp; b.groupCiphers = CipherCcmp; dump("wpa2-psk-ccmp", b);
    b.security = Security::Wpa2Psk; b.pairwiseCiphers = CipherCcmp|CipherTkip; b.groupCiphers = CipherTkip; dump("wpa2-psk-mixed", b);
    b.security = Security::Wpa3Sae;  b.pairwiseCiphers = CipherCcmp; b.groupCiphers = CipherCcmp; dump("wpa3-sae", b);
    b.security = Security::Wpa2Wpa3Psk;                                            dump("wpa2/wpa3", b);
    b.security = Security::Wpa2Eap;                                                dump("wpa2-eap", b);
    b.security = Security::Wpa2Psk; b.pairwiseCiphers = 0; b.groupCiphers = 0;      dump("wpa2-nociphers", b);
    b.ssid = "";  b.security = Security::Open;                                      dump("hidden-open", b);
    return 0;
}
