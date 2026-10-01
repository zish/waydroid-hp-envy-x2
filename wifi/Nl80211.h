/*
 * waydroid-wifid -- nl80211, read directly, for the things NetworkManager
 * structurally cannot answer.
 *
 * WHY THIS EXISTS AT ALL, GIVEN THERE IS ALREADY A BACKEND
 *
 * NmBackend answers almost everything, and where it does it is the better
 * source: it knows which profiles exist, which are ours, and what the user
 * asked for.  But three of Android's questions are about the RADIO rather than
 * about the configuration, and NM does not carry the answers:
 *
 *   - The NEGOTIATED PHY.  ISupplicantStaIface.getConnectionCapabilities wants
 *     HT/VHT/HE/EHT as settled between this station and this AP.  NM's only
 *     candidate is AccessPoint.MaxBitrate, which is the AP's advertised best
 *     case across all its radios -- measured on bigtab01, APs advertise
 *     1170 Mb/s on a 20 MHz 2.4 GHz channel, which is impossible.  See the long
 *     note in Supplicant.cpp's getConnectionCapabilities.
 *   - RX bitrate.  NM exposes ONE Bitrate property, so rx was reported as tx.
 *     Ground truth on this machine's live link was 130 Mb/s tx and 5.5 Mb/s rx
 *     -- a factor of 24, not a rounding difference.
 *   - Packet counters.  IClientInterface.getPacketCounters wants tx good and
 *     tx bad.  NM counts neither.
 *
 * And one it answers less well than the radio does: RSSI.  NM publishes a 0..100
 * quality that it polls on its own schedule, so the value can be seconds stale
 * and is quantised to 60 dB in 100 steps.  NL80211_STA_INFO_SIGNAL is the dBm
 * the driver last measured.
 *
 * WHY RAW NETLINK AND NOT libnl
 *
 * libnl is not installed on the dev box this is cross-built on -- pkg-config
 * cannot find libnl-genl-3.0 and there is no libnl-3.so -- while
 * <linux/nl80211.h>, <linux/netlink.h> and <linux/genetlink.h> all are, because
 * they are kernel uAPI and ship with the C library's headers.  Linking libnl
 * would therefore mean two new runtime dependencies, two more .so files for
 * build.sh --deps to copy off the host, two more pkg-config names in the --rpm
 * arm, and two new RPM Requires -- to do TLV walking that is a few hundred lines
 * and has no interesting cases.
 *
 * The ABI argument that justifies vendoring libgbinder headers does not apply
 * here either, and that is the load-bearing half of the reasoning.  libgbinder
 * is a C++-adjacent library whose layout can change between releases, so the
 * build pins it to the host's exact version.  The netlink WIRE FORMAT is a
 * kernel ABI: attributes are append-only and the kernel never renumbers one.
 * Compiling against this box's headers and running against the host's newer
 * kernel is therefore safe by the kernel's own compatibility rule, and the worst
 * case is not knowing about an attribute added after our header was written.
 *
 * WHERE THIS SITS RELATIVE TO WifiBackend.h
 *
 * Below the line, like NmBackend.  nl80211 is host-radio knowledge and no
 * Android type appears here; a hypothetical iwd backend would consult this same
 * class rather than reimplementing it.  It is deliberately NOT a WifiBackend of
 * its own: nl80211 cannot associate without a supplicant, so it has nothing to
 * say about half the contract.
 *
 * THREAD SAFETY -- THE POINT OF THE ifindex ARGUMENT
 *
 * Every call here is keyed by an INTERFACE INDEX passed in by the caller, and
 * that is a deliberate design choice rather than an interface convenience.
 * These calls are made from binder transaction handlers, which run on binder
 * threads, while NmBackend's own state is mutated from the GLib main loop.  An
 * int is something the caller can hold in a std::atomic and hand over without
 * sharing anything mutable; if this class took an interface NAME it would have
 * to read a std::string that the main loop can rewrite when the radio is
 * renamed, which is exactly the data race docs/59 recorded against
 * NmBackend::state().  See the note on mIfindex in NmBackend.h.
 *
 * The class itself serialises its own socket with a mutex, so several binder
 * threads may call it at once.
 */

#pragma once

#include "WifiBackend.h"

#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

namespace waydroid {
namespace wifi {

/* One direction of a link's rate, as nl80211 describes it. */
struct RateInfo {
    int32_t bitrateKbps = 0;
    int32_t widthMhz    = 0;        /* 0 when no width attribute was present */
    Phy     phy         = Phy::Unknown;
    int32_t nss         = 0;        /* spatial streams; 0 if the rate does not say */
};

/*
 * The associated AP, as the driver sees it.  This is the NL80211_CMD_GET_STATION
 * reply for a managed-mode interface, which has exactly one station.
 */
struct StationInfo {
    bool     valid = false;
    uint8_t  bssid[6] = {0, 0, 0, 0, 0, 0};

    int32_t  signalDbm    = 0;      /* STA_INFO_SIGNAL, s8, negative */
    int32_t  signalAvgDbm = 0;
    bool     haveSignal   = false;

    RateInfo tx;
    RateInfo rx;

    /*
     * Counters, as the driver has them.  64-bit here even though Android's
     * getPacketCounters is int32: the clamp belongs at the seam that has the
     * narrow type, not in the layer reporting what the radio said.
     */
    uint64_t txPackets = 0;
    uint64_t txFailed  = 0;
    uint64_t txRetries = 0;
    uint64_t rxPackets = 0;
    bool     haveCounters = false;

    uint32_t connectedTimeSec = 0;
};

class Nl80211 {
public:
    Nl80211() = default;
    ~Nl80211();

    Nl80211(const Nl80211&) = delete;
    Nl80211& operator=(const Nl80211&) = delete;

    /*
     * Open the netlink socket and resolve the nl80211 generic-netlink family.
     *
     * Failure is NOT fatal to the daemon and callers must treat it that way:
     * every value this class produces has an NM-derived fallback that was in
     * service before it existed.  A host with a kernel that has no nl80211 at
     * all still gets Wi-Fi, just with the coarser numbers.
     */
    bool open();
    bool isOpen() const { return mFd >= 0; }

    /* Human-readable reason the last open() or request failed; "" if none. */
    const std::string& lastError() const { return mLastError; }

    /*
     * The associated station on `ifindex`.  False when the interface is not
     * associated, which is not an error -- an unassociated managed interface
     * simply has no stations, and the dump comes back empty.
     */
    bool station(int ifindex, StationInfo& out);

    /*
     * The capabilities of the wiphy behind `ifindex`, as RadioCaps.
     *
     * Android needs this ANSWERED before it will predict throughput at all:
     * ThroughputPredictor.predictThroughput logs "Null device capabilities
     * passed to throughput predictor" and returns 0 as its first act, before it
     * looks at the PHY or anything else.  So this is not a companion to the
     * negotiated-PHY work, it is what makes that work reach anything.  Read out
     * of this image's own framework dex; see docs/60.
     */
    bool wiphy(int ifindex, RadioCaps& out);

private:
    /*
     * One request/reply round trip.  `dump` selects NLM_F_DUMP, in which case
     * every reply message is appended to `out` until NLMSG_DONE.
     *
     * `extra` is appended after the ifindex attribute, for the one caller that
     * needs a flag attribute (split wiphy dump).
     */
    bool request(uint8_t cmd, int ifindex, bool dump,
                 const std::vector<uint8_t>& extra,
                 std::vector<std::vector<uint8_t> >& out);

    bool resolveFamily();
    void fail(const char* what, int err);

    int         mFd      = -1;
    uint16_t    mFamily  = 0;
    uint32_t    mSeq     = 1;
    uint32_t    mPortId  = 0;
    std::string mLastError;

    /*
     * One socket shared by every caller, so the round trips have to be
     * serialised.  A mutex rather than a socket per thread because the calls are
     * rare (Android polls the link on the order of seconds) and short, and
     * because one socket is one fd and one place for the receive timeout to be
     * set.
     */
    std::mutex  mLock;
};

} /* namespace wifi */
} /* namespace waydroid */
