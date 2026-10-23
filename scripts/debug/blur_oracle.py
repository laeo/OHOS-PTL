#!/usr/bin/env python3
# Oracle for bug1 (partial backdrop blur): diff menu-open vs menu-closed snapshot.
# Rows where the panel mask is applied show a large, spatially uniform difference.
import sys, numpy as np
from PIL import Image

def load(p): return np.asarray(Image.open(p).convert('RGB')).astype(np.float32)

def find_menu_box(diff, thr=25.0):
    d = diff.mean(axis=2)
    ys, xs = np.where(d > thr)
    if len(ys) == 0:
        return None
    return xs.min(), xs.max(), ys.min(), ys.max()

def analyze(openp, closedp):
    o, c = load(openp), load(closedp)
    diff = np.abs(o - c)
    box = find_menu_box(diff)
    if box is None:
        print("no menu diff found"); return
    x0, x1, y0, y1 = box
    d = diff.mean(axis=2)[y0:y1+1, x0:x1+1]
    rowdiff = d.mean(axis=1)
    # panel rows: mean diff > half of max
    mx = rowdiff.max()
    panel = rowdiff > mx * 0.5
    # longest run of panel rows starting at top
    run = 0
    for v in panel:
        if v: run += 1
        else: break
    print(f"menu box x[{x0},{x1}] y[{y0},{y1}] h={y1-y0+1}")
    print(f"max rowdiff={mx:.1f}")
    print(f"masked rows from top={run}  -> coverage={run/(y1-y0+1)*100:.0f}%")
    for i in range(0, y1-y0+1, 10):
        print(f"  y={y0+i:4d} rowdiff={rowdiff[i]:6.1f} {'#' if panel[i] else '.'}")
    return run

if __name__ == '__main__':
    analyze(sys.argv[1], sys.argv[2])
