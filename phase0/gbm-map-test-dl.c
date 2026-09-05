/*
 * Phase 0: can host Mesa map a YUV buffer via GBM?
 *
 * Waydroid's camera preview fails at:
 *   GBM-MESA-WRAPPER: Failed to map the buffer at gbm_mesa_wrapper.cpp:228
 *   ExtCamUtils@3.4:  formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0
 *
 * libgbm_mesa_wrapper.so calls Mesa's gbm_bo_map() on the YV12 buffer the Android
 * external camera HAL writes into. This reproduces that call against the SAME
 * libgbm the host uses, to answer one question:
 *
 *   Does gbm_bo_map() work for YUV formats on this GPU and Mesa version?
 *
 * Everything is loaded with dlopen and declared locally, so this needs no gbm.h
 * and no toolbox container -- and, more importantly, it exercises the host's real
 * /usr/lib64/libgbm.so.1 rather than a container's possibly-different Mesa.
 *
 * Build: gcc -O1 -Wall -o gbm-map-test-dl gbm-map-test-dl.c -ldl
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

static int bind_all(void *h)
{
    struct { void **fn; const char *name; } syms[] = {
        {(void **)&p_create_device, "gbm_create_device"},
        {(void **)&p_device_destroy, "gbm_device_destroy"},
        {(void **)&p_backend_name, "gbm_device_get_backend_name"},
        {(void **)&p_is_format_supported, "gbm_device_is_format_supported"},
        {(void **)&p_bo_create, "gbm_bo_create"},
        {(void **)&p_bo_map, "gbm_bo_map"},
        {(void **)&p_bo_unmap, "gbm_bo_unmap"},
        {(void **)&p_bo_get_stride, "gbm_bo_get_stride"},
        {(void **)&p_bo_get_plane_count, "gbm_bo_get_plane_count"},
        {(void **)&p_bo_destroy, "gbm_bo_destroy"},
    };
    for (size_t i = 0; i < sizeof(syms) / sizeof(*syms); i++) {
        *syms[i].fn = dlsym(h, syms[i].name);
        if (!*syms[i].fn) {
            fprintf(stderr, "missing symbol: %s\n", syms[i].name);
            return -1;
        }
    }
    return 0;
}

int main(int argc, char **argv)
{
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";

    void *h = dlopen("libgbm.so.1", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    if (bind_all(h) != 0) return 1;

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }

    struct gbm_device *dev = p_create_device(fd);
    if (!dev) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }
    printf("device : %s\nbackend: %s\n\n", node, p_backend_name(dev));

    struct { const char *name; uint32_t code; } formats[] = {
        {"YVU420 (YV12)", FOURCC('Y','V','1','2')},   /* what Android allocates for preview */
        {"NV12",          FOURCC('N','V','1','2')},
        {"YUYV",          FOURCC('Y','U','Y','V')},
        {"XRGB8888",      FOURCC('X','R','2','4')},   /* control: must succeed */
        {"R8",            FOURCC('R','8',' ',' ')},   /* control: linear path */
    };
    struct { const char *name; uint32_t flags; } uses[] = {
        {"LINEAR|SWR|SWW", USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN},
        {"LINEAR",         USE_LINEAR},
        {"RENDERING",      USE_RENDERING},
        {"RENDER|LINEAR",  USE_RENDERING | USE_LINEAR},
    };

    const uint32_t W = 1280, H = 720;   /* resolution the camera HAL requested */

    for (size_t f = 0; f < sizeof(formats) / sizeof(*formats); f++) {
        printf("=== %-14s  supported(LINEAR)=%s ===\n", formats[f].name,
               p_is_format_supported(dev, formats[f].code, USE_LINEAR) ? "yes" : "NO");
        for (size_t u = 0; u < sizeof(uses) / sizeof(*uses); u++) {
            struct gbm_bo *bo = p_bo_create(dev, W, H, formats[f].code, uses[u].flags);
            if (!bo) { printf("  %-15s create FAILED\n", uses[u].name); continue; }

            uint32_t map_stride = 0;
            void *md = NULL;
            void *ptr = p_bo_map(bo, 0, 0, W, H, XFER_RW, &map_stride, &md);
            printf("  %-15s create ok  planes=%d stride=%-5u  map %s",
                   uses[u].name, p_bo_get_plane_count(bo), p_bo_get_stride(bo),
                   ptr ? "OK" : "*** FAILED ***");
            if (ptr) {
                printf("  map_stride=%u", map_stride);
                memset(ptr, 0x10, 16);          /* prove it is really writable */
                p_bo_unmap(bo, md);
            }
            printf("\n");
            p_bo_destroy(bo);
        }
        printf("\n");
    }

    p_device_destroy(dev);
    close(fd);
    return 0;
}
