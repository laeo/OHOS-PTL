#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

int main(void) {
    int fd = open("/dev/dri/card0", O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open card0"); return 1; }
    drmModeRes *res = drmModeGetResources(fd);
    if (!res) { perror("res"); return 1; }
    printf("connectors=%d crtcs=%d\n", res->count_connectors, res->count_crtcs);
    for (int c = 0; c < res->count_connectors; c++) {
        drmModeConnector *conn = drmModeGetConnector(fd, res->connectors[c]);
        if (!conn) continue;
        printf("connector %u type=%d status=%d modes=%d enc=%u\n",
               conn->connector_id, conn->connector_type, conn->connection,
               conn->count_modes, conn->encoder_id);
        for (int m = 0; m < conn->count_modes; m++) {
            drmModeModeInfo *mi = &conn->modes[m];
            printf("  [%2d] %dx%d@%d type=0x%x flags=0x%x clk=%d\n",
                   m, mi->hdisplay, mi->vdisplay, mi->vrefresh,
                   mi->type, mi->flags, mi->clock);
        }
        drmModeFreeConnector(conn);
    }
    drmModeFreeResources(res);
    close(fd);
    return 0;
}
