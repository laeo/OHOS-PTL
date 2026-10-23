#!/usr/bin/env python3
import socket, json, time, sys, base64
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

# wake guest
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(3)
def qc(o):
    q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.25)
    try: return q.recv(65536).decode(errors="replace")
    except Exception: return "?"
qc({"execute":"qmp_capabilities"}); qc({"execute":"system_wakeup"})

src = open(sys.argv[1], "rb").read()
b64 = base64.b64encode(src).decode()
name = sys.argv[2] if len(sys.argv) > 2 else "s.sh"
wait = float(sys.argv[3]) if len(sys.argv) > 3 else 15.0

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(f"{BASE}/run/ser.sock"); s.settimeout(0.5)
t0=time.time()
while time.time()-t0<1.5:
    try: s.recv(65536)
    except socket.timeout: break
# write file in chunks to avoid line-wrap issues
chunks = [b64[i:i+200] for i in range(0, len(b64), 200)]
s.sendall(b": > /data/"+name.encode()+b".b64\n")
for ch in chunks:
    s.sendall(b"echo -n "+ch.encode()+b" >> /data/"+name.encode()+b".b64\n")
    time.sleep(0.15)
s.sendall(b"base64 -d /data/"+name.encode()+b".b64 > /data/"+name.encode()+b"; echo WROTE\n")
time.sleep(1.5)
s.sendall(b"sh /data/"+name.encode()+b" > /data/"+name.encode()+b".out 2>/dev/null; echo RAN\n")
time.sleep(wait)
s.sendall(b"echo ===BEGIN===; cat /data/"+name.encode()+b".out; echo ===END===\n")
buf=b""
t0=time.time()
while time.time()-t0<wait:
    try:
        d=s.recv(65536)
        if d: buf+=d
    except socket.timeout: continue
t=buf.decode(errors="replace")
if "===BEGIN===" in t:
    seg=t.split("===BEGIN===",1)[1].split("===END===",1)[0]
    sys.stdout.write(seg)
else:
    sys.stdout.write(t[-3000:])
q.close()
