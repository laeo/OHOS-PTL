#!/usr/bin/env python3
import socket, json, time, os, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(3)
def c(o):
    q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.15)
    try: return q.recv(400000).decode(errors="replace")
    except Exception: return ""
c({"execute":"qmp_capabilities"})
p = '/machine/peripheral-anon/device[0]/virtio-backend'

t0=time.time()
for i in range(50):
    el=time.time()-t0
    st=c({"execute":"x-query-virtio-status","arguments":{"path":p}})
    q0=c({"execute":"x-query-virtio-queue-status","arguments":{"path":p,"queue":0}})
    q1=c({"execute":"x-query-virtio-queue-status","arguments":{"path":p,"queue":1}})
    def pick(s,k):
        import re
        m=re.search(r'"'+k+r'":\s*([^,}]+)', s)
        return m.group(1) if m else '?'
    broken = 'broken' in st and '"broken": true' in st
    print(f"t={el:5.1f}s broken={broken} ctrl[avail={pick(q0,'last-avail-idx')} used={pick(q0,'used-idx')} inuse={pick(q0,'inuse')}] "
          f"cur[avail={pick(q1,'last-avail-idx')} used={pick(q1,'used-idx')}]", flush=True)
    if i in (5,10,15):
        c({"execute":"screendump","arguments":{"filename":f"{BASE}/gp_{i}.ppm"}})
    time.sleep(1.0)
