#!/usr/bin/env python3
# Host-side keep-awake over the QEMU serial console socket.
# Counteracts SceneBoard's power.overrideScreenOffTime(10000) so the desktop
# does not dim/blank after 10s. Also logs the guest power state to a file.
import socket, time, sys, os

BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
sock = f"{BASE}/run/ser.sock"
log = sys.argv[1] if len(sys.argv) > 1 else f"{BASE}/run/keepawake_ser.out"
period = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0

s = None

def connect():
    global s
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.3)
            s.connect(sock)
            return
        except Exception:
            if s:
                try: s.close()
                except Exception: pass
            s = None
            time.sleep(1)

connect()
logf = open(log, "ab", buffering=0)
cmd = ("power-shell timeout -o 86400000 >/dev/null 2>&1; "
       "power-shell dump -a 2>&1 | grep -a 'Current State'\n").encode()
while True:
    try:
        s.sendall(cmd)
        t0 = time.time()
        while time.time() - t0 < 0.4:
            try:
                d = s.recv(65536)
                if d:
                    logf.write(d)
            except socket.timeout:
                break
            except Exception:
                raise
    except Exception:
        try: s.close()
        except Exception: pass
        s = None
        connect()
    time.sleep(period)
