#!/usr/bin/env python3
# Fast-ish capture of the QEMU GTK window: saves only changed frames as JPEG.
# Usage: GDK_BACKEND=x11 anim_cap2.py <outdir> <seconds> [interval]
import sys, os, time, hashlib, io
import gi
gi.require_version('Gdk', '3.0')
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import Gdk, GdkPixbuf
from PIL import Image

out = sys.argv[1]; dur = float(sys.argv[2]); dt = float(sys.argv[3]) if len(sys.argv) > 3 else 0.05
os.makedirs(out, exist_ok=True)
d = Gdk.Display.get_default(); scr = d.get_default_screen()

def find():
    best = None; ba = 0
    for w in (scr.get_window_stack() or []):
        try: a = w.get_width() * w.get_height()
        except Exception: continue
        if a > ba: ba = a; best = w
    return best

w = find()
if w is None:
    print("NO_WINDOW"); sys.exit(1)
W, H = w.get_width(), w.get_height()
t0 = time.time()
last = None
idx = 0
saved = 0
while time.time() - t0 < dur:
    pb = Gdk.pixbuf_get_from_window(w, 0, 0, W, H)
    if pb is None:
        time.sleep(dt); continue
    # small downsample for signature
    small = pb.scale_simple(80, 60, GdkPixbuf.InterpType.BILINEAR)
    sig = hashlib.md5(small.get_pixels()).hexdigest()[:12]
    t = time.time() - t0
    if sig != last:
        raw = pb.get_pixels()
        rs = pb.get_rowstride()
        img = Image.frombytes("RGB", (W, H), raw, "raw", "RGB", rs, 1)
        img.save(f"{out}/{idx:03d}_{t:.3f}.jpg", quality=55)
        saved += 1
        print(f"{idx:03d} t={t:.3f} sig={sig} SAVE", flush=True)
        idx += 1
        last = sig
    time.sleep(dt)
print(f"DONE saved={saved} total_loops idx={idx} dur={time.time()-t0:.2f}")
