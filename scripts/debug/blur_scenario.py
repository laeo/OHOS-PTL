#!/usr/bin/env python3
"""Trigger a guest pointer action over VNC and snapshot while held.

Usage: blur_scenario.py <x> <y> <button> <out.png|jpeg> [port]
Snapshots *while the button is held down* so transient menus are captured.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/scripts")
from vnc_input import Vnc  # noqa: E402

HDC = os.path.expanduser("~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc")


def snap(local):
    remote = "/data/local/tmp/_blur.jpeg"
    subprocess.run([HDC, "shell", f"snapshot_display -i 0 -f {remote}"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([HDC, "file", "recv", remote, local],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    x = int(sys.argv[1]); y = int(sys.argv[2]); button = int(sys.argv[3])
    out = sys.argv[4]
    port = int(sys.argv[5]) if len(sys.argv) > 5 else 5924
    v = Vnc("127.0.0.1", port)
    v.handshake()
    time.sleep(0.3)
    for i in range(1, 13):
        v.pointer(x * i // 12, y * i // 12, 0)
        time.sleep(0.03)
    time.sleep(0.3)
    v.pointer(x, y, 0)
    time.sleep(0.2)
    v.pointer(x, y, button)          # press and HOLD
    time.sleep(0.6)
    snap(out)
    v.pointer(x, y, 0)               # release
    time.sleep(0.1)
    v.close()
    print("captured", out)


if __name__ == "__main__":
    main()
