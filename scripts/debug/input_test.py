#!/usr/bin/env python3
"""VNC input test that keeps the connection open and screenshots via QMP."""
import json
import socket
import struct
import subprocess
import sys
import time

QMP = "/tmp/ohos-qemu-1000/3d6416c7eafe/x86_64_linux_full/07/qmp.sock"
VNC_PORT = 5928


def qmp_shot(name):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(QMP)
    time.sleep(0.2)
    s.recv(65536)
    s.sendall(b'{"execute":"qmp_capabilities"}\r\n')
    time.sleep(0.2)
    s.recv(65536)
    s.sendall((json.dumps({"execute": "screendump",
                           "arguments": {"filename": name}}) + "\r\n").encode())
    time.sleep(0.6)
    try:
        s.recv(4096)
    except OSError:
        pass
    s.close()


class V:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        self.f = self.s.makefile("rb")
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def rd(self, n):
        b = b""
        while len(b) < n:
            c = self.f.read(n - len(b))
            if not c:
                raise EOFError
            b += c
        return b

    def hs(self):
        print("ver", self.rd(12))
        self.s.sendall(b"RFB 003.008\n")
        n = self.rd(1)[0]
        print("sec", self.rd(n))
        self.s.sendall(b"\x01")
        print("auth", self.rd(4))
        self.s.sendall(b"\x01")
        si = self.rd(24)
        w, h = struct.unpack(">HH", si[:4])
        print("screen", w, h)
        return w, h

    def ptr(self, x, y, m=0):
        self.s.sendall(struct.pack(">BBHH", 5, m, x & 0xFFFF, y & 0xFFFF))


def main():
    v = V("127.0.0.1", VNC_PORT)
    w, h = v.hs()
    time.sleep(0.3)

    print("step1: wake click center")
    v.ptr(w // 2, h // 2, 0)
    time.sleep(0.2)
    v.ptr(w // 2, h // 2, 1)
    time.sleep(0.15)
    v.ptr(w // 2, h // 2, 0)
    time.sleep(1.5)
    qmp_shot("/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/t_wake.ppm")

    print("step2: slow swipe up from bottom edge")
    x = w // 2
    v.ptr(x, h - 1, 0)
    time.sleep(0.3)
    v.ptr(x, h - 1, 1)
    time.sleep(0.3)
    for y in range(h - 1, 120, -4):
        v.ptr(x, y, 1)
        time.sleep(0.015)
    v.ptr(x, 120, 0)
    time.sleep(2)
    qmp_shot("/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/t_swipe.ppm")

    v.s.close()
    print("done; screenshots t_wake.ppm t_swipe.ppm")


if __name__ == "__main__":
    main()
