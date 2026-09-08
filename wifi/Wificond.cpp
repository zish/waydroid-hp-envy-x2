#include "Wificond.h"
#include "AidlParcel.h"
#include "NativeScanResult.h"

#include <gutil_log.h>

#include <cstring>

namespace waydroid {
namespace wifi {

using namespace aidl;

/* --------------------------------------------------------- wire constants */

#define IFACE_WIFICOND  "android.net.wifi.nl80211.IWificond"
#define IFACE_CLIENT    "android.net.wifi.nl80211.IClientInterface"
#define IFACE_SCANNER   "android.net.wifi.nl80211.IWifiScannerImpl"
#define IFACE_SCANEVENT "android.net.wifi.nl80211.IScanEvent"
#define IFACE_PNOEVENT  "android.net.wifi.nl80211.IPnoScanEvent"

/* IWificond, codes verified against this image's framework.jar (docs/30). */
enum {
    WIFICOND_createApInterface              = 1,
    WIFICOND_createClientInterface          = 2,
    WIFICOND_tearDownApInterface            = 3,
    WIFICOND_tearDownClientInterface        = 4,
    WIFICOND_tearDownInterfaces             = 5,
    WIFICOND_GetClientInterfaces            = 6,
    WIFICOND_GetApInterfaces                = 7,
    WIFICOND_getAvailable2gChannels         = 8,
    WIFICOND_getAvailable5gNonDFSChannels   = 9,
    WIFICOND_getAvailableDFSChannels        = 10,
    WIFICOND_getAvailable6gChannels         = 11,
    WIFICOND_getAvailable60gChannels        = 12,
    WIFICOND_RegisterCallback               = 13,
    WIFICOND_UnregisterCallback             = 14,
    WIFICOND_registerWificondEventCallback  = 15,
    WIFICOND_unregisterWificondEventCallback= 16,
    WIFICOND_getDeviceWiphyCapabilities     = 17,
    WIFICOND_notifyCountryCodeChanged       = 18,
};

enum {
    CLIENT_getPacketCounters    = 1,
    CLIENT_signalPoll           = 2,
    CLIENT_getMacAddress        = 3,
    CLIENT_getInterfaceName     = 4,
    CLIENT_getWifiScannerImpl   = 5,
    CLIENT_SendMgmtFrame        = 6,
};

enum {
    SCANNER_getScanResults          = 1,
    SCANNER_getPnoScanResults       = 2,
    SCANNER_getMaxSsidsPerScan      = 3,
    SCANNER_scan                    = 4,
    SCANNER_subscribeScanEvents     = 5,
    SCANNER_unsubscribeScanEvents   = 6,
    SCANNER_subscribePnoScanEvents  = 7,
    SCANNER_unsubscribePnoScanEvents= 8,
    SCANNER_startPnoScan            = 9,
    SCANNER_stopPnoScan             = 10,
    SCANNER_abortScan               = 11,
};

/* IScanEvent / IPnoScanEvent -- we are the caller here, not the callee. */
enum {
    SCANEVENT_OnScanResultReady = 1,
    SCANEVENT_OnScanFailed      = 2,
};

/* --------------------------------------------------------------- helpers */

static GBinderLocalReply*
beginReply(GBinderLocalObject* obj, GBinderWriter* w, int* status)
{
    GBinderLocalReply* reply = gbinder_local_object_new_reply(obj);

    gbinder_local_reply_init_writer(reply, w);
    writeNoException(w);
    *status = GBINDER_STATUS_OK;
    return reply;
}

/*
 * Every transaction carries the interface token, and a mismatch means we are
 * about to marshal the wrong thing.  Fail loudly rather than replying with
 * plausible garbage -- a wrong reply shape desynchronises the parcel and shows
 * up much later as an unrelated-looking framework crash.
 */
static bool
ifaceOk(GBinderRemoteRequest* req, const char* expect, guint code)
{
    const char* got = gbinder_remote_request_interface(req);

    if (!g_strcmp0(got, expect)) {
        return true;
    }
    GERR("transaction %u on %s arrived with interface \"%s\"", code, expect,
         got ? got : "(none)");
    return false;
}

/* --------------------------------------------------------------- Wificond */

Wificond::Wificond(GBinderServiceManager* sm, WifiBackend* backend) :
    mSm(sm), mBackend(backend)
{
    mWificond = gbinder_servicemanager_new_local_object(sm, IFACE_WIFICOND,
        onWificond, this);

    /*
     * The framework is told a scan finished only when the host says one did.
     * Announcing earlier is worse than not announcing: WificondScannerImpl
     * discards every result older than the scan it asked for, so an early
     * OnScanResultReady delivers the previous scan's list straight into the
     * stale filter and the picker stays empty with nothing in the log to
     * explain it.
     */
    mBackend->onScanComplete([this](bool ok) {
        if (!mScanPending) {
            return;
        }
        mScanPending = false;
        if (ok) {
            notifyScanResultsReady();
        } else {
            GWARN("the host produced no scan; reporting failure");
            notifyScanFailed();
        }
    });
}

Wificond::~Wificond()
{
    /* The backend holds a std::function capturing this; drop it first. */
    mBackend->onScanComplete(nullptr);
    dropScanEvent();
    dropPnoScanEvent();
    if (mEventCallback) {
        gbinder_remote_object_unref(mEventCallback);
    }
    if (mScanner) {
        gbinder_local_object_drop(mScanner);
    }
    if (mClient) {
        gbinder_local_object_drop(mClient);
    }
    if (mWificond) {
        gbinder_local_object_drop(mWificond);
    }
}

void
Wificond::ensureClientInterface()
{
    if (!mClient) {
        mClient = gbinder_servicemanager_new_local_object(mSm, IFACE_CLIENT,
            onClientInterface, this);
    }
    if (!mScanner) {
        mScanner = gbinder_servicemanager_new_local_object(mSm, IFACE_SCANNER,
            onScanner, this);
    }
}

void
Wificond::dropScanEvent()
{
    /* Nobody left to tell, so no scan is outstanding as far as we care. */
    mScanPending = false;
    if (mScanEventClient) {
        gbinder_client_unref(mScanEventClient);
        mScanEventClient = nullptr;
    }
    if (mScanEvent) {
        gbinder_remote_object_unref(mScanEvent);
        mScanEvent = nullptr;
    }
}

void
Wificond::dropPnoScanEvent()
{
    if (mPnoScanEventClient) {
        gbinder_client_unref(mPnoScanEventClient);
        mPnoScanEventClient = nullptr;
    }
    if (mPnoScanEvent) {
        gbinder_remote_object_unref(mPnoScanEvent);
        mPnoScanEvent = nullptr;
    }
}

void
Wificond::notifyScanResultsReady()
{
    if (!mScanEventClient) {
        GDEBUG("scan results ready, but nobody has subscribed");
        return;
    }
    GDEBUG("-> IScanEvent.OnScanResultReady");
    GBinderLocalRequest* req = gbinder_client_new_request(mScanEventClient);
    int status = gbinder_client_transact_sync_oneway(mScanEventClient,
        SCANEVENT_OnScanResultReady, req);
    if (status != GBINDER_STATUS_OK) {
        GWARN("OnScanResultReady failed: %d", status);
    }
    gbinder_local_request_unref(req);
}

void
Wificond::notifyScanFailed()
{
    if (!mScanEventClient) {
        return;
    }
    GDEBUG("-> IScanEvent.OnScanFailed");
    GBinderLocalRequest* req = gbinder_client_new_request(mScanEventClient);
    gbinder_client_transact_sync_oneway(mScanEventClient,
        SCANEVENT_OnScanFailed, req);
    gbinder_local_request_unref(req);
}

/* ------------------------------------------------------- IWificond itself */

GBinderLocalReply*
Wificond::onWificond(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Wificond*) user)->handleWificond(req, code, flags, status);
}

GBinderLocalReply*
Wificond::handleWificond(GBinderRemoteRequest* req, guint code, guint flags,
    int* status)
{
    GBinderReader reader;
    GBinderWriter writer;

    *status = GBINDER_STATUS_FAILED;
    if (!ifaceOk(req, IFACE_WIFICOND, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case WIFICOND_createClientInterface: {
        std::string name = readString(&reader);

        /*
         * The name comes from WifiNative's no-vendor-HAL fallback, which reads
         * the "wifi.interface" property and defaults to wlan0.  Verified in
         * Stage 0 from dumpsys.  We honour whatever it asks for rather than
         * hardcoding, so a property change does not silently break this.
         */
        mIfaceName = name;
        ensureClientInterface();
        GINFO("createClientInterface(%s) -> serving IClientInterface",
              name.c_str());

        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        gbinder_writer_append_local_object(&writer, mClient);
        return reply;
    }

    case WIFICOND_tearDownClientInterface: {
        std::string name = readString(&reader);
        GINFO("tearDownClientInterface(%s)", name.c_str());
        dropScanEvent();
        dropPnoScanEvent();

        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        writeBool(&writer, true);
        return reply;
    }

    case WIFICOND_tearDownInterfaces: {
        GINFO("tearDownInterfaces()");
        dropScanEvent();
        dropPnoScanEvent();
        return beginReply(mWificond, &writer, status);
    }

    /* SoftAP is explicitly out of scope: fail cleanly rather than oddly. */
    case WIFICOND_createApInterface: {
        std::string name = readString(&reader);
        GINFO("createApInterface(%s) -> null (SoftAP is out of scope)",
              name.c_str());
        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        gbinder_writer_append_local_object(&writer, nullptr);
        return reply;
    }

    case WIFICOND_tearDownApInterface: {
        readString(&reader);
        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        writeBool(&writer, false);
        return reply;
    }

    /* Never called by WifiNl80211Manager (docs/30, finding 5) -- slots only. */
    case WIFICOND_GetClientInterfaces:
    case WIFICOND_GetApInterfaces: {
        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        gbinder_writer_append_int32(&writer, 0);        /* empty List<IBinder> */
        return reply;
    }

    case WIFICOND_getAvailable2gChannels:
    case WIFICOND_getAvailable5gNonDFSChannels:
    case WIFICOND_getAvailableDFSChannels:
    case WIFICOND_getAvailable6gChannels:
    case WIFICOND_getAvailable60gChannels: {
        Band band = Band::Band2g;
        switch (code) {
        case WIFICOND_getAvailable5gNonDFSChannels: band = Band::Band5gNonDfs; break;
        case WIFICOND_getAvailableDFSChannels:      band = Band::Band5gDfs;    break;
        case WIFICOND_getAvailable6gChannels:       band = Band::Band6g;       break;
        case WIFICOND_getAvailable60gChannels:      band = Band::Band60g;      break;
        default: break;
        }
        std::vector<int32_t> freqs = mBackend->frequencies(band);

        /*
         * Logged because this answer has consequences far from here and no
         * other trace at all.  WificondChannelHelper caches these lists at
         * driver-load time and WificondScannerImpl then drops every scan result
         * whose frequency it cannot place in a band -- so an empty or missing
         * reply presents as "Filtering out N scan results" and Android showing
         * no networks, with nothing pointing back to a channel query.  Being
         * the only handler here that said nothing cost a long detour into the
         * scan timestamps instead.
         */
        static const char* const bandName[] = {
            "2g", "5g-non-dfs", "5g-dfs", "6g", "60g"
        };
        GINFO("getAvailable%sChannels() -> %zu channels", bandName[(int) band],
              freqs.size());

        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        writeInt32Array(&writer, freqs);
        return reply;
    }

    case WIFICOND_getDeviceWiphyCapabilities: {
        std::string name = readString(&reader);
        /*
         * Null is a legal answer -- WifiNative checks for it -- and it is the
         * honest one until there is a real radio description to hand up.
         */
        GDEBUG("getDeviceWiphyCapabilities(%s) -> null", name.c_str());
        GBinderLocalReply* reply = beginReply(mWificond, &writer, status);
        writeNullParcelable(&writer);
        return reply;
    }

    /* One-way: no reply parcel at all. */
    case WIFICOND_registerWificondEventCallback: {
        GBinderRemoteObject* cb = gbinder_reader_read_object(&reader);
        if (mEventCallback) {
            gbinder_remote_object_unref(mEventCallback);
        }
        mEventCallback = cb;
        GINFO("registerWificondEventCallback()");
        *status = GBINDER_STATUS_OK;
        return nullptr;
    }

    case WIFICOND_unregisterWificondEventCallback: {
        GBinderRemoteObject* cb = gbinder_reader_read_object(&reader);
        if (cb) {
            gbinder_remote_object_unref(cb);
        }
        if (mEventCallback) {
            gbinder_remote_object_unref(mEventCallback);
            mEventCallback = nullptr;
        }
        *status = GBINDER_STATUS_OK;
        return nullptr;
    }

    case WIFICOND_RegisterCallback:
    case WIFICOND_UnregisterCallback: {
        GBinderRemoteObject* cb = gbinder_reader_read_object(&reader);
        if (cb) {
            gbinder_remote_object_unref(cb);
        }
        *status = GBINDER_STATUS_OK;
        return nullptr;
    }

    case WIFICOND_notifyCountryCodeChanged:
        GDEBUG("notifyCountryCodeChanged()");
        *status = GBINDER_STATUS_OK;
        return nullptr;

    default:
        GWARN("unknown IWificond transaction %u", code);
        return nullptr;
    }
}

/* --------------------------------------------------- IClientInterface */

GBinderLocalReply*
Wificond::onClientInterface(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Wificond*) user)->handleClientInterface(req, code, flags, status);
}

GBinderLocalReply*
Wificond::handleClientInterface(GBinderRemoteRequest* req, guint code,
    guint flags, int* status)
{
    GBinderReader reader;
    GBinderWriter writer;

    *status = GBINDER_STATUS_FAILED;
    if (!ifaceOk(req, IFACE_CLIENT, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case CLIENT_getWifiScannerImpl: {
        ensureClientInterface();
        GDEBUG("getWifiScannerImpl()");
        GBinderLocalReply* reply = beginReply(mClient, &writer, status);
        gbinder_writer_append_local_object(&writer, mScanner);
        return reply;
    }

    case CLIENT_getInterfaceName: {
        GBinderLocalReply* reply = beginReply(mClient, &writer, status);
        writeString(&writer, mIfaceName.empty() ? "wlan0" : mIfaceName);
        return reply;
    }

    case CLIENT_getMacAddress: {
        uint8_t mac[6];
        mBackend->macAddress(mac);
        GBinderLocalReply* reply = beginReply(mClient, &writer, status);
        writeByteArray(&writer, mac, sizeof(mac));
        return reply;
    }

    case CLIENT_signalPoll: {
        /*
         * WifiNl80211Manager insists on exactly four ints and returns null
         * otherwise.  The ORDER is rssi dBm, tx Mbps, association frequency
         * MHz, rx Mbps -- frequency third, NOT last.
         *
         * That is not the order the field names suggest, and getting it wrong
         * is silent: every value is a plausible small integer, so nothing
         * throws and nothing logs.  It surfaced only as a WifiInfo dump reading
         * "Frequency: 130MHz, Rx Link speed: 2412Mbps" -- a 130 MHz channel and
         * a 2.4 Gbps link on 802.11ac, both obviously impossible, and both
         * exactly the other field's value.
         *
         * The authority is wificond's own client_interface_binder.cpp, which
         * pushes rssi, tx_bitrate, associate_freq, rx_bitrate in that order;
         * WifiNl80211Manager.SignalPollResult just reads positionally.
         */
        LinkState st = mBackend->state();
        std::vector<int32_t> v = {
            st.rssiDbm,
            st.txRateKbps / 1000,
            st.freqMhz,
            st.rxRateKbps / 1000,
        };
        GBinderLocalReply* reply = beginReply(mClient, &writer, status);
        writeInt32Array(&writer, v);
        return reply;
    }

    case CLIENT_getPacketCounters: {
        /* { tx good, tx bad }. Nothing counts them below the contract yet. */
        std::vector<int32_t> v = { 0, 0 };
        GBinderLocalReply* reply = beginReply(mClient, &writer, status);
        writeInt32Array(&writer, v);
        return reply;
    }

    case CLIENT_SendMgmtFrame:
        /* One-way, and out of scope: used only for the Wi-Fi "link probe". */
        GDEBUG("SendMgmtFrame() ignored");
        *status = GBINDER_STATUS_OK;
        return nullptr;

    default:
        GWARN("unknown IClientInterface transaction %u", code);
        return nullptr;
    }
}

/* ---------------------------------------------------- IWifiScannerImpl */

GBinderLocalReply*
Wificond::onScanner(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Wificond*) user)->handleScanner(req, code, flags, status);
}

GBinderLocalReply*
Wificond::handleScanner(GBinderRemoteRequest* req, guint code, guint flags,
    int* status)
{
    GBinderReader reader;
    GBinderWriter writer;

    *status = GBINDER_STATUS_FAILED;
    if (!ifaceOk(req, IFACE_SCANNER, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case SCANNER_getScanResults: {
        std::vector<Bss> results = mBackend->scanResults();
        LinkState link = mBackend->state();
        GBinderLocalReply* reply = beginReply(mScanner, &writer, status);
        int n = writeScanResultArray(&writer, results,
            link.associated ? link.bssid : nullptr);
        GDEBUG("getScanResults() -> %d access points", n);
        return reply;
    }

    case SCANNER_getPnoScanResults: {
        /*
         * Empty on purpose, and not the same answer as above: startPnoScan()
         * returns false, so no PNO scan has ever run and there is no PNO
         * result set to report.  Handing back the single-scan list here would
         * be inventing one.
         */
        GBinderLocalReply* reply = beginReply(mScanner, &writer, status);
        gbinder_writer_append_int32(&writer, 0);
        return reply;
    }

    case SCANNER_getMaxSsidsPerScan: {
        GBinderLocalReply* reply = beginReply(mScanner, &writer, status);
        gbinder_writer_append_int32(&writer, 16);
        return reply;
    }

    case SCANNER_scan: {
        /*
         * SingleScanSettings is not parsed yet -- nothing below the contract
         * can act on a channel list or a hidden-SSID list, so reading it would
         * only be ceremony.  Ask the host for a fresh scan; the completion
         * handler installed in the constructor answers with OnScanResultReady
         * when the host has actually produced one.
         */
        bool ok = mBackend->startScan();
        GINFO("scan() -> %s", ok ? "true" : "false");
        mScanPending = ok;
        GBinderLocalReply* reply = beginReply(mScanner, &writer, status);
        writeBool(&writer, ok);
        return reply;
    }

    case SCANNER_subscribeScanEvents: {
        dropScanEvent();
        mScanEvent = gbinder_reader_read_object(&reader);
        if (mScanEvent) {
            mScanEventClient = gbinder_client_new(mScanEvent, IFACE_SCANEVENT);
            GINFO("subscribeScanEvents()");
        } else {
            GWARN("subscribeScanEvents() with a null handler");
        }
        *status = GBINDER_STATUS_OK;
        return nullptr;
    }

    case SCANNER_unsubscribeScanEvents:
        GINFO("unsubscribeScanEvents()");
        dropScanEvent();
        *status = GBINDER_STATUS_OK;
        return nullptr;

    case SCANNER_subscribePnoScanEvents: {
        dropPnoScanEvent();
        mPnoScanEvent = gbinder_reader_read_object(&reader);
        if (mPnoScanEvent) {
            mPnoScanEventClient = gbinder_client_new(mPnoScanEvent,
                IFACE_PNOEVENT);
            GINFO("subscribePnoScanEvents()");
        }
        *status = GBINDER_STATUS_OK;
        return nullptr;
    }

    case SCANNER_unsubscribePnoScanEvents:
        dropPnoScanEvent();
        *status = GBINDER_STATUS_OK;
        return nullptr;

    /* PNO is a power optimisation; saying no is a supported answer. */
    case SCANNER_startPnoScan:
    case SCANNER_stopPnoScan: {
        GBinderLocalReply* reply = beginReply(mScanner, &writer, status);
        writeBool(&writer, false);
        return reply;
    }

    case SCANNER_abortScan:
        GDEBUG("abortScan()");
        mScanPending = false;
        return beginReply(mScanner, &writer, status);

    default:
        GWARN("unknown IWifiScannerImpl transaction %u", code);
        return nullptr;
    }
}

} /* namespace wifi */
} /* namespace waydroid */
