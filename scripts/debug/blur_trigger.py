#!/usr/bin/env python3
"""Move the guest pointer via VNC and optionally right-click.

Usage: blur_trigger.py <x> <y> [button] [port]
  button: 0=move only, 1=left, 2=middle, 4=right (default 4)
"""
import sys
import time

sys.path.insert(0, "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/scripts")
from vnc_input import Vnc  # noqa: E402


def main():
    x = int(sys.argv[1]) if len(sys.argv) > 1 else 640
    y = int(sys.argv[2]) if len(sys.argv) > 2 else 400
    button = int(sys.argv[3]) if len(sys.argv) > 3 else 4
    port = int(sys.argv[4]) if len(sys.argv) > 4 else 5924
    v = Vnc("127.0.0.1", port)
    v.handshake()
    time.sleep(0.3)
    # approach gradually to generate relative motion
    for i in range(1, 13):
        v.pointer(x * i // 12, y * i // 12, 0)
        time.sleep(0.04)
    time.sleep(0.3)
    v.pointer(x, y, 0)
    time.sleep(0.2)
    if button:
        v.pointer(x, y, button)
        time.sleep(0.12)
        v.pointer(x, y, 0)
        time.sleep(0.5)
    v.close()
    print(f"pointer {x},{y} button={button}")


if __name__ == "__main__":
    main()
