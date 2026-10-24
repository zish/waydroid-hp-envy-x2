#include "NativeScanResult.h"
#include "AidlParcel.h"

#include <gutil_log.h>

#include <cstring>

namespace waydroid {
namespace wifi {

using namespace aidl;

/* Android refuses an SSID longer than this and throws where nothing catches. */
#define MAX_SSID_LEN 32

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
