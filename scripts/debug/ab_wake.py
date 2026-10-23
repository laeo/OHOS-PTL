#!/usr/bin/env python3
# QMP keep-awake that OPENS+CLOSES the QMP socket each iteration so it never
# monopolises the single-client QMP unix socket (unlike keepawake.py).
import socket, json, time, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
n = int(sys.argv[1]) if len(sys.argv) > 1 else 600
interval = float(sys.argv[2]) if len(sys.argv) > 2 else 2.0
for _ in range(n):
    try:
        q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        q.settimeout(3)
        q.connect(f"{BASE}/run/qmp.sock")
        q.send(json.dumps({"execute": "qmp_capabilities"}).encode() + b"\n")
        time.sleep(0.05)
        q.recv(65536)
        q.send(json.dumps({"execute": "system_wakeup"}).encode() + b"\n")
        time.sleep(0.05)
        q.recv(65536)
        q.close()
    except Exception as e:
        print("wake err", e, flush=True)
    time.sleep(interval)
