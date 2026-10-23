#!/usr/bin/env python3
import socket, json, time, threading, sys
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

# connect serial ASAP
ser = None
for _ in range(40):
    try:
        ser = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        ser.connect(f"{BASE}/run/ser.sock"); ser.settimeout(0.3)
        break
    except Exception:
        ser = None; time.sleep(0.5)
buf = bytearray()
if ser:
    def rd():
        while True:
            try:
                d = ser.recv(65536)
                if not d: break
                buf.extend(d)
            except socket.timeout:
                pass
            except Exception:
                break
    threading.Thread(target=rd, daemon=True).start()

# qmp
q = None
for _ in range(20):
    try:
        q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(2); break
    except Exception:
        q = None; time.sleep(0.5)

def send(cmd):
    if ser:
        try: ser.sendall((cmd+"\n").encode())
        except Exception: pass

t0=time.time()
# wait until shell should be up (~10s), then dump hilog
while time.time()-t0 < 11:
    time.sleep(0.3)
send("hilog -x > /data/hl.txt 2>/dev/null; echo HL_DONE")
while time.time()-t0 < 16:
    time.sleep(0.3)
send("cat /data/hl.txt")
while time.time()-t0 < 24:
    time.sleep(0.3)
open(f"{BASE}/fastcap_serial.txt","wb").write(buf)
print("bytes", len(buf))
