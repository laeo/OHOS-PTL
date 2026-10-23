#!/usr/bin/env python3
# Capture the QEMU GTK window from the host (X11/XWayland).
# Usage: GDK_BACKEND=x11 gtk_shot.py <out.png>
# Requires QEMU started with GDK_BACKEND=x11.
import sys, os, time
import gi
gi.require_version('Gdk', '3.0')
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import Gdk, GdkPixbuf

out = sys.argv[1] if len(sys.argv) > 1 else "/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/verify_dir/gtk_shot.png"
os.makedirs(os.path.dirname(out), exist_ok=True)

d = Gdk.Display.get_default()
if d is None:
    print("NO_DISPLAY")
    sys.exit(1)
scr = d.get_default_screen()
ws = scr.get_window_stack() or []
best = None
best_area = 0
for w in ws:
    try:
        ww, wh = w.get_width(), w.get_height()
    except Exception:
        continue
    # prefer windows whose title mentions QEMU; else largest
    name = ""
    try:
        name = (w.get_title() or "") + " " + (w.get_wm_class()[1] or "")
    except Exception:
        pass
    area = ww * wh
    score = area + (10**9 if 'qemu' in name.lower() else 0)
    if score > best_area:
        best_area = score
        best = w
if best is None:
    print("NO_WINDOW", [ (w.get_width(), w.get_height()) for w in ws ])
    sys.exit(2)
pb = Gdk.pixbuf_get_from_window(best, 0, 0, best.get_width(), best.get_height())
if pb is None:
    print("NO_PIXBUF")
    sys.exit(3)
pb.savev(out, "png", [], [])
print(f"GTK_SHOT {out} {best.get_width()}x{best.get_height()}")
