/*
 * waydroid-wifid -- a host-side daemon that serves Android's Wi-Fi native
 * interfaces over binder, backed by whatever owns the radio on the host.
 *
 * This is the same shape as waydroid-sensord (docs/14-sensors.md): keep the
 * interface Android expects, replace the data source.  It works for the same
 * verified reason -- lxc/waydroid/config_nodes bind-mounts /dev/binder,
 * /dev/vndbinder and /dev/hwbinder from the host into the container, so a host
 * process shares the guest's binder domains.  Waydroid itself relies on this:
 * its own IPlatform / IUserMonitor / IClipboard services are host-side
 * python-gbinder objects registered in the container's servicemanager.
 *
 * Stage 2 registers "wifinl80211" (IWificond).  Stage 4 adds the supplicant,
 * which is AIDL on the same device -- see docs/30-wifi-aidl-surface.md.
 *
 * Usage:
 *   waydroid-wifid [--device IFNAME] [--verbose] [/dev/binder]
 *   waydroid-wifid --devices        list the host's Wi-Fi radios and exit
 *   waydroid-wifid --scan           scan through the backend and print the
 *                                   result; needs no container at all
 */

#include "NativeScanResult.h"
#include "NmBackend.h"
#include "Wificond.h"

#include <gutil_log.h>

#include <errno.h>
#include <fcntl.h>
#include <glib-unix.h>
#include <signal.h>
#include <string.h>
#include <sys/file.h>
#include <unistd.h>

#include <cstdio>
#include <memory>

using namespace waydroid::wifi;

#define RET_OK      (0)
#define RET_ERR     (1)
#define RET_INVARG  (2)

#define DEFAULT_DEVICE  "/dev/binder"
#define SERVICE_NAME    "wifinl80211"

/*
 * Android 13 is API 33, and waydroid's own tools/helpers/protocol.py maps that
 * to binder_protocol=aidl3 / service_manager_protocol=aidl3 -- the same values
 * it cached in /var/lib/waydroid/waydroid.cfg on this host.  libgbinder's
 * built-in default for /dev/binder is the much older "aidl", so these must be
 * passed explicitly or every parcel is one int32 short of correct.
 */
#define SM_PROTOCOL     "aidl3"
#define RPC_PROTOCOL    "aidl3"

/*
 * Lock file location matters -- see the long note in sensors/service.cpp.
 * /var/lib/waydroid is waydroid_data_t, which the waydroid_t domain writes
 * routinely; /run is var_run_t and fails with EACCES when we are started by
 * waydroid rather than from an ssh login.
 */
static const char* const LOCK_PATHS[] = {
    "/var/lib/waydroid/waydroid-wifid.pid",
    "/run/waydroid-wifid.pid",
    "/tmp/waydroid-wifid.pid",
};

static const char logtag[] = "waydroid-wifid";

typedef struct app {
    GMainLoop* loop;
    GBinderServiceManager* sm;
    Wificond* service;
    int ret;
} App;

static gboolean
app_signal(gpointer user_data)
{
    App* app = (App*) user_data;

    GINFO("Caught signal, shutting down...");
    g_main_loop_quit(app->loop);
    return G_SOURCE_CONTINUE;
}

static int
app_take_lock(void)
{
    const char* path = nullptr;
    int fd = -1;

    for (size_t i = 0; i < G_N_ELEMENTS(LOCK_PATHS); i++) {
        fd = open(LOCK_PATHS[i], O_RDWR | O_CREAT | O_CLOEXEC, 0644);
        if (fd >= 0) {
            path = LOCK_PATHS[i];
            break;
        }
        GDEBUG("cannot open %s: %s", LOCK_PATHS[i], strerror(errno));
    }
    if (fd < 0) {
        GWARN("no writable lock file location; running without a "
              "single-instance guard");
        return -1;
    }

    for (int attempt = 0; attempt < 40; attempt++) {
        if (!flock(fd, LOCK_EX | LOCK_NB)) {
            char buf[32];
            int n = snprintf(buf, sizeof(buf), "%d\n", (int) getpid());
            if (ftruncate(fd, 0) || lseek(fd, 0, SEEK_SET) < 0 ||
                write(fd, buf, n) != n) {
                GWARN("could not record our pid in %s", path);
            }
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
            if (pread(fd, buf, sizeof(buf) - 1, 0) > 0) {
                stale = atoi(buf);
            }
            if (stale > 0 && stale != (int) getpid()) {
                GINFO("another waydroid-wifid (pid %d) is running; asking it "
                      "to exit", stale);
                if (kill(stale, SIGTERM) && errno != ESRCH) {
                    GWARN("kill(%d, SIGTERM): %s", stale, strerror(errno));
                }
            }
        }
        usleep(100000);         /* 40 x 100 ms = 4 s */
    }
    GWARN("another waydroid-wifid still holds %s after 4 s; starting anyway",
          path);
    close(fd);
    return -1;
}

static void
app_add_service_done(GBinderServiceManager* sm, int status, void* user_data)
{
    App* app = (App*) user_data;

    if (status == GBINDER_STATUS_OK) {
        GINFO("Registered \"%s\"", SERVICE_NAME);
        app->ret = RET_OK;
    } else {
        GERR("Failed to register \"%s\" (%d)", SERVICE_NAME, status);
        g_main_loop_quit(app->loop);
    }
}

/*
 * docs/16-waydroid-network.md is a direct warning here: a stale binder
 * registration that survived a system_server restart deadlocked Android's
 * network stack for 38 minutes.  When servicemanager goes and comes back we
 * re-register rather than leaving a dead name behind.
 */
static void
app_sm_presence_handler(GBinderServiceManager* sm, void* user_data)
{
    App* app = (App*) user_data;

    if (gbinder_servicemanager_is_present(app->sm)) {
        GINFO("Service manager reappeared, re-registering");
        gbinder_servicemanager_add_service(app->sm, SERVICE_NAME,
            app->service->object(), app_add_service_done, app);
    } else {
        GINFO("Service manager has died");
    }
}

static void
app_run(App* app)
{
    guint sigtrm = g_unix_signal_add(SIGTERM, app_signal, app);
    guint sigint = g_unix_signal_add(SIGINT, app_signal, app);
    gulong presence_id = gbinder_servicemanager_add_presence_handler(app->sm,
        app_sm_presence_handler, app);

    app->loop = g_main_loop_new(nullptr, TRUE);

    gbinder_servicemanager_add_service(app->sm, SERVICE_NAME,
        app->service->object(), app_add_service_done, app);

    GINFO("waydroid-wifid ready.");
    g_main_loop_run(app->loop);

    if (sigtrm) g_source_remove(sigtrm);
    if (sigint) g_source_remove(sigint);
    gbinder_servicemanager_remove_handler(app->sm, presence_id);
    g_main_loop_unref(app->loop);
    app->loop = nullptr;
}

static void
print_bss(const Bss& b, uint64_t nowUsec)
{
    char mac[18];
    char age[16] = "  ?";

    snprintf(mac, sizeof(mac), "%02x:%02x:%02x:%02x:%02x:%02x",
             b.bssid[0], b.bssid[1], b.bssid[2],
             b.bssid[3], b.bssid[4], b.bssid[5]);
    if (b.lastSeenUsec && nowUsec > b.lastSeenUsec) {
        snprintf(age, sizeof(age), "%3llus",
                 (unsigned long long) ((nowUsec - b.lastSeenUsec) / 1000000));
    }
    printf("  %-32s %s  %5d MHz  %4d dBm  %-14s seen %s\n",
           b.ssid.empty() ? "(hidden)" : b.ssid.c_str(), mac, b.freqMhz,
           b.rssiDbm, securityName(b.security), age);
}

/*
 * The same IE blob and capability field the container would be handed, printed
 * as hex.  This is the one part of the Android-facing marshalling that can be
 * checked without a container at all, so it is worth being able to look at.
 */
static void
print_bss_ies(const Bss& b)
{
    std::vector<uint8_t> ies = buildBeaconIes(b);

    printf("      capability 0x%04x  ies", beaconCapability(b));
    for (uint8_t x : ies) {
        printf(" %02x", x);
    }
    printf("\n");
}

/* --scan waits for a real scan rather than assuming one; see WifiBackend.h. */
typedef struct scan_wait {
    GMainLoop* loop;
    bool ok;
    guint timeout;
} ScanWait;

static gboolean
scan_wait_timeout(gpointer user)
{
    ScanWait* w = (ScanWait*) user;

    GWARN("timed out waiting for the backend to finish a scan");
    w->timeout = 0;
    g_main_loop_quit(w->loop);
    return G_SOURCE_REMOVE;
}

int
main(int argc, char* argv[])
{
    const char* device = DEFAULT_DEVICE;
    const char* want_dev = nullptr;
    bool list_devices = false;
    bool do_scan = false;
    App app;

    gutil_log_timestamp = FALSE;
    gutil_log_set_type(GLOG_TYPE_STDERR, logtag);
    gutil_log_default.level = GLOG_LEVEL_DEFAULT;

    for (int i = 1; i < argc; i++) {
        if (!g_strcmp0(argv[i], "--devices")) {
            list_devices = true;
        } else if (!g_strcmp0(argv[i], "--scan")) {
            do_scan = true;
        } else if (!g_strcmp0(argv[i], "--device") && i + 1 < argc) {
            want_dev = argv[++i];
        } else if (!g_strcmp0(argv[i], "--verbose") ||
                   !g_strcmp0(argv[i], "-v")) {
            gutil_log_default.level = GLOG_LEVEL_VERBOSE;
        } else if (!g_strcmp0(argv[i], "--help") ||
                   !g_strcmp0(argv[i], "-h")) {
            printf("usage: %s [--device IFNAME] [--verbose] [BINDER_DEVICE]\n"
                   "       %s --devices | --scan\n"
                   "\n"
                   "  Serves Android's %s over %s (protocol %s),\n"
                   "  backed by a host Wi-Fi backend.\n"
                   "\n"
                   "  --devices   list the host's Wi-Fi radios and exit\n"
                   "  --scan      scan through the backend and print the\n"
                   "              result; needs no container\n",
                   argv[0], argv[0], SERVICE_NAME, DEFAULT_DEVICE,
                   RPC_PROTOCOL);
            return RET_OK;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return RET_INVARG;
        } else {
            device = argv[i];
        }
    }

    std::unique_ptr<WifiBackend> backend(new NmBackend());
    if (want_dev) {
        backend->selectDevice(want_dev);
    }
    if (!backend->init()) {
        GERR("backend \"%s\" failed to start", backend->name());
        return RET_ERR;
    }

    if (list_devices) {
        for (const std::string& d : backend->devices()) {
            printf("%s%s\n", d.c_str(),
                   d == backend->selectedDevice() ? "  (selected)" : "");
        }
        return RET_OK;
    }

    if (do_scan) {
        ScanWait wait = { g_main_loop_new(nullptr, FALSE), false, 0 };

        printf("backend: %s, radio: %s, enabled: %s\n", backend->name(),
               backend->selectedDevice().c_str(),
               backend->isEnabled() ? "yes" : "no");

        backend->onScanComplete([&wait](bool ok) {
            wait.ok = ok;
            g_main_loop_quit(wait.loop);
        });
        if (!backend->startScan()) {
            GWARN("startScan() failed");
        } else {
            wait.timeout = g_timeout_add_seconds(20, scan_wait_timeout, &wait);
            g_main_loop_run(wait.loop);
            if (wait.timeout) {
                g_source_remove(wait.timeout);
            }
        }
        backend->onScanComplete(nullptr);
        g_main_loop_unref(wait.loop);
        printf("scan: %s\n", wait.ok ? "completed" : "did not complete");

        std::vector<Bss> results = backend->scanResults();
        uint64_t now = boottimeUsec();
        printf("%zu access points\n", results.size());
        for (const Bss& b : results) {
            print_bss(b, now);
            if (gutil_log_default.level >= GLOG_LEVEL_VERBOSE) {
                print_bss_ies(b);
            }
        }
        LinkState st = backend->state();
        printf("link: %s%s\n", st.associated ? "associated to " : "idle",
               st.associated ? st.ssid.c_str() : "");
        return RET_OK;
    }

    app_take_lock();

    memset(&app, 0, sizeof(app));
    app.ret = RET_ERR;
    app.sm = gbinder_servicemanager_new2(device, SM_PROTOCOL, RPC_PROTOCOL);
    if (!app.sm) {
        GERR("cannot open %s", device);
        return RET_ERR;
    }

    GINFO("waiting for the container's service manager on %s", device);
    if (gbinder_servicemanager_wait(app.sm, -1)) {
        app.service = new Wificond(app.sm, backend.get());
        app_run(&app);
        delete app.service;
        app.service = nullptr;
        gbinder_servicemanager_unref(app.sm);
    }
    return app.ret;
}
