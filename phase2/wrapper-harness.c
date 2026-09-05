/*
 * Drive a candidate libgbm_mesa_wrapper.so through exactly the call sequence the
 * minigbm gralloc modules make for the camera buffer -- in a throwaway process,
 * before it is ever installed as the system-wide gralloc backend.
 *
 * Two reasons this exists:
 *
 *   1. Safety. The wrapper backs *all* graphics allocation in the container, not
 *      just the camera. Installing an untested rebuild risks a Waydroid that
 *      cannot render at all. This exercises it without touching /vendor.
 *   2. It is a direct A/B. Run it against the shipped .so and against a
 *      rebuild, and the outputs should agree line for line -- except for the
 *      camera import, which is the one thing the fix is meant to change.
 *
 * The sequences below mirror gbm_mesa_internals.cpp at commit a9367e8:
 *
 *   gbm_mesa_bo_create()  YV12 1280x720 has no GBM format, so it becomes a 1D
 *                         fallback: R8, ALIGN(total_size,4096) x 1, rewritten
 *                         again to 4096 x 338.
 *   gbm_mesa_bo_import()  s_width = total_size, s_height = 1, s_format = R8,
 *                         stride = data->strides[0] = the YV12 luma stride 1280.
 *                         ^ that disagreement is the bug (docs/07).
 *
 * Usage: wrapper-harness <path-to-libgbm_mesa_wrapper.so> [drm-node]
 *
 * Build: see phase2/build.sh --harness
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include "gbm_mesa_wrapper.h"

#define FOURCC(a, b, c, d) ((uint32_t)(a) | ((uint32_t)(b) << 8) | \
                            ((uint32_t)(c) << 16) | ((uint32_t)(d) << 24))
#define FMT_R8   FOURCC('R','8',' ',' ')
#define FMT_XR24 FOURCC('X','R','2','4')

/* 1280x720 YV12, as minigbm's drv_bo_from_format lays it out */
#define W 1280u
#define H 720u
#define YV12_LUMA_STRIDE   W
#define TOTAL_SIZE         (W * H * 3 / 2)                        /* 1382400 */
#define TOTAL_SIZE_A4K     (((TOTAL_SIZE + 4095) / 4096) * 4096)  /* 1384448 */

static struct gbm_ops *ops;

static void map_report(const char *what, struct gbm_bo *bo, int w, int h)
{
    void *addr = NULL, *md = NULL;
    ops->map(bo, w, h, &addr, &md);
    if (addr == NULL || addr == MAP_FAILED) {
        printf("    map %-34s FAILED (%s)\n", what, addr == NULL ? "NULL" : "MAP_FAILED");
        return;
    }
    printf("    map %-34s OK\n", what);
    memset(addr, 0x10, 16);            /* prove it is really writable */
    ops->unmap(bo, md);
}

/* The camera path: 1D R8 fallback, then the import gralloc actually performs. */
static void camera_path(struct gbm_device *dev)
{
    printf("== camera path (YV12 1280x720 -> 1D R8 fallback) ==\n");

    struct alloc_args a;
    memset(&a, 0, sizeof a);
    a.gbm = dev;
    a.width = 4096;                    /* the allocator's second rewrite */
    a.height = (TOTAL_SIZE_A4K + 4095) / 4096;                 /* 338 */
    a.drm_format = FMT_R8;
    a.force_linear = true;             /* BO_USE_SW_MASK is set for camera */
    a.needs_map_stride = true;
    a.use_scanout = true;              /* camera sets scanout_strong */

    int err = ops->alloc(&a);
    printf("  alloc %ux%u R8: %s  out_fd=%d out_stride=%u map_stride=%u modifier=0x%llx\n",
           a.width, a.height, err ? "FAILED" : "ok", a.out_fd, a.out_stride,
           a.out_map_stride, (unsigned long long)a.out_modifier);
    if (err)
        return;

    /* Exactly what gbm_mesa_bo_import() passes for this buffer. */
    printf("  import as gralloc does: w=%u h=1 R8 stride=%u (YV12 luma stride)\n",
           TOTAL_SIZE_A4K, YV12_LUMA_STRIDE);
    struct gbm_bo *bo = ops->import(dev, a.out_fd, TOTAL_SIZE_A4K, 1, YV12_LUMA_STRIDE,
                                    a.out_modifier, FMT_R8);
    if (!bo) {
        printf("    import FAILED  <-- the bug: gralloc then maps a NULL bo\n");
        close(a.out_fd);
        return;
    }
    printf("    import ok\n");
    /* gbm_mesa_bo_map() asks with the same rewritten dims */
    map_report("at s_width x 1", bo, TOTAL_SIZE_A4K, 1);
    map_report("at camera dims 1280x720", bo, W, H);
    ops->free(bo);
    close(a.out_fd);
}

/* Everything else in Android takes this path. It must keep working. */
static void rgb_path(struct gbm_device *dev)
{
    printf("\n== control: XRGB8888 1280x720, the path the rest of Android uses ==\n");

    struct alloc_args a;
    memset(&a, 0, sizeof a);
    a.gbm = dev;
    a.width = W; a.height = H; a.drm_format = FMT_XR24;
    a.force_linear = true; a.needs_map_stride = true;

    int err = ops->alloc(&a);
    printf("  alloc: %s  out_fd=%d out_stride=%u map_stride=%u\n",
           err ? "FAILED" : "ok", a.out_fd, a.out_stride, a.out_map_stride);
    if (err)
        return;

    struct gbm_bo *bo = ops->import(dev, a.out_fd, W, H, a.out_stride, a.out_modifier, FMT_XR24);
    printf("  import: %s\n", bo ? "ok" : "FAILED");
    if (bo) {
        map_report("at 1280x720", bo, W, H);
        ops->free(bo);
    }
    close(a.out_fd);
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);   /* a crash must not swallow the log */

    if (argc < 2) { fprintf(stderr, "usage: %s <wrapper.so> [drm-node]\n", argv[0]); return 2; }
    const char *node = argc > 2 ? argv[2] : "/dev/dri/renderD128";

    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen %s: %s\n", argv[1], dlerror()); return 1; }

    struct gbm_ops *(*get_gbm_ops)(void) = dlsym(h, "get_gbm_ops");
    if (!get_gbm_ops) { fprintf(stderr, "no get_gbm_ops: %s\n", dlerror()); return 1; }
    ops = get_gbm_ops();
    if (!ops) { fprintf(stderr, "get_gbm_ops returned NULL\n"); return 1; }
    printf("wrapper: %s\n\n", argv[1]);

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }

    struct gbm_device *dev = ops->dev_create(fd);
    if (!dev) { fprintf(stderr, "dev_create failed\n"); return 1; }

    camera_path(dev);
    rgb_path(dev);

    ops->dev_destroy(dev);
    close(fd);
    return 0;
}
