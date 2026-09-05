/*
 * Phase 0b: is the bug a geometry mismatch in minigbm's 1D fallback?
 *
 * Established in phase 0a: host Mesa cannot allocate YUV formats at all, so minigbm
 * falls back to a linear "1D buffer", logged as:
 *
 *   Unable to allocate 0x37393939 format, allocate as 1D buffer   (= FLEX_YCbCr_420_888)
 *   Allocate 1D buffer as 4096x338 R8 2D texture
 *   Allocated: 1280x720, stride: 4096, map_stride: 4096
 *
 * The buffer physically exists as a 4096x338 R8 texture. 4096*338 = 1384448 bytes,
 * which covers a 1280x720 YV12 frame (1280*720*3/2 = 1382400).
 *
 * Hypothesis: the wrapper then calls gbm_bo_map() with the LOGICAL dimensions
 * (1280x720) rather than the ALLOCATED ones (4096x338). Height 720 > 338, so the
 * map region is out of bounds and Mesa refuses it.
 *
 * This tests exactly that, on the real allocation geometry from the log.
 *
 * Build: gcc -O1 -Wall -o gbm-fallback-test gbm-fallback-test.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define FOURCC(a,b,c,d) ((uint32_t)(a)|((uint32_t)(b)<<8)|((uint32_t)(c)<<16)|((uint32_t)(d)<<24))
enum { USE_LINEAR = 1u << 4, USE_SW_READ_OFTEN = 1u << 9, USE_SW_WRITE_OFTEN = 1u << 11 };
enum { XFER_READ = 1u << 0, XFER_WRITE = 1u << 1 };
#define XFER_RW (XFER_READ | XFER_WRITE)

struct gbm_device; struct gbm_bo;
static struct gbm_device *(*p_create_device)(int);
static struct gbm_bo *(*p_bo_create)(struct gbm_device *, uint32_t, uint32_t, uint32_t, uint32_t);
static void *(*p_bo_map)(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t *, void **);
static void (*p_bo_unmap)(struct gbm_bo *, void *);
static uint32_t (*p_bo_get_stride)(struct gbm_bo *);
static void (*p_bo_destroy)(struct gbm_bo *);

#define BIND(v, n) do { *(void **)&v = dlsym(h, n); if (!v) { fprintf(stderr, "missing %s\n", n); return 1; } } while (0)

/* Try mapping a sub-rectangle of an already-created bo, and report the outcome. */
static void try_map(struct gbm_bo *bo, const char *label,
                    uint32_t x, uint32_t y, uint32_t w, uint32_t h)
{
    uint32_t stride = 0; void *md = NULL;
    void *ptr = p_bo_map(bo, x, y, w, h, XFER_RW, &stride, &md);
    printf("    map %-28s (%4u x %4u) : %s", label, w, h,
           ptr ? "OK" : "*** FAILED ***");
    if (ptr) { printf("  map_stride=%u", stride); memset(ptr, 0x10, 16); p_bo_unmap(bo, md); }
    printf("\n");
}

int main(int argc, char **argv)
{
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    void *h = dlopen("libgbm.so.1", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    BIND(p_create_device, "gbm_create_device");
    BIND(p_bo_create, "gbm_bo_create");
    BIND(p_bo_map, "gbm_bo_map");
    BIND(p_bo_unmap, "gbm_bo_unmap");
    BIND(p_bo_get_stride, "gbm_bo_get_stride");
    BIND(p_bo_destroy, "gbm_bo_destroy");

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }
    struct gbm_device *dev = p_create_device(fd);
    if (!dev) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }

    const uint32_t R8 = FOURCC('R','8',' ',' ');
    const uint32_t AW = 4096, AH = 338;      /* exactly what minigbm logged */
    const uint32_t LW = 1280, LH = 720;      /* logical YV12 frame dims */
    const uint32_t flags = USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN;

    printf("Reproducing minigbm's 1D fallback: R8 %ux%u (= %u bytes)\n",
           AW, AH, AW * AH);
    printf("YV12 %ux%u needs %u bytes\n\n", LW, LH, LW * LH * 3 / 2);

    struct gbm_bo *bo = p_bo_create(dev, AW, AH, R8, flags);
    if (!bo) { printf("  create FAILED -- fallback geometry itself is unusable\n"); return 1; }
    printf("  created ok, bo_stride=%u\n", p_bo_get_stride(bo));

    try_map(bo, "full allocated extent",   0, 0, AW, AH);
    try_map(bo, "logical dims (the bug?)", 0, 0, LW, LH);
    try_map(bo, "logical width, safe hgt", 0, 0, LW, AH);
    try_map(bo, "one row",                 0, 0, AW, 1);

    p_bo_destroy(bo);
    close(fd);
    return 0;
}
