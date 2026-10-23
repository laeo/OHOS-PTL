import socket, time, base64, sys

SOCK = "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/run/ser.sock"

def run(guest_script, wait=15.0):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    s.settimeout(2)
    # drain
    end = time.time() + 2
    while time.time() < end:
        try:
            s.recv(65536)
        except socket.timeout:
            pass
    b = base64.b64encode(guest_script.encode()).decode()
    s.sendall(("echo " + b + "|base64 -d>/data/ser_probe_script.sh;sh /data/ser_probe_script.sh;echo __QDONE__\n").encode())
    out = b""
    end = time.time() + wait
    while time.time() < end:
        try:
            d = s.recv(65536)
            if not d:
                break
            out += d
        except socket.timeout:
            pass
    s.close()
    text = out.decode(errors="replace")
    lines = []
    for ln in text.splitlines():
        if "access_token_id" in ln or "audit:" in ln or "kauditd" in ln:
            continue
        lines.append(ln)
    return "\n".join(lines)

if __name__ == "__main__":
    path = sys.argv[1]
    wait = float(sys.argv[2]) if len(sys.argv) > 2 else 15.0
    with open(path) as f:
        script = f.read()
    print(run(script, wait))
