#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static int dump_crtcs(int fd, const char *out) {
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { fprintf(stderr, "getresources: %s\n", strerror(errno)); return -1; }
    int done = 0;
    for (int i = 0; i < res->count_crtcs; i++) {
        drmModeCrtc *c = drmModeGetCrtc(fd, res->crtcs[i]);
        if (!c) continue;
        if (!c->buffer_id) { drmModeFreeCrtc(c); continue; }
        drmModeFB *fb = drmModeGetFB(fd, c->buffer_id);
        if (!fb) { drmModeFreeCrtc(c); continue; }
        int dfd = -1;
        if (drmPrimeHandleToFD(fd, fb->handle, DRM_CLOEXEC, &dfd) != 0)
            fprintf(stderr, "prime(%u): %s\n", fb->handle, strerror(errno));
        size_t size = (size_t)fb->pitch * fb->height;
        void *p = MAP_FAILED;
        if (dfd >= 0) p = mmap(NULL, size, PROT_READ, MAP_SHARED, dfd, 0);
        if (p != MAP_FAILED && p) {
            char tmp[256]; snprintf(tmp, sizeof tmp, "%s", out);
            FILE *f = fopen(tmp, "wb");
            fprintf(f, "P6\n%d %d\n255\n", fb->width, fb->height);
            unsigned char *b = p;
            for (int y = 0; y < fb->height; y++)
                for (int x = 0; x < fb->width; x++) {
                    unsigned char *px = b + (size_t)y * fb->pitch + x * 4;
                    fputc(px[0], f); fputc(px[1], f); fputc(px[2], f);
                }
            fclose(f);
            printf("DUMP ok crtc=%u %dx%d pitch=%d handle=%u bpp=%d\n",
                   c->crtc_id, fb->width, fb->height, fb->pitch, fb->handle, fb->bpp);
            munmap(p, size); done = 1;
        } else {
            printf("MMAP fail dfd=%d errno=%d\n", dfd, errno);
        }
        if (dfd >= 0) close(dfd);
        drmModeFreeFB(fb); drmModeFreeCrtc(c);
    }
    drmModeFreeResources(res);
    return done ? 0 : -1;
}

int main(int argc, char **argv) {
    const char *out = argc > 1 ? argv[1] : "/data/local/tmp/drm.ppm";
    const char *devs[] = { "/dev/dri/card0", "/dev/dri/renderD128" };
    for (int i = 0; i < 2; i++) {
        int fd = open(devs[i], O_RDWR | O_CLOEXEC);
        if (fd < 0) { fprintf(stderr, "open %s: %s\n", devs[i], strerror(errno)); continue; }
        printf("trying %s\n", devs[i]);
        if (dump_crtcs(fd, out) == 0) { close(fd); return 0; }
        close(fd);
    }
    printf("NO_DUMP\n");
    return 1;
}
