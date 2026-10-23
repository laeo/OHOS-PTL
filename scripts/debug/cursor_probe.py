#!/usr/bin/env python3
"""Move cursor via QMP rel events, snapshot, and report what is drawn at the
reported pointer window Bounds."""
import json
import os
import socket
import subprocess
import sys
import time
from PIL import Image

BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
HDC = os.path.expanduser("~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc")
QMP = f"{BASE}/run/qmp_pc.sock"
OUT = f"{BASE}/verify_cursor"


def qmp(cmds):
    q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    q.settimeout(8)
    q.connect(QMP)
    q.send(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
    time.sleep(0.1)
    q.recv(1 << 20)
    for c in cmds:
        q.send(json.dumps(c).encode() + b"\n")
        time.sleep(0.1)
        q.recv(1 << 20)
    q.close()


def rel(dx, dy):
    qmp([{"execute": "input-send-event", "arguments": {"events": [
        {"type": "rel", "data": {"axis": "x", "value": dx}},
        {"type": "rel", "data": {"axis": "y", "value": dy}}]}}])


def bounds():
    out = subprocess.check_output([HDC, "shell", "hidumper -s RenderService -a allInfo"],
                                  stderr=subprocess.DEVNULL).decode(errors="replace")
    for line in out.splitlines():
        if "Name [pointer window]" in line and "Bounds[" in line:
            i = line.index("Bounds[")
            j = line.index("]", i)
            vals = [int(float(v)) for v in line[i + 7:j].split()]
            return vals
    return None


def snapshot(name):
    subprocess.run([HDC, "shell", "snapshot_display -i 0 -f /data/local/tmp/p.jpeg"],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    p = f"{OUT}/{name}.jpeg"
    subprocess.run([HDC, "file", "recv", "/data/local/tmp/p.jpeg", p],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return p


def main():
    # Move to a plain background area near (640, 300)
    for _ in range(40):
        b = bounds()
        if b is None:
            print("no bounds"); break
        cx, cy = b[0] + 32, b[1] + 32
        dx, dy = 640 - cx, 300 - cy
        if abs(dx) < 40 and abs(dy) < 40:
            break
        rel(max(-60, min(60, dx)), max(-60, min(60, dy)))
        time.sleep(0.15)
    b = bounds()
    print("bounds:", b)
    p = snapshot("probe")
    im = Image.open(p).convert("RGB")
    x, y = b[0], b[1]
    crop = im.crop((max(0, x), max(0, y), min(im.width, x + 64), min(im.height, y + 64)))
    crop.resize((crop.width * 6, crop.height * 6), Image.NEAREST).save(f"{OUT}/probe_zoom.png")
    outside = im.crop((max(0, x - 90), max(0, y - 90), min(im.width, x - 20), min(im.height, y - 20)))
    print("cursor-region colors:", len(crop.getcolors(1 << 20) or []))
    print("outside-region colors:", len(outside.getcolors(1 << 20) or []))
    print("saved", f"{OUT}/probe_zoom.png")


if __name__ == "__main__":
    main()
