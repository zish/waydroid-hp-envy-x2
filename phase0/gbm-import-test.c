/*
 * Phase 0c: can an IMPORTED (dmabuf) buffer be mapped?
 *
 * The decisive clue is in the original failure log -- the PIDs differ:
 *
 *   pid 83  [minigbm]: Allocated: 1280x720, stride: 4096, map_stride: 4096
 *   pid 79  GBM-MESA-WRAPPER: Failed to map the buffer at ...:228
 *
 * pid 83 is the gralloc allocator service; pid 79 is the camera provider. So the
 * buffer is allocated in one process, exported as a dmabuf fd, and imported into
 * the camera HAL -- which then maps it. Phase 0b showed a freshly *created* bo maps
 * fine, so the suspect is the *imported* one.
 *
 * This allocates, exports via gbm_bo_get_fd, re-imports with gbm_bo_import, and
 * maps both the original and the import -- in-process and in a forked child.
 *
 * Build: gcc -O1 -Wall -o gbm-import-test gbm-import-test.c -ldl
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define FOURCC(a,b,c,d) ((uint32_t)(a)|((uint32_t)(b)<<8)|((uint32_t)(c)<<16)|((uint32_t)(d)<<24))
enum { USE_LINEAR = 1u << 4, USE_SW_READ_OFTEN = 1u << 9, USE_SW_WRITE_OFTEN = 1u << 11 };
enum { XFER_READ = 1u << 0, XFER_WRITE = 1u << 1 };
#define XFER_RW (XFER_READ | XFER_WRITE)
#define GBM_BO_IMPORT_FD          0x5503
#define GBM_BO_IMPORT_FD_MODIFIER 0x5504

struct gbm_import_fd_data { int fd; uint32_t width, height, stride, format; };
struct gbm_import_fd_modifier_data {
    uint32_t width, height, format, num_fds;
    int fds[4]; int strides[4]; int offsets[4]; uint64_t modifier;
};

struct gbm_device; struct gbm_bo;
static struct gbm_device *(*p_create_device)(int);
static struct gbm_bo *(*p_bo_create)(struct gbm_device *, uint32_t, uint32_t, uint32_t, uint32_t);
static struct gbm_bo *(*p_bo_import)(struct gbm_device *, uint32_t, void *, uint32_t);
static void *(*p_bo_map)(struct gbm_bo *, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t *, void **);
static void (*p_bo_unmap)(struct gbm_bo *, void *);
static uint32_t (*p_bo_get_stride)(struct gbm_bo *);
static int (*p_bo_get_fd)(struct gbm_bo *);
static uint64_t (*p_bo_get_modifier)(struct gbm_bo *);
static void (*p_bo_destroy)(struct gbm_bo *);

#define BIND(v, n) do { *(void **)&v = dlsym(h, n); if (!v) { fprintf(stderr, "missing %s\n", n); return 1; } } while (0)

static int map_report(struct gbm_bo *bo, const char *what, uint32_t w, uint32_t h)
{
    uint32_t stride = 0; void *md = NULL;
    void *ptr = p_bo_map(bo, 0, 0, w, h, XFER_RW, &stride, &md);
    printf("    %-34s : %s", what, ptr ? "OK" : "*** FAILED ***");
    if (ptr) { printf("  map_stride=%u", stride); memset(ptr, 0x10, 16); p_bo_unmap(bo, md); }
    printf("\n");
    return ptr ? 0 : -1;
}

int main(int argc, char **argv)
{
    const char *node = argc > 1 ? argv[1] : "/dev/dri/renderD128";
    void *h = dlopen("libgbm.so.1", RTLD_NOW);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    BIND(p_create_device, "gbm_create_device");
    BIND(p_bo_create, "gbm_bo_create");
    BIND(p_bo_import, "gbm_bo_import");
    BIND(p_bo_map, "gbm_bo_map");
    BIND(p_bo_unmap, "gbm_bo_unmap");
    BIND(p_bo_get_stride, "gbm_bo_get_stride");
    BIND(p_bo_get_fd, "gbm_bo_get_fd");
    BIND(p_bo_get_modifier, "gbm_bo_get_modifier");
    BIND(p_bo_destroy, "gbm_bo_destroy");

    int fd = open(node, O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror(node); return 1; }
    struct gbm_device *dev = p_create_device(fd);
    if (!dev) { fprintf(stderr, "gbm_create_device failed\n"); return 1; }

    const uint32_t R8 = FOURCC('R','8',' ',' ');
    const uint32_t AW = 4096, AH = 338;    /* minigbm's logged fallback geometry */
    const uint32_t LW = 1280, LH = 720;

    struct gbm_bo *bo = p_bo_create(dev, AW, AH, R8, USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
    if (!bo) { printf("create FAILED\n"); return 1; }
    uint32_t stride = p_bo_get_stride(bo);
    uint64_t mod = p_bo_get_modifier(bo);
    int dmabuf = p_bo_get_fd(bo);
    printf("original bo: %ux%u R8 stride=%u modifier=0x%llx dmabuf_fd=%d\n\n",
           AW, AH, stride, (unsigned long long)mod, dmabuf);

    printf("  [original bo]\n");
    map_report(bo, "map logical dims", LW, LH);

    printf("\n  [imported via GBM_BO_IMPORT_FD]\n");
    struct gbm_import_fd_data d = { .fd = dmabuf, .width = AW, .height = AH,
                                    .stride = stride, .format = R8 };
    struct gbm_bo *imp = p_bo_import(dev, GBM_BO_IMPORT_FD, &d,
                                     USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
    if (!imp) printf("    import FAILED\n");
    else { map_report(imp, "map allocated extent", AW, AH);
           map_report(imp, "map logical dims", LW, LH); p_bo_destroy(imp); }

    printf("\n  [imported via GBM_BO_IMPORT_FD_MODIFIER]\n");
    struct gbm_import_fd_modifier_data dm = { .width = AW, .height = AH, .format = R8,
                                              .num_fds = 1, .modifier = mod };
    dm.fds[0] = dmabuf; dm.strides[0] = (int)stride; dm.offsets[0] = 0;
    struct gbm_bo *impm = p_bo_import(dev, GBM_BO_IMPORT_FD_MODIFIER, &dm,
                                      USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
    if (!impm) printf("    import FAILED\n");
    else { map_report(impm, "map allocated extent", AW, AH);
           map_report(impm, "map logical dims", LW, LH); p_bo_destroy(impm); }

    printf("\n  [child process: fresh gbm device, import same dmabuf]\n");
    fflush(stdout);
    pid_t pid = fork();
    if (pid == 0) {
        int cfd = open(node, O_RDWR | O_CLOEXEC);
        struct gbm_device *cdev = p_create_device(cfd);
        if (!cdev) { printf("    child gbm_create_device FAILED\n"); _exit(1); }
        struct gbm_import_fd_data cd = { .fd = dmabuf, .width = AW, .height = AH,
                                         .stride = stride, .format = R8 };
        struct gbm_bo *cbo = p_bo_import(cdev, GBM_BO_IMPORT_FD, &cd,
                                         USE_LINEAR | USE_SW_READ_OFTEN | USE_SW_WRITE_OFTEN);
        if (!cbo) { printf("    child import FAILED\n"); _exit(1); }
        map_report(cbo, "child: map allocated extent", AW, AH);
        map_report(cbo, "child: map logical dims", LW, LH);
        _exit(0);
    }
    waitpid(pid, NULL, 0);

    p_bo_destroy(bo);
    close(fd);
    return 0;
}
