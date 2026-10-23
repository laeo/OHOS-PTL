#!/usr/bin/env python3
import socket, json, sys, time
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
sock = sys.argv[1]
if not sock.startswith("/"):
    sock = f"{BASE}/run/{sock}"
cmds = json.loads(sys.argv[2])
if not isinstance(cmds, list):
    cmds = [cmds]
q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
q.settimeout(8)
q.connect(sock)
def send(o):
    q.send(json.dumps(o).encode() + b"\n")
    time.sleep(0.15)
    try:
        return q.recv(1 << 20).decode(errors="replace")
    except Exception as e:
        return f"<no reply: {e}>"
print(send({"execute": "qmp_capabilities"}), end="")
for c in cmds:
    print(send(c), end="")
q.close()
