#!/usr/bin/env python3
import socket, json, time, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

def qmp(keep=False):
    q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    q.connect(f"{BASE}/run/qmp.sock")
    q.settimeout(3)
    def c(o):
        q.send(json.dumps(o).encode() + b"\n")
        time.sleep(0.25)
        try:
            return q.recv(65536).decode(errors="replace")
        except Exception:
            return "?"
    c({"execute": "qmp_capabilities"})
    c({"execute": "system_wakeup"})
    if not keep:
        q.close()
    return q, c

cmd = sys.argv[1]
wait = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0

q, qc = qmp()
time.sleep(1.0)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(f"{BASE}/run/ser.sock")
s.settimeout(0.5)
t0 = time.time()
while time.time() - t0 < 1.5:
    try:
        s.recv(65536)
    except socket.timeout:
        break
s.sendall((cmd + "\n").encode())
buf = b""
t0 = time.time()
while time.time() - t0 < wait:
    try:
        d = s.recv(65536)
        if d:
            buf += d
    except socket.timeout:
        continue
sys.stdout.buffer.write(buf)
q.close()
