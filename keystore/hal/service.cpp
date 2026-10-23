/*
 * waydroid-keystored -- a host-side HIDL
 * android.hardware.keymaster@4.0::IKeymasterDevice served over hwbinder via
 * libgbinder, registered as the "strongbox" instance, backed by the TPM keyblob
 * engine (keystore/engine.h). docs/65 stages 3 and 4, docs/73.
 *
 * Stage 3a made keystore2 bind it as STRONGBOX. Stage 4 serves the key
 * operations: generateKey, importKey (raw AES), getKeyCharacteristics,
 * exportKey (EC, X.509), and begin/update/finish/abort for EC P-256 signing and
 * AES ECB/CBC/CTR/GCM. This file is marshalling only -- every decision about a
 * key is the engine's, and is exercised by `keystore-engine selftest` without
 * binder. Still not served, and answered with a well-formed UNIMPLEMENTED:
 * attestKey (a non-goal, docs/65), upgradeKey, importWrappedKey and
 * verifyAuthorization. computeSharedHmac still returns an empty check, which
 * keystore2 tolerates (docs/73); auth-bound keys are refused until it is real.
 *
 * Launch model: started by hand for now, as root and unconfined_t, before the
 * session -- it waits for the container's hwservicemanager and registers the
 * moment it appears, which is how it wins the race against keystore2's boot-time
 * probe. A packaged launch has to keep that property; docs/73.
 */
#include "km_parcel.h"

#include <algorithm>
#include <errno.h>
#include <gio/gio.h>
#include <string>
#include <glib-unix.h>
#include <gutil_log.h>
#include <string.h>
#include <sys/random.h>
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
    /* Per-boot shared-secret material. Stable for the life of the process, as
     * the spec requires (the nonce must not change between
     * getHmacSharingParameters and computeSharedHmac). */
    uint8_t seed[32];
    uint8_t nonce[32];
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

    case KM_GET_HMAC_SHARING_PARAMETERS:
        /* generates (ErrorCode, HmacSharingParameters). A per-boot seed and
         * nonce; a correct shared secret waits on the pre-shared key the TEE
         * keymaster and gatekeeper use (stage 5). */
        reply = km_reply_new(obj, status, &writer, KmError::OK);
        km_append_hmac_params(&writer, app->seed, sizeof(app->seed), app->nonce);
        GINFO("getHmacSharingParameters -> OK (provisional seed/nonce)");
        break;

    case KM_COMPUTE_SHARED_HMAC:
        /* generates (ErrorCode, vec<uint8_t> sharingCheck). An empty check is a
         * deliberate mismatch: keystore2 logs it and carries on (docs/73), and
         * auth-bound keys -- the only thing a real shared secret is for here --
         * are refused at generation until stage 5 computes it. */
        reply = km_reply_new(obj, status, &writer, KmError::OK);
        gbinder_writer_append_hidl_vec(&writer, NULL, 0, 1);
        GINFO("computeSharedHmac -> OK with an empty check (stage 5 makes it real)");
        break;

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
        guint64 handle = 0;
        KmError e = (gbinder_reader_read_uint32(&reader, &purpose) &&
            km_read_bytes(&reader, blob) && km_read_params(&reader, in)) ?
            eng->begin(static_cast<Purpose>(purpose), blob, in, out, handle) :
            KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_params(&writer, out);
        gbinder_writer_append_int64(&writer, handle);
        GINFO("begin purpose=%u {%s} -> %s, op %016llx (%zu open)", purpose,
            km_describe(in).c_str(), kmErrorName(e), (unsigned long long) handle,
            eng->operationCount());
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
        uint32_t consumed = 0;
        KmError e = (gbinder_reader_read_uint64(&reader, &handle) &&
            km_read_params(&reader, in) && km_read_bytes(&reader, input)) ?
            eng->update(handle, in, input, consumed, out, output) :
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
        break;
    }

    case KM_FINISH: {
        /* (uint64_t handle, vec<KeyParameter> inParams, vec<uint8_t> input,
         * vec<uint8_t> signature, HardwareAuthToken, VerificationToken)
         * generates (ErrorCode, vec<KeyParameter> outParams, vec<uint8_t> output) */
        guint64 handle = 0;
        AuthList in, out;
        Bytes input, signature, output;
        KmError e = (gbinder_reader_read_uint64(&reader, &handle) &&
            km_read_params(&reader, in) && km_read_bytes(&reader, input) &&
            km_read_bytes(&reader, signature)) ?
            eng->finish(handle, in, input, signature, out, output) :
            KmError::INVALID_ARGUMENT;

        reply = km_reply_new(obj, status, &writer, e);
        km_append_params(&writer, out);
        km_append_bytes(&writer, output);
        GINFO("finish op %016llx +%zu -> %s, %zu bytes out", (unsigned long long)
            handle, input.size(), kmErrorName(e), output.size());
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

static gboolean
app_session_present(void)
{
    GError* err = NULL;
    GDBusConnection* bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &err);
    GVariant* res;
    gboolean present = TRUE;

    if (!bus) {
        g_clear_error(&err);
        return TRUE;
    }
    res = g_dbus_connection_call_sync(bus, "id.waydro.Container",
        "/ContainerManager", "id.waydro.ContainerManager", "GetSession",
        NULL, G_VARIANT_TYPE("(a{ss})"), G_DBUS_CALL_FLAGS_NONE, 2000,
        NULL, &err);
    if (res) {
        GVariant* dict = g_variant_get_child_value(res, 0);
        present = g_variant_n_children(dict) > 0;
        g_variant_unref(dict);
        g_variant_unref(res);
    } else {
        g_clear_error(&err);
    }
    g_object_unref(bus);
    return present;
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
    GINFO("waydroid-keystored ready (stage 4: key operations).");
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
    App app;

    gutil_log_timestamp = TRUE;   /* to line up with keystore2's log */
    gutil_log_set_type(GLOG_TYPE_STDERR, logtag);
    gutil_log_default.level = GLOG_LEVEL_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (!g_strcmp0(argv[i], "--name") && i + 1 < argc) {
            name = argv[++i];
        } else if (!g_strcmp0(argv[i], "--tcti") && i + 1 < argc) {
            tcti = argv[++i];
        } else if (!g_strcmp0(argv[i], "--verbose") || !g_strcmp0(argv[i], "-v")) {
            gutil_log_default.level = GLOG_LEVEL_VERBOSE;
        } else if (!g_strcmp0(argv[i], "--help") || !g_strcmp0(argv[i], "-h")) {
            printf("usage: %s [--name INSTANCE] [--tcti TCTI] [--verbose] "
                   "[BINDER_DEVICE]\n"
                   "  Serves %s/%s on BINDER_DEVICE (default %s),\n"
                   "  backed by the TPM behind TCTI (default the waydroid-swtpm\n"
                   "  socket).\n",
                   argv[0], KM_IFACE, DEFAULT_NAME, DEFAULT_DEVICE);
            return RET_OK;
        } else {
            device = argv[i];
        }
    }

    memset(&app, 0, sizeof(app));
    app.ret = RET_ERR;
    app.name = name;
    /* Per-boot seed and nonce from the host CSPRNG. Binding must not depend on
     * the TPM, so neither does this. */
    if (getentropy(app.seed, sizeof(app.seed)) ||
        getentropy(app.nonce, sizeof(app.nonce))) {
        GERR("getentropy failed: %s", strerror(errno));
        return RET_ERR;
    }
    app.engine = new Engine(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)));
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

    app.sm = gbinder_servicemanager_new2(device, "hidl", "hidl");
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
