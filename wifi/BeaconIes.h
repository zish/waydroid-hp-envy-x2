/*
 * The 802.11 beacon pieces Android parses a scan result's security out of,
 * synthesised from what the host backend reported.
 *
 * NetworkManager parsed the real beacon and kept only its conclusions, so
 * these are rebuilt from those conclusions or every network in the picker
 * shows up as open (docs/32).  Split out of NativeScanResult.cpp so they can be
 * tested without gbinder: this half is pure bytes, the other half is the
 * parcel.  tests/cpp/test_beacon_ies.cpp pins the output against the bytes
 * artifacts/wifi/stage3/ie-synthesis-check.txt recorded and the device
 * confirmed.
 */
#pragma once

#include "WifiBackend.h"

#include <cstdint>
#include <vector>

namespace waydroid {
namespace wifi {

/* CLOCK_BOOTTIME in microseconds -- the clock Android compares tsf against. */
uint64_t boottimeUsec();

/* The 802.11 capability field, from what the host knows about the BSS. */
uint16_t beaconCapability(const Bss& bss);

/* A beacon IE blob describing this BSS: SSID plus RSN/WPA if it is secured. */
std::vector<uint8_t> buildBeaconIes(const Bss& bss);

} // namespace wifi
} // namespace waydroid
