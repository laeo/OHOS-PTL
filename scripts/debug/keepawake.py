#!/usr/bin/env python3
import socket, json, time, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
p='/machine/peripheral-anon/device[0]/virtio-backend'
n = int(sys.argv[1]) if len(sys.argv) > 1 else 300
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(2)
def c(o):
    try:
        q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.1)
        return q.recv(65536).decode(errors="replace")
    except Exception: return ""
c({"execute":"qmp_capabilities"})
for i in range(n):
    c({"execute":"system_wakeup"})
    time.sleep(2.5)
