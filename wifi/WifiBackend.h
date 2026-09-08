/*
 * waydroid-wifid -- the host-side backend contract.
 *
 * This header is the extension point of the whole daemon, and it is the
 * reason the daemon is worth building properly rather than narrowly.
 *
 * Everything ABOVE this line (Wificond.cpp, and later the supplicant shim)
 * speaks Android: AIDL parcels on /dev/binder, transaction codes, Android's
 * idea of what a "scan result" is.  Everything BELOW it speaks to whatever
 * actually owns the radio on the host.  NmBackend drives NetworkManager over
 * D-Bus; somebody running iwd or connman writes their own and changes nothing
 * on the Android side.
 *
 * Two rules keep the seam honest:
 *
 *   1. No Android/binder type appears in this file.  If a concept only makes
 *      sense to Android, it belongs above the line.
 *   2. Multiple host radios are resolved HERE, below the contract.  Android is
 *      shown exactly one interface and has no adapter picker -- verified in
 *      Stage 0: with no vendor HAL there is nothing to declare interface
 *      combinations, so "STA + STA Concurrency Supported: false".  See
 *      docs/29-wifi-plan.md.
 */

#pragma once

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace waydroid {
namespace wifi {

enum class Security {
    Open,
    Wep,
    WpaPsk,
    Wpa2Psk,
    Wpa2Wpa3Psk,                    /* transition mode: PSK and SAE together */
    Wpa3Sae,
    Wpa2Eap,
};

/*
 * Cipher suites, as a mask, because an AP advertises a list of pairwise
 * ciphers rather than one.  These are the suites NetworkManager distinguishes;
 * anything a future backend learns about (GCMP, say) gets a bit here.
 */
enum Cipher {
    CipherWep40  = 1 << 0,
    CipherWep104 = 1 << 1,
    CipherTkip   = 1 << 2,
    CipherCcmp   = 1 << 3,
};

const char* securityName(Security s);

/* One access point as the host sees it. */
struct Bss {
    std::string ssid;
    uint8_t     bssid[6] = {0, 0, 0, 0, 0, 0};
    int32_t     freqMhz  = 0;
    int32_t     rssiDbm  = 0;       /* dBm, negative */
    Security    security = Security::Open;
    uint32_t    pairwiseCiphers = 0;/* Cipher mask; 0 means "host did not say" */
    uint32_t    groupCiphers    = 0;/* Cipher mask; one bit in practice */
    bool        known    = false;   /* the host already has a profile for it */

    /*
     * When the host last saw this AP, in CLOCK_BOOTTIME microseconds; 0 if it
     * does not know.  An absolute instant rather than an age because that is
     * what the host actually records, and because the reader above the line
     * compares it against its own boot clock -- the container shares the
     * host's kernel, so the two agree exactly.
     */
    uint64_t    lastSeenUsec = 0;
};

/* A connection request coming down from Android's Wi-Fi dialog. */
struct NetworkRequest {
    std::string ssid;
    Security    security = Security::Open;
    std::string passphrase;         /* arrives in the clear from setPskPassphrase() */
    std::string identity;           /* EAP, later */
};

struct LinkState {
    bool        associated = false;
    std::string ssid;
    uint8_t     bssid[6] = {0, 0, 0, 0, 0, 0};
    int32_t     freqMhz  = 0;
    int32_t     rssiDbm  = 0;
    int32_t     txRateKbps = 0;
    int32_t     rxRateKbps = 0;
    std::string ipv4;
};

/*
 * Why the association is in the state it is in.
 *
 * This is separate from LinkState because "not associated" is one state with
 * several very different meanings, and the layer above cannot guess which.
 * Android in particular renders a rejected password quite differently from a
 * failed association -- and it will only do so if it is told specifically, in
 * a specific sequence.  A backend that collapses the two turns "wrong
 * password" into a silent retry loop, so the distinction is carried here
 * rather than reconstructed later.
 *
 * Every host that owns a radio knows this much: NetworkManager reports it as
 * the `reason` argument of Device.StateChanged, iwd as an agent error.
 */
enum class LinkEvent {
    Associated,     /* an association is up and usable */
    Associating,    /* an attempt is in progress */
    AuthFailed,     /* credentials were rejected -- the password is wrong */
    Failed,         /* everything else: no such AP, timed out, radio off */
    Disconnected,   /* an established association ended */
};

const char* linkEventName(LinkEvent e);

/* Bands, in the shape wificond's getAvailable*Channels() asks for them. */
enum class Band {
    Band2g,
    Band5gNonDfs,
    Band5gDfs,
    Band6g,
    Band60g,
};

class WifiBackend {
public:
    virtual ~WifiBackend() = default;

    /*
     * Bring the backend up, and choose the radio in the same breath.
     *
     * `spec` is the radio the operator asked for -- an interface name or a
     * hardware address, see selectDevice() -- or empty to let the backend
     * choose.  A non-empty spec that does not resolve MUST fail: the backend
     * has already had to pick something by then, and carrying on with that
     * after the operator named a different radio is how Android ends up
     * driving the host's own link (trap 5 of docs/33-wifi-stage4.md).
     *
     * The selection is a parameter of init() rather than a call the caller
     * makes afterwards because doing it in two steps is what went wrong
     * before: selectDevice() has to ask the backend whether the device exists,
     * so calling it first silently validated nothing (docs/34, change 3), and
     * calling it second meant the backend auto-selected a radio it was about
     * to be told not to use.  One call cannot be sequenced wrongly.
     */
    virtual bool init(const std::string& spec) = 0;
    virtual const char* name() const = 0;

    /* Radio state.  setEnabled() is rfkill / NM's WirelessEnabled. */
    virtual bool setEnabled(bool on) = 0;
    virtual bool isEnabled() = 0;

    /* Scanning. */
    virtual bool startScan() = 0;
    virtual std::vector<Bss> scanResults() = 0;

    /*
     * Called when a scan the host was asked for has finished, successfully or
     * not.  This is a fact the layer above cannot infer from startScan()
     * returning true, and it needs it: the reader discards every result whose
     * timestamp predates the scan it requested, so announcing results before
     * the host has actually produced any means announcing nothing.
     */
    virtual void onScanComplete(std::function<void(bool ok)> cb) = 0;

    /* Association. */
    virtual bool connect(const NetworkRequest& req) = 0;
    virtual bool disconnect() = 0;
    virtual bool forget(const std::string& ssid) = 0;
    virtual LinkState state() = 0;

    /*
     * Association progress.  One callback carrying both what is true now and
     * why, because that is the shape the host reports it in -- NM's
     * StateChanged emits (new state, old state, reason) together, and splitting
     * them here would only invite the layer above to correlate two streams that
     * arrived as one.
     */
    virtual void onLinkEvent(
        std::function<void(const LinkState&, LinkEvent)> cb) = 0;

    /*
     * Radio selection.  Android sees exactly one interface, so if the host has
     * several radios the choice is made here and never surfaced upwards.
     *
     * selectDevice() takes an interface name OR a hardware address, because on
     * this machine the name is not an identity: wlp0s20u1 encodes a USB port,
     * so the adapter renames itself when it moves.  A backend that cannot
     * resolve an address may reject it, but it should try -- an unattended
     * daemon has nothing else stable to name a radio by.
     */
    virtual std::vector<std::string> devices() = 0;
    virtual bool selectDevice(const std::string& spec) = 0;
    virtual std::string selectedDevice() const = 0;

    /* MAC of the selected device, or all-zero if unknown. */
    virtual void macAddress(uint8_t out[6]) = 0;

    /*
     * Channel lists.  Not in the plan's original fourteen methods; added
     * because IWificond has five getAvailable*Channels() calls and the answer
     * is a property of the host radio, which is exactly what lives below this
     * line.
     */
    virtual std::vector<int32_t> frequencies(Band band) = 0;
};

} /* namespace wifi */
} /* namespace waydroid */
