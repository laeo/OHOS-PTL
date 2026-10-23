#!/usr/bin/env python3
# Resize the (largest) QEMU GTK window from the host, hoping QEMU propagates
# the new size to the guest via virtio-gpu. Usage: gtk_resize.py W H
import sys, time
import gi
gi.require_version('Gdk', '3.0')
gi.require_version('Gtk', '3.0')
from gi.repository import Gdk
W = int(sys.argv[1]); H = int(sys.argv[2])
d = Gdk.Display.get_default(); scr = d.get_default_screen()
best = None; ba = 0
for w in (scr.get_window_stack() or []):
    try: a = w.get_width() * w.get_height()
    except Exception: continue
    if a > ba: ba = a; best = w
if best is None:
    print("NO_WINDOW"); sys.exit(1)
print("before", best.get_width(), best.get_height())
best.resize(W, H)
time.sleep(1.0)
print("after", best.get_width(), best.get_height())
