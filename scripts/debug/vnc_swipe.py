#!/usr/bin/env python3
import json, socket, struct, time

QMP="/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/run/qmp.sock"; PORT=5924
def shot(name):
    s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(QMP); time.sleep(0.2); s.recv(65536)
    s.sendall(b'{"execute":"qmp_capabilities"}\r\n'); time.sleep(0.2); s.recv(65536)
    s.sendall((json.dumps({"execute":"screendump","arguments":{"filename":name}})+"\r\n").encode())
    time.sleep(1.0)
    try: s.recv(4096)
    except OSError: pass
    s.close()
class V:
    def __init__(s,h,p):
        s.s=socket.create_connection((h,p),timeout=10); s.f=s.s.makefile("rb")
        s.s.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
    def rd(s,n):
        b=b""
        while len(b)<n:
            c=s.f.read(n-len(b))
            if not c: raise EOFError
            b+=c
        return b
    def hs(s):
        s.rd(12); s.s.sendall(b"RFB 003.008\n"); n=s.rd(1)[0]; s.rd(n)
        s.s.sendall(b"\x01"); s.rd(4); s.s.sendall(b"\x01")
        si=s.rd(24); return struct.unpack(">HH",si[:4])
    def ptr(s,x,y,m=0):
        s.s.sendall(struct.pack(">BBHH",5,m,x&0xFFFF,y&0xFFFF))
v=V("127.0.0.1",PORT); w,h=v.hs(); print("screen",w,h)
time.sleep(0.5); shot("/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/sw_pre.ppm")
# wake
v.ptr(w//2,h//2,0); time.sleep(0.2); v.ptr(w//2,h//2,1); time.sleep(0.15); v.ptr(w//2,h//2,0); time.sleep(1.5)
# swipe up from bottom
x=w//2
v.ptr(x,h-1,0); time.sleep(0.3); v.ptr(x,h-1,1); time.sleep(0.3)
for y in range(h-1,100,-5):
    v.ptr(x,y,1); time.sleep(0.02)
v.ptr(x,100,0); time.sleep(2.5)
shot("/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/sw_post.ppm")
v.s.close(); print("done")
