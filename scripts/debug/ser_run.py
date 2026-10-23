import socket, sys, time, base64
# Usage: ser_run.py "<shell command>" [wait_seconds]
sock = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/run/ser.sock"
cmd = sys.argv[1]
wait = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.settimeout(0.5)
# bounded drain
t0 = time.time()
while time.time() - t0 < 2.0:
    try: s.recv(65536)
    except socket.timeout: break
s.sendall((cmd + "\n").encode())
buf = b""
t0 = time.time()
while time.time() - t0 < wait:
    try:
        d = s.recv(65536)
        if d: buf += d
    except socket.timeout:
        continue
sys.stdout.buffer.write(buf)
s.close()
