import socket, sys, time
sock = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/run/ser.sock"
cmd = sys.argv[1]
wait = float(sys.argv[2]) if len(sys.argv) > 2 else 3.0
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
s.settimeout(1)
try:
    while True:
        d = s.recv(65536)
        if not d: break
except socket.timeout:
    pass
s.sendall((cmd + "\n").encode())
start = time.time()
buf = b""
while time.time() - start < wait:
    try:
        d = s.recv(65536)
        if not d: break
        buf += d
    except socket.timeout:
        continue
sys.stdout.buffer.write(buf)
s.close()
