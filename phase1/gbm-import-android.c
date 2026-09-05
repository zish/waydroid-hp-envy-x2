/*
 * Phase 1b: reproduce, against Android's own Mesa, the exact gbm_bo_import()
 * the shipped gbm_mesa wrapper performs for the camera buffer -- and the
 * alternatives that might work instead.
 *
 * Why: the shipped /vendor/lib64/libgbm_mesa_wrapper.so was fingerprinted to
 * waydroid/android_external_minigbm commit a9367e8 (both "Failed to map the
 * buffer" call sites land on lines 183 and 228, matching that commit exactly).
 * At that commit, allocation and import disagree about the buffer's geometry:
 *
 *   ALLOCATOR (gbm_mesa_bo_create):
 *     YV12 1280x720 -> no GBM format -> 1D fallback
 *     width = ALIGN(total_size, 4096) = 1384448, height = 1
 *     -> rewritten again to a 4096 x 338 R8 2D texture
 *     -> gbm_bo_create(4096, 338, R8)            stride 4096   [log confirms]
 *
 *   MAPPER (gbm_mesa_bo_import):
 *     s_width  = bo->meta.total_size   (~1384448)
 *     s_height = 1
 *     s_format = DRM_FORMAT_R8
 *     stride   = data->strides[0]      = 1280  <-- the YV12 luma stride!
 *
 * So the import claims a 1384448-pixel-wide R8 image with a stride of 1280.
 * Stride is far smaller than the width. If Mesa rejects that, gbm_bo_import
 * returns NULL, the subsequent gbm_bo_map returns NULL, and the camera HAL is
 * handed the all-zero plane layout we observed. This probe tests that directly.
 *
 * Variants, in order:
 *   A  shipped geometry (w=total_size, h=1, stride=1280)   <- expect FAIL
 *   B  1D but self-consistent (stride = width)
 *   C  the geometry the buffer was really allocated with (4096x338, stride 4096)
 *   D  proper 3-plane YVU420 import from the one dmabuf, with real offsets
 *
 * D matters most for the way forward: Mesa cannot *allocate* YUV (proved by
 * gbm-android-test), but importing YUV dmabufs is a different code path in
 * Mesa and may well work. If D maps, a fix is possible that never asks Mesa to
 * allocate YUV at all.
 *
 * Build: see phase1/build.sh
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
#define FMT_R8   FOURCC('R','8',' ',' ')
#define FMT_YV12 FOURCC('Y','V','1','2')

enum { USE_LINEAR = 1u << 4, USE_SW_READ_OFTEN = 1u << 9, USE_SW_WRITE_OFTEN = 1u << 11 };
enum { XFER_READ = 1u << 0, XFER_WRITE = 1u << 1 };
#define XFER_RW (XFER_READ | XFER_WRITE)

#define GBM_BO_IMPORT_FD_MODIFIER 0x5504

struct gbm_import_fd_modifier_data {
    uint32_t width, height, format, num_fds;
    int fds[4]; int strides[4]; int offsets[4]; uint64_t modifier;
};

struct gbm_device; struct gbm_bo;
static struct gbm_device *(*p_create_device)(int);
static void (*p_device_destroy)(struct gbm_device *);
static struct gbm_bo *(*p_bo_create)(struct gbm_device *, uint32_t, uint32_t, uint32_t, uint32_t);
static struct gbm_bo *(*p_bo_import)(struct gbm_device *, uint32_t, void *, uint32_t);
static void *(*p_bo_map)(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                         uint32_t *, void **);
static void (*p_bo_unmap)(struct gbm_bo *, void *);
static uint32_t (*p_bo_get_stride)(struct gbm_bo *);
static int (*p_bo_get_fd)(struct gbm_bo *);
static int (*p_bo_get_plane_count)(struct gbm_bo *);
static uint64_t (*p_bo_get_modifier)(struct gbm_bo *);
static void (*p_bo_destroy)(struct gbm_bo *);

#define BIND(v, n) do { *(void **)&v = dlsym(h, n); \
    if (!v) { fprintf(stderr, "missing %s\n", n); return 1; } } while (0)

/* 1280x720 YV12, exactly as minigbm's drv_bo_from_format lays it out */
#define W 1280u
#define H 720u
static const uint32_t YV12_STRIDES[3] = { W, W / 2, W / 2 };
static const uint32_t YV12_OFFSETS[3] = { 0, W * H, W * H + (W / 2) * (H / 2) };
#define TOTAL_SIZE      (W * H * 3 / 2)                 /* 1382400 */
#define TOTAL_SIZE_A4K  (((TOTAL_SIZE + 4095) / 4096) * 4096)  /* 1384448 */

static void map_report(struct gbm_bo *bo, const char *what, uint32_t w, uint32_t h)
{
    uint32_t stride = 0; void *md = NULL;
    void *ptr = p_bo_map(bo, 0, 0, w, h, XFER_RW, &stride, &md);
    printf("      map %-28s %s", what, ptr ? "OK" : "*** FAILED ***");
    if (ptr) { printf("  map_stride=%u", stride); memset(ptr, 0x10, 16); p_bo_unmap(bo, md); }
    printf("\n");
}

static const char *g_only = NULL;   /* run one variant per process: a segfault in
                                     * one must not truncate the others */
static uint32_t g_extra_w, g_extra_h;

static void try_import(struct gbm_device *dev, const char *id, const char *label,
                       struct gbm_import_fd_modifier_data *d)
{
    if (g_only && strcmp(g_only, id) != 0)
        return;
    printf("  %s\n", label);
    printf("      request: %ux%u fmt=0x%08x num_fds=%u stride0=%d offset0=%d mod=0x%llx\n",
           d->width, d->height, d->format, d->num_fds, d->strides[0], d->offsets[0],
           (unsigned long long)d->modifier);

    struct gbm_bo *bo = p_bo_import(dev, GBM_BO_IMPORT_FD_MODIFIER, d, 0);
    if (!bo) { printf("      import *** FAILED ***\n\n"); return; }

    printf("      import OK  planes=%d stride=%u\n", p_bo_get_plane_count(bo),
           p_bo_get_stride(bo));
    map_report(bo, "at import dims", d->width, d->height);
    map_report(bo, "at camera dims 1280x720", W, H);
    if (g_extra_w)
        map_report(bo, "at s_width x 1 (gbm_mesa_bo_map)", g_extra_w, g_extra_h);
    p_bo_destroy(bo);
    printf("\n");
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);   /* a crash must not swallow the log */
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    g_only = argc > 2 ? argv[2] : NULL;
    void *h = dlopen("libgbm_mesa.so", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }

    BIND(p_create_device, "gbm_create_device");
    BIND(p_device_destroy, "gbm_device_destroy");
    BIND(p_bo_create, "gbm_bo_create");
    BIND(p_bo_import, "gbm_bo_import");
    BIND(p_bo_map, "gbm_bo_map");
    BIND(p_bo_unmap, "gbm_bo_unmap");
    BIND(p_bo_get_stride, "gbm_bo_get_stride");
    BIND(p_bo_get_fd, "gbm_bo_get_fd");
    BIND(p_bo_get_plane_count, "gbm_bo_get_plane_count");
    BIND(p_bo_get_modifier, "gbm_bo_get_modifier");
    BIND(p_bo_destroy, "gbm_bo_destroy");

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }
    struct gbm_device *dev = p_create_device(fd);
    if (!dev) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }

    /* Allocate exactly what the shipped allocator allocates for the camera. */
    struct gbm_bo *src = p_bo_create(dev, 4096, 338, FMT_R8,
                                     USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
    if (!src) { fprintf(stderr, "source 4096x338 R8 create failed\n"); return 1; }

    int buf_fd = p_bo_get_fd(src);
    uint64_t mod = p_bo_get_modifier(src);
    uint32_t alloc_stride = p_bo_get_stride(src);
    printf("source buffer: 4096x338 R8  stride=%u modifier=0x%llx fd=%d\n\n",
           alloc_stride, (unsigned long long)mod, buf_fd);

    struct gbm_import_fd_modifier_data d;

    /* A -- what the shipped code actually asks for. */
    memset(&d, 0, sizeof d);
    d.width = TOTAL_SIZE_A4K; d.height = 1; d.format = FMT_R8; d.num_fds = 1;
    d.fds[0] = buf_fd; d.strides[0] = (int)YV12_STRIDES[0]; d.modifier = mod;
    try_import(dev, "A", "A  SHIPPED: w=total_size h=1 R8, stride = YV12 luma stride 1280", &d);

    /* A' -- same, in case total_size is not 4096-aligned on the import side. */
    memset(&d, 0, sizeof d);
    d.width = TOTAL_SIZE; d.height = 1; d.format = FMT_R8; d.num_fds = 1;
    d.fds[0] = buf_fd; d.strides[0] = (int)YV12_STRIDES[0]; d.modifier = mod;
    try_import(dev, "A2", "A' SHIPPED variant: unaligned total_size, stride 1280", &d);

    /* B -- 1D, but with a stride that actually covers the width. */
    memset(&d, 0, sizeof d);
    d.width = TOTAL_SIZE_A4K; d.height = 1; d.format = FMT_R8; d.num_fds = 1;
    d.fds[0] = buf_fd; d.strides[0] = (int)TOTAL_SIZE_A4K; d.modifier = mod;
    try_import(dev, "B", "B  1D self-consistent: stride = width", &d);

    /* C -- the geometry the buffer was really allocated with. */
    memset(&d, 0, sizeof d);
    d.width = 4096; d.height = 338; d.format = FMT_R8; d.num_fds = 1;
    d.fds[0] = buf_fd; d.strides[0] = (int)alloc_stride; d.modifier = mod;
    g_extra_w = TOTAL_SIZE_A4K; g_extra_h = 1;
    try_import(dev, "C", "C  as allocated: 4096x338 R8, stride 4096", &d);

    /* D -- the real goal: a 3-plane YVU420 view of the same dmabuf. */
    memset(&d, 0, sizeof d);
    d.width = W; d.height = H; d.format = FMT_YV12; d.num_fds = 3;
    for (int i = 0; i < 3; i++) {
        d.fds[i] = buf_fd;                       /* all three planes, one dmabuf */
        d.strides[i] = (int)YV12_STRIDES[i];
        d.offsets[i] = (int)YV12_OFFSETS[i];
    }
    d.modifier = mod;
    g_extra_w = 0;
    try_import(dev, "D", "D  YVU420 3-plane from the single dmabuf (num_fds=3)", &d);

    /* D' -- same, declared as one fd. Some stacks expect num_fds=1 + 3 offsets. */
    memset(&d, 0, sizeof d);
    d.width = W; d.height = H; d.format = FMT_YV12; d.num_fds = 1;
    for (int i = 0; i < 3; i++) {
        d.fds[i] = buf_fd;
        d.strides[i] = (int)YV12_STRIDES[i];
        d.offsets[i] = (int)YV12_OFFSETS[i];
    }
    d.modifier = mod;
    try_import(dev, "D2", "D' YVU420 3-plane, num_fds=1", &d);

    close(buf_fd);
    p_bo_destroy(src);
    p_device_destroy(dev);
    close(fd);
    return 0;
}
