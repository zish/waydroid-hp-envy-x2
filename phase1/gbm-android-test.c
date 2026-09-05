/*
 * Phase 1: can ANDROID'S bundled Mesa allocate and map YUV via GBM?
 *
 * Phase 0 (phase0/gbm-map-test-dl.c) asked this of the *host's* Mesa 26.1.8 and got
 * a flat no -- YVU420 is neither supported nor allocatable on this Broadwell GPU.
 * But the Mesa that actually matters is the 41 MB libgallium_dri.so inside the
 * Waydroid image, reached through /vendor/lib64/libgbm_mesa.so. This is the same
 * probe retargeted to bionic/x86_64 so it can run in the container against that
 * Mesa.
 *
 * The upstream minigbm fix (waydroid/android_external_minigbm branch yuv, a41dbe7)
 * maps DRM_FORMAT_FLEX_YCbCr_420_888 -> GBM_FORMAT_YVU420 and then calls
 * gbm_bo_create() plus the per-plane accessors. If Android's Mesa refuses YVU420
 * the way the host's does, that fix cannot work here.
 *
 * Three questions, in order of importance:
 *   1. does gbm_bo_create(GBM_FORMAT_YVU420) succeed?           <- decides the build
 *   2. if so, do the per-plane accessors the fix relies on return sane values?
 *   3. can the R8 "1D fallback" buffer minigbm substitutes today be mapped?
 *      (phase 0 left this untested on Android's Mesa; it is the step that fails)
 *
 * Everything is dlopen'd and declared locally -- no gbm.h, no AOSP tree.
 *
 * Build: see phase1/build.sh (NDK clang, x86_64-linux-android33)
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | \
                            ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))

/* enum gbm_bo_flags, from Mesa's gbm.h */
enum {
    USE_SCANOUT = 1u << 0, USE_CURSOR = 1u << 1, USE_RENDERING = 1u << 2,
    USE_WRITE = 1u << 3, USE_LINEAR = 1u << 4, USE_PROTECTED = 1u << 5,
    USE_SW_READ_OFTEN = 1u << 9, USE_SW_READ_RARELY = 1u << 10,
    USE_SW_WRITE_OFTEN = 1u << 11, USE_SW_WRITE_RARELY = 1u << 12,
    USE_FRONT_RENDERING = 1u << 13,
};
enum { XFER_READ = 1u << 0, XFER_WRITE = 1u << 1 };
#define XFER_RW (XFER_READ | XFER_WRITE)

#define MOD_LINEAR 0ull   /* DRM_FORMAT_MOD_LINEAR */

struct gbm_device;
struct gbm_bo;

static struct gbm_device *(*p_create_device)(int);
static void (*p_device_destroy)(struct gbm_device *);
static const char *(*p_backend_name)(struct gbm_device *);
static int (*p_is_format_supported)(struct gbm_device *, uint32_t, uint32_t);
static struct gbm_bo *(*p_bo_create)(struct gbm_device *, uint32_t, uint32_t, uint32_t, uint32_t);
static void *(*p_bo_map)(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t,
                         uint32_t, uint32_t *, void **);
static void (*p_bo_unmap)(struct gbm_bo *, void *);
static uint32_t (*p_bo_get_stride)(struct gbm_bo *);
static int (*p_bo_get_plane_count)(struct gbm_bo *);
static void (*p_bo_destroy)(struct gbm_bo *);

/* the per-plane API the upstream fix depends on */
static uint32_t (*p_bo_get_stride_for_plane)(struct gbm_bo *, int);
static int (*p_bo_get_fd_for_plane)(struct gbm_bo *, int);
static uint32_t (*p_bo_get_offset)(struct gbm_bo *, int);
static uint64_t (*p_bo_get_modifier)(struct gbm_bo *);
static struct gbm_bo *(*p_bo_create_with_modifiers2)(struct gbm_device *, uint32_t, uint32_t,
                                                     uint32_t, const uint64_t *, unsigned int,
                                                     uint32_t);

struct sym { void **fn; const char *name; int required; };

static int bind_all(void *h)
{
    struct sym syms[] = {
        {(void **)&p_create_device,            "gbm_create_device",              1},
        {(void **)&p_device_destroy,           "gbm_device_destroy",             1},
        {(void **)&p_backend_name,             "gbm_device_get_backend_name",    1},
        {(void **)&p_is_format_supported,      "gbm_device_is_format_supported", 1},
        {(void **)&p_bo_create,                "gbm_bo_create",                  1},
        {(void **)&p_bo_map,                   "gbm_bo_map",                     1},
        {(void **)&p_bo_unmap,                 "gbm_bo_unmap",                   1},
        {(void **)&p_bo_get_stride,            "gbm_bo_get_stride",              1},
        {(void **)&p_bo_get_plane_count,       "gbm_bo_get_plane_count",         1},
        {(void **)&p_bo_destroy,               "gbm_bo_destroy",                 1},
        {(void **)&p_bo_get_stride_for_plane,  "gbm_bo_get_stride_for_plane",    0},
        {(void **)&p_bo_get_fd_for_plane,      "gbm_bo_get_fd_for_plane",        0},
        {(void **)&p_bo_get_offset,            "gbm_bo_get_offset",              0},
        {(void **)&p_bo_get_modifier,          "gbm_bo_get_modifier",            0},
        {(void **)&p_bo_create_with_modifiers2,"gbm_bo_create_with_modifiers2",  0},
    };
    int rc = 0;
    for (size_t i = 0; i < sizeof(syms) / sizeof(*syms); i++) {
        *syms[i].fn = dlsym(h, syms[i].name);
        if (!*syms[i].fn) {
            printf("%s symbol: %s\n", syms[i].required ? "MISSING required" : "absent optional",
                   syms[i].name);
            if (syms[i].required) rc = -1;
        }
    }
    return rc;
}

/* Report everything the fix would need to know about a successfully created bo. */
static void describe(struct gbm_bo *bo, uint32_t w, uint32_t h)
{
    int planes = p_bo_get_plane_count(bo);
    printf("      planes=%d stride=%u", planes, p_bo_get_stride(bo));
    if (p_bo_get_modifier) printf(" modifier=0x%llx", (unsigned long long)p_bo_get_modifier(bo));
    printf("\n");

    if (p_bo_get_stride_for_plane && p_bo_get_offset) {
        for (int i = 0; i < planes && i < 4; i++) {
            printf("      plane %d: stride=%-6u offset=%-9u", i,
                   p_bo_get_stride_for_plane(bo, i), p_bo_get_offset(bo, i));
            if (p_bo_get_fd_for_plane) {
                int fd = p_bo_get_fd_for_plane(bo, i);
                printf(" fd=%d", fd);
                if (fd >= 0) close(fd);
            }
            printf("\n");
        }
    }

    uint32_t map_stride = 0;
    void *md = NULL;
    void *ptr = p_bo_map(bo, 0, 0, w, h, XFER_RW, &map_stride, &md);
    printf("      map(%ux%u) %s", w, h, ptr ? "OK" : "*** FAILED ***");
    if (ptr) {
        printf(" map_stride=%u", map_stride);
        memset(ptr, 0x10, 16);          /* prove it is really writable */
        p_bo_unmap(bo, md);
    }
    printf("\n");
}

int main(int argc, char **argv)
{
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    const char *libs[] = { "libgbm_mesa.so", "/vendor/lib64/libgbm_mesa.so",
                           "/system/lib64/libgbm_mesa.so" };
    void *h = NULL;

    for (size_t i = 0; i < sizeof(libs) / sizeof(*libs) && !h; i++) {
        h = dlopen(libs[i], RTLD_NOW);
        printf("dlopen %-32s %s\n", libs[i], h ? "OK" : dlerror());
    }
    if (!h) return 1;
    if (bind_all(h) != 0) return 1;
    printf("\n");

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }

    struct gbm_device *dev = p_create_device(fd);
    if (!dev) { fprintf(stderr, "gbm_create_device failed on %s\n", node); return 1; }
    printf("device : %s\nbackend: %s\n\n", node, p_backend_name(dev));

    struct { const char *name; uint32_t code; } formats[] = {
        {"YVU420 (YV12)",  FOURCC('Y','V','1','2')},  /* what the fix maps FLEX to */
        {"NV12",           FOURCC('N','V','1','2')},
        {"YUYV",           FOURCC('Y','U','Y','V')},
        {"FLEX_YCbCr_420", 926497081u},               /* 0x37393939, what the HAL asks for */
        {"XRGB8888",       FOURCC('X','R','2','4')},  /* control: must succeed */
        {"R8",             FOURCC('R','8',' ',' ')},  /* control: the 1D fallback path */
    };
    struct { const char *name; uint32_t flags; } uses[] = {
        {"LINEAR|SWR|SWW", USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN},
        {"LINEAR",         USE_LINEAR},
        {"RENDERING",      USE_RENDERING},
        {"RENDER|LINEAR",  USE_RENDERING | USE_LINEAR},
    };

    const uint32_t W = 1280, H = 720;   /* resolution the camera HAL requested */

    for (size_t f = 0; f < sizeof(formats) / sizeof(*formats); f++) {
        printf("=== %-15s (0x%08x)  supported(LINEAR)=%s ===\n", formats[f].name,
               formats[f].code,
               p_is_format_supported(dev, formats[f].code, USE_LINEAR) ? "yes" : "NO");
        for (size_t u = 0; u < sizeof(uses) / sizeof(*uses); u++) {
            struct gbm_bo *bo = p_bo_create(dev, W, H, formats[f].code, uses[u].flags);
            printf("  create %-15s %s\n", uses[u].name, bo ? "ok" : "FAILED");
            if (!bo) continue;
            describe(bo, W, H);
            p_bo_destroy(bo);
        }
        /* the modifier path, in case plain create is the only thing refused */
        if (p_bo_create_with_modifiers2) {
            uint64_t mods[] = { MOD_LINEAR };
            struct gbm_bo *bo = p_bo_create_with_modifiers2(dev, W, H, formats[f].code, mods, 1,
                                                            USE_LINEAR | USE_SW_READ_OFTEN |
                                                            USE_SW_WRITE_OFTEN);
            printf("  create %-15s %s\n", "MODIFIER:LINEAR", bo ? "ok" : "FAILED");
            if (bo) { describe(bo, W, H); p_bo_destroy(bo); }
        }
        printf("\n");
    }

    /*
     * The buffer minigbm actually substitutes today, from the failure log:
     *   "Allocate 1D buffer as 4096x338 R8 2D texture"
     * Mapping it is the step that fails inside the camera HAL. Phase 0 showed the
     * host's Mesa maps it fine both ways; this is the same check on Android's Mesa.
     */
    printf("=== R8 1D fallback, exactly as minigbm allocates it today ===\n");
    struct gbm_bo *bo = p_bo_create(dev, 4096, 338, FOURCC('R','8',' ',' '),
                                    USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
    if (!bo) {
        printf("  create 4096x338 R8 FAILED\n");
    } else {
        printf("  create 4096x338 R8 ok\n");
        printf("    as allocated extent:\n");
        describe(bo, 4096, 338);
        printf("    as logical camera dims (what the wrapper maps with):\n");
        describe(bo, 1280, 720);
        p_bo_destroy(bo);
    }

    p_device_destroy(dev);
    close(fd);
    return 0;
}
