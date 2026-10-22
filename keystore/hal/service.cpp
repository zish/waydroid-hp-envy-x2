/*
 * waydroid-keystored -- stage 3 of docs/65: a host-side HIDL
 * android.hardware.keymaster@4.0::IKeymasterDevice served over hwbinder via
 * libgbinder, registered as the "strongbox" instance, backed by the stage-1
 * TPM keyblob engine (keystore/engine.h). docs/73.
 *
 * STAGE 3a (this file's current scope): BIND + MEASURE. keystore2 reaches for a
 * StrongBox KeyMint through its km_compat Legacy wrapper every boot and fails
 * -68 (docs/65 OQ3/OQ4, measured 2026-10-22). This serves getHardwareInfo so it
 * can bind, and instruments getHmacSharingParameters / computeSharedHmac so the
 * next console session can measure the real risk: whether a strongbox that does
 * not (yet) share the pre-shared HMAC key breaks the TEE instance's shared-secret
 * negotiation. The key-operation methods (generateKey/begin/update/finish/...)
 * are stage 4 and return a transaction error for now -- keystore2 does not call
 * them at boot, only when an app asks for a StrongBox key.
 *
 * It is spawned, not a systemd unit, for the same reason as waydroid-sensord:
 * a bin_t binary started by systemd runs unconfined_service_t and hits the
 * binder { transfer } dontaudit trap (docs/35). A13's keymaster@4.0 passes only
 * value types across begin(), so the trap is milder here than A16's KeyMint, but
 * the launch model is kept identical.
 */
#include "km_hidl_types.h"
#include "../engine.h"

#include <errno.h>
#include <gio/gio.h>
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
    Engine* engine;        /* stage 4 key ops; unused at boot in stage 3a */
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

/* A reply that is just the HIDL Status header plus one ErrorCode return value,
 * for the methods whose only output is ErrorCode. */
static GBinderLocalReply*
km_reply_error_only(
    GBinderLocalObject* obj,
    int* status,
    KmError err)
{
    GBinderLocalReply* reply = gbinder_local_object_new_reply(obj);
    GBinderWriter writer;

    gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
    *status = GBINDER_STATUS_OK;
    gbinder_local_reply_init_writer(reply, &writer);
    gbinder_writer_append_int32(&writer, static_cast<gint32>(err));
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
    GBinderLocalReply* reply = NULL;
    GBinderWriter writer;
    const char* iface = gbinder_remote_request_interface(req);

    (void) flags;
    /* Stage 3a diagnostic: log every incoming transaction with its code and
     * interface, so a timestamped log shows exactly what keystore2 does and
     * when, relative to its boot-time strongbox probe. */
    GINFO("transaction code=%u iface=\"%s\"", code, iface ? iface : "(null)");
    if (g_strcmp0(iface, KM_IFACE)) {
        GDEBUG("not our interface; declining");
        return NULL;
    }

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
        /* generates (ErrorCode, HmacSharingParameters). STAGE 3a: we return a
         * well-formed params with a per-boot seed+nonce and ErrorCode OK, so
         * keystore2 proceeds to computeSharedHmac -- which is where the real
         * measurement is. The seed is ours and stable; a correct value waits on
         * knowing the pre-shared key the TEE keymaster and gatekeeper use. */
        reply = gbinder_local_object_new_reply(obj);
        gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
        *status = GBINDER_STATUS_OK;
        gbinder_local_reply_init_writer(reply, &writer);
        gbinder_writer_append_int32(&writer, static_cast<gint32>(KmError::OK));
        km_append_hmac_params(&writer, app->seed, sizeof(app->seed), app->nonce);
        GINFO("getHmacSharingParameters -> OK (provisional seed/nonce)");
        break;

    case KM_COMPUTE_SHARED_HMAC:
        /* generates (ErrorCode, vec<uint8_t> sharingCheck). STAGE 3a PROBE: we
         * do NOT yet compute the real CKDF/HMAC (needs the shared pre-shared key
         * and a crypto path -- stage 3b). Returning OK with an empty check is a
         * deliberate, measurable mismatch: the next console session reads whether
         * this breaks the TEE instance's negotiation (docs/65 OQ4, present-but-
         * failing case) or is tolerated. If it breaks TEE, computeSharedHmac must
         * be correct before this instance may ever be served. */
        reply = gbinder_local_object_new_reply(obj);
        gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
        *status = GBINDER_STATUS_OK;
        gbinder_local_reply_init_writer(reply, &writer);
        gbinder_writer_append_int32(&writer, static_cast<gint32>(KmError::OK));
        gbinder_writer_append_hidl_vec(&writer, NULL, 0, 1); /* empty check */
        GWARN("computeSharedHmac -> OK with EMPTY check (stage 3a probe); "
              "expect a negotiation mismatch, this is what we are measuring");
        break;

    case KM_ADD_RNG_ENTROPY:
        /* generates (ErrorCode). Harmless to accept; the TPM has its own RNG. */
        reply = km_reply_error_only(obj, status, KmError::OK);
        break;

    case KM_DELETE_KEY:
    case KM_DELETE_ALL_KEYS:
    case KM_DESTROY_ATTESTATION_IDS:
    case KM_ABORT:
        /* generates (ErrorCode) only. Nothing is stored yet (stage 4), so OK. */
        reply = km_reply_error_only(obj, status, KmError::OK);
        break;

    default:
        /* Stage 4: generateKey/importKey/getKeyCharacteristics/exportKey/
         * attestKey/upgradeKey/begin/update/finish/verifyAuthorization. These
         * return complex parcelables and are not marshalled yet. keystore2 does
         * not call them during binding or negotiation -- only when an app asks
         * for a StrongBox key -- so a transaction error here is safe for stage 3. */
        GINFO("code %u not implemented (stage 4)", code);
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
    GINFO("waydroid-keystored ready (stage 3a: bind + measure).");
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

    gutil_log_timestamp = TRUE;   /* stage 3a: correlate with keystore2's probe */
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
                   "  Serves %s/%s on BINDER_DEVICE (default %s).\n"
                   "  Stage 3a: binds and measures shared-secret behaviour; key\n"
                   "  operations are stage 4.\n",
                   argv[0], KM_IFACE, DEFAULT_NAME, DEFAULT_DEVICE);
            return RET_OK;
        } else {
            device = argv[i];
        }
    }

    memset(&app, 0, sizeof(app));
    app.ret = RET_ERR;
    app.name = name;
    /* Per-boot seed and nonce from the host CSPRNG. Stage 3a does not touch the
     * TPM: the engine (and its swtpm socket, tss:tss 0660) is for key ops in
     * stage 4, and binding must not depend on TPM socket permissions. */
    if (getentropy(app.seed, sizeof(app.seed)) ||
        getentropy(app.nonce, sizeof(app.nonce))) {
        GERR("getentropy failed: %s", strerror(errno));
        return RET_ERR;
    }
    app.engine = new Engine(std::unique_ptr<TpmBackend>(makeToolsBackend(tcti)));

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
