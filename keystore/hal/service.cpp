/*
 * waydroid-keystored -- a host-side HIDL
 * android.hardware.keymaster@4.0::IKeymasterDevice served over hwbinder via
 * libgbinder, registered as the "strongbox" instance, backed by the TPM keyblob
 * engine (keystore/engine.h). docs/65 stages 3 and 4, docs/73.
 *
 * Stage 3a made keystore2 bind it as STRONGBOX. Stage 4 serves the key
 * operations: generateKey, importKey (raw AES), getKeyCharacteristics,
 * exportKey (EC, X.509), and begin/update/finish/abort for EC P-256 signing and
 * AES ECB/CBC/CTR/GCM. Stage 5 (docs/74) joins the shared-secret negotiation
 * for real and serves auth-bound keys: computeSharedHmac derives the key the
 * TEE derives, and the HardwareAuthToken and VerificationToken that arrive with
 * begin/update/finish are read and handed to the engine. This file is
 * marshalling only -- every decision about a key is the engine's, and is
 * exercised by `keystore-engine selftest` without binder. Still not served, and
 * answered with a well-formed UNIMPLEMENTED: attestKey (a non-goal, docs/65),
 * upgradeKey, importWrappedKey and verifyAuthorization (a TEE's job).
 *
 * --accept-unsigned-auth-tokens is for this image: its gatekeeper writes 32
 * zero bytes where a token's MAC belongs (docs/74), so without the flag no
 * password-bound key can ever be used. engine.h says what it costs.
 *
 * Launch model: waydroid-keystored.service (artifacts/keystore), from boot, as
 * root and unconfined_t. It waits for a waydroid session without touching
 * binder (app_wait_for_session), then for the session's hwservicemanager, and
 * registers the moment that appears. When the session ends it exits and systemd
 * starts it again for the next one, so every session meets a new party with a
 * fresh seed and nonce -- keystore2 negotiates once a session, so a daemon
 * carried over from the last one would be a stranger anyway. A hand start
 * (artifacts/keystore/hand-deploy.sh) behaves the same. docs/73, docs/75.
 */
#include "km_parcel.h"

#include <algorithm>
#include <gio/gio.h>
#include <string>
#include <glib-unix.h>
#include <gutil_log.h>
#include <string.h>
#include <unistd.h>

using namespace wks;

namespace wks { TpmBackend* makeToolsBackend(const std::string& tcti); }

#define RET_OK      0
#define RET_ERR     3

#define DEFAULT_DEVICE "/dev/hwbinder"
#define KM_IFACE       "android.hardware.keymaster@4.0::IKeymasterDevice"
#define DEFAULT_NAME   "strongbox"

/* docs/70 / sensors/service.cpp: once the service manager dies, find out whether
 * the session died with it before deciding to stay up and re-register. */
#define SESSION_WATCH_INTERVAL_MS (2000)
#define SESSION_WATCH_GIVEUP_MS   (60000)

static const char logtag[] = "waydroid-keystored";

typedef struct app {
    GMainLoop* loop;
    GBinderServiceManager* sm;
    GBinderLocalObject* obj;
    int ret;
    const char* name;
    Engine* engine;
    guint sessionWatch;
    guint sessionWatchMs;
} App;

/* ------------------------------------------------------------------ helpers */

/* Append a keymaster@4.0 HmacSharingParameters struct { vec<uint8_t> seed;
 * uint8_t nonce[32]; } as a HIDL return-by-value: the struct is one buffer
 * object, the seed bytes its child. seed is field 0, so the child's parent
 * offset is 0. */
static void
km_append_hmac_params(
    GBinderWriter* w,
    const uint8_t* seed, guint seedLen,
    const uint8_t* nonce)
{
    km_hmac_sharing_parameters* p =
        gbinder_writer_new0(w, km_hmac_sharing_parameters);
    uint8_t* seedbuf = (uint8_t*) gbinder_writer_malloc(w, seedLen);
    GBinderParent parent;

    memcpy(seedbuf, seed, seedLen);
    p->seed.data.ptr = seedbuf;
    p->seed.count = seedLen;
    p->seed.owns_buffer = TRUE;
    memcpy(p->nonce, nonce, 32);

    parent.index = gbinder_writer_append_buffer_object(w, p, sizeof(*p));
    parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET; /* seed at struct offset 0 */
    gbinder_writer_append_buffer_object_with_parent(w, seedbuf, seedLen,
        &parent);
}

/* A one-line rendering of a parameter list for the log: the tags a bench
 * session needs to read off, by name, and the rest by number. */
static std::string
km_describe(
    const AuthList& a)
{
    std::string out;
    char buf[64];

    for (const KeyParam& p : a.params) {
        const char* name = NULL;
        switch (p.tag) {
        case Tag::PURPOSE: name = "PURPOSE"; break;
        case Tag::ALGORITHM: name = "ALGORITHM"; break;
        case Tag::KEY_SIZE: name = "KEY_SIZE"; break;
        case Tag::BLOCK_MODE: name = "BLOCK_MODE"; break;
        case Tag::DIGEST: name = "DIGEST"; break;
        case Tag::PADDING: name = "PADDING"; break;
        case Tag::EC_CURVE: name = "EC_CURVE"; break;
        case Tag::MAC_LENGTH: name = "MAC_LENGTH"; break;
        case Tag::MIN_MAC_LENGTH: name = "MIN_MAC_LENGTH"; break;
        case Tag::NONCE: name = "NONCE"; break;
        case Tag::ASSOCIATED_DATA: name = "AAD"; break;
        case Tag::NO_AUTH_REQUIRED: name = "NO_AUTH_REQUIRED"; break;
        case Tag::CALLER_NONCE: name = "CALLER_NONCE"; break;
        case Tag::USER_SECURE_ID: name = "USER_SECURE_ID"; break;
        case Tag::USER_AUTH_TYPE: name = "USER_AUTH_TYPE"; break;
        case Tag::AUTH_TIMEOUT: name = "AUTH_TIMEOUT"; break;
        case Tag::APPLICATION_ID: name = "APPLICATION_ID"; break;
        case Tag::ORIGIN: name = "ORIGIN"; break;
        default: break;
        }
        if (!name) {
            snprintf(buf, sizeof(buf), "0x%08x ", static_cast<unsigned>(p.tag));
        } else if (tagIsBytes(p.tag)) {
            snprintf(buf, sizeof(buf), "%s[%zu] ", name, p.blob.size());
        } else {
            snprintf(buf, sizeof(buf), "%s=%llu ", name, (unsigned long long) p.u);
        }
        out += buf;
    }
    if (!out.empty()) out.pop_back();
    return out;
}

/* A token for the log: present or not, and whether its MAC is all zeros --
 * which is what this image's gatekeeper sends (docs/74). Never the MAC itself. */
static std::string
km_describe_token(
    const HardwareAuthToken& t)
{
    char buf[96];
    gboolean zero = TRUE;

    if (!t.present()) return "no token";
    for (guint8 b : t.mac) zero = zero && !b;
    snprintf(buf, sizeof(buf), "token type=%u, %zu-byte MAC%s", t.authenticatorType,
        t.mac.size(), zero ? " of zeros" : "");
    return buf;
}

/* Every reply starts with the HIDL status and, for this interface, an
 * ErrorCode. The return values follow, and are always written in full: the
 * client reads every one of them whatever the ErrorCode says, so an error reply
 * still carries empty vectors and structs. */
static GBinderLocalReply*
km_reply_new(
    GBinderLocalObject* obj,
    int* status,
    GBinderWriter* w,
    KmError err)
{
    GBinderLocalReply* reply = gbinder_local_object_new_reply(obj);

    gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
    *status = GBINDER_STATUS_OK;
    gbinder_local_reply_init_writer(reply, w);
    gbinder_writer_append_int32(w, static_cast<gint32>(err));
    return reply;
}

/* ------------------------------------------------------------- transactions */

static GBinderLocalReply*
app_reply(
    GBinderLocalObject* obj,
    GBinderRemoteRequest* req,
    guint code,
    guint flags,
    int* status,
    void* user_data)
{
    App* app = (App*) user_data;
    Engine* eng = app->engine;
    GBinderLocalReply* reply = NULL;
    GBinderWriter writer;
    GBinderReader reader;
    const char* iface = gbinder_remote_request_interface(req);

    (void) flags;
    GDEBUG("transaction code=%u iface=\"%s\"", code, iface ? iface : "(null)");
    if (g_strcmp0(iface, KM_IFACE)) {
        GDEBUG("not our interface; declining");
        return NULL;
    }
    gbinder_remote_request_init_reader(req, &reader);

    switch (code) {
    case KM_GET_HARDWARE_INFO:
        /* generates (SecurityLevel, string name, string author). This is the
         * call that lets keystore2's km_compat bind us as the STRONGBOX level. */
        reply = gbinder_local_object_new_reply(obj);
        gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
        *status = GBINDER_STATUS_OK;
        gbinder_local_reply_init_writer(reply, &writer);
        gbinder_writer_append_int32(&writer, KM_SECURITY_STRONGBOX);
        gbinder_writer_append_hidl_string(&writer, "WaydroidTpmKeymaster");
        gbinder_writer_append_hidl_string(&writer, "bigtab01-waydroid");
        GINFO("getHardwareInfo -> STRONGBOX WaydroidTpmKeymaster");
        break;

    case KM_GET_HMAC_SHARING_PARAMETERS: {
        /* generates (ErrorCode, HmacSharingParameters). The engine's per-process
         * seed and nonce. */
        const HmacSharingParams& p = eng->hmacSharingParameters();

        reply = km_reply_new(obj, status, &writer, KmError::OK);
        km_append_hmac_params(&writer, p.seed.data(), p.seed.size(), p.nonce.data());
        GINFO("getHmacSharingParameters -> OK");
        break;
    }

    case KM_COMPUTE_SHARED_HMAC: {
        /* (vec<HmacSharingParameters>) generates (ErrorCode, vec<uint8_t>
         * sharingCheck). The same derivation as the TEE's, so keystore2 finds
         * the checks equal; docs/74 measured the TEE's against this one. */
        std::vector<HmacSharingParams> params;
        Bytes check;
        KmError e = km_read_hmac_params_vec(&reader, params) ?
            eng->computeSharedHmac(params, check) : KmError::INVALID_ARGUMENT;
        char head[12] = "";

        reply = km_reply_new(obj, status, &writer, e);
        km_append_bytes(&writer, check);
        if (check.size() >= 4) {
            snprintf(head, sizeof(head), "%02x%02x%02x%02x", check[0], check[1],
                check[2], check[3]);
        }
        GINFO("computeSharedHmac over %zu participants -> %s, check %s...",
            params.size(), kmErrorName(e), head);
        break;
    }

    case KM_ADD_RNG_ENTROPY:
        /* generates (ErrorCode). Harmless to accept; the TPM has its own RNG. */
        reply = km_reply_new(obj, status, &writer, KmError::OK);
        break;

    case KM_GENERATE_KEY: {
        /* (vec<KeyParameter>) generates (ErrorCode, vec<uint8_t> keyBlob,
         * KeyCharacteristics) */
        AuthList params;
        Bytes blob;
        KeyCharacteristics kc;
        KmError e = km_read_params(&reader, params) ?
            eng->generateKey(params, blob, kc) : KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_bytes(&writer, blob);
        km_append_characteristics(&writer, kc);
        GINFO("generateKey {%s} -> %s, %zu-byte blob", km_describe(params).c_str(),
            kmErrorName(e), blob.size());
        break;
    }

    case KM_IMPORT_KEY: {
        /* (vec<KeyParameter>, KeyFormat, vec<uint8_t> keyData) generates
         * (ErrorCode, vec<uint8_t> keyBlob, KeyCharacteristics) */
        AuthList params;
        guint32 format = 0;
        Bytes data, blob;
        KeyCharacteristics kc;
        KmError e = (km_read_params(&reader, params) &&
            gbinder_reader_read_uint32(&reader, &format) &&
            km_read_bytes(&reader, data)) ?
            eng->importKey(params, static_cast<KeyFormat>(format), data, blob, kc) :
            KmError::INVALID_ARGUMENT;

        std::fill(data.begin(), data.end(), 0);
        reply = km_reply_new(obj, status, &writer, e);
        km_append_bytes(&writer, blob);
        km_append_characteristics(&writer, kc);
        GINFO("importKey {%s} format=%u -> %s", km_describe(params).c_str(),
            format, kmErrorName(e));
        break;
    }

    case KM_GET_KEY_CHARACTERISTICS: {
        /* (vec<uint8_t> keyBlob, vec<uint8_t> clientId, vec<uint8_t> appData)
         * generates (ErrorCode, KeyCharacteristics) */
        Bytes blob, clientId, appData;
        KeyCharacteristics kc;
        KmError e = (km_read_bytes(&reader, blob) &&
            km_read_bytes(&reader, clientId) && km_read_bytes(&reader, appData)) ?
            eng->getKeyCharacteristics(blob, clientId, appData, kc) :
            KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_characteristics(&writer, kc);
        GINFO("getKeyCharacteristics -> %s", kmErrorName(e));
        break;
    }

    case KM_EXPORT_KEY: {
        /* (KeyFormat, vec<uint8_t> keyBlob, vec<uint8_t> clientId,
         * vec<uint8_t> appData) generates (ErrorCode, vec<uint8_t>) */
        guint32 format = 0;
        Bytes blob, clientId, appData, out;
        KmError e = (gbinder_reader_read_uint32(&reader, &format) &&
            km_read_bytes(&reader, blob) && km_read_bytes(&reader, clientId) &&
            km_read_bytes(&reader, appData)) ?
            eng->exportKey(static_cast<KeyFormat>(format), blob, clientId, appData,
                out) : KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_bytes(&writer, out);
        GINFO("exportKey format=%u -> %s, %zu bytes", format, kmErrorName(e),
            out.size());
        break;
    }

    case KM_ATTEST_KEY:
        /* generates (ErrorCode, vec<vec<uint8_t>> certChain). Attestation needs a
         * chain rooted in a Google-signed key, which no TPM can have: a non-goal
         * (docs/65). km_compat signs the key's own certificate without it. */
        reply = km_reply_new(obj, status, &writer, KmError::UNIMPLEMENTED);
        gbinder_writer_append_hidl_vec(&writer, NULL, 0, sizeof(GBinderHidlVec));
        GINFO("attestKey -> UNIMPLEMENTED (attestation is a non-goal)");
        break;

    case KM_UPGRADE_KEY:
        /* generates (ErrorCode, vec<uint8_t>). Only asked after begin returns
         * KEY_REQUIRES_UPGRADE, which this engine never does. */
        reply = km_reply_new(obj, status, &writer, KmError::UNIMPLEMENTED);
        km_append_bytes(&writer, Bytes());
        GINFO("upgradeKey -> UNIMPLEMENTED");
        break;

    case KM_IMPORT_WRAPPED_KEY:
        /* generates (ErrorCode, vec<uint8_t>, KeyCharacteristics) */
        reply = km_reply_new(obj, status, &writer, KmError::UNIMPLEMENTED);
        km_append_bytes(&writer, Bytes());
        km_append_characteristics(&writer, KeyCharacteristics());
        GINFO("importWrappedKey -> UNIMPLEMENTED");
        break;

    case KM_VERIFY_AUTHORIZATION: {
        /* generates (ErrorCode, VerificationToken). A TEE's job, not a
         * StrongBox's; answered with an empty token. */
        km_verification_token* tok = NULL;

        reply = km_reply_new(obj, status, &writer, KmError::UNIMPLEMENTED);
        tok = gbinder_writer_new0(&writer, km_verification_token);
        tok->securityLevel = KM_SECURITY_STRONGBOX;
        km_set_vec(&tok->parametersVerified, NULL, 0);
        km_set_vec(&tok->mac, NULL, 0);
        gbinder_writer_append_struct(&writer, tok, &km_verification_token_t, NULL);
        GINFO("verifyAuthorization -> UNIMPLEMENTED");
        break;
    }

    case KM_DELETE_KEY:
    case KM_DELETE_ALL_KEYS:
    case KM_DESTROY_ATTESTATION_IDS:
        /* generates (ErrorCode). Keys live in their blobs and nothing is stored
         * here, so there is nothing to delete. */
        reply = km_reply_new(obj, status, &writer, KmError::OK);
        GDEBUG("code %u -> OK (nothing stored)", code);
        break;

    case KM_BEGIN: {
        /* (KeyPurpose, vec<uint8_t> keyBlob, vec<KeyParameter> inParams,
         * HardwareAuthToken) generates (ErrorCode, vec<KeyParameter> outParams,
         * uint64_t operationHandle) */
        guint32 purpose = 0;
        Bytes blob;
        AuthList in, out;
        HardwareAuthToken hat;
        guint64 handle = 0;
        std::string why;
        KmError e = (gbinder_reader_read_uint32(&reader, &purpose) &&
            km_read_bytes(&reader, blob) && km_read_params(&reader, in) &&
            km_read_auth_token(&reader, hat)) ?
            eng->begin(static_cast<Purpose>(purpose), blob, in, out, handle, hat,
                &why) : KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_params(&writer, out);
        gbinder_writer_append_int64(&writer, handle);
        GINFO("begin purpose=%u {%s} -> %s, op %016llx (%zu open)", purpose,
            km_describe(in).c_str(), kmErrorName(e), (unsigned long long) handle,
            eng->operationCount());
        if (!why.empty() || hat.present()) {
            GINFO("  auth: %s; %s", km_describe_token(hat).c_str(),
                why.empty() ? "not an auth-bound key" : why.c_str());
        }
        break;
    }

    case KM_UPDATE: {
        /* (uint64_t handle, vec<KeyParameter> inParams, vec<uint8_t> input,
         * HardwareAuthToken, VerificationToken) generates (ErrorCode,
         * uint32_t inputConsumed, vec<KeyParameter> outParams,
         * vec<uint8_t> output) */
        guint64 handle = 0;
        AuthList in, out;
        Bytes input, output;
        HardwareAuthToken hat;
        VerificationToken vt;
        uint32_t consumed = 0;
        std::string why;
        KmError e = (gbinder_reader_read_uint64(&reader, &handle) &&
            km_read_params(&reader, in) && km_read_bytes(&reader, input) &&
            km_read_auth_token(&reader, hat) &&
            km_read_verification_token(&reader, vt)) ?
            eng->update(handle, in, input, consumed, out, output, hat, vt, &why) :
            KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        gbinder_writer_append_int32(&writer, consumed);
        km_append_params(&writer, out);
        km_append_bytes(&writer, output);
        GDEBUG("update op %016llx +%zu -> %s", (unsigned long long) handle,
            input.size(), kmErrorName(e));
        if (e != KmError::OK) {
            GINFO("update op %016llx -> %s", (unsigned long long) handle,
                kmErrorName(e));
        }
        if (!why.empty()) {
            GINFO("  auth: %s%s; %s", km_describe_token(hat).c_str(),
                vt.present() ? ", verification token" : "", why.c_str());
        }
        break;
    }

    case KM_FINISH: {
        /* (uint64_t handle, vec<KeyParameter> inParams, vec<uint8_t> input,
         * vec<uint8_t> signature, HardwareAuthToken, VerificationToken)
         * generates (ErrorCode, vec<KeyParameter> outParams, vec<uint8_t> output) */
        guint64 handle = 0;
        AuthList in, out;
        Bytes input, signature, output;
        HardwareAuthToken hat;
        VerificationToken vt;
        std::string why;
        KmError e = (gbinder_reader_read_uint64(&reader, &handle) &&
            km_read_params(&reader, in) && km_read_bytes(&reader, input) &&
            km_read_bytes(&reader, signature) &&
            km_read_auth_token(&reader, hat) &&
            km_read_verification_token(&reader, vt)) ?
            eng->finish(handle, in, input, signature, out, output, hat, vt, &why) :
            KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_params(&writer, out);
        km_append_bytes(&writer, output);
        GINFO("finish op %016llx +%zu -> %s, %zu bytes out", (unsigned long long)
            handle, input.size(), kmErrorName(e), output.size());
        if (!why.empty()) {
            GINFO("  auth: %s%s; %s", km_describe_token(hat).c_str(),
                vt.present() ? ", verification token" : "", why.c_str());
        }
        break;
    }

    case KM_ABORT: {
        /* (uint64_t handle) generates (ErrorCode) */
        guint64 handle = 0;
        KmError e = gbinder_reader_read_uint64(&reader, &handle) ?
            eng->abort(handle) : KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        GINFO("abort op %016llx -> %s", (unsigned long long) handle,
            kmErrorName(e));
        break;
    }

    default:
        GWARN("unknown transaction code %u", code);
        *status = GBINDER_STATUS_FAILED;
        return NULL;
    }

    return reply;
}

/* ------------------------------------------------------- session-watch (docs/70) */

/* What id.waydro.Container's GetSession says: 1 a session exists, 0 none, -1 no
 * answer -- no container manager, or a waydroid without the method. It answers
 * an empty a{ss} until container_manager.do_start() has started the container
 * and assigned args.session (docs/69), and costs no binder traffic at all. */
static int
app_query_session(GDBusConnection* bus, gint timeoutMs)
{
    GError* err = NULL;
    GVariant* res = g_dbus_connection_call_sync(bus, "id.waydro.Container",
        "/ContainerManager", "id.waydro.ContainerManager", "GetSession",
        NULL, G_VARIANT_TYPE("(a{ss})"), G_DBUS_CALL_FLAGS_NONE, timeoutMs,
        NULL, &err);
    if (!res) {
        GDEBUG("GetSession: %s", err ? err->message : "?");
        g_clear_error(&err);
        return -1;
    }
    GVariant* dict = g_variant_get_child_value(res, 0);
    int present = g_variant_n_children(dict) > 0;
    g_variant_unref(dict);
    g_variant_unref(res);
    return present;
}

/* For the watch after a service-manager death: only an answer of "no session"
 * means gone. No answer is not evidence, so it keeps the daemon up. */
static gboolean
app_session_present(void)
{
    GError* err = NULL;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);

    if (!bus) {
        g_clear_error(&err);
        return TRUE;
    }
    int s = app_query_session(bus, 2000);
    g_object_unref(bus);
    return s != 0;
}

/* Wait for waydroid to have a session before touching binder -- docs/69, and
 * wifi/service.cpp's app_wait_for_session(), which this follows.
 *
 * gbinder_servicemanager_wait() pings handle 0 once a second, and every ping
 * that lands while no hwservicemanager exists costs the kernel log two lines.
 * Measured on bigtab01 on 2026-10-23, before this gate existed: the hand-started
 * daemon waited 2 h 6 min with nobody logged in and wrote 7,551 "cannot find
 * target node" pairs, all of them its own. A unit that runs from boot would do
 * that for as long as the machine sits at the greeter.
 *
 * Registering a second or so later than an ungated wait is safe here, more so
 * than for Wi-Fi: keystore2 only engages a strongbox the VINTF manifest
 * declares, and it retries a declared one -- which is how it already won the
 * race against hwservicemanager's failed lazy start in stage 3a (docs/73).
 *
 * The gate is given up only if GetSession never answers at all within 60 s, so
 * a waydroid without the method still gets a working daemon. Once it has
 * answered, a later failure means the container manager went away, and no
 * hwservicemanager can appear without it, so keep waiting. Called before
 * gbinder_servicemanager_new2(), so nothing exists that could poll binder. */
#define SESSION_GATE_GIVEUP_SEC (60)

static void
app_wait_for_session(void)
{
    GError* err = NULL;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
    gboolean answered = FALSE;

    if (!bus) {
        GWARN("no system bus (%s); probing binder unguarded",
              err ? err->message : "?");
        g_clear_error(&err);
        return;
    }
    for (int i = 0; ; i++) {
        int s = app_query_session(bus, 5000);
        if (s > 0) break;
        if (s == 0) answered = TRUE;
        if (!answered && i >= SESSION_GATE_GIVEUP_SEC) {
            GWARN("id.waydro.Container has not answered GetSession in %d s; "
                  "probing binder unguarded", SESSION_GATE_GIVEUP_SEC);
            break;
        }
        if (!i) {
            GINFO("no waydroid session yet; waiting for one before probing "
                  "binder");
        }
        sleep(1);
    }
    g_object_unref(bus);
}

static gboolean
app_session_watch(void* user_data)
{
    App* app = (App*) user_data;

    app->sessionWatchMs += SESSION_WATCH_INTERVAL_MS;
    if (!app_session_present()) {
        GINFO("Session is gone; exiting rather than polling a dead binder.");
        app->sessionWatch = 0;
        if (app->loop) g_main_loop_quit(app->loop);
        return G_SOURCE_REMOVE;
    }
    if (app->sessionWatchMs >= SESSION_WATCH_GIVEUP_MS) {
        app->sessionWatch = 0;
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static void
app_add_service_done(GBinderServiceManager* sm, int status, void* user_data)
{
    App* app = (App*) user_data;
    (void) sm;
    if (status == GBINDER_STATUS_OK) {
        GINFO("Added \"%s/%s\"", KM_IFACE, app->name);
        app->ret = RET_OK;
    } else {
        GERR("Failed to add \"%s/%s\" (%d)", KM_IFACE, app->name, status);
        g_main_loop_quit(app->loop);
    }
}

static void
app_sm_presence_handler(GBinderServiceManager* sm, void* user_data)
{
    App* app = (App*) user_data;
    (void) sm;
    if (gbinder_servicemanager_is_present(app->sm)) {
        GINFO("Service manager reappeared; re-registering");
        if (app->sessionWatch) {
            g_source_remove(app->sessionWatch);
            app->sessionWatch = 0;
        }
        gbinder_servicemanager_add_service(app->sm, app->name, app->obj,
            app_add_service_done, app);
    } else {
        GINFO("Service manager died");
        if (!app->sessionWatch) {
            app->sessionWatchMs = 0;
            app->sessionWatch = g_timeout_add(SESSION_WATCH_INTERVAL_MS,
                app_session_watch, app);
        }
    }
}

static gboolean
app_signal(gpointer user_data)
{
    App* app = (App*) user_data;
    GINFO("Caught signal, shutting down");
    g_main_loop_quit(app->loop);
    return G_SOURCE_CONTINUE;
}

static void
app_run(App* app)
{
    guint sigtrm = g_unix_signal_add(SIGTERM, app_signal, app);
    guint sigint = g_unix_signal_add(SIGINT, app_signal, app);
    gulong pres = gbinder_servicemanager_add_presence_handler(app->sm,
        app_sm_presence_handler, app);

    app->loop = g_main_loop_new(NULL, TRUE);
    gbinder_servicemanager_add_service(app->sm, app->name, app->obj,
        app_add_service_done, app);
    GINFO("waydroid-keystored ready (stage 5: shared secret and auth-bound keys).");
    g_main_loop_run(app->loop);

    if (sigtrm) g_source_remove(sigtrm);
    if (sigint) g_source_remove(sigint);
    if (app->sessionWatch) g_source_remove(app->sessionWatch);
    gbinder_servicemanager_remove_handler(app->sm, pres);
    g_main_loop_unref(app->loop);
    app->loop = NULL;
}

int main(int argc, char* argv[])
{
    const char* device = DEFAULT_DEVICE;
    const char* name = DEFAULT_NAME;
    const char* tcti = "swtpm:path=/run/swtpm-waydroid/sock";
    EngineOptions opts;
    App app;

    gutil_log_timestamp = TRUE;   /* to line up with keystore2's log */
    gutil_log_set_type(GLOG_TYPE_STDERR, logtag);
    gutil_log_default.level = GLOG_LEVEL_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (!g_strcmp0(argv[i], "--name") && i + 1 < argc) {
            name = argv[++i];
        } else if (!g_strcmp0(argv[i], "--tcti") && i + 1 < argc) {
            tcti = argv[++i];
        } else if (!g_strcmp0(argv[i], "--accept-unsigned-auth-tokens")) {
            opts.acceptUnsignedAuthTokens = true;
        } else if (!g_strcmp0(argv[i], "--verbose") || !g_strcmp0(argv[i], "-v")) {
            gutil_log_default.level = GLOG_LEVEL_VERBOSE;
        } else if (!g_strcmp0(argv[i], "--help") || !g_strcmp0(argv[i], "-h")) {
            printf("usage: %s [--name INSTANCE] [--tcti TCTI] "
                   "[--accept-unsigned-auth-tokens] [--verbose] [BINDER_DEVICE]\n"
                   "  Serves %s/%s on BINDER_DEVICE (default %s),\n"
                   "  backed by the TPM behind TCTI (default the waydroid-swtpm\n"
                   "  socket). --accept-unsigned-auth-tokens lets a HardwareAuthToken\n"
                   "  with an all-zero MAC through, and reports the auth tags at the\n"
                   "  KEYSTORE level (docs/74).\n",
                   argv[0], KM_IFACE, DEFAULT_NAME, DEFAULT_DEVICE);
            return RET_OK;
        } else {
            device = argv[i];
        }
    }

    memset(&app, 0, sizeof(app));
    app.ret = RET_ERR;
    app.name = name;
    /* The engine draws the per-process seed and nonce from the host CSPRNG:
     * binding must not depend on the TPM, so neither does the negotiation. */
    app.engine = new Engine(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)),
        opts);
    if (app.engine->hmacSharingParameters().nonce.empty()) {
        GERR("getentropy failed: no shared-secret nonce");
        delete app.engine;
        return RET_ERR;
    }
    GINFO("auth tokens: %s", opts.acceptUnsignedAuthTokens ?
        "signed or unsigned (--accept-unsigned-auth-tokens); auth tags at KEYSTORE level" :
        "signed with the shared key only; auth tags at STRONGBOX level");
    /* Say now, not at the first key request, whether the TPM answers. Not
     * fatal: the engine retries on every key operation, and a strongbox that
     * binds and then fails key generation is still better diagnosed than one
     * that never registered. */
    {
        KmError e = app.engine->init();
        if (e == KmError::OK) {
            GINFO("TPM ready: %s", app.engine->backendDescription().c_str());
        } else {
            GWARN("TPM not ready (%s): %s -- key operations will fail until it is",
                kmErrorName(e), app.engine->backendDescription().c_str());
        }
    }

    app_wait_for_session();
    app.sm = gbinder_servicemanager_new2(device, "hidl", "hidl");
    if (!app.sm) {
        GERR("cannot open %s", device);
        delete app.engine;
        return RET_ERR;
    }
    GINFO("waiting for the container's hwservicemanager on %s", device);
    if (gbinder_servicemanager_wait(app.sm, -1)) {
        app.obj = gbinder_servicemanager_new_local_object(app.sm, KM_IFACE,
            app_reply, &app);
        app_run(&app);
        gbinder_local_object_unref(app.obj);
        gbinder_servicemanager_unref(app.sm);
    }
    delete app.engine;
    return app.ret;
}
