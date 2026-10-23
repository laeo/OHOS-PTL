#!/usr/bin/env python3
# QMP screendump + PIL extrema/unique-colour report. Opens a fresh QMP conn.
import socket, json, sys
from PIL import Image
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
fn = sys.argv[1]
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.settimeout(15)
q.connect(f"{BASE}/run/qmp.sock")
fbuf = b""
def rdline():
    global fbuf
    while b"\n" not in fbuf:
        d = q.recv(65536)
        if not d:
            break
        fbuf += d
    line, fbuf = fbuf.split(b"\n", 1)
    return line
def exec_cmd(o):
    q.send(json.dumps(o).encode() + b"\n")
    while True:
        line = rdline()
        if not line:
            return {"error": "eof"}
        msg = json.loads(line)
        if "return" in msg or "error" in msg:
            return msg
rdline()  # greeting
exec_cmd({"execute": "qmp_capabilities"})
r = exec_cmd({"execute": "screendump", "arguments": {"filename": fn}})
print("screendump:", r)
try:
    im = Image.open(fn).convert("RGB")
    print("size:", im.size)
    print("extrema:", im.getextrema())
    pal = im.getcolors(maxcolors=1000000) or []
    print("unique:", len(pal), "top:", sorted(pal, reverse=True)[:5])
except Exception as e:
    print("PIL error:", e)
q.close()
