/*
 * The supplicant half of the shim: ISupplicant, ISupplicantStaIface and
 * ISupplicantStaNetwork, served from the host over libgbinder as AIDL on
 * /dev/binder, with NetworkManager doing the actual associating.
 *
 * WHY THIS EXISTS AT ALL, AND WHY IT IS NOT wpa_supplicant
 *
 * Stage 2 replaced wificond and got Android as far as ScanOnlyModeState.  It
 * could get no further, and not for want of trying: switching the Wi-Fi master
 * toggle on puts ActiveModeWarden into ROLE_CLIENT_PRIMARY, which runs
 * WifiNative.setupInterfaceForClientInConnectivityMode(), and that calls
 * startSupplicant() BEFORE it ever reaches wificond.  No supplicant, no
 * toggle -- so the Settings picker stayed empty however real the scan data
 * behind it had become.
 *
 * A stock wpa_supplicant cannot fill the hole.  It drives nl80211 against a
 * real wiphy, and the container has none -- that is the whole reason Path U
 * exists (docs/29-wifi-plan.md).  So the supplicant interface is implemented
 * and the association is delegated to whatever owns the radio on the host,
 * across the same WifiBackend seam the scan results already cross.
 *
 * WHAT ANDROID ACTUALLY REQUIRES, WHICH IS MUCH LESS THAN THE INTERFACE
 *
 * The three interfaces declare 167 methods between them, and docs/30 counts
 * 203 slots across all six.  Almost none of them matter.  Disassembling
 * service-wifi.jar shows which ones the framework ever calls, and reading
 * SupplicantStaIfaceHalAidlImpl and SupplicantStaNetworkHalAidlImpl shows
 * which of THOSE are load-bearing -- a call whose failure aborts the connect
 * flow, rather than one whose failure is logged and shrugged off.  The
 * load-bearing set is small enough to list:
 *
 *   ISupplicant            addStaInterface
 *   ISupplicantStaIface    registerCallback, addNetwork, listNetworks,
 *                          removeNetwork
 *   ISupplicantStaNetwork  setSsid, setBssid, setScanSsid, setRequirePmf,
 *                          setKeyMgmt, setProto, setAuthAlg, setGroupCipher,
 *                          setPairwiseCipher, setPskPassphrase (or setPsk /
 *                          setSaePassword), setIdStr, registerCallback,
 *                          select, getId
 *
 * Everything else gets a slot and an honest refusal.  The slots are not
 * optional: transaction codes are positional, so a missing method does not
 * merely go unanswered, it shifts nothing -- but answering the WRONG code
 * because the table was mis-numbered would corrupt every later call.  Codes
 * here were read out of this image's own bytecode, not assumed; see
 * docs/30-wifi-aidl-surface.md and artifacts/wifi/interface-surface/.
 *
 * THE SETTERS ARE AN ACCUMULATOR, NOT A CONFIGURATION
 *
 * wpa_supplicant's network block is built one property at a time and then
 * committed by select().  NetworkManager's is a single D-Bus dictionary handed
 * over whole.  So the setters below do not act; they fill in a Network struct,
 * and select() is the one call that crosses the WifiBackend seam.  That is
 * also where the password arrives -- setPskPassphrase() gets it in the clear,
 * which is what makes the whole design work and is worth saying out loud.
 */

#pragma once

#include "WifiBackend.h"

#include <gbinder.h>

#include <cstdint>
#include <string>
#include <vector>

namespace waydroid {
namespace wifi {

/* Registered in servicemanager under this name; the VINTF fragment in
 * artifacts/overlay/vendor/etc/vintf/manifest/ declares the same one, and
 * ServiceManager.isDeclared() on it is what selects the AIDL path over HIDL. */
#define SUPPLICANT_SERVICE_NAME "android.hardware.wifi.supplicant.ISupplicant/default"

class Supplicant {
public:
    Supplicant(GBinderServiceManager* sm, WifiBackend* backend);
    ~Supplicant();

    /* The object registered as SUPPLICANT_SERVICE_NAME. */
    GBinderLocalObject* object() const { return mSupplicant; }

private:
    /*
     * The network the framework is building, or has built.  One at a time is
     * enough: WifiNative calls removeAllNetworks() before every connect, so
     * the framework itself never keeps two.
     */
    struct Network {
        int32_t     id = 0;
        std::string ssid;               /* decoded from the byte[] setSsid() */
        std::string passphrase;         /* setPskPassphrase, in the clear */
        std::string saePassword;        /* setSaePassword, WPA3 */
        std::string pskHex;             /* setPsk, a raw 32-byte PMK as hex */
        std::string idStr;
        uint8_t     bssid[6] = {0, 0, 0, 0, 0, 0};
        bool        haveBssid = false;
        int32_t     keyMgmt = 0;        /* KeyMgmtMask */
        int32_t     proto = 0;          /* ProtoMask */
        int32_t     authAlg = 0;        /* AuthAlgMask */
        int32_t     groupCipher = 0;    /* GroupCipherMask */
        int32_t     pairwiseCipher = 0; /* PairwiseCipherMask */
        bool        scanSsid = false;
        bool        requirePmf = false;
    };

    static GBinderLocalReply* onSupplicant(GBinderLocalObject*,
        GBinderRemoteRequest*, guint code, guint flags, int* status, void*);
    static GBinderLocalReply* onStaIface(GBinderLocalObject*,
        GBinderRemoteRequest*, guint code, guint flags, int* status, void*);
    static GBinderLocalReply* onStaNetwork(GBinderLocalObject*,
        GBinderRemoteRequest*, guint code, guint flags, int* status, void*);

    GBinderLocalReply* handleSupplicant(GBinderRemoteRequest*, guint code,
        int* status);
    GBinderLocalReply* handleStaIface(GBinderRemoteRequest*, guint code,
        int* status);
    GBinderLocalReply* handleStaNetwork(GBinderRemoteRequest*, guint code,
        int* status);

    void ensureStaIface();
    void dropIfaceCallback();
    void dropNetworkCallback();

    /* Translate the accumulated Network into a backend request and act on it. */
    bool selectNetwork();
    Security securityFromNetwork() const;

    /* Host link events -> ISupplicantStaIfaceCallback. */
    void onHostLinkEvent(const LinkState& st, LinkEvent ev);
    void sendStateChanged(int32_t state, const uint8_t bssid[6]);
    void sendDisconnected(const uint8_t bssid[6], bool locallyGenerated,
        int32_t reasonCode);
    void sendNetworkAdded(int32_t id);
    void sendBssidChanged(int8_t reason, const uint8_t bssid[6]);
    void sendAuthTimeout(const uint8_t bssid[6]);

    GBinderServiceManager* mSm;
    WifiBackend* mBackend;

    GBinderLocalObject* mSupplicant = nullptr;
    GBinderLocalObject* mStaIface = nullptr;
    GBinderLocalObject* mStaNetwork = nullptr;

    /* Callbacks the framework handed us; we are the client of these. */
    GBinderRemoteObject* mIfaceCallback = nullptr;
    GBinderClient* mIfaceCallbackClient = nullptr;
    GBinderRemoteObject* mNetworkCallback = nullptr;
    GBinderClient* mNetworkCallbackClient = nullptr;

    std::string mIfaceName;             /* what addStaInterface() was given */
    Network mNetwork;
    bool mHaveNetwork = false;
    int32_t mNextNetworkId = 1;

    /*
     * The last StaIfaceCallbackState we reported.  Kept because the framework
     * reacts to transitions, not to levels: re-sending COMPLETED is not
     * harmless -- it re-broadcasts NETWORK_CONNECTION_EVENT and restarts L3
     * provisioning -- and NM emits several state changes that map to the same
     * Android state.
     */
    int32_t mReportedState = -1;
    bool mConnecting = false;           /* select() called, not yet resolved */
};

} /* namespace wifi */
} /* namespace waydroid */
