#!/usr/bin/env python3
import socket, json, time, sys, os
BASE = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"

def main():
    # QMP
    q = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    q.connect(f"{BASE}/run/qmp.sock"); q.settimeout(3)
    def qc(o):
        q.send(json.dumps(o).encode()+b"\n"); time.sleep(0.15)
        try: return q.recv(200000).decode(errors="replace")
        except Exception: return "?"
    qc({"execute":"qmp_capabilities"})

    # serial
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(f"{BASE}/run/ser.sock"); s.settimeout(0.5)

    def drain(t=1.0):
        t0=time.time()
        while time.time()-t0<t:
            try: s.recv(65536)
            except socket.timeout: break

    def sendcmd(cmd, wait=3.0):
        qc({"execute":"system_wakeup"})
        s.sendall((cmd+"\n").encode())
        buf=b""
        t0=time.time()
        while time.time()-t0<wait:
            try:
                d=s.recv(65536)
                if d: buf+=d
            except socket.timeout: continue
        return buf.decode(errors="replace")

    # wait for boot
    print("waiting 25s for boot...", flush=True)
    time.sleep(25)
    drain()
    out = sendcmd("echo BOOT_READY_$((2+3))", 6)
    print("shell:", "OK" if "BOOT_READY_5" in out else "NO", flush=True)

    # capture hilog to file in guest
    print(sendcmd("hilog -x > /data/hl.txt 2>/dev/null; wc -l /data/hl.txt", 12)[-200:], flush=True)

    # keep awake + fetch
    qc({"execute":"system_wakeup"})
    r = sendcmd("cat /data/hl.txt", 25)
    open(f"{BASE}/hl_guest.txt","w").write(r)
    print("fetched", len(r), "chars -> hl_guest.txt", flush=True)

main()
