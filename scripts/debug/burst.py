#!/usr/bin/env python3
import socket, json, time, os, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

q = None
for _ in range(40):
    try:
        q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(2); break
    except Exception:
        q = None; time.sleep(0.5)

def qc(o):
    if not q: return ""
    try:
        q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.05)
        return q.recv(65536).decode(errors="replace")
    except Exception: return ""
qc({"execute":"qmp_capabilities"})

from PIL import Image
t0 = time.time()
i = 0
results = []
while time.time()-t0 < 30:
    fn = f"{BASE}/burst_{i:03d}.ppm"
    qc({"execute":"screendump","arguments":{"filename":fn}})
    try:
        im = Image.open(fn).convert("RGB")
        ex = im.getextrema()
        pal = im.getcolors(maxcolors=1000000) or []
        n = len(pal)
        top = sorted(pal, reverse=True)[:4] if pal else []
        results.append((i, round(time.time()-t0,2), ex, n, top))
    except Exception as e:
        results.append((i, round(time.time()-t0,2), str(e), 0, []))
    i += 1
    time.sleep(0.25)

for r in results:
    print(r, flush=True)
