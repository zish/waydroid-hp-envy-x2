#include "NmBackend.h"

#include <gutil_log.h>

#include <cctype>
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

#define NM_SETTINGS         "org.freedesktop.NetworkManager.Settings"
#define NM_SETTINGS_PATH    "/org/freedesktop/NetworkManager/Settings"
#define NM_CONNECTION       "org.freedesktop.NetworkManager.Settings.Connection"
#define NM_ACTIVE           "org.freedesktop.NetworkManager.Connection.Active"

#define NM_DEVICE_TYPE_WIFI     2

/*
 * Ours, not NM's: the route metric for profiles this daemon creates.  Chosen to
 * sit above NM's Wi-Fi default (600) so the host's own radio always outranks
 * the one Android drives.  See buildSettings() for why that matters.
 */
#define WAYDROID_ROUTE_METRIC   1000

/*
 * How far below a scan's completion an AP's own sighting may fall and still
 * count as "found by that scan".  A channel sweep, not a margin of error; see
 * scanResults().
 */
#define SCAN_SWEEP_USEC         (8 * 1000000ULL)

/* NMDeviceState */
#define NM_STATE_UNKNOWN        0
#define NM_STATE_UNMANAGED      10
#define NM_STATE_UNAVAILABLE    20
#define NM_STATE_DISCONNECTED   30
#define NM_STATE_PREPARE        40
#define NM_STATE_CONFIG         50
#define NM_STATE_NEED_AUTH      60
#define NM_STATE_IP_CONFIG      70
#define NM_STATE_IP_CHECK       80
#define NM_STATE_SECONDARIES    90
#define NM_STATE_ACTIVATED      100
#define NM_STATE_DEACTIVATING   110
#define NM_STATE_FAILED         120

/*
 * NMDeviceStateReason.  Only the credential ones are named, because they are
 * the only ones the layer above draws a distinction on -- everything else is
 * "it did not work", which Android renders identically however it happened.
 */
#define NM_REASON_NO_SECRETS            7
#define NM_REASON_SUPPLICANT_DISCONNECT 8
#define NM_REASON_SUPPLICANT_FAILED     10
#define NM_REASON_SUPPLICANT_TIMEOUT    11
#define NM_REASON_SSID_NOT_FOUND        53

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

const char*
linkEventName(LinkEvent e)
{
    switch (e) {
    case LinkEvent::Associated:   return "associated";
    case LinkEvent::Associating:  return "associating";
    case LinkEvent::AuthFailed:   return "auth-failed";
    case LinkEvent::Failed:       return "failed";
    case LinkEvent::Disconnected: return "disconnected";
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
    if (mStateSignalId && mBus) {
        g_dbus_connection_signal_unsubscribe(mBus, mStateSignalId);
    }
    if (mBus) {
        g_object_unref(mBus);
    }
}

bool
NmBackend::init(const std::string& spec)
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

    /*
     * Watch the device's state changes.  Subscribed before the radio is chosen,
     * not after: there is no path filter -- the device path is resolved lazily
     * and NM may not have one yet -- so the subscription does not depend on the
     * selection, and doing it first means the failure paths below cannot return
     * with it half set up.
     */
    mStateSignalId = g_dbus_connection_signal_subscribe(mBus, NM_BUS, NM_DEV,
        "StateChanged", nullptr, nullptr, G_DBUS_SIGNAL_FLAGS_NONE,
        onNmSignal, this, nullptr);

    if (!spec.empty()) {
        if (!selectDevice(spec)) {
            GERR("no Wi-Fi device matching \"%s\"", spec.c_str());
            return false;
        }
        return true;
    }

    /*
     * Nobody named a radio, so pick one -- and prefer one that is not carrying
     * the host's own default route.
     *
     * Android sees exactly one radio, so something has to choose.  Taking the
     * first NM happened to list was fine while this machine had a single
     * adapter and unacceptable once it had two: NM's order is not stable or
     * meaningful, so a coin flip decided whether Android drove the spare or the
     * link this daemon is administered over.  Trap 5 of 33-wifi-stage4.md is
     * what losing that flip costs -- a trip to the console.
     *
     * "Carries the default route" is NM's own judgement (Connection.Active's
     * Default/Default6), not ours, so it stays right as the host's routing
     * changes underneath us.
     *
     * This is a guard, not a guarantee.  If the host's radio is down at the
     * moment we look, nothing is carrying a default route and the first entry
     * wins again -- which is why --device exists and why anything unattended
     * should pass it.
     */
    std::vector<std::string> devs = devices();
    if (devs.empty()) {
        GWARN("NetworkManager reports no Wi-Fi device");
        return true;
    }

    std::string pick;
    for (const std::string& d : devs) {
        if (!carriesHostDefaultRoute(d)) {
            pick = d;
            break;
        }
    }
    if (pick.empty()) {
        pick = devs[0];
        GWARN("every Wi-Fi device carries the host's default route; falling "
              "back to %s -- pass --device to be sure", pick.c_str());
    } else if (devs.size() > 1) {
        GINFO("%zu Wi-Fi devices; choosing %s (not carrying the host's default "
              "route)", devs.size(), pick.c_str());
    }
    selectDevice(pick);
    return true;
}

/* ------------------------------------------------------------ D-Bus glue */

GVariant*
NmBackend::call(const char* path, const char* iface, const char* method,
                GVariant* args, const char* replyType)
{
    GError* err = nullptr;

    /*
     * Callable before init() has a bus, and deliberately so: --devices answers
     * even when init() failed, because "what radios does this host have" is
     * exactly the question being asked when the named one did not resolve.
     * Without this guard that path reaches g_dbus_connection_call_sync(NULL)
     * and trades a clean empty list for a GLib CRITICAL.
     */
    if (!mBus) {
        if (args) {
            g_variant_unref(g_variant_ref_sink(args));
        }
        return nullptr;
    }
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

    for (const std::pair<std::string, std::string>& d : wifiDeviceList()) {
        out.push_back(d.second);
    }
    return out;
}

std::vector<std::pair<std::string, std::string> >
NmBackend::wifiDeviceList()
{
    std::vector<std::pair<std::string, std::string> > out;
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
                out.push_back(std::make_pair(std::string(path), ifname));
            }
        }
    }
    g_variant_iter_free(iter);
    g_variant_unref(res);
    return out;
}

/*
 * Written out by hand rather than with sscanf because the length check is
 * doing real work here: an interface name can never be 17 characters (IFNAMSIZ
 * is 16 including the terminator), so "17 characters and every one of them in
 * place" is what lets --device take either kind of argument without a flag to
 * say which.  Accepts '-' as a separator too, since that is how a MAC printed
 * off a sticker often reads.
 */
std::string
NmBackend::normalizeMac(const std::string& s)
{
    static const char hex[] = "0123456789ABCDEF";
    std::string out;

    if (s.size() != 17) {
        return std::string();
    }
    for (size_t i = 0; i < 17; i++) {
        unsigned char c = (unsigned char) s[i];

        if (i % 3 == 2) {
            if (c != ':' && c != '-') {
                return std::string();
            }
            out += ':';
        } else if (isdigit(c)) {
            out += hex[c - '0'];
        } else if (isxdigit(c)) {
            out += hex[tolower(c) - 'a' + 10];
        } else {
            return std::string();
        }
    }
    return out;
}

/*
 * PermHwAddress is the factory address; HwAddress is whatever the interface is
 * wearing right now, which on this host is a RANDOMIZED one on both radios --
 * wlp1s0's permanent 60:57:18:0A:E8:B7 was answering as DE:FA:B4:68:D3:C7.  So
 * HwAddress identifies nothing across a reconnect and must not be used to pin
 * hardware.  It is taken only as a fallback, for a device NM will not publish
 * a permanent address for at all.
 */
std::string
NmBackend::permMacOf(const std::string& path)
{
    std::string mac =
        normalizeMac(propString(path.c_str(), NM_WIFI, "PermHwAddress"));

    if (mac.empty() || mac == "00:00:00:00:00:00") {
        mac = normalizeMac(propString(path.c_str(), NM_WIFI, "HwAddress"));
    }
    return mac;
}

std::pair<std::string, std::string>
NmBackend::resolveByMac()
{
    if (!mSelectorMac.empty()) {
        for (const std::pair<std::string, std::string>& d : wifiDeviceList()) {
            if (permMacOf(d.first) == mSelectorMac) {
                return d;
            }
        }
    }
    return std::make_pair(std::string(), std::string());
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

    /*
     * The name has gone.  If we know which piece of hardware we were pinned to,
     * find it again by its factory MAC rather than giving up -- and rather than
     * the far worse alternative of falling back to some other radio.
     *
     * This is the same move waydroid-sensord makes after an ITE8350 reprobe
     * (docs/19-sensor-hub-suspend-wedge.md): re-resolve by a stable identity so
     * that recovering the device underneath us costs the daemon nothing.  Here
     * the provoking events are a driver reprobe by bin/wifi-radio-reset.sh and
     * the adapter being moved to another USB socket, both of which can hand the
     * same hardware a different ifname.
     *
     * Only reached when the lookup by name already failed, so the cost of
     * enumerating every device is paid on a path that was about to return "".
     */
    if (mDevPath.empty() && !mSelectorMac.empty()) {
        std::pair<std::string, std::string> d = resolveByMac();
        if (!d.first.empty() && d.second != mIfname) {
            GINFO("radio %s is now %s (factory MAC %s)", mIfname.c_str(),
                  d.second.c_str(), mSelectorMac.c_str());
            mIfname = d.second;
            mDevPath = d.first;
        }
    }
    return mDevPath;
}

bool
NmBackend::carriesHostDefaultRoute(const std::string& ifname)
{
    GVariant* res = call(NM_PATH, NM_IFACE, "GetDeviceByIpIface",
        g_variant_new("(s)", ifname.c_str()), "(o)");

    if (!res) {
        return false;
    }

    const char* path = nullptr;
    g_variant_get(res, "(&o)", &path);
    std::string devPath = path ? path : "";
    g_variant_unref(res);

    if (devPath.empty()) {
        return false;
    }

    /* No active connection means no routes of any kind. */
    std::string active = propString(devPath.c_str(), NM_DEV, "ActiveConnection");
    if (active.empty() || active == "/") {
        return false;
    }

    bool isDefault = false;
    for (const char* prop : { "Default", "Default6" }) {
        GVariant* v = getProp(active.c_str(), NM_ACTIVE, prop);
        if (v) {
            if (g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN)) {
                isDefault = isDefault || g_variant_get_boolean(v);
            }
            g_variant_unref(v);
        }
    }
    return isDefault;
}

/*
 * Takes either an interface name or a factory MAC address, told apart by shape
 * -- see normalizeMac().  A MAC is the better argument for anything unattended
 * because it is the only stable name this hardware has; see mSelectorMac.
 */
bool
NmBackend::selectDevice(const std::string& spec)
{
    std::string mac = normalizeMac(spec);

    mDevPath.clear();
    if (!mac.empty()) {
        mSelectorMac = mac;
        std::pair<std::string, std::string> d = resolveByMac();
        if (d.first.empty()) {
            GWARN("no Wi-Fi device with factory MAC %s", mac.c_str());
            mSelectorMac.clear();
            return false;
        }
        mIfname = d.second;
        mDevPath = d.first;
    } else {
        mIfname = spec;
        mSelectorMac.clear();
        if (wifiDevicePath().empty()) {
            GWARN("NetworkManager has no Wi-Fi device called %s", spec.c_str());
            return false;
        }
        /*
         * Pin to the hardware from here on, even though we were handed a name.
         * The name got us to the right radio once; keeping it as the identity
         * would mean following whatever wears it next, which after a re-plug or
         * a reprobe is a different adapter -- possibly the host's own.
         */
        mSelectorMac = permMacOf(mDevPath);
    }

    if (mSelectorMac.empty()) {
        GWARN("using host radio %s (%s) -- NM publishes no factory MAC for it, "
              "so a rename cannot be followed", mIfname.c_str(),
              mDevPath.c_str());
    } else {
        GINFO("using host radio %s (%s), pinned to factory MAC %s",
              mIfname.c_str(), mDevPath.c_str(), mSelectorMac.c_str());
    }
    return true;
}

/*
 * The address Android should believe is on the air, so HwAddress and NOT
 * PermHwAddress -- NM randomizes it and the container's wlan0 is a veth with a
 * MAC of its own anyway.  permMacOf() is the other one, and identifies the
 * hardware rather than the association; do not confuse them.
 */
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
        /*
         * Wait one more poll after the scan lands before announcing it.
         *
         * NM publishes the device's LastScan and each AP's own LastSeen as
         * separate property changes, and nothing says they land together, so
         * announcing the instant LastScan moves risks handing Android a list in
         * which APs still carry their previous sighting -- which its filter
         * then correctly discards as older than the scan it asked for.
         *
         * BE CLEAR ABOUT WHAT THIS DID AND DID NOT FIX.  It was added to
         * explain a low yield -- "results=1, Filtering out 7" scan after scan,
         * while reading the same AP list by hand seconds later showed six
         * freshly dated.  It did NOT change that yield measurably.  The
         * ordering concern is real and the settle is nearly free, so it stays,
         * but it is not the explanation and must not be recorded as one.
         *
         * The better hypothesis, untested: those measurements were taken while
         * the radio was ASSOCIATED, and an associated station cannot leave its
         * operating channel for long, so its background scans re-see its own
         * channel every time and other channels only occasionally.  Before the
         * association the same code returned all eight APs.  If that is right
         * the low yield is the radio behaving normally and there is nothing
         * here to fix -- test it by comparing yields associated vs idle.
         *
         * A fixed settle rather than a retry loop keyed on the AP list, because
         * "have the APs updated yet" has no answer for a scan that genuinely
         * found nothing new -- an empty result is a legitimate outcome and must
         * not be made to wait for one that never comes.
         */
        if (!self->mScanSettling) {
            self->mScanSettling = true;
            GDEBUG("NM finished a scan (LastScan %" G_GINT64_FORMAT "), "
                   "letting the AP list settle", last);
            return G_SOURCE_CONTINUE;
        }
        GDEBUG("announcing scan results");
        self->mScanPollId = 0;
        self->mScanSettling = false;
        self->mScanSuppressed = false;
        self->scanFinished(true);
        return G_SOURCE_REMOVE;
    }
    if (--self->mScanPollsLeft <= 0) {
        self->mScanPollId = 0;
        self->mScanSettling = false;
        if (self->mScanBlind || self->mScanSuppressed) {
            /* Nothing to watch on this host, or we deliberately did not scan:
             * either way the cached results are the honest answer. */
            self->mScanSuppressed = false;
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

    /*
     * Do not ask the radio to scan while it is trying to associate.
     *
     * PRECAUTIONARY, AND HONESTLY LABELLED: this guard was written to explain a
     * run of failed associations where the supplicant sat in "scanning" until
     * NetworkManager's 25 s activation timeout fired, and its log filled with
     * "Reject scan trigger since one is already pending" without ever reaching
     * "SME: Trying to authenticate".  The theory was that Android's
     * disconnected-state scanning, forwarded through here, kept restarting
     * wpa_supplicant's scan cycle so it never settled on a BSS.
     *
     * THAT THEORY DID NOT SURVIVE.  The next failure was captured with this
     * guard in place and it never fired once -- no scan() arrived during the
     * association at all -- and the real cause turned out to be a wedged
     * rtw88_8822bu, which a driver reprobe cleared (see 34-wifi-second-radio.md).
     * So nothing here is known to have fixed anything.
     *
     * It is kept because it is correct on its own terms -- asking a radio to
     * go off-channel while it is mid-authentication is not something to do on
     * purpose, and the scan-rejection spam in the supplicant log was real --
     * but it should not be credited with a fix it did not make, and if it ever
     * gets in the way it can be removed without regret.
     *
     * The scan is still ANSWERED, just not performed: getScanResults() returns
     * NM's existing list, which is real data a few seconds old rather than
     * invented.  Refusing outright would be worse -- WifiScannerImpl treats a
     * failed scan as a reason to tear the interface down.
     */
    guint32 devState = propUint(path.c_str(), NM_DEV, "State");
    if (devState >= NM_STATE_PREPARE && devState < NM_STATE_ACTIVATED) {
        GDEBUG("association in progress (NM state %u); answering the scan from "
               "cache rather than disturbing the radio", devState);
        mScanSuppressed = true;
        mScanPollsLeft = 1;
        mScanPollId = g_timeout_add(SCAN_POLL_MS, scanPollTick, this);
        return true;
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
    mScanSettling = false;      /* fresh scan: it has not landed, let alone settled */
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

    /*
     * When the scan we just announced actually finished, in CLOCK_BOOTTIME
     * milliseconds.  Unlike the per-AP LastSeen this has millisecond
     * resolution, and it is the timestamp the reader's filter is really asking
     * about -- see the long note further down where it is applied.
     */
    gint64 lastScanMs = propInt64(dev.c_str(), NM_WIFI, "LastScan", -1);

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
         *
         * The extra 999 ms is not a fudge, and leaving it out was a real bug --
         * it dropped every scan result Android asked for, roughly half the time.
         *
         * NM truncates: an AP whose LastSeen reads 202 was last seen somewhere
         * in [202.000, 203.000).  Taking the bottom of that interval biases
         * every timestamp up to a full second into the PAST, and the reader
         * compares it against the instant it asked for the scan
         * (WificondScannerImpl, docs/32-wifi-stage3.md).  So when NM's scan
         * finishes in the same wall-clock second Android asked in -- which is
         * common, since NM often has one in flight already -- the truncated
         * value lands before the request and the result is discarded.  Measured
         * on this host: Android asked at 202445 ms, the scan completed at
         * 202945 ms, LastSeen read 202 -> 202000 ms, and all 8 results were
         * dropped with "Filtering out 8 scan results".
         *
         * That it is a coin flip rather than a constant failure is why it
         * survived Stages 3 and 4: whether the second ticks over between the
         * request and the scan completing decides it.
         *
         * 999 ms is the LATEST instant consistent with what NM actually told
         * us, so it never claims an AP was seen at a time NM has ruled out, and
         * it removes the systematic backwards bias rather than papering over it
         * with a margin.  Genuinely stale APs still filter correctly: one seen
         * 10 s ago reads 10999 ms old, which is still older than the request.
         *
         * NM does publish a millisecond LastScan, but that is a property of the
         * DEVICE and says nothing about which APs appeared in that scan, so it
         * cannot date an individual result.
         */
        GVariant* seen = getProp(path, NM_AP, "LastSeen");
        if (seen) {
            gint32 t = g_variant_is_of_type(seen, G_VARIANT_TYPE_INT32) ?
                g_variant_get_int32(seen) : -1;
            if (t > 0) {
                bss.lastSeenUsec = (uint64_t) t * 1000000 + 999000;

                /*
                 * If this AP was found by the scan that just finished, date it
                 * at that scan rather than at its own coarse LastSeen.
                 *
                 * A scan is a SWEEP, not an instant: it walks the channels over
                 * a couple of seconds, so an AP on channel 1 is seen well before
                 * the scan completes.  NM reports the sweep's end in LastScan
                 * and each AP's own sighting in LastSeen.  The reader compares
                 * against the moment it ASKED for the scan, which lands inside
                 * that window -- so results found early in the very scan Android
                 * requested are older than the request and get dropped.
                 * Measured: request at 523471 ms, scan completed 523974 ms, APs
                 * dated 521-523 s, "Filtering out 8 scan results".
                 *
                 * Dating them at LastScan is not a fudge -- it is the more
                 * accurate answer to the question actually being asked, which is
                 * "was this AP present in the scan that just completed".  It was.
                 * The daemon only announces results after watching LastScan
                 * change, so that scan is by construction the one Android asked
                 * for.
                 *
                 * The window is bounded so genuinely stale APs still filter
                 * correctly: NM keeps an AP in its list long after it stops
                 * appearing in scans, and those must keep their real age or
                 * Android would be told a vanished network is still in range.
                 * Sweeps measured on this radio spread LastSeen about 3 s below
                 * LastScan; 8 s leaves room without reaching the next scan.
                 */
                if (lastScanMs > 0 &&
                    (uint64_t) lastScanMs * 1000 > bss.lastSeenUsec &&
                    (uint64_t) lastScanMs * 1000 - bss.lastSeenUsec <=
                        SCAN_SWEEP_USEC) {
                    bss.lastSeenUsec = (uint64_t) lastScanMs * 1000;
                }
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
 * Build the connection profile NM will store and activate.
 *
 * The awkward part is not the dictionary, it is that NM and the supplicant
 * interface disagree about what a "network" is.  Android hands over a dozen
 * separately-set properties -- key management mask, proto mask, pairwise and
 * group ciphers, auth algorithms -- because that is wpa_supplicant's network
 * block.  NM takes a key-mgmt string and works the rest out from the AP's own
 * beacon.  So most of what Android carefully set is deliberately dropped here:
 * passing NM a pairwise-cipher restriction derived from Android's defaults is
 * a good way to fail an association that would otherwise have worked.
 *
 * What survives is what NM cannot infer: the SSID, the key management family,
 * and the secret.
 */
GVariant*
NmBackend::buildSettings(const NetworkRequest& req)
{
    GVariantBuilder conn, wireless, security, ipv4, ipv6, outer;
    const char* keyMgmt = nullptr;

    switch (req.security) {
    case Security::Open:
        keyMgmt = nullptr;
        break;
    case Security::WpaPsk:
    case Security::Wpa2Psk:
    case Security::Wpa2Wpa3Psk:
        /*
         * "wpa-psk" and not "sae" even for the transition case: NM negotiates
         * the strongest the AP offers from this setting, whereas pinning "sae"
         * would refuse the WPA2 leg outright if the AP turned out not to do
         * WPA3 after all.
         */
        keyMgmt = "wpa-psk";
        break;
    case Security::Wpa3Sae:
        keyMgmt = "sae";
        break;
    case Security::Wep:
    case Security::Wpa2Eap:
        GWARN("connect(%s): %s is not carried across this backend yet",
              req.ssid.c_str(), securityName(req.security));
        return nullptr;
    }

    if (keyMgmt && req.passphrase.empty()) {
        GWARN("connect(%s): %s needs a passphrase and none arrived",
              req.ssid.c_str(), securityName(req.security));
        return nullptr;
    }

    g_variant_builder_init(&conn, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&conn, "{sv}", "id",
        g_variant_new_string(connectionId(req.ssid).c_str()));
    /* Identity; the id above is only a label.  See findConnection(). */
    g_variant_builder_add(&conn, "{sv}", "uuid",
        g_variant_new_string(connectionUuid(req.ssid).c_str()));
    g_variant_builder_add(&conn, "{sv}", "type",
        g_variant_new_string("802-11-wireless"));
    g_variant_builder_add(&conn, "{sv}", "interface-name",
        g_variant_new_string(mIfname.c_str()));
    /*
     * No NM-level autoconnect on profiles we own.  Android has its own
     * reconnect logic -- WifiConnectivityManager calls connectToNetwork() when
     * it wants to rejoin -- so autoconnect here would be a second, invisible
     * scheduler competing with it.
     *
     * It also matters for failure.  A profile of ours with a bad password and
     * autoconnect on would be retried by NM ahead of the host's own working
     * profile for the same network, delaying the fallback that is the only
     * thing keeping a mistyped password from stranding this machine.  With it
     * off, a failed attempt leaves the field immediately.
     */
    g_variant_builder_add(&conn, "{sv}", "autoconnect",
        g_variant_new_boolean(FALSE));

    g_variant_builder_init(&wireless, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&wireless, "{sv}", "ssid",
        g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, req.ssid.data(),
                                  req.ssid.size(), 1));
    g_variant_builder_add(&wireless, "{sv}", "mode",
        g_variant_new_string("infrastructure"));

    /*
     * DHCP, but never at the host's expense.
     *
     * The radio Android drives is a second adapter; the host reaches the world
     * over its own.  Both are likely to be on the SAME AP and therefore the
     * same subnet, so without a guard NM would install two competing sets of
     * routes and the host's default could land on the radio Android is free to
     * disconnect at any moment.  That is trap 5 of 33-wifi-stage4.md wearing a
     * different hat: the outage there came from Android's control of a radio
     * reaching further than Android's own session.
     *
     * Two settings, because they stop two different things:
     *
     *   never-default  keeps this profile from ever supplying a DEFAULT route.
     *   route-metric   keeps its ON-LINK subnet route from outranking the
     *                  host's.  never-default does not cover this, and on a
     *                  shared subnet it is the one that matters: a lower metric
     *                  here would send replies to the host's own traffic out of
     *                  the wrong interface, with a source address belonging to
     *                  the other one.
     *
     * WAYDROID_ROUTE_METRIC sits well above NM's Wi-Fi default (600 on this
     * host) so the host's radio always wins.  Android's traffic does not flow
     * over this link today anyway -- wlan0 is a veth onto waydroid0 -- so this
     * profile carries no route worth preferring.
     */
    g_variant_builder_init(&ipv4, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&ipv4, "{sv}", "method",
        g_variant_new_string("auto"));
    g_variant_builder_add(&ipv4, "{sv}", "never-default",
        g_variant_new_boolean(TRUE));
    g_variant_builder_add(&ipv4, "{sv}", "route-metric",
        g_variant_new_int64(WAYDROID_ROUTE_METRIC));
    g_variant_builder_init(&ipv6, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_add(&ipv6, "{sv}", "method",
        g_variant_new_string("auto"));
    g_variant_builder_add(&ipv6, "{sv}", "never-default",
        g_variant_new_boolean(TRUE));
    g_variant_builder_add(&ipv6, "{sv}", "route-metric",
        g_variant_new_int64(WAYDROID_ROUTE_METRIC));

    g_variant_builder_init(&outer, G_VARIANT_TYPE("a{sa{sv}}"));
    g_variant_builder_add(&outer, "{sa{sv}}", "connection", &conn);
    g_variant_builder_add(&outer, "{sa{sv}}", "802-11-wireless", &wireless);
    if (keyMgmt) {
        g_variant_builder_init(&security, G_VARIANT_TYPE("a{sv}"));
        g_variant_builder_add(&security, "{sv}", "key-mgmt",
            g_variant_new_string(keyMgmt));
        g_variant_builder_add(&security, "{sv}", "psk",
            g_variant_new_string(req.passphrase.c_str()));
        /*
         * Secret flag 0 is NM_SETTING_SECRET_FLAG_NONE: the passphrase is
         * stored in the profile and owned by the system.  It has to be, or NM
         * asks a secret agent for it at association time -- and there is no
         * agent in the kiosk session to ask, so the connection would hang in
         * NEED_AUTH rather than failing in a way we could report.
         */
        g_variant_builder_add(&security, "{sv}", "psk-flags",
            g_variant_new_uint32(0));
        g_variant_builder_add(&outer, "{sa{sv}}", "802-11-wireless-security",
            &security);
    }
    g_variant_builder_add(&outer, "{sa{sv}}", "ipv4", &ipv4);
    g_variant_builder_add(&outer, "{sa{sv}}", "ipv6", &ipv6);

    return g_variant_builder_end(&outer);
}

/*
 * Our OWN profile for an SSID, or "" if we have not made one.
 *
 * The important word is "own".  An earlier version of this matched on the SSID
 * and updated whatever profile it found, so that Android and the host's
 * desktop would share one profile per network -- which is tidy, and which is
 * also a way to brick the machine.  wlp1s0 is this host's ONLY network
 * interface (docs/28-wifi-feasibility.md).  Overwriting the psk of a working
 * host profile with a password mistyped in Android therefore destroys the
 * machine's only route off itself, and the repair is a trip to the physical
 * console.
 *
 * So profiles we create are ours alone, and we never read, write or delete
 * anything else.  The host's own saved networks are left exactly alone, which
 * also leaves NM's autoconnect able to fall back to them when one of ours fails
 * -- that fallback is what makes a wrong password recoverable rather than
 * terminal.
 *
 * OWNERSHIP IS BY UUID, NOT BY NAME.  connection.id is a display string: the
 * user can rename any profile from the desktop GUI, NM does not require it to
 * be unique, and matching on it makes the guarantee above only as strong as a
 * label nobody promised to leave alone.  Someone naming a profile
 * "coffeeshop (Waydroid)" would hand us write access to it, and renaming ours
 * would orphan it and silently accumulate duplicates -- the first of those is
 * exactly the failure this rule exists to prevent.
 *
 * connection.uuid is NM's real primary key: unique, and immutable across
 * renames.  We derive ours from the SSID (RFC 4122 v5, our own namespace) so it
 * is reproducible from nothing but the SSID -- this daemon keeps no state
 * between runs and must still recognise its own profile after a restart, which
 * a randomly generated UUID could not do.
 *
 * The id is still set, because a human reading `nmcli connection` deserves to
 * know where the profile came from.  It is a label now, not an identity.
 *
 * The cost is a duplicate profile for a network the host already knows.  That
 * is a fair price.
 */
std::string
NmBackend::connectionId(const std::string& ssid)
{
    return ssid + " (Waydroid)";
}

std::string
NmBackend::connectionUuid(const std::string& ssid)
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

std::string
NmBackend::findConnection(const std::string& ssid)
{
    const std::string want = connectionUuid(ssid);
    GVariant* res = call(NM_SETTINGS_PATH, NM_SETTINGS, "ListConnections",
        nullptr, "(ao)");

    if (!res) {
        return "";
    }

    GVariantIter* iter = nullptr;
    gchar* path = nullptr;
    std::string found;

    /* _next rather than _loop: this loop exits early on a match, and
     * g_variant_iter_loop leaks its last value if you break out of it. */
    g_variant_get(res, "(ao)", &iter);
    while (found.empty() && g_variant_iter_next(iter, "o", &path)) {
        GVariant* settings = call(path, NM_CONNECTION, "GetSettings", nullptr,
            "(a{sa{sv}})");
        if (!settings) {
            g_free(path);
            continue;
        }

        GVariant* dict = g_variant_get_child_value(settings, 0);
        GVariant* conn = g_variant_lookup_value(dict, "connection",
            G_VARIANT_TYPE("a{sv}"));
        if (conn) {
            GVariant* v = g_variant_lookup_value(conn, "uuid",
                G_VARIANT_TYPE_STRING);
            if (v) {
                if (want == g_variant_get_string(v, nullptr)) {
                    found = path;
                }
                g_variant_unref(v);
            }
            g_variant_unref(conn);
        }
        g_variant_unref(dict);
        g_variant_unref(settings);
        g_free(path);
    }
    g_variant_iter_free(iter);
    g_variant_unref(res);
    return found;
}

/*
 * Associate.  Returns whether NM ACCEPTED the request, not whether it worked
 * -- the outcome arrives asynchronously through onLinkEvent(), which is what
 * the supplicant interface above needs anyway.
 */
bool
NmBackend::connect(const NetworkRequest& req)
{
    std::string dev = wifiDevicePath();

    if (dev.empty()) {
        GWARN("connect(%s): no Wi-Fi device", req.ssid.c_str());
        return false;
    }

    GVariant* settings = buildSettings(req);
    if (!settings) {
        return false;
    }
    g_variant_ref_sink(settings);

    std::string existing = findConnection(req.ssid);
    GVariant* res = nullptr;

    if (!existing.empty()) {
        GINFO("connect(%s): updating our profile %s",
              req.ssid.c_str(), existing.c_str());
        GVariant* upd = call(existing.c_str(), NM_CONNECTION, "Update",
            g_variant_new("(@a{sa{sv}})", settings), "()");
        if (!upd) {
            GWARN("connect(%s): could not update the profile", req.ssid.c_str());
            g_variant_unref(settings);
            return false;
        }
        g_variant_unref(upd);
        mOurSettingsPath = existing;
        res = call(NM_PATH, NM_IFACE, "ActivateConnection",
            g_variant_new("(ooo)", existing.c_str(), dev.c_str(), "/"), "(o)");
    } else {
        GINFO("connect(%s): adding our profile \"%s\"", req.ssid.c_str(),
              connectionId(req.ssid).c_str());
        res = call(NM_PATH, NM_IFACE, "AddAndActivateConnection",
            g_variant_new("(@a{sa{sv}}oo)", settings, dev.c_str(), "/"),
            "(oo)");
    }

    g_variant_unref(settings);
    if (!res) {
        GWARN("connect(%s): NetworkManager refused the activation",
              req.ssid.c_str());
        return false;
    }
    /* AddAndActivateConnection returns (settings, active); ActivateConnection
     * returns just (active).  Only the first tells us a NEW settings path. */
    if (existing.empty()) {
        const char* added = nullptr;
        g_variant_get_child(res, 0, "&o", &added);
        mOurSettingsPath = added ? added : "";
    }
    g_variant_unref(res);

    mConnectingSsid = req.ssid;
    return true;
}

/*
 * Disconnect ONLY a connection we activated, and do it by deactivating that
 * connection rather than by disconnecting the device.
 *
 * Both halves of that sentence were learned the hard way, in the same outage.
 *
 * Device.Disconnect() is not "drop this association", it is "the user wants
 * this device down", and NM honours it by BLOCKING autoconnect until something
 * explicitly activates a connection again.  So calling it does not merely take
 * the host off the network -- it pins it there, defeating the fallback to the
 * host's own profile that is the entire safety net on a machine whose only
 * network interface is this radio.  The device state that followed said so
 * exactly: 110 -> 30, reason 39, "user-requested".
 *
 * And Android must not be able to disconnect something it did not connect.  If
 * the active connection is the host's own profile, "turn Wi-Fi off in Android"
 * has no business taking the host off its network, so this does nothing and
 * says why.
 */
bool
NmBackend::disconnect()
{
    std::string dev = wifiDevicePath();

    if (dev.empty()) {
        return false;
    }

    std::string active = propString(dev.c_str(), NM_DEV, "ActiveConnection");
    if (active.empty() || active == "/") {
        GDEBUG("disconnect(): nothing is active");
        return true;
    }

    /* Is the active connection one of ours?  Compare by the settings object
     * it was made from, which is what findConnection() returns. */
    std::string settings = propString(active.c_str(), NM_ACTIVE, "Connection");
    if (settings.empty() || settings != mOurSettingsPath) {
        std::string id = propString(active.c_str(), NM_ACTIVE, "Id");
        GINFO("disconnect(): the active connection \"%s\" is not ours -- "
              "leaving the host's own network alone", id.c_str());
        return true;
    }

    GINFO("disconnect(): deactivating our connection %s", active.c_str());
    GVariant* res = call(NM_PATH, NM_IFACE, "DeactivateConnection",
        g_variant_new("(o)", active.c_str()), "()");
    if (!res) {
        return false;
    }
    g_variant_unref(res);
    return true;
}

/*
 * Delete OUR profile for an SSID.  A profile the host made for the same
 * network survives, so "forget" in Android does not silently unsave a network
 * from the host's desktop -- see findConnection().  The host may therefore go
 * on autoconnecting to a network Android has forgotten, which is the correct
 * outcome: they are different users of one radio, and only one of them asked.
 */
bool
NmBackend::forget(const std::string& ssid)
{
    std::string path = findConnection(ssid);

    if (path.empty()) {
        GDEBUG("forget(%s): we have no profile for it", ssid.c_str());
        return true;
    }

    GINFO("forget(%s): deleting our profile %s", ssid.c_str(), path.c_str());
    GVariant* res = call(path.c_str(), NM_CONNECTION, "Delete", nullptr, "()");
    if (!res) {
        return false;
    }
    g_variant_unref(res);
    return true;
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
NmBackend::onLinkEvent(std::function<void(const LinkState&, LinkEvent)> cb)
{
    mLinkCb = std::move(cb);
}

/*
 * NM's Device.StateChanged, translated.
 *
 * Two things here are not obvious from the state numbers:
 *
 *   - DISCONNECTED is not a failure and usually is not even an ending.  NM
 *     passes through it on the way INTO every association, so forwarding it
 *     as a disconnect would tear down a connection that is being set up.  It
 *     only means something when it follows ACTIVATED.
 *
 *   - NEED_AUTH is where a wrong password shows up first, but not reliably:
 *     with the secret stored in the profile (psk-flags 0) NM retries and lands
 *     in FAILED/NO_SECRETS, whereas with an agent in the picture it can sit in
 *     NEED_AUTH instead.  Both are treated as a credential rejection, because
 *     to the person who just typed a password they are the same event.
 */
void
NmBackend::deviceStateChanged(guint32 newState, guint32 oldState, guint32 reason)
{
    LinkEvent ev;

    if (!mLinkCb) {
        return;
    }

    switch (newState) {
    case NM_STATE_ACTIVATED:
        ev = LinkEvent::Associated;
        mConnectingSsid.clear();
        break;

    case NM_STATE_PREPARE:
    case NM_STATE_CONFIG:
    case NM_STATE_IP_CONFIG:
    case NM_STATE_IP_CHECK:
    case NM_STATE_SECONDARIES:
        ev = LinkEvent::Associating;
        break;

    case NM_STATE_NEED_AUTH:
        /*
         * NOT a failure, however much it reads like one.  NM passes through
         * NEED_AUTH on the way into a perfectly ordinary association -- it is
         * "I am about to need the secret", not "the secret was wrong" -- and
         * the successful association that recovered this machine on 2026-09-08
         * went 50 -> 60 -> 40 -> 50 -> 70 -> ... -> 100 straight through it.
         *
         * Reporting AuthFailed here cost an outage.  The layer above turned it
         * into Android's "wrong password" sequence mid-association, Android
         * gave up and called disconnect(), and the host -- whose only network
         * interface is this radio -- went offline while NM was still busy
         * succeeding.  A credential rejection is FAILED with NO_SECRETS, and
         * nothing else is.
         */
        ev = LinkEvent::Associating;
        break;

    case NM_STATE_FAILED:
        ev = (reason == NM_REASON_NO_SECRETS) ?
            LinkEvent::AuthFailed : LinkEvent::Failed;
        mConnectingSsid.clear();
        break;

    case NM_STATE_DISCONNECTED:
    case NM_STATE_DEACTIVATING:
    case NM_STATE_UNAVAILABLE:
    case NM_STATE_UNMANAGED:
        /* Only an ending if something had actually started. */
        if (oldState < NM_STATE_IP_CONFIG && !mConnectingSsid.empty()) {
            return;
        }
        ev = LinkEvent::Disconnected;
        break;

    default:
        return;
    }

    GDEBUG("NM device state %u -> %u (reason %u) = %s", oldState, newState,
           reason, linkEventName(ev));

    LinkState st = state();
    mLinkCb(st, ev);
}

void
NmBackend::onNmSignal(GDBusConnection* bus, const gchar* sender,
    const gchar* path, const gchar* iface, const gchar* signal,
    GVariant* params, gpointer user)
{
    NmBackend* self = (NmBackend*) user;
    guint32 newState = 0, oldState = 0, reason = 0;

    /* Subscribed without a path filter, because the device path is not known
     * until NM has one; check here instead of assuming. */
    if (self->wifiDevicePath() != path) {
        return;
    }
    g_variant_get(params, "(uuu)", &newState, &oldState, &reason);
    self->deviceStateChanged(newState, oldState, reason);
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
