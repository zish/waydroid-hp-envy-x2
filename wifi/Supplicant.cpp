#include "Supplicant.h"
#include "AidlParcel.h"

#include <gutil_log.h>

#include <cstdio>
#include <cstring>

namespace waydroid {
namespace wifi {

using namespace aidl;

/* --------------------------------------------------------- wire constants */

/*
 * Unshaded, despite the mainline Wi-Fi module being jarjar-shaded.  AIDL's
 * Java backend emits the descriptor as a '$'-separated literal with a
 * .replace('$','.') at runtime precisely so jarjar cannot rewrite it, so the
 * name on the wire is the ordinary dotted one.  Grepping the dex for the
 * dotted form finds nothing and would wrongly suggest the AIDL path is absent
 * -- see docs/30-wifi-aidl-surface.md, finding 2.
 */
#define IFACE_SUPPLICANT    "android.hardware.wifi.supplicant.ISupplicant"
#define IFACE_STA_IFACE     "android.hardware.wifi.supplicant.ISupplicantStaIface"
#define IFACE_STA_NETWORK   "android.hardware.wifi.supplicant.ISupplicantStaNetwork"
#define IFACE_STA_IFACE_CB  "android.hardware.wifi.supplicant.ISupplicantStaIfaceCallback"
#define IFACE_STA_NET_CB    "android.hardware.wifi.supplicant.ISupplicantStaNetworkCallback"

/* The frozen v1 snapshot this shim implements, and its hash, from
 * hardware/interfaces/wifi/supplicant/aidl/aidl_api/.../1/.hash at r75. */
#define SUPPLICANT_AIDL_VERSION 1
#define SUPPLICANT_AIDL_HASH    "5b8bcab6b43177dffdec5873e84205b04757cc9d"

/*
 * Transaction codes.  Positional: code = FIRST_CALL_TRANSACTION + index, and
 * FIRST_CALL_TRANSACTION is 1.  These were read out of THIS image's
 * service-wifi.jar bytecode and matched against AOSP android-13.0.0_r75; the
 * tables are in artifacts/wifi/interface-surface/.  Get one wrong and every
 * call lands on the wrong method, so the full range is enumerated even where
 * the method is refused -- a gap would be indistinguishable from a typo.
 */
enum {
    SUPPLICANT_addP2pInterface          = 1,
    SUPPLICANT_addStaInterface          = 2,
    SUPPLICANT_getDebugLevel            = 3,
    SUPPLICANT_getP2pInterface          = 4,
    SUPPLICANT_getStaInterface          = 5,
    SUPPLICANT_isDebugShowKeysEnabled   = 6,
    SUPPLICANT_isDebugShowTimestampEnabled = 7,
    SUPPLICANT_listInterfaces           = 8,
    SUPPLICANT_registerCallback         = 9,
    SUPPLICANT_removeInterface          = 10,
    SUPPLICANT_setConcurrencyPriority   = 11,
    SUPPLICANT_setDebugParams           = 12,
    SUPPLICANT_terminate                = 13,
};

enum {
    STAIFACE_addDppPeerUri              = 1,
    STAIFACE_addExtRadioWork            = 2,
    STAIFACE_addNetwork                 = 3,
    STAIFACE_addRxFilter                = 4,
    STAIFACE_cancelWps                  = 5,
    STAIFACE_disconnect                 = 6,
    STAIFACE_enableAutoReconnect        = 7,
    STAIFACE_filsHlpAddRequest          = 8,
    STAIFACE_filsHlpFlushRequest        = 9,
    STAIFACE_generateDppBootstrapInfoForResponder = 10,
    STAIFACE_generateSelfDppConfiguration = 11,
    STAIFACE_getConnectionCapabilities  = 12,
    STAIFACE_getConnectionMloLinksInfo  = 13,
    STAIFACE_getKeyMgmtCapabilities     = 14,
    STAIFACE_getMacAddress              = 15,
    STAIFACE_getName                    = 16,
    STAIFACE_getNetwork                 = 17,
    STAIFACE_getType                    = 18,
    STAIFACE_getWpaDriverCapabilities   = 19,
    STAIFACE_initiateAnqpQuery          = 20,
    STAIFACE_initiateHs20IconQuery      = 21,
    STAIFACE_initiateTdlsDiscover       = 22,
    STAIFACE_initiateTdlsSetup          = 23,
    STAIFACE_initiateTdlsTeardown       = 24,
    STAIFACE_initiateVenueUrlAnqpQuery  = 25,
    STAIFACE_listNetworks               = 26,
    STAIFACE_reassociate                = 27,
    STAIFACE_reconnect                  = 28,
    STAIFACE_registerCallback           = 29,
    STAIFACE_setQosPolicyFeatureEnabled = 30,
    STAIFACE_sendQosPolicyResponse      = 31,
    STAIFACE_removeAllQosPolicies       = 32,
    STAIFACE_removeDppUri               = 33,
    STAIFACE_removeExtRadioWork         = 34,
    STAIFACE_removeNetwork              = 35,
    STAIFACE_removeRxFilter             = 36,
    STAIFACE_setBtCoexistenceMode       = 37,
    STAIFACE_setBtCoexistenceScanModeEnabled = 38,
    STAIFACE_setCountryCode             = 39,
    STAIFACE_setExternalSim             = 40,
    STAIFACE_setMboCellularDataStatus   = 41,
    STAIFACE_setPowerSave               = 42,
    STAIFACE_setSuspendModeEnabled      = 43,
    STAIFACE_setWpsConfigMethods        = 44,
    STAIFACE_setWpsDeviceName           = 45,
    STAIFACE_setWpsDeviceType           = 46,
    STAIFACE_setWpsManufacturer         = 47,
    STAIFACE_setWpsModelName            = 48,
    STAIFACE_setWpsModelNumber          = 49,
    STAIFACE_setWpsSerialNumber         = 50,
    STAIFACE_startDppConfiguratorInitiator = 51,
    STAIFACE_startDppEnrolleeInitiator  = 52,
    STAIFACE_startDppEnrolleeResponder  = 53,
    STAIFACE_startRxFilter              = 54,
    STAIFACE_startWpsPbc                = 55,
    STAIFACE_startWpsPinDisplay         = 56,
    STAIFACE_startWpsPinKeypad          = 57,
    STAIFACE_startWpsRegistrar          = 58,
    STAIFACE_stopDppInitiator           = 59,
    STAIFACE_stopDppResponder           = 60,
    STAIFACE_stopRxFilter               = 61,
};

enum {
    STANET_disable                      = 1,
    STANET_enable                       = 2,
    STANET_enableSaePkOnlyMode          = 3,
    STANET_enableSuiteBEapOpenSslCiphers = 4,
    STANET_enableTlsSuiteBEapPhase1Param = 5,
    STANET_getAuthAlg                   = 6,
    STANET_getBssid                     = 7,
    STANET_getEapAltSubjectMatch        = 8,
    STANET_getEapAnonymousIdentity      = 9,
    STANET_getEapCACert                 = 10,
    STANET_getEapCAPath                 = 11,
    STANET_getEapClientCert             = 12,
    STANET_getEapDomainSuffixMatch      = 13,
    STANET_getEapEngine                 = 14,
    STANET_getEapEngineId               = 15,
    STANET_getEapIdentity               = 16,
    STANET_getEapMethod                 = 17,
    STANET_getEapPassword               = 18,
    STANET_getEapPhase2Method           = 19,
    STANET_getEapPrivateKeyId           = 20,
    STANET_getEapSubjectMatch           = 21,
    STANET_getEdmg                      = 22,
    STANET_getGroupCipher               = 23,
    STANET_getGroupMgmtCipher           = 24,
    STANET_getId                        = 25,
    STANET_getIdStr                     = 26,
    STANET_getInterfaceName             = 27,
    STANET_getKeyMgmt                   = 28,
    STANET_getOcsp                      = 29,
    STANET_getPairwiseCipher            = 30,
    STANET_getProto                     = 31,
    STANET_getPsk                       = 32,
    STANET_getPskPassphrase             = 33,
    STANET_getRequirePmf                = 34,
    STANET_getSaePassword               = 35,
    STANET_getSaePasswordId             = 36,
    STANET_getScanSsid                  = 37,
    STANET_getSsid                      = 38,
    STANET_getType                      = 39,
    STANET_getWapiCertSuite             = 40,
    STANET_getWepKey                    = 41,
    STANET_getWepTxKeyIdx               = 42,
    STANET_getWpsNfcConfigurationToken  = 43,
    STANET_registerCallback             = 44,
    STANET_select                       = 45,
    STANET_sendNetworkEapIdentityResponse = 46,
    STANET_sendNetworkEapSimGsmAuthFailure = 47,
    STANET_sendNetworkEapSimGsmAuthResponse = 48,
    STANET_sendNetworkEapSimUmtsAuthFailure = 49,
    STANET_sendNetworkEapSimUmtsAuthResponse = 50,
    STANET_sendNetworkEapSimUmtsAutsResponse = 51,
    STANET_setAuthAlg                   = 52,
    STANET_setBssid                     = 53,
    STANET_setDppKeys                   = 54,
    STANET_setEapAltSubjectMatch        = 55,
    STANET_setEapAnonymousIdentity      = 56,
    STANET_setEapCACert                 = 57,
    STANET_setEapCAPath                 = 58,
    STANET_setEapClientCert             = 59,
    STANET_setEapDomainSuffixMatch      = 60,
    STANET_setEapEncryptedImsiIdentity  = 61,
    STANET_setEapEngine                 = 62,
    STANET_setEapEngineID               = 63,
    STANET_setEapErp                    = 64,
    STANET_setEapIdentity               = 65,
    STANET_setEapMethod                 = 66,
    STANET_setEapPassword               = 67,
    STANET_setEapPhase2Method           = 68,
    STANET_setEapPrivateKeyId           = 69,
    STANET_setEapSubjectMatch           = 70,
    STANET_setEdmg                      = 71,
    STANET_setGroupCipher               = 72,
    STANET_setGroupMgmtCipher           = 73,
    STANET_setIdStr                     = 74,
    STANET_setKeyMgmt                   = 75,
    STANET_setOcsp                      = 76,
    STANET_setPairwiseCipher            = 77,
    STANET_setPmkCache                  = 78,
    STANET_setProactiveKeyCaching       = 79,
    STANET_setProto                     = 80,
    STANET_setPsk                       = 81,
    STANET_setPskPassphrase             = 82,
    STANET_setRequirePmf                = 83,
    STANET_setSaeH2eMode                = 84,
    STANET_setSaePassword               = 85,
    STANET_setSaePasswordId             = 86,
    STANET_setScanSsid                  = 87,
    STANET_setSsid                      = 88,
    STANET_setUpdateIdentifier          = 89,
    STANET_setWapiCertSuite             = 90,
    STANET_setWepKey                    = 91,
    STANET_setWepTxKeyIdx               = 92,
    STANET_setRoamingConsortiumSelection = 93,
};

/*
 * The two callback interfaces we CALL rather than serve.  docs/30 flagged
 * these as the one part of the surface its bytecode method could not verify:
 * the framework holds their Stub, not a Proxy, so there are no transact()
 * sites to read codes from, and the onTransact sparse-switch is not laid out
 * in declaration order either.  They are taken from AOSP declaration order and
 * confirmed at runtime instead -- a wrong code here shows up as the framework
 * simply not reacting to an event, which is exactly what Stage 2 did for
 * IScanEvent.OnScanResultReady before it was confirmed.
 */
enum {
    STAIFACECB_onAnqpQueryDone          = 1,
    STAIFACECB_onAssociationRejected    = 2,
    STAIFACECB_onAuthenticationTimeout  = 3,
    STAIFACECB_onAuxiliarySupplicantEvent = 4,
    STAIFACECB_onBssTmHandlingDone      = 5,
    STAIFACECB_onBssidChanged           = 6,
    STAIFACECB_onDisconnected           = 7,
    STAIFACECB_onDppFailure             = 8,
    STAIFACECB_onDppProgress            = 9,
    STAIFACECB_onDppSuccess             = 10,
    STAIFACECB_onDppSuccessConfigReceived = 11,
    STAIFACECB_onDppSuccessConfigSent   = 12,
    STAIFACECB_onEapFailure             = 13,
    STAIFACECB_onExtRadioWorkStart      = 14,
    STAIFACECB_onExtRadioWorkTimeout    = 15,
    STAIFACECB_onHs20DeauthImminentNotice = 16,
    STAIFACECB_onHs20IconQueryDone      = 17,
    STAIFACECB_onHs20SubscriptionRemediation = 18,
    STAIFACECB_onHs20TermsAndConditionsAcceptanceRequestedNotification = 19,
    STAIFACECB_onNetworkAdded           = 20,
    STAIFACECB_onNetworkNotFound        = 21,
    STAIFACECB_onNetworkRemoved         = 22,
    STAIFACECB_onPmkCacheAdded          = 23,
    STAIFACECB_onStateChanged           = 24,
    STAIFACECB_onWpsEventFail           = 25,
    STAIFACECB_onWpsEventPbcOverlap     = 26,
    STAIFACECB_onWpsEventSuccess        = 27,
    STAIFACECB_onQosPolicyReset         = 28,
    STAIFACECB_onQosPolicyRequest       = 29,
};

/* StaIfaceCallbackState */
enum {
    STATE_DISCONNECTED      = 0,
    STATE_IFACE_DISABLED    = 1,
    STATE_INACTIVE          = 2,
    STATE_SCANNING          = 3,
    STATE_AUTHENTICATING    = 4,
    STATE_ASSOCIATING       = 5,
    STATE_ASSOCIATED        = 6,
    STATE_FOURWAY_HANDSHAKE = 7,
    STATE_GROUP_HANDSHAKE   = 8,
    STATE_COMPLETED         = 9,
};

/* SupplicantStatusCode, for service-specific exceptions. */
enum {
    STATUS_SUCCESS                  = 0,
    STATUS_FAILURE_UNKNOWN          = 1,
    STATUS_FAILURE_ARGS_INVALID     = 2,
    STATUS_FAILURE_IFACE_INVALID    = 3,
    STATUS_FAILURE_IFACE_UNKNOWN    = 4,
    STATUS_FAILURE_IFACE_EXISTS     = 5,
    STATUS_FAILURE_IFACE_DISABLED   = 6,
    STATUS_FAILURE_IFACE_NOT_DISCONNECTED = 7,
    STATUS_FAILURE_NETWORK_INVALID  = 8,
    STATUS_FAILURE_NETWORK_UNKNOWN  = 9,
    STATUS_FAILURE_UNSUPPORTED      = 10,
};

/* KeyMgmtMask */
enum {
    KEYMGMT_WPA_EAP     = 1 << 0,
    KEYMGMT_WPA_PSK     = 1 << 1,
    KEYMGMT_NONE        = 1 << 2,
    KEYMGMT_IEEE8021X   = 1 << 3,
    KEYMGMT_FT_EAP      = 1 << 5,
    KEYMGMT_FT_PSK      = 1 << 6,
    KEYMGMT_WPA_EAP_SHA256 = 1 << 7,
    KEYMGMT_WPA_PSK_SHA256 = 1 << 8,
    KEYMGMT_SAE         = 1 << 10,
    KEYMGMT_WAPI_PSK    = 1 << 12,
    KEYMGMT_WAPI_CERT   = 1 << 13,
    KEYMGMT_OSEN        = 1 << 15,
    KEYMGMT_SUITE_B_192 = 1 << 17,
    KEYMGMT_FILS_SHA256 = 1 << 18,
    KEYMGMT_FILS_SHA384 = 1 << 19,
    KEYMGMT_OWE         = 1 << 22,
    KEYMGMT_DPP         = 1 << 23,
};

/* BssidChangeReason */
enum {
    BSSID_ASSOC_START    = 0,
    BSSID_ASSOC_COMPLETE = 1,
    BSSID_DISASSOC       = 2,
};

/*
 * StaIfaceReasonCode.  Only two are used, and the choice of the second is not
 * arbitrary: SupplicantStaIfaceCallbackAidlImpl.onDisconnected() reports a
 * wrong PSK only when the state before the disconnect was FOURWAY_HANDSHAKE
 * and the reason is anything OTHER than IE_IN_4WAY_DIFFERS (17).
 */
#define REASON_DEAUTH_LEAVING           3
#define REASON_FOURWAY_HANDSHAKE_TIMEOUT 15

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
 * The honest refusal.  A stable-AIDL method that cannot do what it says has
 * one correct answer -- a service-specific exception -- and the framework
 * turns it into `false` from the corresponding HAL method.  Returning success
 * instead would claim we had, say, run a WPS exchange.
 */
static GBinderLocalReply*
refuse(GBinderLocalObject* obj, int* status, int32_t code, const char* what)
{
    GBinderLocalReply* reply = gbinder_local_object_new_reply(obj);
    GBinderWriter w;

    gbinder_local_reply_init_writer(reply, &w);
    writeServiceSpecificError(&w, code, what);
    *status = GBINDER_STATUS_OK;
    return reply;
}

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

/*
 * getInterfaceVersion / getInterfaceHash.  Every stable-AIDL interface answers
 * these, and they are the same answer for all three of ours because all three
 * come from one frozen package version.
 */
static GBinderLocalReply*
metaTransaction(GBinderLocalObject* obj, guint code, int* status, bool* handled)
{
    GBinderWriter w;

    *handled = true;
    if (code == AIDL_TRANSACTION_getInterfaceVersion) {
        GBinderLocalReply* reply = beginReply(obj, &w, status);
        gbinder_writer_append_int32(&w, SUPPLICANT_AIDL_VERSION);
        return reply;
    }
    if (code == AIDL_TRANSACTION_getInterfaceHash) {
        GBinderLocalReply* reply = beginReply(obj, &w, status);
        writeString(&w, SUPPLICANT_AIDL_HASH);
        return reply;
    }
    *handled = false;
    return nullptr;
}

static std::string
macToString(const uint8_t mac[6])
{
    char buf[18];

    snprintf(buf, sizeof(buf), "%02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    return buf;
}

/* ------------------------------------------------------------- lifecycle */

Supplicant::Supplicant(GBinderServiceManager* sm, WifiBackend* backend) :
    mSm(sm), mBackend(backend)
{
    mSupplicant = gbinder_servicemanager_new_local_object(sm, IFACE_SUPPLICANT,
        onSupplicant, this);

    mBackend->onLinkEvent([this](const LinkState& st, LinkEvent ev) {
        onHostLinkEvent(st, ev);
    });
}

Supplicant::~Supplicant()
{
    /* The backend holds a std::function capturing this; drop it first. */
    mBackend->onLinkEvent(nullptr);
    dropIfaceCallback();
    dropNetworkCallback();
    if (mStaNetwork) {
        gbinder_local_object_drop(mStaNetwork);
    }
    if (mStaIface) {
        gbinder_local_object_drop(mStaIface);
    }
    if (mSupplicant) {
        gbinder_local_object_drop(mSupplicant);
    }
}

void
Supplicant::ensureStaIface()
{
    if (!mStaIface) {
        mStaIface = gbinder_servicemanager_new_local_object(mSm,
            IFACE_STA_IFACE, onStaIface, this);
    }
}

void
Supplicant::dropIfaceCallback()
{
    if (mIfaceCallbackClient) {
        gbinder_client_unref(mIfaceCallbackClient);
        mIfaceCallbackClient = nullptr;
    }
    if (mIfaceCallback) {
        gbinder_remote_object_unref(mIfaceCallback);
        mIfaceCallback = nullptr;
    }
    mReportedState = -1;
}

void
Supplicant::dropNetworkCallback()
{
    if (mNetworkCallbackClient) {
        gbinder_client_unref(mNetworkCallbackClient);
        mNetworkCallbackClient = nullptr;
    }
    if (mNetworkCallback) {
        gbinder_remote_object_unref(mNetworkCallback);
        mNetworkCallback = nullptr;
    }
}

/* ------------------------------------------------------------ ISupplicant */

GBinderLocalReply*
Supplicant::onSupplicant(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Supplicant*) user)->handleSupplicant(req, code, status);
}

GBinderLocalReply*
Supplicant::handleSupplicant(GBinderRemoteRequest* req, guint code, int* status)
{
    GBinderReader reader;
    GBinderWriter writer;
    bool handled = false;

    *status = GBINDER_STATUS_FAILED;

    GBinderLocalReply* meta = metaTransaction(mSupplicant, code, status,
        &handled);
    if (handled) {
        return meta;
    }
    if (!ifaceOk(req, IFACE_SUPPLICANT, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case SUPPLICANT_addStaInterface: {
        /*
         * The one load-bearing call on this interface.  Its failure is what
         * kept the master toggle off for all of Stages 2 and 3:
         * setupInterfaceForClientInConnectivityMode() calls startSupplicant()
         * before it ever reaches wificond.
         */
        mIfaceName = readString(&reader);
        ensureStaIface();
        GINFO("addStaInterface(%s) -> serving ISupplicantStaIface",
              mIfaceName.c_str());

        GBinderLocalReply* reply = beginReply(mSupplicant, &writer, status);
        gbinder_writer_append_local_object(&writer, mStaIface);
        return reply;
    }

    case SUPPLICANT_getStaInterface: {
        std::string name = readString(&reader);
        if (!mStaIface || name != mIfaceName) {
            return refuse(mSupplicant, status, STATUS_FAILURE_IFACE_UNKNOWN,
                          "no such STA interface");
        }
        GBinderLocalReply* reply = beginReply(mSupplicant, &writer, status);
        gbinder_writer_append_local_object(&writer, mStaIface);
        return reply;
    }

    case SUPPLICANT_listInterfaces: {
        /*
         * IfaceInfo[] -- a stable-AIDL parcelable, so each element is
         * length-prefixed: int32 total size (including itself), then the
         * fields in declaration order (IfaceType type, String name).
         */
        GBinderLocalReply* reply = beginReply(mSupplicant, &writer, status);
        if (mStaIface) {
            gbinder_writer_append_int32(&writer, 1);
            gbinder_writer_append_int32(&writer, 4 + 4 +
                4 + 2 * (gint32) (mIfaceName.size() + 1));
            gbinder_writer_append_int32(&writer, 0);    /* IfaceType.STA */
            writeString(&writer, mIfaceName);
        } else {
            gbinder_writer_append_int32(&writer, 0);
        }
        return reply;
    }

    case SUPPLICANT_removeInterface: {
        GINFO("removeInterface()");
        dropIfaceCallback();
        dropNetworkCallback();
        if (mStaNetwork) {
            gbinder_local_object_drop(mStaNetwork);
            mStaNetwork = nullptr;
        }
        mHaveNetwork = false;
        return beginReply(mSupplicant, &writer, status);
    }

    /*
     * Debug and concurrency knobs.  These are genuinely ours to accept: they
     * describe supplicant-internal policy that has no equivalent below the
     * WifiBackend seam, so there is nothing to delegate and nothing to fake.
     */
    case SUPPLICANT_setDebugParams:
    case SUPPLICANT_setConcurrencyPriority:
        return beginReply(mSupplicant, &writer, status);

    case SUPPLICANT_getDebugLevel: {
        GBinderLocalReply* reply = beginReply(mSupplicant, &writer, status);
        gbinder_writer_append_int32(&writer, 3);        /* DebugLevel.INFO */
        return reply;
    }

    case SUPPLICANT_isDebugShowKeysEnabled:
    case SUPPLICANT_isDebugShowTimestampEnabled: {
        GBinderLocalReply* reply = beginReply(mSupplicant, &writer, status);
        writeBool(&writer, false);
        return reply;
    }

    case SUPPLICANT_registerCallback: {
        /* ISupplicantCallback only reports interface add/remove, which the
         * framework already knows because it asked for them.  R8 stripped the
         * proxy for this method, so it is never actually called -- but the
         * object still has to be released, or holding a reference to the
         * framework's callback would keep it alive for the process lifetime. */
        GBinderRemoteObject* cb = gbinder_reader_read_object(&reader);
        if (cb) {
            gbinder_remote_object_unref(cb);
        }
        return beginReply(mSupplicant, &writer, status);
    }

    case SUPPLICANT_terminate:
        /*
         * Emphatically not exit().  Android calls this when it stops the
         * supplicant, but this process also serves wificond, and the daemon
         * outliving a Wi-Fi off/on cycle is the whole point -- docs/32 records
         * that a restart leaves WifiNl80211Manager caching the failure.
         */
        GINFO("terminate() -- tearing down the supplicant side only");
        dropIfaceCallback();
        dropNetworkCallback();
        return beginReply(mSupplicant, &writer, status);

    /* P2P is explicitly out of scope; Wi-Fi Direct is not a goal. */
    case SUPPLICANT_addP2pInterface:
    case SUPPLICANT_getP2pInterface:
        return refuse(mSupplicant, status, STATUS_FAILURE_UNSUPPORTED,
                      "P2P is out of scope");

    default:
        GWARN("unknown ISupplicant transaction %u", code);
        return nullptr;
    }
}

/* ----------------------------------------------------- ISupplicantStaIface */

GBinderLocalReply*
Supplicant::onStaIface(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Supplicant*) user)->handleStaIface(req, code, status);
}

GBinderLocalReply*
Supplicant::handleStaIface(GBinderRemoteRequest* req, guint code, int* status)
{
    GBinderReader reader;
    GBinderWriter writer;
    bool handled = false;

    *status = GBINDER_STATUS_FAILED;

    GBinderLocalReply* meta = metaTransaction(mStaIface, code, status,
        &handled);
    if (handled) {
        return meta;
    }
    if (!ifaceOk(req, IFACE_STA_IFACE, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case STAIFACE_registerCallback: {
        /*
         * Load-bearing: setupIface() returns false if this fails, and that
         * fails the whole client-mode setup.  It is also the channel every
         * connection result comes back on.
         */
        dropIfaceCallback();
        mIfaceCallback = gbinder_reader_read_object(&reader);
        if (mIfaceCallback) {
            mIfaceCallbackClient = gbinder_client_new(mIfaceCallback,
                IFACE_STA_IFACE_CB);
            GINFO("registerCallback() -- iface events will be delivered");
        } else {
            GWARN("registerCallback() with a null handler");
        }
        return beginReply(mStaIface, &writer, status);
    }

    case STAIFACE_addNetwork: {
        if (!mStaNetwork) {
            mStaNetwork = gbinder_servicemanager_new_local_object(mSm,
                IFACE_STA_NETWORK, onStaNetwork, this);
        }
        mNetwork = Network();
        mNetwork.id = mNextNetworkId++;
        mHaveNetwork = true;
        GINFO("addNetwork() -> id %d", mNetwork.id);

        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_local_object(&writer, mStaNetwork);
        sendNetworkAdded(mNetwork.id);
        return reply;
    }

    case STAIFACE_getNetwork: {
        int32_t id = readInt32(&reader);
        if (!mHaveNetwork || id != mNetwork.id || !mStaNetwork) {
            return refuse(mStaIface, status, STATUS_FAILURE_NETWORK_UNKNOWN,
                          "no such network");
        }
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_local_object(&writer, mStaNetwork);
        return reply;
    }

    case STAIFACE_listNetworks: {
        std::vector<int32_t> ids;
        if (mHaveNetwork) {
            ids.push_back(mNetwork.id);
        }
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        writeInt32Array(&writer, ids);
        return reply;
    }

    case STAIFACE_removeNetwork: {
        int32_t id = readInt32(&reader);
        if (!mHaveNetwork || id != mNetwork.id) {
            return refuse(mStaIface, status, STATUS_FAILURE_NETWORK_UNKNOWN,
                          "no such network");
        }
        GDEBUG("removeNetwork(%d)", id);
        mHaveNetwork = false;
        dropNetworkCallback();
        return beginReply(mStaIface, &writer, status);
    }

    case STAIFACE_disconnect: {
        GINFO("disconnect()");
        mConnecting = false;
        mBackend->disconnect();
        return beginReply(mStaIface, &writer, status);
    }

    case STAIFACE_reconnect:
    case STAIFACE_reassociate: {
        GINFO("%s()", code == STAIFACE_reconnect ? "reconnect" : "reassociate");
        if (mHaveNetwork) {
            selectNetwork();
        }
        return beginReply(mStaIface, &writer, status);
    }

    case STAIFACE_getMacAddress: {
        /*
         * The host radio's MAC, not the container's wlan0.  The association
         * genuinely happens on wlp1s0, and this is the address that appears in
         * the AP's association table -- the same view the scan results already
         * present.  Android does not attempt to change it: with no vendor HAL
         * there is no IWifiStaIface.setMacAddress to call, so MAC randomisation
         * is skipped rather than silently ignored.
         */
        uint8_t mac[6];
        mBackend->macAddress(mac);
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        writeByteArray(&writer, mac, sizeof(mac));
        return reply;
    }

    case STAIFACE_getName: {
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        writeString(&writer, mIfaceName.empty() ? "wlan0" : mIfaceName);
        return reply;
    }

    case STAIFACE_getType: {
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_int32(&writer, 0);        /* IfaceType.STA */
        return reply;
    }

    case STAIFACE_getKeyMgmtCapabilities: {
        /*
         * What the HOST can associate with, which is the honest reading of the
         * question -- NetworkManager and its own supplicant do all of these.
         * Advertising SAE matters: without it the framework will not offer
         * WPA3 security params, and a WPA2/WPA3 transition AP (which docs/32
         * had to learn to describe correctly) would be joined as PSK only.
         */
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_int32(&writer, KEYMGMT_NONE | KEYMGMT_WPA_PSK |
            KEYMGMT_WPA_EAP | KEYMGMT_IEEE8021X | KEYMGMT_SAE | KEYMGMT_OWE);
        return reply;
    }

    case STAIFACE_getWpaDriverCapabilities: {
        /* No MBO, OCE, SAE-PK, WFD-R2 or trust-on-first-use.  Nothing below
         * the seam reports them, so claiming them would be invention. */
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_int32(&writer, 0);
        return reply;
    }

    case STAIFACE_getConnectionCapabilities: {
        /*
         * ConnectionCapabilities, a five-int stable-AIDL parcelable, all
         * unknown: NetworkManager reports a bitrate but not the PHY mode,
         * bandwidth or spatial streams.  Answered rather than refused because
         * ClientModeImpl stores the result unconditionally after every
         * connection.
         *
         * THE LEADING 1 IS NOT OPTIONAL, AND OMITTING IT KILLED system_server.
         *
         * A parcelable RETURN VALUE is read with Parcel.readTypedObject(), which
         * reads a non-null marker int32 first and only then calls
         * createFromParcel().  Without the marker, Java consumed the size field
         * as the marker -- non-zero, so it happily continued -- and then read
         * the first field, technology=0, as the parcelable's size.  Zero is
         * less than the four bytes of the size word itself, so
         * ConnectionCapabilities.readFromParcel() threw BadParcelableException
         * ("Parcelable too small") on WifiHandlerThread, and an uncaught
         * exception on a system_server handler thread is a system_server death:
         * every app died with DeadSystemException, wificond came back with the
         * restart and stole "wifinl80211" again, and Wi-Fi could not be
         * re-enabled afterwards.  The visible symptom was three layers away
         * from the cause.
         *
         * ClientModeImpl calls this from updateWifiInfoLinkParamsAfterAssociation(),
         * i.e. on EVERY successful association -- so this was not an edge case,
         * it was the guaranteed outcome of the thing Stage 4 exists to do.
         *
         * NativeScanResult.cpp already did this correctly for its list elements
         * (see the note at its non-null flag), which is why Stage 3 never hit it.
         * Arrays are different again: listInterfaces() above writes a LENGTH
         * there, not a marker, because createTypedArray() is length-prefixed.
         */
        GBinderLocalReply* reply = beginReply(mStaIface, &writer, status);
        gbinder_writer_append_int32(&writer, 1);         /* non-null marker */
        gbinder_writer_append_int32(&writer, 4 + 5 * 4); /* parcelable size */
        gbinder_writer_append_int32(&writer, 0);        /* technology UNKNOWN */
        gbinder_writer_append_int32(&writer, 0);        /* channelBandwidth 20 */
        gbinder_writer_append_int32(&writer, 1);        /* max tx streams */
        gbinder_writer_append_int32(&writer, 1);        /* max rx streams */
        gbinder_writer_append_int32(&writer, 0);        /* legacyMode UNKNOWN */
        return reply;
    }

    /*
     * Radio and station policy that the host genuinely owns.  NetworkManager
     * and the kernel decide power save, regulatory domain, suspend behaviour
     * and BT coexistence for wlp1s0, and they do so for the whole machine, not
     * for Android's session.  Accepting is not a fake: the policy really is
     * applied, just not by us and not only for this caller.
     */
    case STAIFACE_setPowerSave:
    case STAIFACE_setSuspendModeEnabled:
    case STAIFACE_setCountryCode:
    case STAIFACE_setBtCoexistenceMode:
    case STAIFACE_setBtCoexistenceScanModeEnabled:
    case STAIFACE_enableAutoReconnect:
    case STAIFACE_setMboCellularDataStatus:
        GDEBUG("staIface: accepting host-owned policy call %u", code);
        return beginReply(mStaIface, &writer, status);

    /*
     * Everything below is refused, and the refusals are the interesting part
     * of the interface rather than an oversight:
     *
     *   WPS, DPP        provisioning protocols that need to drive the radio's
     *                   own state machine; NM exposes no equivalent.
     *   TDLS, ANQP,     peer-to-peer and Hotspot 2.0 queries that require
     *   Hs20            frames we cannot send.
     *   RX filters,     driver-level knobs with no D-Bus surface at all.
     *   ext radio work
     *   EAP-SIM, QoS    unreachable without a SIM stack and a QoS-aware
     *   policies        driver respectively.
     */
    case STAIFACE_addDppPeerUri:
    case STAIFACE_removeDppUri:
    case STAIFACE_startDppConfiguratorInitiator:
    case STAIFACE_startDppEnrolleeInitiator:
    case STAIFACE_startDppEnrolleeResponder:
    case STAIFACE_stopDppInitiator:
    case STAIFACE_stopDppResponder:
    case STAIFACE_generateDppBootstrapInfoForResponder:
    case STAIFACE_generateSelfDppConfiguration:
    case STAIFACE_startWpsPbc:
    case STAIFACE_startWpsPinDisplay:
    case STAIFACE_startWpsPinKeypad:
    case STAIFACE_startWpsRegistrar:
    case STAIFACE_cancelWps:
    case STAIFACE_setWpsConfigMethods:
    case STAIFACE_setWpsDeviceName:
    case STAIFACE_setWpsDeviceType:
    case STAIFACE_setWpsManufacturer:
    case STAIFACE_setWpsModelName:
    case STAIFACE_setWpsModelNumber:
    case STAIFACE_setWpsSerialNumber:
    case STAIFACE_initiateTdlsDiscover:
    case STAIFACE_initiateTdlsSetup:
    case STAIFACE_initiateTdlsTeardown:
    case STAIFACE_initiateAnqpQuery:
    case STAIFACE_initiateVenueUrlAnqpQuery:
    case STAIFACE_initiateHs20IconQuery:
    case STAIFACE_addRxFilter:
    case STAIFACE_removeRxFilter:
    case STAIFACE_startRxFilter:
    case STAIFACE_stopRxFilter:
    case STAIFACE_addExtRadioWork:
    case STAIFACE_removeExtRadioWork:
    case STAIFACE_setExternalSim:
    case STAIFACE_filsHlpAddRequest:
    case STAIFACE_filsHlpFlushRequest:
    case STAIFACE_setQosPolicyFeatureEnabled:
    case STAIFACE_sendQosPolicyResponse:
    case STAIFACE_removeAllQosPolicies:
    case STAIFACE_getConnectionMloLinksInfo:
        GDEBUG("staIface: refusing unsupported call %u", code);
        return refuse(mStaIface, status, STATUS_FAILURE_UNSUPPORTED,
                      "not supported by the NetworkManager backend");

    default:
        GWARN("unknown ISupplicantStaIface transaction %u", code);
        return nullptr;
    }
}

/* --------------------------------------------------- ISupplicantStaNetwork */

GBinderLocalReply*
Supplicant::onStaNetwork(GBinderLocalObject* obj, GBinderRemoteRequest* req,
    guint code, guint flags, int* status, void* user)
{
    return ((Supplicant*) user)->handleStaNetwork(req, code, status);
}

GBinderLocalReply*
Supplicant::handleStaNetwork(GBinderRemoteRequest* req, guint code, int* status)
{
    GBinderReader reader;
    GBinderWriter writer;
    bool handled = false;

    *status = GBINDER_STATUS_FAILED;

    GBinderLocalReply* meta = metaTransaction(mStaNetwork, code, status,
        &handled);
    if (handled) {
        return meta;
    }
    if (!ifaceOk(req, IFACE_STA_NETWORK, code)) {
        return nullptr;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {

    /* ---- the setters saveWifiConfiguration() walks, in its own order ---- */

    case STANET_setSsid: {
        std::vector<uint8_t> ssid = readByteArray(&reader);
        mNetwork.ssid.assign(ssid.begin(), ssid.end());
        GINFO("setSsid(%s)", mNetwork.ssid.c_str());
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_setBssid: {
        std::vector<uint8_t> b = readByteArray(&reader);
        if (b.size() == 6) {
            memcpy(mNetwork.bssid, b.data(), 6);
            /*
             * All-zero means "any BSSID"; the framework uses it to clear a
             * previous pin rather than to ask for the zero address.
             */
            mNetwork.haveBssid = memcmp(mNetwork.bssid,
                "\0\0\0\0\0\0", 6) != 0;
            GDEBUG("setBssid(%s)", macToString(mNetwork.bssid).c_str());
        }
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_setScanSsid:
        mNetwork.scanSsid = readBool(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setRequirePmf:
        mNetwork.requirePmf = readBool(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setKeyMgmt:
        mNetwork.keyMgmt = readInt32(&reader);
        GDEBUG("setKeyMgmt(0x%x)", mNetwork.keyMgmt);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setProto:
        mNetwork.proto = readInt32(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setAuthAlg:
        mNetwork.authAlg = readInt32(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setGroupCipher:
        mNetwork.groupCipher = readInt32(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setPairwiseCipher:
        mNetwork.pairwiseCipher = readInt32(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_setPskPassphrase: {
        /*
         * This is the call the whole goal rests on: the passphrase the user
         * typed into Android's Wi-Fi dialog, in the clear, on its way to
         * NetworkManager.  Never logged -- the value, that is; that it
         * arrived is worth knowing.
         */
        mNetwork.passphrase = readString(&reader);
        GINFO("setPskPassphrase(<%zu chars>)", mNetwork.passphrase.size());
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_setSaePassword: {
        mNetwork.saePassword = readString(&reader);
        GINFO("setSaePassword(<%zu chars>)", mNetwork.saePassword.size());
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_setPsk: {
        /*
         * A raw 32-byte PMK rather than a passphrase.  NM accepts it as a
         * 64-character hex string in the same 'psk' property.
         */
        std::vector<uint8_t> psk = readByteArray(&reader);
        char hex[3];
        mNetwork.pskHex.clear();
        for (uint8_t b : psk) {
            snprintf(hex, sizeof(hex), "%02x", b);
            mNetwork.pskHex += hex;
        }
        GINFO("setPsk(<%zu bytes>)", psk.size());
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_setIdStr:
        mNetwork.idStr = readString(&reader);
        return beginReply(mStaNetwork, &writer, status);

    case STANET_registerCallback: {
        dropNetworkCallback();
        mNetworkCallback = gbinder_reader_read_object(&reader);
        if (mNetworkCallback) {
            mNetworkCallbackClient = gbinder_client_new(mNetworkCallback,
                IFACE_STA_NET_CB);
        }
        GDEBUG("network registerCallback()");
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_select: {
        /*
         * The commit point.  Everything above merely accumulated; this is the
         * one call that crosses the WifiBackend seam and asks the host to
         * associate.  It answers immediately and reports the outcome through
         * ISupplicantStaIfaceCallback, because that is what the framework
         * waits on -- a synchronous "true" here means "the request was
         * accepted", not "you are connected".
         */
        GINFO("select() -> connecting to \"%s\"", mNetwork.ssid.c_str());
        bool ok = selectNetwork();
        if (!ok) {
            return refuse(mStaNetwork, status, STATUS_FAILURE_UNKNOWN,
                          "the host backend refused the connection");
        }
        return beginReply(mStaNetwork, &writer, status);
    }

    case STANET_enable:
        readBool(&reader);              /* noConnect */
        return beginReply(mStaNetwork, &writer, status);

    case STANET_disable:
        mConnecting = false;
        mBackend->disconnect();
        return beginReply(mStaNetwork, &writer, status);

    /* ---- getters: read back what we were told, nothing invented ---- */

    case STANET_getId: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.id);
        return reply;
    }

    case STANET_getSsid: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeByteArray(&writer, mNetwork.ssid.data(),
                       (int32_t) mNetwork.ssid.size());
        return reply;
    }

    case STANET_getBssid: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeByteArray(&writer, mNetwork.bssid, 6);
        return reply;
    }

    case STANET_getIdStr: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeString(&writer, mNetwork.idStr);
        return reply;
    }

    case STANET_getInterfaceName: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeString(&writer, mIfaceName.empty() ? "wlan0" : mIfaceName);
        return reply;
    }

    case STANET_getType: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, 0);        /* IfaceType.STA */
        return reply;
    }

    case STANET_getKeyMgmt: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.keyMgmt);
        return reply;
    }

    case STANET_getProto: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.proto);
        return reply;
    }

    case STANET_getAuthAlg: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.authAlg);
        return reply;
    }

    case STANET_getGroupCipher: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.groupCipher);
        return reply;
    }

    case STANET_getPairwiseCipher: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        gbinder_writer_append_int32(&writer, mNetwork.pairwiseCipher);
        return reply;
    }

    case STANET_getScanSsid: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeBool(&writer, mNetwork.scanSsid);
        return reply;
    }

    case STANET_getRequirePmf: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeBool(&writer, mNetwork.requirePmf);
        return reply;
    }

    case STANET_getPskPassphrase: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeString(&writer, mNetwork.passphrase);
        return reply;
    }

    case STANET_getSaePassword: {
        GBinderLocalReply* reply = beginReply(mStaNetwork, &writer, status);
        writeString(&writer, mNetwork.saePassword);
        return reply;
    }

    /*
     * Accepted no-ops: preferences about how to run an association we are not
     * the ones running.  NetworkManager and its own supplicant apply their
     * equivalents; refusing would fail saveWifiConfiguration() outright for
     * setSaeH2eMode, which the framework calls for every SAE network.
     */
    case STANET_setSaeH2eMode:
    case STANET_setProactiveKeyCaching:
    case STANET_setUpdateIdentifier:
    case STANET_setEdmg:
    case STANET_enableSaePkOnlyMode:
    case STANET_setGroupMgmtCipher:
    case STANET_setOcsp:
        return beginReply(mStaNetwork, &writer, status);

    /*
     * WEP is refused rather than accepted-and-ignored.  NM can still join a
     * WEP network, but nothing in this shim carries the key across, so
     * accepting would produce a connection attempt guaranteed to fail with
     * no explanation.  Better to fail where the reason is visible.
     */
    case STANET_setWepKey:
    case STANET_setWepTxKeyIdx:
    case STANET_getWepKey:
    case STANET_getWepTxKeyIdx:
        return refuse(mStaNetwork, status, STATUS_FAILURE_UNSUPPORTED,
                      "WEP is not carried across the NetworkManager backend");

    default:
        /*
         * The whole EAP surface, the EAP-SIM responses, PMK caching, WAPI,
         * DPP keys and the remaining getters.  Enterprise Wi-Fi is a Stage 5
         * question -- it needs certificates and identities moved across the
         * seam, which is a design problem, not a marshalling one.
         */
        if (code >= STANET_disable && code <= STANET_setRoamingConsortiumSelection) {
            GDEBUG("staNetwork: refusing unsupported call %u", code);
            return refuse(mStaNetwork, status, STATUS_FAILURE_UNSUPPORTED,
                          "not supported by the NetworkManager backend");
        }
        GWARN("unknown ISupplicantStaNetwork transaction %u", code);
        return nullptr;
    }
}

/* ------------------------------------------------- crossing the seam */

/*
 * Translate the key management mask the framework set into the backend's
 * vocabulary.  The framework has already decided which security type it wants
 * -- these masks come from SecurityParams, not from the scan -- so this is a
 * translation, not a negotiation.
 */
Security
Supplicant::securityFromNetwork() const
{
    const int32_t km = mNetwork.keyMgmt;

    if (km & KEYMGMT_SAE) {
        /* PSK and SAE together is the transition case, and the framework does
         * offer both when the AP advertises both -- see docs/32. */
        return (km & (KEYMGMT_WPA_PSK | KEYMGMT_WPA_PSK_SHA256)) ?
            Security::Wpa2Wpa3Psk : Security::Wpa3Sae;
    }
    if (km & (KEYMGMT_WPA_EAP | KEYMGMT_IEEE8021X | KEYMGMT_WPA_EAP_SHA256 |
              KEYMGMT_FT_EAP | KEYMGMT_SUITE_B_192)) {
        return Security::Wpa2Eap;
    }
    if (km & (KEYMGMT_WPA_PSK | KEYMGMT_WPA_PSK_SHA256 | KEYMGMT_FT_PSK)) {
        /* WPA vs WPA2 is the ProtoMask, not the key management. */
        return (mNetwork.proto & 0x2) ? Security::Wpa2Psk : Security::WpaPsk;
    }
    return Security::Open;
}

bool
Supplicant::selectNetwork()
{
    NetworkRequest req;

    if (mNetwork.ssid.empty()) {
        GWARN("select() with no SSID set");
        return false;
    }

    req.ssid = mNetwork.ssid;
    req.security = securityFromNetwork();
    if (!mNetwork.passphrase.empty()) {
        req.passphrase = mNetwork.passphrase;
    } else if (!mNetwork.saePassword.empty()) {
        req.passphrase = mNetwork.saePassword;
    } else if (!mNetwork.pskHex.empty()) {
        req.passphrase = mNetwork.pskHex;
    }

    GINFO("connecting: ssid=\"%s\" security=%s passphrase=%s",
          req.ssid.c_str(), securityName(req.security),
          req.passphrase.empty() ? "none" : "yes");

    mConnecting = true;

    /*
     * Announce ASSOCIATING before asking, not after.  The framework starts its
     * connection timeout when it calls select(), and a host that takes a
     * second to answer would otherwise look like a supplicant that never
     * responded at all.
     */
    sendStateChanged(STATE_ASSOCIATING, mNetwork.bssid);

    if (!mBackend->connect(req)) {
        GWARN("the backend refused to connect to \"%s\"", req.ssid.c_str());
        mConnecting = false;
        sendStateChanged(STATE_DISCONNECTED, mNetwork.bssid);
        sendDisconnected(mNetwork.bssid, true, REASON_DEAUTH_LEAVING);
        return false;
    }
    return true;
}

/*
 * The host's link events, mapped onto the states Android's supplicant state
 * machine expects.  Two things make this less mechanical than it looks:
 *
 *   - The framework reacts to TRANSITIONS.  Re-sending COMPLETED is not a
 *     harmless repeat: it re-broadcasts NETWORK_CONNECTION_EVENT and restarts
 *     L3 provisioning.  Hence mReportedState.
 *
 *   - A failed association has to arrive as a specific SHAPE, not just as a
 *     failure.  SupplicantStaIfaceCallbackAidlImpl.onDisconnected() reports a
 *     wrong password only when the state before the disconnect was
 *     FOURWAY_HANDSHAKE, the network is PSK, and the disconnect was not
 *     locally generated.  So AuthFailed has to walk Android THROUGH the
 *     handshake state it never actually reached -- otherwise the user gets a
 *     silent retry loop instead of "Wrong password".  That is a deliberate
 *     fiction and the only one in this file: the four-way handshake really did
 *     happen, on wlp1s0, and really did fail on the key.
 */
void
Supplicant::onHostLinkEvent(const LinkState& st, LinkEvent ev)
{
    const uint8_t* bssid = st.associated ? st.bssid : mNetwork.bssid;

    GDEBUG("host link event: %s (associated=%d)", linkEventName(ev),
           st.associated);

    switch (ev) {
    case LinkEvent::Associating:
        if (mReportedState != STATE_ASSOCIATING &&
            mReportedState != STATE_COMPLETED) {
            sendStateChanged(STATE_ASSOCIATING, bssid);
        }
        return;

    case LinkEvent::Associated:
        if (mReportedState != STATE_COMPLETED) {
            GINFO("host associated to \"%s\" -- reporting COMPLETED",
                  st.ssid.c_str());
            sendStateChanged(STATE_ASSOCIATED, bssid);
            sendBssidChanged(BSSID_ASSOC_COMPLETE, bssid);
            sendStateChanged(STATE_COMPLETED, bssid);
        }
        mConnecting = false;
        return;

    case LinkEvent::AuthFailed:
        GINFO("host rejected the credentials for \"%s\"",
              mNetwork.ssid.c_str());
        sendStateChanged(STATE_FOURWAY_HANDSHAKE, bssid);
        sendStateChanged(STATE_DISCONNECTED, bssid);
        sendDisconnected(bssid, false, REASON_FOURWAY_HANDSHAKE_TIMEOUT);
        mConnecting = false;
        return;

    case LinkEvent::Failed:
        GINFO("host failed to associate with \"%s\"", mNetwork.ssid.c_str());
        sendStateChanged(STATE_DISCONNECTED, bssid);
        sendDisconnected(bssid, false, REASON_DEAUTH_LEAVING);
        mConnecting = false;
        return;

    case LinkEvent::Disconnected:
        /*
         * Only interesting if Android believes it is connected.  NM emits
         * DISCONNECTED on its way into every new association too, and
         * forwarding those would tear down a connection that is being set up.
         */
        if (mReportedState == STATE_COMPLETED) {
            GINFO("host lost its association -- reporting DISCONNECTED");
            sendStateChanged(STATE_DISCONNECTED, bssid);
            sendDisconnected(bssid, false, REASON_DEAUTH_LEAVING);
        }
        mConnecting = false;
        return;
    }
}

/*
 * onAuthenticationTimeout.  Not used by the NetworkManager backend -- NM
 * reports a credential rejection as NO_SECRETS, which onHostLinkEvent turns
 * into the FOURWAY_HANDSHAKE + onDisconnected sequence above, and that is what
 * produces "Wrong password" rather than "Could not connect".  Kept because a
 * backend that CAN distinguish an 802.11 authentication timeout from a key
 * failure should say so, and this is the call that says it.
 */
void
Supplicant::sendAuthTimeout(const uint8_t bssid[6])
{
    if (!mIfaceCallbackClient) {
        return;
    }
    GBinderLocalRequest* req = gbinder_client_new_request(mIfaceCallbackClient);
    GBinderWriter w;

    gbinder_local_request_init_writer(req, &w);
    writeByteArray(&w, bssid, 6);
    gbinder_client_transact_sync_oneway(mIfaceCallbackClient,
        STAIFACECB_onAuthenticationTimeout, req);
    gbinder_local_request_unref(req);
}

/* ------------------------------------------------------ callback senders */

void
Supplicant::sendStateChanged(int32_t state, const uint8_t bssid[6])
{
    if (!mIfaceCallbackClient) {
        GDEBUG("state %d, but nobody has registered a callback", state);
        return;
    }

    GBinderLocalRequest* req = gbinder_client_new_request(mIfaceCallbackClient);
    GBinderWriter w;

    gbinder_local_request_init_writer(req, &w);
    gbinder_writer_append_int32(&w, state);
    writeByteArray(&w, bssid, 6);
    gbinder_writer_append_int32(&w, mNetwork.id);
    writeByteArray(&w, mNetwork.ssid.data(), (int32_t) mNetwork.ssid.size());
    writeBool(&w, false);               /* filsHlpSent */

    GDEBUG("-> onStateChanged(%d)", state);
    int status = gbinder_client_transact_sync_oneway(mIfaceCallbackClient,
        STAIFACECB_onStateChanged, req);
    if (status != GBINDER_STATUS_OK) {
        GWARN("onStateChanged failed: %d", status);
    }
    gbinder_local_request_unref(req);

    /* DISCONNECTED deliberately does not become the remembered state: the
     * framework tracks the state BEFORE a disconnect to classify it, and so
     * must we, or a wrong password becomes an ordinary drop. */
    if (state != STATE_DISCONNECTED) {
        mReportedState = state;
    }
}

void
Supplicant::sendDisconnected(const uint8_t bssid[6], bool locallyGenerated,
    int32_t reasonCode)
{
    if (!mIfaceCallbackClient) {
        return;
    }

    GBinderLocalRequest* req = gbinder_client_new_request(mIfaceCallbackClient);
    GBinderWriter w;

    gbinder_local_request_init_writer(req, &w);
    writeByteArray(&w, bssid, 6);
    writeBool(&w, locallyGenerated);
    gbinder_writer_append_int32(&w, reasonCode);

    GDEBUG("-> onDisconnected(local=%d, reason=%d)", locallyGenerated,
           reasonCode);
    gbinder_client_transact_sync_oneway(mIfaceCallbackClient,
        STAIFACECB_onDisconnected, req);
    gbinder_local_request_unref(req);

    mReportedState = STATE_DISCONNECTED;
}

void
Supplicant::sendNetworkAdded(int32_t id)
{
    if (!mIfaceCallbackClient) {
        return;
    }

    GBinderLocalRequest* req = gbinder_client_new_request(mIfaceCallbackClient);
    GBinderWriter w;

    gbinder_local_request_init_writer(req, &w);
    gbinder_writer_append_int32(&w, id);
    gbinder_client_transact_sync_oneway(mIfaceCallbackClient,
        STAIFACECB_onNetworkAdded, req);
    gbinder_local_request_unref(req);
}

void
Supplicant::sendBssidChanged(int8_t reason, const uint8_t bssid[6])
{
    if (!mIfaceCallbackClient) {
        return;
    }

    GBinderLocalRequest* req = gbinder_client_new_request(mIfaceCallbackClient);
    GBinderWriter w;

    gbinder_local_request_init_writer(req, &w);
    /* BssidChangeReason is @Backing(type="byte"), and Java's
     * Parcel.writeByte() is writeInt() -- four bytes on the wire, not one. */
    gbinder_writer_append_int32(&w, reason);
    writeByteArray(&w, bssid, 6);
    gbinder_client_transact_sync_oneway(mIfaceCallbackClient,
        STAIFACECB_onBssidChanged, req);
    gbinder_local_request_unref(req);
}

} /* namespace wifi */
} /* namespace waydroid */
