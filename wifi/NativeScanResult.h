/*
 * android.net.wifi.nl80211.NativeScanResult, on the wire.
 *
 * NativeScanResult is a *custom* parcelable -- its .aidl is only
 * "parcelable NativeScanResult cpp_header ..." -- so there is no generated
 * layout to read off and no self-describing header on the wire.  The layout is
 * whatever the reader's createFromParcel() does, field by field, and getting it
 * wrong desynchronises the rest of the reply.
 *
 * So it was not taken from AOSP on trust.  It was disassembled out of THIS
 * image's framework.jar, the same method docs/30-wifi-aidl-surface.md used for
 * the transaction codes:
 *
 *   dexdump -d classes2.dex   ->  NativeScanResult$1.createFromParcel
 *
 *     createByteArray()   ssid            (null is replaced with byte[0])
 *     createByteArray()   bssid           (must be exactly 6, or the result
 *                                          is dropped by WifiNative)
 *     createByteArray()   infoElement     (the beacon/probe-response IEs)
 *     readInt()           frequency       MHz
 *     readInt()           signalMbm       mBm, i.e. dBm x 100
 *     readLong()          tsf             CLOCK_BOOTTIME microseconds when the
 *                                         AP was last seen -- despite the name
 *     readInt()           capability      the 802.11 capability field
 *     readInt()           associated      0/1
 *     readTypedList()     radioChainInfos each element: two ints
 *
 * The array framing around it is Parcel.createTypedArray(), also read from the
 * image: int32 count, then per element an int32 non-null flag (readTypedObject)
 * followed by the body.  An empty *array* is count 0; a null array is -1.
 *
 * WHY THE IEs ARE SYNTHESISED
 *
 * Android does not read a "security type" field, because 802.11 has none: it
 * parses the information elements out of the beacon and derives everything
 * from them (InformationElementUtil.Capabilities).  A host backend has no
 * beacon to forward -- NetworkManager parsed one and threw it away, keeping
 * the conclusions -- so the IEs have to be rebuilt from those conclusions or
 * every network in the picker shows up as open.
 *
 * Only IEs that carry something the host actually told us are emitted: the
 * SSID, and one RSN or WPA element describing the security NM reported.  No
 * rates, HT or VHT elements are invented, which costs an accurate
 * WifiStandard badge (Android shows "unknown") and is the honest trade.
 */

#pragma once

#include "WifiBackend.h"

#include <gbinder.h>

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

/*
 * Write NativeScanResult[].  Results whose SSID cannot be represented are
 * dropped rather than truncated; returns how many were written.
 * "associated" is set for the BSS matching assocBssid, which may be null.
 */
int writeScanResultArray(GBinderWriter* w, const std::vector<Bss>& list,
    const uint8_t* assocBssid);

} /* namespace wifi */
} /* namespace waydroid */
