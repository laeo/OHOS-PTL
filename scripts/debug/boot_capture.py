import socket, time, sys, re

sock = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/run/ser.sock"
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
for _ in range(60):
    try:
        s.connect(sock); break
    except OSError:
        time.sleep(1)
s.settimeout(2)
buf = b""
# Wait for the console shell prompt, then immediately dump hilog.
start = time.time()
sent = False
out = open("/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/boot_hilog.txt", "wb")
last_len = 0
while time.time() - start < 240:
    try:
        d = s.recv(65536)
        if d:
            buf += d
            out.write(d); out.flush()
    except socket.timeout:
        pass
    if not sent and re.search(rb"\n# ", buf):
        s.sendall(b"hilog -x > /data/early.txt 2>&1; echo EARLYDONE\n")
        sent = True
    if sent and b"EARLYDONE" in buf:
        # fetch the file back via base64 in chunks
        time.sleep(1)
        break
out.close()
print("capture phase done, sent=%s" % sent)
s.close()
