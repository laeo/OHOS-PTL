#!/usr/bin/env python3
# Host-side helper for run_pc.sh.
# Waits for the QEMU serial console shell, then injects the "swipe up" gesture
# on the QEMU Virtio MultiTouch device to pass the SceneBoard lock screen.
# Commands are sent one short line at a time (the serial console wraps/breaks
# long lines). The helper exits afterwards, freeing the serial console.
import socket, time, re, os

BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
sock = f"{BASE}/run/ser.sock"
logpath = f"{BASE}/run/pc_ser.log"
log = open(logpath, "ab", buffering=0)

def connect():
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect(sock)
            return s
        except Exception:
            time.sleep(1)

def pump(s, seconds):
    t0 = time.time()
    while time.time() - t0 < seconds:
        try:
            d = s.recv(262144)
            if not d:
                break
            log.write(d)
        except socket.timeout:
            pass
        except Exception:
            break

s = connect()
ready = False
for _ in range(100):
    try:
        s.sendall(b"echo PZREADY\n")
    except Exception:
        s = connect()
    pump(s, 0.8)
    time.sleep(1.2)
    try:
        tail = open(logpath, "rb").read()[-8192:]
        if tail.count(b"PZREADY") >= 3:
            ready = True
            break
    except Exception:
        pass

if not ready:
    print("pc_session: shell not detected", flush=True)
    s.close(); log.close(); raise SystemExit(1)

print("pc_session: shell ready", flush=True)

# Discover the MultiTouch event node.
s.sendall(b"grep -A5 'Virtio MultiTouch' /proc/bus/input/devices\n")
pump(s, 2.0)
try:
    data = open(logpath, "rb").read()[-16384:].decode(errors="replace")
except Exception:
    data = ""
m = None
for mm in re.finditer(r"Virtio MultiTouch[\s\S]{0,200}?(event\d+)", data):
    m = mm.group(1)
DEV = "/dev/input/" + (m if m else "event1")
print("pc_session: touch device", DEV, flush=True)

def swipe():
    ys = list(range(25400, 8191, -1230))
    cmds = [f"sendevent {DEV} 3 47 0",
            f"sendevent {DEV} 3 57 1",
            f"sendevent {DEV} 3 53 16383",
            f"sendevent {DEV} 3 54 26624",
            f"sendevent {DEV} 1 330 1",
            f"sendevent {DEV} 0 0 0"]
    for y in ys:
        cmds.append(f"sendevent {DEV} 3 54 {y}")
        cmds.append(f"sendevent {DEV} 0 0 0")
    cmds += [f"sendevent {DEV} 3 57 -1",
             f"sendevent {DEV} 1 330 0",
             f"sendevent {DEV} 0 0 0"]
    for c in cmds:
        try:
            s.sendall(c.encode() + b"\n")
        except Exception:
            pass
        pump(s, 0.12)

for i in range(3):
    print(f"pc_session: swipe {i+1}", flush=True)
    swipe()
    time.sleep(4)

s.close()
log.close()
