/*
 * The Android-facing half: a replacement for /system/bin/wificond, served from
 * the host over libgbinder as AIDL on /dev/binder.
 *
 * WHY REPLACE WIFICOND AT ALL (docs/29-wifi-plan.md, "Path U")
 *
 * Stock wificond drives nl80211 and needs a wiphy it can see.  virt_wifi puts
 * its netdev in the container's network namespace but pins the wiphy to
 * init_net -- it never sets WIPHY_FLAG_NETNS_OK -- so "iw phy set netns" is
 * refused with -EOPNOTSUPP and wificond inside the container reports
 * "No wiphy is found".  Patching the kernel module would fix that, at the cost
 * of an out-of-tree module on a host that updates kernels often.  Replacing
 * wificond in userspace makes the wiphy irrelevant instead: nothing here talks
 * to nl80211, so wlan0 only ever has to be a netdev.
 *
 * The three objects mirror wificond's own hierarchy exactly, because
 * WifiNl80211Manager walks it in a fixed order:
 *
 *   IWificond           registered as "wifinl80211"
 *     -> createClientInterface(name) -> IClientInterface
 *          -> getWifiScannerImpl()   -> IWifiScannerImpl
 *               -> subscribeScanEvents(IScanEvent)      (framework's object)
 *               -> subscribePnoScanEvents(IPnoScanEvent)
 *
 * Transaction codes are positional and were not taken on trust: they were read
 * out of THIS image's framework.jar bytecode and matched against AOSP
 * android-13.0.0_r75.  See docs/30-wifi-aidl-surface.md and
 * artifacts/wifi/interface-surface/.
 */

#pragma once

#include "WifiBackend.h"

#include <gbinder.h>

#include <string>

namespace waydroid {
namespace wifi {

class Wificond {
public:
    Wificond(GBinderServiceManager* sm, WifiBackend* backend);
    ~Wificond();

    /* The object registered in servicemanager as "wifinl80211". */
    GBinderLocalObject* object() const { return mWificond; }

    /* Tell the framework a fresh scan result set is available. */
    void notifyScanResultsReady();
    void notifyScanFailed();

private:
    static GBinderLocalReply* onWificond(GBinderLocalObject* obj,
        GBinderRemoteRequest* req, guint code, guint flags, int* status,
        void* user);
    static GBinderLocalReply* onClientInterface(GBinderLocalObject* obj,
        GBinderRemoteRequest* req, guint code, guint flags, int* status,
        void* user);
    static GBinderLocalReply* onScanner(GBinderLocalObject* obj,
        GBinderRemoteRequest* req, guint code, guint flags, int* status,
        void* user);

    GBinderLocalReply* handleWificond(GBinderRemoteRequest*, guint code,
        guint flags, int* status);
    GBinderLocalReply* handleClientInterface(GBinderRemoteRequest*, guint code,
        guint flags, int* status);
    GBinderLocalReply* handleScanner(GBinderRemoteRequest*, guint code,
        guint flags, int* status);

    void ensureClientInterface();
    void dropScanEvent();
    void dropPnoScanEvent();

    GBinderServiceManager* mSm;
    WifiBackend* mBackend;

    GBinderLocalObject* mWificond = nullptr;
    GBinderLocalObject* mClient = nullptr;
    GBinderLocalObject* mScanner = nullptr;

    /* Callbacks the framework handed us; we are the client of these. */
    GBinderRemoteObject* mScanEvent = nullptr;
    GBinderClient* mScanEventClient = nullptr;
    GBinderRemoteObject* mPnoScanEvent = nullptr;
    GBinderClient* mPnoScanEventClient = nullptr;
    GBinderRemoteObject* mEventCallback = nullptr;

    std::string mIfaceName;     /* what Android asked us to create, e.g. wlan0 */
    bool mScanPending = false;  /* the framework asked, the host has not answered */
};

} /* namespace wifi */
} /* namespace waydroid */
