#!/usr/bin/env python3
# wake via QMP, optionally Ctrl-C, send cmd, drain for N secs, print.
import socket, json, time, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
cmd  = sys.argv[1] if len(sys.argv) > 1 else ""
wait = float(sys.argv[2]) if len(sys.argv) > 2 else 8.0
usectrl = (sys.argv[3] == "ctrl") if len(sys.argv) > 3 else False
presend = float(sys.argv[4]) if len(sys.argv) > 4 else 2.0

# wake
try:
    q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(3)
    q.send(json.dumps({"execute":"qmp_capabilities"}).encode()+b"\n"); time.sleep(0.2)
    try: q.recv(65536)
    except Exception: pass
    q.send(json.dumps({"execute":"system_wakeup"}).encode()+b"\n"); time.sleep(0.2)
    try: q.recv(65536)
    except Exception: pass
    q.send(json.dumps({"execute":"query-status"}).encode()+b"\n"); time.sleep(0.2)
    try: sys.stderr.write("STATUS:"+q.recv(65536).decode(errors="replace")+"\n")
    except Exception: pass
    q.close()
except Exception as e:
    sys.stderr.write(f"qmp err {e}\n")

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(f"{BASE}/run/ser.sock")
# drain pre
t0=time.time()
while time.time()-t0<presend:
    try: s.recv(65536)
    except socket.timeout: pass
if usectrl:
    s.sendall(b"\x03")
    time.sleep(1.0)
if cmd:
    s.sendall((cmd+"\n").encode())
buf=b""; t0=time.time()
while time.time()-t0<wait:
    try:
        d=s.recv(65536)
        if d: buf+=d
    except socket.timeout: continue
sys.stdout.buffer.write(buf)
s.close()
