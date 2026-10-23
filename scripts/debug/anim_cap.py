import sys, os, time
import gi
gi.require_version('Gdk','3.0')
from gi.repository import Gdk
out=sys.argv[1]; n=int(sys.argv[2]); dt=float(sys.argv[3])
os.makedirs(out,exist_ok=True)
d=Gdk.Display.get_default(); scr=d.get_default_screen()
def find():
    best=None;ba=0
    for w in (scr.get_window_stack() or []):
        try: a=w.get_width()*w.get_height()
        except: continue
        if a>ba: ba=a;best=w
    return best
t0=time.time()
for i in range(n):
    w=find()
    if w:
        pb=Gdk.pixbuf_get_from_window(w,0,0,w.get_width(),w.get_height())
        if pb: pb.savev(f"{out}/f{i:03d}.png","png",[],[])
    time.sleep(dt)
print("captured",n,"in",round(time.time()-t0,2),"s")
