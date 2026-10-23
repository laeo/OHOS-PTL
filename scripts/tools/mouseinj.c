// Inject relative mouse events into a Linux input device (for OHOS guest).
// Usage: mouseinj <dev> move <dx> <dy>
//        mouseinj <dev> click <left|right>
//        mouseinj <dev> corner
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/input.h>

static int fd;

static void emit(unsigned short type, unsigned short code, int value)
{
    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = type;
    ev.code = code;
    ev.value = value;
    if (write(fd, &ev, sizeof(ev)) != sizeof(ev)) { perror("write"); }
}

static void syn(void) { emit(EV_SYN, SYN_REPORT, 0); }

int main(int argc, char **argv)
{
    if (argc < 3) { fprintf(stderr, "usage: %s <dev> move dx dy | click left|right | corner\n", argv[0]); return 2; }
    fd = open(argv[1], O_WRONLY);
    if (fd < 0) { perror("open"); return 1; }
    if (!strcmp(argv[2], "corner")) {
        // slam to top-left: big negative relative moves (clamped)
        for (int i = 0; i < 40; i++) { emit(EV_REL, REL_X, -2000); emit(EV_REL, REL_Y, -2000); syn(); }
        return 0;
    }
    if (!strcmp(argv[2], "move")) {
        if (argc < 5) return 2;
        int dx = atoi(argv[3]), dy = atoi(argv[4]);
        int steps = abs(dx) > abs(dy) ? abs(dx) : abs(dy);
        if (steps < 1) steps = 1;
        for (int i = 1; i <= steps; i++) {
            int cx = dx * i / steps, cy = dy * i / steps;
            int px = dx * (i - 1) / steps, py = dy * (i - 1) / steps;
            if (cx != px) emit(EV_REL, REL_X, cx - px);
            if (cy != py) emit(EV_REL, REL_Y, cy - py);
            syn();
            usleep(2000);
        }
        return 0;
    }
    if (!strcmp(argv[2], "click")) {
        int btn = (argc > 3 && !strcmp(argv[3], "right")) ? BTN_RIGHT : BTN_LEFT;
        emit(EV_KEY, btn, 1); syn(); usleep(60000);
        emit(EV_KEY, btn, 0); syn(); usleep(60000);
        return 0;
    }
    fprintf(stderr, "unknown cmd\n");
    return 2;
}
