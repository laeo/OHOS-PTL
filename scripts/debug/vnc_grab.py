#!/usr/bin/env python3
"""Grab the QEMU VNC framebuffer (what the user actually sees on screen).

Usage: vnc_grab.py <out.png> [port]
Uses RFB 3.8, requests a full framebuffer update with raw encoding,
handles QEMU cursor/desktop pseudo-encodings by ignoring them.
"""
import socket
import struct
import sys
from PIL import Image

HOST = "127.0.0.1"


class Vnc:
    def __init__(self, port, timeout=25):
        self.s = socket.create_connection((HOST, port), timeout=timeout)
        self.s.settimeout(timeout)
        self.buf = b""

    def rd(self, n):
        while len(self.buf) < n:
            c = self.s.recv(65536)
            if not c:
                raise EOFError("vnc closed")
            self.buf += c
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def handshake(self):
        self.rd(12)
        self.s.sendall(b"RFB 003.008\n")
        n = self.rd(1)[0]
        types = self.rd(n)
        choice = 1 if 1 in types else types[0]
        self.s.sendall(bytes([choice]))
        res = struct.unpack(">I", self.rd(4))[0]
        if res != 0:
            raise RuntimeError("security failed")
        self.s.sendall(b"\x01")
        si = self.rd(24)
        self.w, self.h = struct.unpack(">HH", si[:4])
        nl = struct.unpack(">I", si[20:24])[0]
        self.name = self.rd(nl)
        self.s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("server:", self.name, self.w, self.h)

    def set_format(self):
        pf = struct.pack(">BBBBHHHBBBB", 32, 24, 0, 1, 255, 255, 255, 16, 8, 0, 0)
        self.s.sendall(b"\x00\x00\x00\x00" + pf)

    def set_encodings(self, encs=(0,)):
        payload = struct.pack(">BBH", 2, 0, len(encs))
        for e in encs:
            payload += struct.pack(">i", e)
        self.s.sendall(payload)

    def update(self):
        self.s.sendall(struct.pack(">BBHHHH", 3, 0, 0, 0, self.w, self.h))
        while True:
            mt = self.rd(1)[0]
            if mt == 0:
                break
            if mt == 2:
                continue
            if mt == 3:
                self.rd(3)
                ln = struct.unpack(">I", self.rd(4))[0]
                self.rd(ln)
                continue
            raise RuntimeError(f"unexpected msg {mt}")
        self.rd(1)
        nrect = struct.unpack(">H", self.rd(2))[0]
        print("rects:", nrect)
        img = Image.new("RGB", (self.w, self.h))
        for _ in range(nrect):
            x, y, w, h = struct.unpack(">HHHH", self.rd(8))
            enc = struct.unpack(">i", self.rd(4))[0]
            if enc == 0:
                data = self.rd(w * h * 4)
                tile = Image.frombytes("RGBA", (w, h), data, "raw", "BGRA")
                img.paste(tile.convert("RGB"), (x, y))
            elif enc == -239 or enc == -240:  # cursor pseudo-encoding
                # read length depending on version
                if enc == -239:
                    # pending length from server; skip via subsequent update? just bail
                    print("cursor pseudo-encoding -239 at", x, y, w, h)
                    break
                else:
                    print("cursor pseudo-encoding -240")
                    break
            else:
                raise RuntimeError(f"encoding {enc} not raw")
        return img

    def close(self):
        self.s.close()


def main():
    out = sys.argv[1]
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 5924
    v = Vnc(port)
    v.handshake()
    v.set_format()
    v.set_encodings((0,))
    img = v.update()
    img.save(out)
    print(f"saved {out} ({img.size[0]}x{img.size[1]}, colors={len(img.getcolors(1 << 20) or [])})")
    v.close()


if __name__ == "__main__":
    main()
