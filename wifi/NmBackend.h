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

namespace waydroid {
namespace wifi {

class NmBackend : public WifiBackend {
public:
    NmBackend();
    ~NmBackend() override;

    bool init() override;
    const char* name() const override { return "networkmanager"; }

    bool setEnabled(bool on) override;
    bool isEnabled() override;

    bool startScan() override;
    std::vector<Bss> scanResults() override;

    bool connect(const NetworkRequest& req) override;
    bool disconnect() override;
    bool forget(const std::string& ssid) override;
    LinkState state() override;
    void onStateChanged(std::function<void(LinkState)> cb) override;

    std::vector<std::string> devices() override;
    bool selectDevice(const std::string& ifname) override;
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

    /* Resolve the Wi-Fi device object path for mIfname, "" if none. */
    std::string wifiDevicePath();

    GDBusConnection* mBus = nullptr;
    std::string mIfname;                 /* selected host interface, e.g. wlp1s0 */
    std::string mDevPath;                /* cached NM object path for it */
    std::function<void(LinkState)> mStateCb;
};

} /* namespace wifi */
} /* namespace waydroid */
