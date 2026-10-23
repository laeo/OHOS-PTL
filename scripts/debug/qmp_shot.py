#!/usr/bin/env python3
import socket, json, time, sys, os
from PIL import Image

BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
fn = sys.argv[1]
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.settimeout(10)
q.connect(f"{BASE}/run/qmp.sock")
def cmd(o):
    q.send(json.dumps(o).encode() + b"\n")
    time.sleep(0.15)
    try:
        return q.recv(65536).decode(errors="replace")
    except Exception:
        return "?"
cmd({"execute": "qmp_capabilities"})
cmd({"execute": "screendump", "arguments": {"filename": fn}})
q.close()
im = Image.open(fn).convert("RGB")
ex = im.getextrema()
cols = im.getcolors(maxcolors=2000000) or []
n = len(cols)
cols_sorted = sorted(cols, reverse=True)[:5]
print(f"{os.path.basename(fn)}: size={im.size} extrema={ex} distinct_colors={n} top={cols_sorted}")
