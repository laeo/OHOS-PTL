#!/usr/bin/env python3
"""Move the guest pointer via VNC (absolute coords -> QEMU -> virtio-mouse rel).

Usage: cursor_move.py [port] [steps]
Moves to a few points in the middle of a 1280x800 screen to trigger MMI
pointer rendering.
"""
import sys
import time

sys.path.insert(0, "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/scripts")
from vnc_input import Vnc  # noqa: E402


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 5924
    v = Vnc("127.0.0.1", port)
    v.handshake()
    time.sleep(0.3)
    # Move through several absolute positions -> QEMU emits relative motion.
    pts = [(200, 200), (640, 400), (900, 300), (640, 400), (700, 450), (640, 400)]
    for (x, y) in pts:
        # approach the point gradually to generate multiple rel events
        for i in range(1, 9):
            v.pointer(x, y)
            time.sleep(0.05)
        time.sleep(0.2)
    v.close()
    print("cursor moved")


if __name__ == "__main__":
    main()
