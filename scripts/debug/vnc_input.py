#!/usr/bin/env python3
"""Minimal VNC (RFB 3.8) client to drive the OpenHarmony guest pointer.

Only what we need: handshake, set pixel format (ignored), then send
PointerEvent / KeyEvent messages. Pointer coordinates are absolute and get
translated by QEMU into the guest's input device.
"""
import socket
import struct
import sys
import time


class Vnc:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        self.f = self.s.makefile("rb")

    def _read(self, n):
        b = b""
        while len(b) < n:
            chunk = self.f.read(n - len(b))
            if not chunk:
                raise EOFError("vnc closed")
            b += chunk
        return b

    def handshake(self):
        ver = self._read(12)
        if not ver.startswith(b"RFB "):
            raise RuntimeError(f"bad version {ver!r}")
        self.s.sendall(b"RFB 003.008\n")
        n = self._read(1)[0]
        self._read(n)                      # security types
        self.s.sendall(b"\x01")            # choose None (1)
        res = struct.unpack(">I", self._read(4))[0]
        if res != 0:
            raise RuntimeError(f"security failed {res}")
        self.s.sendall(b"\x01")            # ClientInit shared=1
        self._read(24)                     # ServerInit
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

    def pointer(self, x, y, mask=0):
        x &= 0xFFFF
        y &= 0xFFFF
        self.s.sendall(struct.pack(">BBHH", 5, mask, x, y))

    def key(self, keysym, down):
        self.s.sendall(struct.pack(">BBxxI", 4, 1 if down else 0, keysym))

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def swipe(v, x0, y0, x1, y1, steps=30, hold=0.02):
    """Press, drag through intermediate points, release."""
    v.pointer(x0, y0)
    time.sleep(0.1)
    v.pointer(x0, y0, 1)                   # button1 down
    time.sleep(0.05)
    for i in range(1, steps + 1):
        x = x0 + (x1 - x0) * i // steps
        y = y0 + (y1 - y0) * i // steps
        v.pointer(x, y, 1)
        time.sleep(hold)
    time.sleep(0.05)
    v.pointer(x1, y1, 0)                   # release


if __name__ == "__main__":
    host, port = "127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 5928
    v = Vnc(host, port)
    v.handshake()
    time.sleep(0.3)
    # Swipe up from lower middle to upper middle (unlock gesture).
    swipe(v, 640, 700, 640, 250, steps=40, hold=0.02)
    time.sleep(1.5)
    v.close()
    print("swipe sent")
