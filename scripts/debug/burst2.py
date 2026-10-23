import socket,json,time,sys
B="/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
from PIL import Image
def qmp(cmds):
    q=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); q.settimeout(5)
    try:
        q.connect(B+"/run/qmp_pc.sock")
    except Exception as e:
        return None
    q.send(json.dumps({"execute":"qmp_capabilities"}).encode()+b"\n"); time.sleep(0.05)
    try: q.recv(65536)
    except: pass
    for c in cmds:
        q.send(json.dumps(c).encode()+b"\n"); time.sleep(0.05)
        try: q.recv(65536)
        except: pass
    q.close()
t0=time.time()
for i in range(45):
    t=time.time()-t0
    fn=f"{B}/verify_pc2/burst_{i:02d}.ppm"
    qmp([{"execute":"screendump","arguments":{"filename":fn}}])
    try:
        im=Image.open(fn).convert('RGB')
        cols=im.getcolors(maxcolors=2000000)
        print(f"t={t:5.1f}s ncolors={len(cols) if cols else 'many'} extrema={im.getextrema()}",flush=True)
    except Exception as e:
        print(f"t={t:5.1f}s no shot {e}",flush=True)
    time.sleep(1.0)
