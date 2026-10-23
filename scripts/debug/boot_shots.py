#!/usr/bin/env python3
import socket, json, time, sys, os
from PIL import Image

BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
os.chdir(BASE)

# serial reader
ser = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
ser.connect("run/ser.sock")
ser.settimeout(0.5)
data = bytearray()
stop = False

import threading
def rd():
    while not stop:
        try:
            c = ser.recv(65536)
            if not c:
                break
            data.extend(c)
        except socket.timeout:
            pass
        except Exception:
            break
threading.Thread(target=rd, daemon=True).start()

q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.connect("run/qmp.sock")
q.settimeout(3)
def cmd(o):
    q.send(json.dumps(o).encode() + b"\n")
    time.sleep(0.2)
    try:
        return q.recv(65536).decode(errors="replace")
    except Exception:
        return "?"

cmd({"execute": "qmp_capabilities"})
t0 = time.time()
shots = [8, 10, 12, 15, 18, 22, 30, 45]
for s in shots:
    while time.time() - t0 < s:
        time.sleep(0.2)
    fn = f"{BASE}/shot_s{s}.ppm"
    cmd({"execute": "screendump", "arguments": {"filename": fn}})
    try:
        im = Image.open(fn).convert("RGB")
        ex = im.getextrema()
        n = len(im.getcolors(maxcolors=1000000) or [])
        print(f"t={s}s extrema={ex} distinct_colors={n}")
    except Exception as e:
        print(f"t={s}s ERR {e}")

stop = True
time.sleep(0.3)
open(f"{BASE}/ser_bootshots.txt", "wb").write(data)
print("serial bytes", len(data))
EOF_MARK = None
