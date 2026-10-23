#!/usr/bin/env python3
# Connect to serial socket, optionally send data, drain for N seconds, print all.
import socket, sys, time
BASE="/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
s.settimeout(0.5)
s.connect(f"{BASE}/run/ser.sock")
send = sys.argv[1] if len(sys.argv)>1 else ""
dur  = float(sys.argv[2]) if len(sys.argv)>2 else 10.0
pre  = float(sys.argv[3]) if len(sys.argv)>3 else 0.0
if pre>0:
    t0=time.time()
    while time.time()-t0<pre:
        try: s.recv(65536)
        except socket.timeout: pass
if send:
    s.sendall((send+"\n").encode())
buf=b""; t0=time.time()
while time.time()-t0<dur:
    try:
        d=s.recv(65536)
        if d: buf+=d
    except socket.timeout: continue
sys.stdout.buffer.write(buf)
s.close()
