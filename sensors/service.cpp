/*
 * Copyright © 2021 Waydroid Project.
 *
 * This program is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3,
 * as published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Erfan Abdi <erfangplus@gmail.com>
 *
 * bigtab01-waydroid changes: /dev/hwbinder default, a --selftest mode that
 * exercises the IIO reader without binder, and guards against taking
 * &vec[0] of an empty std::vector (undefined behaviour upstream).
 */

#include "Sensors.h"
#include "Lights.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

using waydroid::sensors::implementation::Sensors;

#define RET_OK          (0)
#define RET_NOTFOUND    (1)
#define RET_INVARG      (2)
#define RET_ERR         (3)

#define DEFAULT_DEVICE  "/dev/hwbinder"
/*
 * Lock file location matters more than it looks. container_manager.py spawns
 * us from a service running confined as system_u:system_r:waydroid_t:s0, and
 * we inherit that domain -- so being root is NOT enough. /run is var_run_t and
 * the open() fails with EACCES; /var/lib/waydroid is waydroid_data_t, which
 * waydroid_t writes routinely (waydroid.log lives there). Running the same
 * binary by hand under sudo works, because an ssh login gives unconfined_t --
 * which makes this fail exactly one way round and look like a phantom.
 */
static const char *const LOCK_PATHS[] = {
    "/var/lib/waydroid/waydroid-sensord.pid",
    "/run/waydroid-sensord.pid",
    "/tmp/waydroid-sensord.pid",
};
#define DEFAULT_IFACE   "android.hardware.sensors@1.0::ISensors"
#define DEFAULT_NAME    "default"

typedef struct app {
    GMainLoop* loop;
    GBinderServiceManager* sm;
    GBinderLocalObject* obj;
    int ret;
    Sensors *service;
    /* The lights half. Registered as a second name on the same hwbinder
     * connection; see build.sh for why it shares this process. */
    GBinderLocalObject* lightObj;
    waydroid::Backlight* backlight;
} App;

typedef struct response {
    GBinderRemoteRequest* req;
    GBinderLocalReply* reply;
    int maxCount;
    Sensors *service;
} Response;

static const char logtag[] = "waydroid-sensors-daemon";

static
gboolean
app_signal(
    gpointer user_data)
{
    App* app = (App*) user_data;

    GINFO("Caught signal, shutting down...");
    app->service->killLoops();
    g_main_loop_quit(app->loop);
    return G_SOURCE_CONTINUE;
}

#define sensors_write_hidl_string_data(writer,ptr,field,index,off) \
     sensors_write_string_with_parent(writer, &ptr->field, index, \
        (off) + ((guint8*)(&ptr->field) - (guint8*)ptr))

static
inline
void
sensors_write_string_with_parent(
    GBinderWriter* writer,
    const GBinderHidlString* str,
    guint32 index,
    guint32 offset)
{
    GBinderParent parent;

    parent.index = index;
    parent.offset = offset;

    /* Strings are NULL-terminated, hence len + 1 */
    gbinder_writer_append_buffer_object_with_parent(writer, str->data.str,
        str->len + 1, &parent);
}

static
void
sensors_write_info_strings(
    GBinderWriter* w,
    const sensor_t* sensor,
    guint idx,
    guint i)
{
    const guint off = sizeof(*sensor) * i;

    /* Write the string data in the right order */
    sensors_write_hidl_string_data(w, sensor, name, idx, off);
    sensors_write_hidl_string_data(w, sensor, vendor, idx, off);
    sensors_write_hidl_string_data(w, sensor, typeAsString, idx, off);
    sensors_write_hidl_string_data(w, sensor, requiredPermission, idx, off);
}

static
gboolean
app_async_resp(
    gpointer user_data)
{
    Response* resp = (Response*)user_data;
    int err = 0;
    GBinderWriter writer;

    std::vector<sensors_event_t> event_vec = resp->service->poll(resp->maxCount, &err);
    int event_len = event_vec.size();
    sensors_event_t *event = event_len ? &event_vec[0] : NULL;

    gbinder_local_reply_init_writer(resp->reply, &writer);
    gbinder_writer_append_int32(&writer, err);
    gbinder_writer_append_hidl_vec(&writer, (void *)event, event_len, sizeof(sensors_event_t));

    /* Dynamic sensors: ISensors@1.0::poll returns a second vector for
     * dynamically-connected sensors.  We never report any, so this is always
     * an empty vec. */
    gbinder_writer_append_hidl_vec(&writer, NULL, 0, sizeof(sensor_t));

    gbinder_remote_request_complete(resp->req, resp->reply, 0);
    return G_SOURCE_REMOVE;
}

static
void
app_async_free(
    gpointer user_data)
{
    Response* resp = (Response*)user_data;

    gbinder_local_reply_unref(resp->reply);
    gbinder_remote_request_unref(resp->req);
    g_free(resp);
}

static
GBinderLocalReply*
app_reply(
    GBinderLocalObject* obj,
    GBinderRemoteRequest* req,
    guint code,
    guint flags,
    int* status,
    void* user_data)
{
    App* app = (App*) user_data;
    GBinderLocalReply *reply = NULL;
    GBinderReader reader;
    GBinderWriter writer;

    gbinder_remote_request_init_reader(req, &reader);
    if (code == GET_SENSORS_LIST) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            sensor_t* sensors;
            std::vector<sensor_t> sensors_vec = app->service->getSensorsList();
            int sensors_len = sensors_vec.size();

            gbinder_local_reply_init_writer(reply, &writer);

            guint index;
            GBinderParent vec_parent;
            GBinderHidlVec *vec = gbinder_writer_new0(&writer, GBinderHidlVec);
            const gsize total = sensors_len * sizeof(*sensors);
            sensors = (sensor_t*) gbinder_writer_malloc0(&writer, total);

            /* Fill in the vector descriptor */
            if (sensors) {
                vec->data.ptr = sensors;
                vec->count = sensors_len;
            }
            vec->owns_buffer = TRUE;

            std::copy(sensors_vec.begin(), sensors_vec.end(), sensors);

            /* Prepare parent descriptor for the string data */
            vec_parent.index = gbinder_writer_append_buffer_object(&writer, vec, sizeof(*vec));
            vec_parent.offset = GBINDER_HIDL_VEC_BUFFER_OFFSET;

            index = gbinder_writer_append_buffer_object_with_parent(&writer,
                sensors, total, &vec_parent);

            for (int i = 0; i < sensors_len; i++)
                sensors_write_info_strings(&writer, sensors + i, index, i);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == SET_OPERATION_MODE) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            gint32 tmp = 0;
            gbinder_reader_read_int32(&reader, &tmp);
            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_INVALID_OPERATION);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == ACTIVATE) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            int handle = 0;
            gboolean enabled;
            gbinder_reader_read_int32(&reader, &handle);
            gbinder_reader_read_bool(&reader, &enabled);

            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, app->service->activate(handle, enabled == TRUE));
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == POLL) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            int maxCount = 0;
            gbinder_reader_read_int32(&reader, &maxCount);

            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            Response* resp = g_new0(Response, 1);
            resp->service = app->service;
            resp->maxCount = maxCount;
            resp->reply = reply;
            resp->req = gbinder_remote_request_ref(req);
            g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, app_async_resp,
                                resp, app_async_free);
            gbinder_remote_request_block(resp->req);
            return NULL;
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == BATCH) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            gint32 tmp = 0;
            gint64 tmp64 = 0;
            gbinder_reader_read_int32(&reader, &tmp);
            gbinder_reader_read_int64(&reader, &tmp64);
            gbinder_reader_read_int64(&reader, &tmp64);

            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_OK);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == FLUSH) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            int handle = 0;
            gbinder_reader_read_int32(&reader, &handle);

            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, app->service->flush(handle));
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == INJECT_SENSOR_DATA) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_INVALID_OPERATION);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == REGISTER_DIRECT_CHANNEL) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_INVALID_OPERATION);
            gbinder_writer_append_int32(&writer, -1);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == UNREGISTER_DIRECT_CHANNEL) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            int tmp = 0;
            gbinder_reader_read_int32(&reader, &tmp);

            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_OK);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    } else if (code == CONFIG_DIRECT_REPORT) {
        const char* iface = gbinder_remote_request_interface(req);

        if (!g_strcmp0(iface, DEFAULT_IFACE)) {
            reply = gbinder_local_object_new_reply(obj);

            gbinder_local_reply_append_int32(reply, GBINDER_STATUS_OK);
            *status = GBINDER_STATUS_OK;

            gbinder_local_reply_init_writer(reply, &writer);
            gbinder_writer_append_int32(&writer, RESULT_INVALID_OPERATION);
            gbinder_writer_append_int32(&writer, -1);
        } else {
            GDEBUG("Unexpected interface \"%s\"", iface);
        }
    }

    return reply;
}


/*
 * Enforce a single running instance.
 *
 * Waydroid is supposed to stop us at session stop, but its cleanup cannot be
 * relied on. In tools/actions/container_manager.py:
 *
 *     try:
 *         ...                                     # several fallible steps
 *         if which("waydroid-sensord"):
 *             pid = run(["pidof", "waydroid-sensord"]).strip()
 *             if pid:
 *                 run(["kill", "-9", pid])        # pid is the WHOLE output
 *     except Exception as e:
 *         logging.debug(...)                      # swallowed
 *
 * Two problems: any earlier failure skips the kill silently, and once two
 * instances exist pidof returns "A B", which becomes a single argv element
 * `kill -9 "A B"` and always fails -- so the leak is self-perpetuating.
 * Observed on bigtab01: one session stop/start cycle left two daemons running,
 * both polling the sensor hub over i2c.
 *
 * So we take an exclusive flock ourselves. If another instance holds it, we
 * are the newer session's daemon and it is stale, so ask it to go and take
 * over. Returns the held fd, or -1 to abort startup.
 */
static int
app_take_lock(void)
{
    const char *path = NULL;
    int fd = -1;

    for (size_t i = 0; i < sizeof(LOCK_PATHS) / sizeof(LOCK_PATHS[0]); i++) {
        fd = open(LOCK_PATHS[i], O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        if (fd >= 0) {
            path = LOCK_PATHS[i];
            break;
        }
        GDEBUG("cannot open %s: %s", LOCK_PATHS[i], strerror(errno));
    }

    if (fd < 0) {
        /* Fail open. The lock is hygiene, not correctness: serving sensors
         * without it beats refusing to start. */
        GWARN("no writable lock file location; running without a "
              "single-instance guard");
        return -1;
    }

    for (int attempt = 0; attempt < 40; attempt++) {
        if (!flock(fd, LOCK_EX | LOCK_NB)) {
            char buf[32];
            int n = snprintf(buf, sizeof(buf), "%d\n", (int)getpid());
            if (ftruncate(fd, 0) || lseek(fd, 0, SEEK_SET) < 0 ||
                write(fd, buf, n) != n)
                GWARN("could not record our pid in %s", path);
            GDEBUG("holding %s", path);
            return fd;
        }
        if (errno != EWOULDBLOCK) {
            GWARN("flock(%s): %s -- continuing without a guard", path,
                  strerror(errno));
            close(fd);
            return -1;
        }
        if (attempt == 0) {
            char buf[32] = {0};
            int stale = 0;
            if (pread(fd, buf, sizeof(buf) - 1, 0) > 0)
                stale = atoi(buf);
            if (stale > 0 && stale != (int)getpid()) {
                GINFO("another waydroid-sensord (pid %d) is running; "
                      "asking it to exit", stale);
                if (kill(stale, SIGTERM) && errno != ESRCH)
                    GWARN("kill(%d, SIGTERM): %s", stale, strerror(errno));
            } else {
                GINFO("%s is locked by an unknown process; waiting", path);
            }
        }
        usleep(100000);         /* 40 x 100 ms = 4 s */
    }

    GWARN("another waydroid-sensord still holds %s after 4 s; starting anyway",
          path);
    close(fd);
    return -1;
}

static
void
app_add_service_done(
    GBinderServiceManager* sm,
    int status,
    void* user_data)
{
    App* app = (App*) user_data;

    if (status == GBINDER_STATUS_OK) {
        printf("Added \"%s\"\n", DEFAULT_NAME);
        app->ret = RET_OK;
    } else {
        GERR("Failed to add \"%s\" (%d)", DEFAULT_NAME, status);
        g_main_loop_quit(app->loop);
    }
}

/*
 * Deliberately not app_add_service_done: that one quits the main loop when
 * registration fails, which is right for sensors and wrong for lights. Losing
 * the brightness service must never cost the machine its accelerometer.
 */
static
void
lights_add_service_done(
    GBinderServiceManager* sm,
    int status,
    void* user_data)
{
    if (status == GBINDER_STATUS_OK) {
        /* GINFO, not printf: stdout is block-buffered once the daemon is
         * started with its output redirected to a log, so a printf here does
         * not appear until the buffer fills -- which for a line this rare
         * means never. */
        GINFO("Added \"%s/%s\"", LIGHT_IFACE, LIGHT_NAME);
    } else {
        GERR("Failed to add \"%s/%s\" (%d); brightness control is off, "
             "sensors continue", LIGHT_IFACE, LIGHT_NAME, status);
    }
}

static
void
app_sm_presence_handler(
    GBinderServiceManager* sm,
    void* user_data)
{
    App* app = (App*) user_data;

    if (gbinder_servicemanager_is_present(app->sm)) {
        GINFO("Service manager has reappeared");
        gbinder_servicemanager_add_service(app->sm, DEFAULT_NAME, app->obj,
            app_add_service_done, app);
        if (app->lightObj) {
            gbinder_servicemanager_add_service(app->sm, LIGHT_NAME,
                app->lightObj, lights_add_service_done, app);
        }
    } else {
        GINFO("Service manager has died");
        app->service->killLoops();
        /*
         * Android is gone; this daemon deliberately is not.  It stays up so it
         * can re-register when a new container appears, which means stopping a
         * Waydroid session never signals us and the RestoreInitial() on the
         * exit path in main() is simply never reached.
         *
         * On 2026-09-09 that left the panel at 0 with the SDDM greeter behind
         * it: a black screen on a machine whose only other input is ssh from
         * somewhere else.  Nothing on the host but this process is holding the
         * value Android dimmed away from, so the restore has to happen here.
         * See docs/37-brightness.md.
         */
        if (app->backlight)
            app->backlight->RestoreInitial("Android went away");
    }
}

static
void
app_run(
   App* app)
{
    guint sigtrm = g_unix_signal_add(SIGTERM, app_signal, app);
    guint sigint = g_unix_signal_add(SIGINT, app_signal, app);
    gulong presence_id = gbinder_servicemanager_add_presence_handler
        (app->sm, app_sm_presence_handler, app);

    app->loop = g_main_loop_new(NULL, TRUE);

    gbinder_servicemanager_add_service(app->sm, DEFAULT_NAME, app->obj,
        app_add_service_done, app);
    if (app->lightObj) {
        gbinder_servicemanager_add_service(app->sm, LIGHT_NAME, app->lightObj,
            lights_add_service_done, app);
    }

    GINFO("Waydroid Sensors HAL service ready.");

    g_main_loop_run(app->loop);

    if (sigtrm) g_source_remove(sigtrm);
    if (sigint) g_source_remove(sigint);
    gbinder_servicemanager_remove_handler(app->sm, presence_id);
    g_main_loop_unref(app->loop);
    app->loop = NULL;
}

int main(int argc, char* argv[])
{
    const char* device = DEFAULT_DEVICE;
    gboolean selftest = FALSE;
    gboolean backlight_info = FALSE;
    int backlight_set = -1;
    App app;

    gutil_log_timestamp = FALSE;
    gutil_log_set_type(GLOG_TYPE_STDERR, logtag);
    gutil_log_default.level = GLOG_LEVEL_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (!g_strcmp0(argv[i], "--selftest")) {
            selftest = TRUE;
        } else if (!g_strcmp0(argv[i], "--backlight-info")) {
            backlight_info = TRUE;
        } else if (!g_strcmp0(argv[i], "--backlight")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "--backlight needs a value 0..255\n");
                return RET_INVARG;
            }
            backlight_set = atoi(argv[++i]);
        } else if (!g_strcmp0(argv[i], "--verbose") ||
                   !g_strcmp0(argv[i], "-v")) {
            gutil_log_default.level = GLOG_LEVEL_VERBOSE;
        } else if (!g_strcmp0(argv[i], "--help") ||
                   !g_strcmp0(argv[i], "-h")) {
            printf("usage: %s [--selftest] [--verbose] [BINDER_DEVICE]\n"
                   "\n"
                   "  Waydroid sensors HAL, sourcing data from Linux IIO.\n"
                   "  Registers %s/%s on BINDER_DEVICE\n"
                   "  (default %s).\n"
                   "\n"
                   "  Also serves %s/%s, mapping Android's\n"
                   "  0..255 brightness onto the host panel backlight.\n"
                   "\n"
                   "  --selftest        read the sensors, cross-check them against\n"
                   "                    each other and exit; needs no container.\n"
                   "  --backlight-info  print the backlight device and the whole\n"
                   "                    0..255 -> raw mapping, and exit.\n"
                   "  --backlight N     set brightness to Android value N (0..255)\n"
                   "                    and exit. Needs no container either.\n",
                   argv[0], DEFAULT_IFACE, DEFAULT_NAME, DEFAULT_DEVICE,
                   LIGHT_IFACE, LIGHT_NAME);
            return RET_OK;
        } else {
            device = argv[i];
        }
    }

    if (backlight_info || backlight_set >= 0) {
        waydroid::Backlight bl;
        if (!bl.Available()) {
            fprintf(stderr, "no usable backlight found\n");
            return RET_NOTFOUND;
        }
        printf("device      %s\n", bl.Name().c_str());
        printf("max_brightness  %d\n", bl.MaxRaw());
        printf("actual          %d\n", bl.ReadRaw());

        if (backlight_info) {
            printf("\nandroid -> raw\n");
            for (int v = 0; v <= 255; v += 15)
                printf("  %3d -> %6d  (%5.1f%%)\n", v, bl.AndroidToRaw(v),
                       100.0 * bl.AndroidToRaw(v) / bl.MaxRaw());
        }
        if (backlight_set >= 0) {
            const int raw = bl.SetAndroidBrightness(backlight_set);
            printf("\nset %d/255 -> raw %d; panel now reads %d\n",
                   backlight_set, raw, bl.ReadRaw());
        }
        return RET_OK;
    }

    if (selftest) {
        printf("waydroid-sensord self-test\n\n");
        Sensors* svc = new Sensors();
        int bad = svc->iio()->SelfTest();
        return bad ? RET_ERR : RET_OK;
    }

    /* Best effort: make sure we are the only instance, so a leaked daemon
     * from a previous session is not left polling the sensor hub. Deliberately
     * non-fatal -- an earlier version aborted on failure and that stopped the
     * daemon starting at all when SELinux denied it the lock file. */
    app_take_lock();

    memset(&app, 0, sizeof(app));
    app.ret = RET_INVARG;
    app.service = new Sensors();
    app.backlight = new waydroid::Backlight();

    app.sm = gbinder_servicemanager_new2(device, "hidl", "hidl");
    if (gbinder_servicemanager_wait(app.sm, -1)) {
        app.obj = gbinder_servicemanager_new_local_object
            (app.sm, DEFAULT_IFACE, app_reply, &app);
        if (app.backlight->Available()) {
            app.lightObj = waydroid::lights_new_object(app.sm, app.backlight);
        } else {
            GWARN("No backlight device; ILight will not be registered");
        }
        app_run(&app);
        /* Leaving the panel wherever Android last dimmed it would be a trap:
         * once this process is gone, nothing on the host is left that could
         * ever brighten it again. */
        app.backlight->RestoreInitial("daemon exiting");
        if (app.lightObj)
            gbinder_local_object_unref(app.lightObj);
        gbinder_local_object_unref(app.obj);
        gbinder_servicemanager_unref(app.sm);
    }
    return app.ret;
}
