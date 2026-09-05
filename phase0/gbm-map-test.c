/*
 * Phase 0: can host Mesa map a YUV buffer via GBM?
 *
 * Waydroid's camera preview fails at:
 *   GBM-MESA-WRAPPER: Failed to map the buffer at gbm_mesa_wrapper.cpp:228
 *   ExtCamUtils@3.4:  formatConvert: unsupported flexible yuv layout y 0x0 cb 0x0 cr 0x0
 *
 * libgbm_mesa_wrapper.so calls Mesa's gbm_bo_map() on the YV12 buffer the Android
 * external camera HAL must write into. This reproduces that call directly against
 * host Mesa and the real GPU, to answer one question:
 *
 *   Does gbm_bo_map() work for YUV formats on this hardware and Mesa version?
 *
 * If YUV map fails while RGB succeeds, the minigbm fix is to allocate YUV as a
 * linear buffer (as it already does for BLOB) instead of a 2D texture.
 * If YUV map succeeds, the bug is in how the wrapper calls it, not in Mesa.
 *
 * Build: gcc -O1 -Wall -o gbm-map-test gbm-map-test.c $(pkg-config --cflags --libs gbm)
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <gbm.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static const char *node = "/dev/dri/renderD128";

struct fmt {
    const char *name;
    uint32_t code;
};

/* YV12 is what Android allocates for the camera preview stream (HAL 0x32315659). */
static struct fmt formats[] = {
    {"YVU420 (YV12)", GBM_FORMAT_YVU420},
    {"NV12",          GBM_FORMAT_NV12},
    {"YUYV",          GBM_FORMAT_YUYV},
    {"XRGB8888",      GBM_FORMAT_XRGB8888},   /* control: must succeed */
    {"R8",            GBM_FORMAT_R8},         /* control: linear-ish path */
};

struct usecase {
    const char *name;
    uint32_t flags;
};

static struct usecase usecases[] = {
    {"LINEAR|READ|WRITE",     GBM_BO_USE_LINEAR | GBM_BO_USE_SW_READ_OFTEN | GBM_BO_USE_SW_WRITE_OFTEN},
    {"LINEAR only",           GBM_BO_USE_LINEAR},
    {"RENDERING",             GBM_BO_USE_RENDERING},
    {"RENDERING|LINEAR",      GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR},
};

int main(void)
{
    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror(node);
        return 1;
    }

    struct gbm_device *dev = gbm_create_device(fd);
    if (!dev) {
        fprintf(stderr, "gbm_create_device failed\n");
        return 1;
    }
    printf("device: %s   backend: %s\n\n", node, gbm_device_get_backend_name(dev));

    const uint32_t W = 1280, H = 720;   /* the resolution the camera HAL requested */

    for (size_t f = 0; f < sizeof(formats) / sizeof(*formats); f++) {
        printf("=== %s ===\n", formats[f].name);

        if (!gbm_device_is_format_supported(dev, formats[f].code, GBM_BO_USE_LINEAR))
            printf("  gbm_device_is_format_supported(LINEAR): NO\n");

        for (size_t u = 0; u < sizeof(usecases) / sizeof(*usecases); u++) {
            struct gbm_bo *bo = gbm_bo_create(dev, W, H, formats[f].code, usecases[u].flags);
            if (!bo) {
                printf("  %-20s create: FAILED\n", usecases[u].name);
                continue;
            }

            uint32_t stride = 0;
            void *map_data = NULL;
            void *ptr = gbm_bo_map(bo, 0, 0, W, H,
                                   GBM_BO_TRANSFER_READ_WRITE, &stride, &map_data);

            printf("  %-20s create: ok  planes=%d bo_stride=%u  map: %s",
                   usecases[u].name, gbm_bo_get_plane_count(bo),
                   gbm_bo_get_stride(bo), ptr ? "OK" : "*** FAILED ***");
            if (ptr) {
                printf("  map_stride=%u", stride);
                memset(ptr, 0x10, 16);          /* prove it is really writable */
                gbm_bo_unmap(bo, map_data);
            }
            printf("\n");
            gbm_bo_destroy(bo);
        }
        printf("\n");
    }

    gbm_device_destroy(dev);
    close(fd);
    return 0;
}
