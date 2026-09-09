/*
 * NetworkManager implementation of WifiBackend, over the system D-Bus.
 *
 * NM is the right first backend for bigtab01 because it is what already owns
 * wlp1s0 on the host -- the machine's ONLY network interface, which is also
 * why handing the radio to the container was rejected outright
 * (docs/28-wifi-feasibility.md).  Nothing here is Waydroid-specific; it is an
 * ordinary NM client that happens to be driven by Android.
 */

#pragma once

#include "WifiBackend.h"

#include <gio/gio.h>

#include <map>
#include <utility>

namespace waydroid {
namespace wifi {

class NmBackend : public WifiBackend {
public:
    NmBackend();
    ~NmBackend() override;

    bool init(const std::string& spec) override;
    const char* name() const override { return "networkmanager"; }

    bool setEnabled(bool on) override;
    bool isEnabled() override;

    bool startScan() override;
    std::vector<Bss> scanResults() override;
    void onScanComplete(std::function<void(bool ok)> cb) override;

    bool connect(const NetworkRequest& req) override;
    bool disconnect() override;
    bool forget(const std::string& ssid) override;
    LinkState state() override;
    void onLinkEvent(
        std::function<void(const LinkState&, LinkEvent)> cb) override;

    std::vector<std::string> devices() override;
    bool selectDevice(const std::string& spec) override;
    std::string selectedDevice() const override { return mIfname; }

    void macAddress(uint8_t out[6]) override;

    std::vector<int32_t> frequencies(Band band) override;

private:
    /* Small D-Bus conveniences.  Returned GVariants are owned by the caller. */
    GVariant* call(const char* path, const char* iface, const char* method,
                   GVariant* args, const char* replyType);
    GVariant* getProp(const char* path, const char* iface, const char* prop);
    bool setProp(const char* path, const char* iface, const char* prop, GVariant* value);
    std::string propString(const char* path, const char* iface, const char* prop);
    guint32 propUint(const char* path, const char* iface, const char* prop, guint32 def = 0);
    gint64 propInt64(const char* path, const char* iface, const char* prop, gint64 def = -1);

    /* Scan completion, polled -- see the note above NmBackend::startScan(). */
    static gboolean scanPollTick(gpointer user);
    void scanFinished(bool ok);

    /* Resolve the Wi-Fi device object path for mIfname, "" if none. */
    std::string wifiDevicePath();

    /*
     * Every Wi-Fi device NM knows about, as (object path, interface name).
     * devices() and MAC resolution both want this list and neither wants to
     * pay for the other's shape.
     */
    std::vector<std::pair<std::string, std::string> > wifiDeviceList();

    /* Factory MAC of a device object path, uppercase; "" if NM will not say. */
    std::string permMacOf(const std::string& path);

    /* "34:e8:94:f8:61:70" -> "34:E8:94:F8:61:70"; "" if it is not a MAC. */
    static std::string normalizeMac(const std::string& s);

    /*
     * The radio whose factory MAC is mSelectorMac, as (object path, ifname).
     * Both empty if that hardware is not present.
     */
    std::pair<std::string, std::string> resolveByMac();

    /*
     * Whether NM currently routes the host's own default traffic over this
     * interface.  Used only to keep automatic selection off the host's lifeline
     * when the machine has more than one radio; see init().
     */
    bool carriesHostDefaultRoute(const std::string& ifname);

    /*
     * Whether a profile of ours must leave the host's default route alone.
     * True when some OTHER device carries it, false when this radio is itself
     * the host's path off the machine, or when nothing carries one at all.
     * See the long note above the ipv4 builder in buildSettings().
     */
    bool yieldDefaultRouteToHost();

    /*
     * Association.  NM takes a whole connection profile at once, where the
     * supplicant interface above the seam builds one a property at a time, so
     * the translation happens here rather than being spread across callers.
     */
    GVariant* buildSettings(const NetworkRequest& req);

    /*
     * Profiles this daemon owns are named "<ssid> (Waydroid)" and nothing else
     * is ever touched.  See the long note above findConnection() in the .cpp:
     * this host has one network interface, and updating a host profile's psk
     * with a password mistyped in Android would strand the machine.
     */
    static std::string connectionId(const std::string& ssid);
    static std::string connectionUuid(const std::string& ssid);
    std::string findConnection(const std::string& ssid);
    static void onNmSignal(GDBusConnection* bus, const gchar* sender,
        const gchar* path, const gchar* iface, const gchar* signal,
        GVariant* params, gpointer user);
    void deviceStateChanged(guint32 newState, guint32 oldState, guint32 reason);

    GDBusConnection* mBus = nullptr;
    std::string mIfname;                 /* selected host interface, e.g. wlp1s0 */
    std::string mDevPath;                /* cached NM object path for it */

    /*
     * The FACTORY MAC of the radio we are pinned to, uppercase.
     *
     * The interface name is not an identity.  wlp0s20u1 encodes the USB port
     * the T3U happens to be in, so moving it one socket along renames it; a
     * driver reprobe (bin/wifi-radio-reset.sh) can rename it too.  Anything
     * unattended keying off the name is therefore keying off a coincidence,
     * and the failure it invites is the expensive one -- Android silently
     * driving the host's own link, trap 5 of docs/33-wifi-stage4.md.
     *
     * Set on the first successful selection however the radio was named, so
     * even --device wlp0s20u1 follows that piece of hardware afterwards rather
     * than following whatever wears the name next.  NOT the same thing as
     * macAddress(), which reports the randomized address actually on the air.
     */
    std::string mSelectorMac;
    std::function<void(const LinkState&, LinkEvent)> mLinkCb;
    guint   mStateSignalId = 0;          /* Device.StateChanged subscription */

    /*
     * The SSID we were last asked to associate with.  NM reports a failure
     * against the device, not against the request, so without this a failure
     * arriving after we gave up would be reported as a failure of whatever is
     * being attempted now.
     */
    std::string mConnectingSsid;

    /*
     * The settings object of the profile we last activated.  Ownership has to
     * be tracked by identity, not by "whatever matches the SSID we are
     * currently attempting": mConnectingSsid is cleared once an association
     * succeeds, so using it to decide ownership would make disconnect() refuse
     * to drop the very connection it had just made.
     */
    std::string mOurSettingsPath;

    std::function<void(bool)> mScanCb;
    guint   mScanPollId = 0;             /* GLib source while a scan is pending */
    int     mScanPollsLeft = 0;
    gint64  mScanBaseline = -1;          /* Device.Wireless LastScan before it */
    bool    mScanBlind = false;          /* this NM does not publish LastScan */
    bool    mScanSuppressed = false;     /* this scan was skipped mid-association */
    bool    mScanSettling = false;       /* scan landed; AP properties catching up */
};

} /* namespace wifi */
} /* namespace waydroid */
