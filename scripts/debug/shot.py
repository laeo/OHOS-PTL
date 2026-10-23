#!/usr/bin/env python3
# QMP screendump + simple color analysis. Usage: shot.py <out.ppm>
import socket, json, sys, time, struct, collections
BASE="/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg"
out=sys.argv[1] if len(sys.argv)>1 else f"{BASE}/run/shot.ppm"
s=socket.socket(socket.AF_UNIX); s.connect(f"{BASE}/run/qmp_pc.sock"); s.settimeout(10)
def rd():
    time.sleep(0.2)
    try: return s.recv(1<<20)
    except Exception: return b""
rd()
s.sendall(json.dumps({"execute":"qmp_capabilities"}).encode()+b"\n"); rd()
s.sendall(json.dumps({"execute":"screendump","arguments":{"filename":out}}).encode()+b"\n")
r=rd().decode(errors="replace")
if "error" in r:
    print("SCREENDUMP ERR", r.strip()); sys.exit(1)
try:
    d=open(out,"rb").read()
    parts=d.split(b"\n",3); w,h=map(int,parts[1].split()); data=parts[3]
    cnt=collections.Counter()
    for i in range(0,len(data),3):
        cnt[(data[i],data[i+1],data[i+2])]+=1
    n=w*h
    blk=sum(v for k,v in cnt.items() if k[0]<16 and k[1]<16 and k[2]<16)
    mx=[max(data[i::3]) for i in range(3)]
    mn=[min(data[i::3]) for i in range(3)]
    print(f"SHOT {out}: {w}x{h} colors={len(cnt)} black%={100*blk/n:.1f} min={tuple(mn)} max={tuple(mx)} top3={cnt.most_common(3)}")
except Exception as e:
    print("SCREENDUMP OK (unparsed)", r.strip(), e)
