#!/usr/bin/env python3
import socket, json, time, os, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
OUT = f"{BASE}/bg_capture.txt"
log = open(OUT, "w")
def p(*a):
    print(*a, file=log, flush=True)

# connect serial as early as possible
ser = None
for _ in range(60):
    try:
        ser = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ser.connect(f"{BASE}/run/ser.sock"); ser.settimeout(0.5)
        break
    except Exception:
        ser = None; time.sleep(1)
if ser is None:
    p("NO SERIAL"); sys.exit(1)
p("serial connected")

q = None
for _ in range(30):
    try:
        q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(2); break
    except Exception:
        q = None; time.sleep(1)

def qc(o):
    if not q: return ""
    try:
        q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.1)
        return q.recv(65536).decode(errors="replace")
    except Exception: return ""
qc({"execute":"qmp_capabilities"})

# continuously read serial and keep awake for 40s
buf = bytearray()
t0 = time.time()
while time.time() - t0 < 40:
    try:
        d = ser.recv(65536)
        if d: buf.extend(d)
    except socket.timeout:
        pass
    if time.time() - t0 > 20 and int(time.time()-t0) % 3 == 0:
        qc({"execute":"system_wakeup"})
p("=== after 40s serial dump ===")
open(f"{BASE}/bg_serial.txt","wb").write(buf)

# now send hilog command
qc({"execute":"system_wakeup"})
ser.sendall(b"hilog -x > /data/hl.txt 2>/dev/null; wc -l /data/hl.txt\n")
time.sleep(8)
buf2 = bytearray()
t1=time.time()
while time.time()-t1 < 8:
    try:
        d=ser.recv(65536)
        if d: buf2.extend(d)
    except socket.timeout: pass
p("=== hilog wc output ===")
p(buf2[-800:].decode(errors="replace"))
open(f"{BASE}/bg_serial2.txt","wb").write(buf2)
log.close()
