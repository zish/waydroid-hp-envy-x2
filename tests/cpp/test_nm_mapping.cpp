/*
 * Unit tests for wifi/NmMapping.h -- NetworkManager's numbers turned into the
 * ones Android is handed.  Needs only glib; no gbinder, no D-Bus, no radio.
 *
 * No test framework on purpose, for the same reason the apps have no Gradle:
 * nothing to install, and tests/run.sh builds this with one g++ line.
 *
 * The expected UUIDs were produced by Python's uuid.uuid5 in the daemon's
 * namespace, which is the same oracle tests/test_wifi_uuid.py checks
 * waydroid-wifi-sync's bash against -- so the C++, the bash and RFC 4122
 * agree pairwise, and a profile the daemon creates is one the reaper owns.
 */
#include "NmMapping.h"

#include <cstdio>
#include <cstdlib>

using namespace waydroid::wifi;

static int failures;
static int checks;

#define CHECK_EQ(got, want) do {                                            \
    ++checks;                                                               \
    auto g_ = (got);                                                        \
    auto w_ = (want);                                                       \
    if (!(g_ == w_)) {                                                      \
        ++failures;                                                         \
        std::fprintf(stderr, "%s:%d: %s == %s failed\n",                    \
                     __FILE__, __LINE__, #got, #want);                      \
    }                                                                       \
} while (0)

/* NM's own nm_wifi_utils_level_to_quality(), the function rssiFromQuality()
 * claims to invert.  Transcribed, not derived, so the test cannot share a
 * misreading with the code under test. */
static guint32
nmLevelToQuality(int dbm)
{
    int v = dbm;
    if (v < -100) v = -100;
    if (v > -40)  v = -40;
    v += 40;
    if (v < 0) v = -v;
    return 100 - (int) (100.0 * v / 60.0);
}

static void
testRssi()
{
    /* docs/59's claim, checked whole: every dBm NM can represent survives
     * the round trip exactly.  The old q/2-100 failed 58 of these 61. */
    for (int dbm = -100; dbm <= -40; ++dbm) {
        int got = rssiFromQuality(nmLevelToQuality(dbm));
        if (got != dbm) {
            std::fprintf(stderr, "rssi round trip: %d dBm -> q %u -> %d\n",
                         dbm, nmLevelToQuality(dbm), got);
        }
        CHECK_EQ(got, dbm);
    }

    /* The field table in NmMapping.h, measured against iw on bigtab01. */
    CHECK_EQ(rssiFromQuality(7), -96);
    CHECK_EQ(rssiFromQuality(20), -88);
    CHECK_EQ(rssiFromQuality(40), -76);
    CHECK_EQ(rssiFromQuality(70), -58);
    CHECK_EQ(rssiFromQuality(72), -57);

    CHECK_EQ(rssiFromQuality(0), -100);
    CHECK_EQ(rssiFromQuality(100), -40);
    CHECK_EQ(rssiFromQuality(255), -40);      /* clamped, not -100 + 153 */
    CHECK_EQ(rssiFromQuality(0xffffffffu), -40);
}

static void
testSecurity()
{
    const guint32 P = NM_AP_FLAGS_PRIVACY;
    const guint32 PSK = NM_SEC_KEY_MGMT_PSK;
    const guint32 SAE = NM_SEC_KEY_MGMT_SAE;

    CHECK_EQ(securityFromFlags(0, 0, 0), Security::Open);
    CHECK_EQ(securityFromFlags(P, 0, 0), Security::Wep);
    CHECK_EQ(securityFromFlags(P, PSK, 0), Security::WpaPsk);
    CHECK_EQ(securityFromFlags(P, 0, PSK), Security::Wpa2Psk);
    CHECK_EQ(securityFromFlags(P, PSK, PSK), Security::Wpa2Psk);
    /* Transition mode and WPA3-only differ in required PMF; docs/59. */
    CHECK_EQ(securityFromFlags(P, 0, PSK | SAE), Security::Wpa2Wpa3Psk);
    CHECK_EQ(securityFromFlags(P, 0, SAE), Security::Wpa3Sae);
    CHECK_EQ(securityFromFlags(P, 0, NM_SEC_KEY_MGMT_802_1X), Security::Wpa2Eap);
    CHECK_EQ(securityFromFlags(P, NM_SEC_KEY_MGMT_802_1X, 0), Security::Wpa2Eap);
    CHECK_EQ(securityFromFlags(P, 0, NM_SEC_KEY_MGMT_EAP_192), Security::Wpa2Eap);
    /* Privacy with WPA flags we do not model is not WEP. */
    CHECK_EQ(securityFromFlags(P, 0, NM_SEC_KEY_MGMT_OWE), Security::Open);
}

static void
testCiphers()
{
    const guint32 f = NM_SEC_PAIR_CCMP | NM_SEC_GROUP_TKIP | NM_SEC_KEY_MGMT_PSK;
    CHECK_EQ(ciphersFromFlags(f, false), (uint32_t) CipherCcmp);
    CHECK_EQ(ciphersFromFlags(f, true), (uint32_t) CipherTkip);
    CHECK_EQ(ciphersFromFlags(0xff, false),
             (uint32_t) (CipherWep40 | CipherWep104 | CipherTkip | CipherCcmp));
    CHECK_EQ(ciphersFromFlags(0xff, true),
             (uint32_t) (CipherWep40 | CipherWep104 | CipherTkip | CipherCcmp));
    CHECK_EQ(ciphersFromFlags(NM_SEC_KEY_MGMT_PSK, false), 0u);
}

static void
testUuid()
{
    CHECK_EQ(waydroidConnectionUuid("vidiot"),
             std::string("14921b3a-4895-5fcb-8d38-a71863bef507"));
    CHECK_EQ(waydroidConnectionUuid("My Network"),
             std::string("f04ce4dd-6be9-5a1c-b89e-df6fb999e91f"));
    CHECK_EQ(waydroidConnectionUuid("caf\xc3\xa9 \xe2\x98\x95"),
             std::string("29efa0d6-6450-5223-9661-31fdbca97533"));
    CHECK_EQ(waydroidConnectionUuid(std::string(32, 'x')),
             std::string("e3940893-ef3c-5cc3-a661-0d6e8ae79dfc"));
    CHECK_EQ(waydroidConnectionUuid(""),
             std::string("ba43da89-f501-5344-8068-98b04b356c15"));
}

int
main()
{
    testRssi();
    testSecurity();
    testCiphers();
    testUuid();
    std::printf("test_nm_mapping: %d checks, %d failed\n", checks, failures);
    return failures ? EXIT_FAILURE : EXIT_SUCCESS;
}
