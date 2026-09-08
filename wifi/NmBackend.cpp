#include "NmBackend.h"

#include <gutil_log.h>

#include <cstring>

namespace waydroid {
namespace wifi {

/* ------------------------------------------------------------------ names */

#define NM_BUS      "org.freedesktop.NetworkManager"
#define NM_PATH     "/org/freedesktop/NetworkManager"
#define NM_IFACE    "org.freedesktop.NetworkManager"
#define NM_DEV      "org.freedesktop.NetworkManager.Device"
#define NM_WIFI     "org.freedesktop.NetworkManager.Device.Wireless"
#define NM_AP       "org.freedesktop.NetworkManager.AccessPoint"
#define DBUS_PROPS  "org.freedesktop.DBus.Properties"

#define NM_DEVICE_TYPE_WIFI     2

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

const char*
securityName(Security s)
{
    switch (s) {
    case Security::Open:    return "open";
    case Security::Wep:     return "wep";
    case Security::WpaPsk:  return "wpa-psk";
    case Security::Wpa2Psk: return "wpa2-psk";
    case Security::Wpa2Wpa3Psk: return "wpa2/wpa3-psk";
    case Security::Wpa3Sae: return "wpa3-sae";
    case Security::Wpa2Eap: return "wpa-eap";
    }
    return "?";
}

/* ------------------------------------------------------------- lifecycle */

NmBackend::NmBackend() = default;

NmBackend::~NmBackend()
{
    if (mScanPollId) {
        g_source_remove(mScanPollId);
    }
    if (mBus) {
        g_object_unref(mBus);
    }
}

bool
NmBackend::init()
{
    GError* err = nullptr;

    mBus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nullptr, &err);
    if (!mBus) {
        GERR("cannot reach the system bus: %s", err ? err->message : "?");
        g_clear_error(&err);
        return false;
    }

    /* Prove NetworkManager is actually there before claiming success. */
    GVariant* v = getProp(NM_PATH, NM_IFACE, "Version");
    if (!v) {
        GERR("NetworkManager is not answering on the system bus");
        return false;
    }
    GINFO("NetworkManager %s", g_variant_get_string(v, nullptr));
    g_variant_unref(v);

    /* Pick a radio if the caller did not name one. */
    if (mIfname.empty()) {
        std::vector<std::string> devs = devices();
        if (devs.empty()) {
            GWARN("NetworkManager reports no Wi-Fi device");
        } else {
            if (devs.size() > 1) {
                GINFO("%zu Wi-Fi devices; Android sees exactly one, choosing %s",
                      devs.size(), devs[0].c_str());
            }
            selectDevice(devs[0]);
        }
    }
    return true;
}

/* ------------------------------------------------------------ D-Bus glue */

GVariant*
NmBackend::call(const char* path, const char* iface, const char* method,
                GVariant* args, const char* replyType)
{
    GError* err = nullptr;
    GVariantType* rt = replyType ? g_variant_type_new(replyType) : nullptr;
    GVariant* res = g_dbus_connection_call_sync(mBus, NM_BUS, path, iface,
        method, args, rt, G_DBUS_CALL_FLAGS_NONE, 5000, nullptr, &err);

    if (rt) {
        g_variant_type_free(rt);
    }
    if (!res) {
        GDEBUG("%s.%s(%s): %s", iface, method, path, err ? err->message : "?");
        g_clear_error(&err);
    }
    return res;
}

GVariant*
NmBackend::getProp(const char* path, const char* iface, const char* prop)
{
    GVariant* res = call(path, DBUS_PROPS, "Get",
        g_variant_new("(ss)", iface, prop), "(v)");

    if (!res) {
        return nullptr;
    }

    GVariant* boxed = nullptr;
    g_variant_get(res, "(v)", &boxed);
    g_variant_unref(res);
    return boxed;
}

bool
NmBackend::setProp(const char* path, const char* iface, const char* prop,
                   GVariant* value)
{
    GVariant* res = call(path, DBUS_PROPS, "Set",
        g_variant_new("(ssv)", iface, prop, value), "()");

    if (!res) {
        return false;
    }
    g_variant_unref(res);
    return true;
}

std::string
NmBackend::propString(const char* path, const char* iface, const char* prop)
{
    GVariant* v = getProp(path, iface, prop);
    std::string out;

    if (v) {
        if (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING) ||
            g_variant_is_of_type(v, G_VARIANT_TYPE_OBJECT_PATH)) {
            out = g_variant_get_string(v, nullptr);
        }
        g_variant_unref(v);
    }
    return out;
}

guint32
NmBackend::propUint(const char* path, const char* iface, const char* prop,
                    guint32 def)
{
    GVariant* v = getProp(path, iface, prop);
    guint32 out = def;

    if (v) {
        if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32)) {
            out = g_variant_get_uint32(v);
        } else if (g_variant_is_of_type(v, G_VARIANT_TYPE_BYTE)) {
            out = g_variant_get_byte(v);
        } else if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT32)) {
            out = (guint32) g_variant_get_int32(v);
        }
        g_variant_unref(v);
    }
    return out;
}

gint64
NmBackend::propInt64(const char* path, const char* iface, const char* prop,
                     gint64 def)
{
    GVariant* v = getProp(path, iface, prop);
    gint64 out = def;

    if (v) {
        if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT64)) {
            out = g_variant_get_int64(v);
        } else if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT32)) {
            out = g_variant_get_int32(v);
        }
        g_variant_unref(v);
    }
    return out;
}

/* ---------------------------------------------------------------- radios */

std::vector<std::string>
NmBackend::devices()
{
    std::vector<std::string> out;
    GVariant* res = call(NM_PATH, NM_IFACE, "GetAllDevices", nullptr, "(ao)");

    if (!res) {
        return out;
    }

    GVariantIter* iter = nullptr;
    const char* path = nullptr;
    g_variant_get(res, "(ao)", &iter);
    while (g_variant_iter_loop(iter, "o", &path)) {
        if (propUint(path, NM_DEV, "DeviceType") == NM_DEVICE_TYPE_WIFI) {
            std::string ifname = propString(path, NM_DEV, "Interface");
            if (!ifname.empty()) {
                out.push_back(ifname);
            }
        }
    }
    g_variant_iter_free(iter);
    g_variant_unref(res);
    return out;
}

std::string
NmBackend::wifiDevicePath()
{
    if (!mDevPath.empty()) {
        /* Cheap revalidation: NM recycles object paths across restarts. */
        if (propString(mDevPath.c_str(), NM_DEV, "Interface") == mIfname) {
            return mDevPath;
        }
        mDevPath.clear();
    }
    if (mIfname.empty()) {
        return std::string();
    }

    GVariant* res = call(NM_PATH, NM_IFACE, "GetDeviceByIpIface",
        g_variant_new("(s)", mIfname.c_str()), "(o)");
    if (res) {
        const char* path = nullptr;
        g_variant_get(res, "(&o)", &path);
        mDevPath = path ? path : "";
        g_variant_unref(res);
    }
    return mDevPath;
}

bool
NmBackend::selectDevice(const std::string& ifname)
{
    mIfname = ifname;
    mDevPath.clear();
    if (wifiDevicePath().empty()) {
        GWARN("NetworkManager has no Wi-Fi device called %s", ifname.c_str());
        return false;
    }
    GINFO("using host radio %s (%s)", mIfname.c_str(), mDevPath.c_str());
    return true;
}

void
NmBackend::macAddress(uint8_t out[6])
{
    memset(out, 0, 6);

    std::string path = wifiDevicePath();
    if (path.empty()) {
        return;
    }

    std::string mac = propString(path.c_str(), NM_WIFI, "HwAddress");
    unsigned b[6];
    if (mac.size() >= 17 &&
        sscanf(mac.c_str(), "%x:%x:%x:%x:%x:%x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) == 6) {
        for (int i = 0; i < 6; i++) {
            out[i] = (uint8_t) b[i];
        }
    }
}

/* ----------------------------------------------------------------- radio */

bool
NmBackend::setEnabled(bool on)
{
    return setProp(NM_PATH, NM_IFACE, "WirelessEnabled",
        g_variant_new_boolean(on ? TRUE : FALSE));
}

bool
NmBackend::isEnabled()
{
    GVariant* v = getProp(NM_PATH, NM_IFACE, "WirelessEnabled");
    bool on = false;

    if (v) {
        on = g_variant_get_boolean(v);
        g_variant_unref(v);
    }
    return on;
}

/* ------------------------------------------------------------- scanning */

/*
 * SCAN COMPLETION
 *
 * NM publishes Device.Wireless.LastScan -- CLOCK_BOOTTIME milliseconds at
 * which the last scan *finished*, -1 if it has never scanned.  Watching that
 * value cross the point where we asked is the only signal NM offers that a
 * scan actually happened; there is no "scan done" D-Bus signal.
 *
 * It is polled rather than watched through PropertiesChanged.  A property read
 * on the local system bus costs almost nothing, the poll only runs while a
 * scan is outstanding (a few seconds, a few times a minute), and it avoids a
 * signal subscription whose match rules and lifetime would be more code than
 * the thing it replaces.  If that ever stops being true, this is the only
 * place that has to change.
 */
#define SCAN_POLL_MS        500
#define SCAN_POLL_MAX       24          /* 12 s: NM's rate-limit window + a scan */

gboolean
NmBackend::scanPollTick(gpointer user)
{
    NmBackend* self = (NmBackend*) user;
    std::string path = self->wifiDevicePath();
    gint64 last = path.empty() ? -1 :
        self->propInt64(path.c_str(), NM_WIFI, "LastScan");

    if (last > self->mScanBaseline) {
        GDEBUG("NM finished a scan (LastScan %" G_GINT64_FORMAT ")", last);
        self->mScanPollId = 0;
        self->scanFinished(true);
        return G_SOURCE_REMOVE;
    }
    if (--self->mScanPollsLeft <= 0) {
        self->mScanPollId = 0;
        if (self->mScanBlind) {
            /* Nothing to watch on this host, so take the scan on trust. */
            self->scanFinished(true);
        } else {
            GWARN("no scan from NetworkManager after %d ms",
                  SCAN_POLL_MS * SCAN_POLL_MAX);
            self->scanFinished(false);
        }
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

void
NmBackend::scanFinished(bool ok)
{
    if (mScanCb) {
        mScanCb(ok);
    }
}

void
NmBackend::onScanComplete(std::function<void(bool ok)> cb)
{
    mScanCb = cb;
}

bool
NmBackend::startScan()
{
    std::string path = wifiDevicePath();
    if (path.empty()) {
        return false;
    }

    if (mScanPollId) {
        /* One is already in flight; its completion answers this caller too. */
        GDEBUG("scan already pending");
        return true;
    }

    /*
     * Absent (not merely -1) means this NM is too old to publish it, which is
     * a different situation and is handled differently below.
     */
    GVariant* v = getProp(path.c_str(), NM_WIFI, "LastScan");
    bool haveLastScan = (v != nullptr);
    mScanBaseline = -1;
    if (v) {
        if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT64)) {
            mScanBaseline = g_variant_get_int64(v);
        }
        g_variant_unref(v);
    }

    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
    GVariant* res = call(path.c_str(), NM_WIFI, "RequestScan",
        g_variant_new("(a{sv})", &b), "()");

    if (res) {
        g_variant_unref(res);
    } else {
        /*
         * NM rate-limits RequestScan and answers "Scanning not allowed
         * immediately following previous scan".  Not fatal: NM scans on its
         * own schedule while unassociated, so the wait below still ends with
         * a real scan -- just not one we caused.
         */
        GDEBUG("RequestScan refused; waiting for NM's own scan");
    }

    /*
     * If NM is too old to publish LastScan there is nothing to watch, so fall
     * back to announcing completion after one poll interval.  Results will
     * then be dated by their own LastSeen, which is still honest -- some of
     * them will simply be filtered out by the reader as too old.
     */
    mScanBlind = !haveLastScan;
    if (mScanBlind) {
        GWARN("NetworkManager does not publish LastScan; scan completion is "
              "a guess on this host");
        mScanPollsLeft = 1;
    } else {
        mScanPollsLeft = SCAN_POLL_MAX;
    }
    mScanPollId = g_timeout_add(SCAN_POLL_MS, scanPollTick, this);
    return true;
}

static Security
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
static uint32_t
ciphersFromFlags(guint32 f, bool group)
{
    uint32_t out = 0;

    if (f & (group ? NM_SEC_GROUP_WEP40  : NM_SEC_PAIR_WEP40))  out |= CipherWep40;
    if (f & (group ? NM_SEC_GROUP_WEP104 : NM_SEC_PAIR_WEP104)) out |= CipherWep104;
    if (f & (group ? NM_SEC_GROUP_TKIP   : NM_SEC_PAIR_TKIP))   out |= CipherTkip;
    if (f & (group ? NM_SEC_GROUP_CCMP   : NM_SEC_PAIR_CCMP))   out |= CipherCcmp;
    return out;
}

std::vector<Bss>
NmBackend::scanResults()
{
    std::vector<Bss> out;
    std::string dev = wifiDevicePath();

    if (dev.empty()) {
        return out;
    }

    GVariant* res = call(dev.c_str(), NM_WIFI, "GetAllAccessPoints",
        nullptr, "(ao)");
    if (!res) {
        return out;
    }

    GVariantIter* iter = nullptr;
    const char* path = nullptr;
    g_variant_get(res, "(ao)", &iter);
    while (g_variant_iter_loop(iter, "o", &path)) {
        Bss bss;

        /* Ssid is ay, and is NOT necessarily valid UTF-8 or NUL-terminated. */
        GVariant* ssid = getProp(path, NM_AP, "Ssid");
        if (ssid) {
            gsize n = 0;
            const guint8* d = (const guint8*)
                g_variant_get_fixed_array(ssid, &n, 1);
            bss.ssid.assign((const char*) d, n);
            g_variant_unref(ssid);
        }

        std::string mac = propString(path, NM_AP, "HwAddress");
        unsigned b[6];
        if (sscanf(mac.c_str(), "%x:%x:%x:%x:%x:%x",
                   &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) == 6) {
            for (int i = 0; i < 6; i++) {
                bss.bssid[i] = (uint8_t) b[i];
            }
        }

        bss.freqMhz = (int32_t) propUint(path, NM_AP, "Frequency");

        /*
         * NM reports Strength as 0..100, Android wants dBm.  This is the
         * inverse of NM's own wifi_utils nm_wifi_utils_level_to_quality()
         * approximation; it is a mapping, not a measurement, and it is one of
         * the things that would improve if a future backend read the RSSI
         * from nl80211 directly.
         */
        guint32 quality = propUint(path, NM_AP, "Strength");
        if (quality > 100) {
            quality = 100;
        }
        bss.rssiDbm = (int32_t) (quality / 2) - 100;   /* 0 -> -100, 100 -> -50 */

        guint32 apFlags  = propUint(path, NM_AP, "Flags");
        guint32 wpaFlags = propUint(path, NM_AP, "WpaFlags");
        guint32 rsnFlags = propUint(path, NM_AP, "RsnFlags");

        bss.security = securityFromFlags(apFlags, wpaFlags, rsnFlags);
        guint32 sec = (bss.security == Security::WpaPsk) ? wpaFlags : rsnFlags;
        bss.pairwiseCiphers = ciphersFromFlags(sec, false);
        bss.groupCiphers    = ciphersFromFlags(sec, true);

        /*
         * LastSeen is CLOCK_BOOTTIME *seconds*, -1 if NM has never seen it.
         * The truncation to whole seconds is NM's, not ours, and it is the
         * only thing standing between this and the microsecond value the
         * reader wants -- so it is converted and left alone.
         */
        GVariant* seen = getProp(path, NM_AP, "LastSeen");
        if (seen) {
            gint32 t = g_variant_is_of_type(seen, G_VARIANT_TYPE_INT32) ?
                g_variant_get_int32(seen) : -1;
            if (t > 0) {
                bss.lastSeenUsec = (uint64_t) t * 1000000;
            }
            g_variant_unref(seen);
        }
        out.push_back(bss);
    }
    g_variant_iter_free(iter);
    g_variant_unref(res);
    return out;
}

/* ---------------------------------------------------------- association */

/*
 * Stage 4.  Deliberately not faked: returning false here makes an unfinished
 * connect path visible in the log rather than silently doing nothing.
 */
bool
NmBackend::connect(const NetworkRequest& req)
{
    GWARN("connect(%s): not implemented yet -- Stage 4", req.ssid.c_str());
    return false;
}

bool
NmBackend::disconnect()
{
    std::string dev = wifiDevicePath();
    if (dev.empty()) {
        return false;
    }
    GVariant* res = call(dev.c_str(), NM_DEV, "Disconnect", nullptr, "()");
    if (!res) {
        return false;
    }
    g_variant_unref(res);
    return true;
}

bool
NmBackend::forget(const std::string& ssid)
{
    GWARN("forget(%s): not implemented yet -- Stage 5", ssid.c_str());
    return false;
}

LinkState
NmBackend::state()
{
    LinkState st;
    std::string dev = wifiDevicePath();

    if (dev.empty()) {
        return st;
    }

    std::string ap = propString(dev.c_str(), NM_WIFI, "ActiveAccessPoint");
    if (ap.empty() || ap == "/") {
        return st;
    }

    st.associated = true;

    GVariant* ssid = getProp(ap.c_str(), NM_AP, "Ssid");
    if (ssid) {
        gsize n = 0;
        const guint8* d = (const guint8*) g_variant_get_fixed_array(ssid, &n, 1);
        st.ssid.assign((const char*) d, n);
        g_variant_unref(ssid);
    }

    std::string mac = propString(ap.c_str(), NM_AP, "HwAddress");
    unsigned b[6];
    if (sscanf(mac.c_str(), "%x:%x:%x:%x:%x:%x",
               &b[0], &b[1], &b[2], &b[3], &b[4], &b[5]) == 6) {
        for (int i = 0; i < 6; i++) {
            st.bssid[i] = (uint8_t) b[i];
        }
    }

    st.freqMhz = (int32_t) propUint(ap.c_str(), NM_AP, "Frequency");
    guint32 quality = propUint(ap.c_str(), NM_AP, "Strength");
    if (quality > 100) {
        quality = 100;
    }
    st.rssiDbm = (int32_t) (quality / 2) - 100;
    st.txRateKbps = (int32_t) propUint(ap.c_str(), NM_AP, "MaxBitrate");
    st.rxRateKbps = st.txRateKbps;
    return st;
}

void
NmBackend::onStateChanged(std::function<void(LinkState)> cb)
{
    /*
     * Stage 4 wires this to NM's StateChanged / PropertiesChanged signals.
     * Stored now so the contract is honoured and the call site can already
     * be written above the line.
     */
    mStateCb = std::move(cb);
}

/* -------------------------------------------------------------- channels */

/*
 * NetworkManager does not publish the radio's supported channel list, so
 * these are the regulatory-agnostic sets Android expects to be told about.
 * They are a superset: the host's own regulatory domain still governs what
 * actually gets scanned, and our scan results come from NM regardless of what
 * Android asks for.  A future nl80211 backend can report the real list.
 */
std::vector<int32_t>
NmBackend::frequencies(Band band)
{
    switch (band) {
    case Band::Band2g: {
        std::vector<int32_t> v;
        for (int ch = 1; ch <= 13; ch++) {
            v.push_back(2407 + 5 * ch);
        }
        return v;
    }
    case Band::Band5gNonDfs:
        return { 5180, 5200, 5220, 5240,
                 5745, 5765, 5785, 5805, 5825 };
    case Band::Band5gDfs:
        return { 5260, 5280, 5300, 5320,
                 5500, 5520, 5540, 5560, 5580, 5600, 5620, 5640,
                 5660, 5680, 5700 };
    case Band::Band6g:
    case Band::Band60g:
        return {};
    }
    return {};
}

} /* namespace wifi */
} /* namespace waydroid */
