#!/bin/bash
# Host-side: wait until render_service is up, then continuously toggle the
# desktop context menu and snapshot every frame for ~3 min. Captures boot-time
# RS render glitches (partial backdrop blur / missing cursor).
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
OUT=$BASE/verify_rsbugs/bootrun
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
mkdir -p "$OUT"; rm -f "$OUT"/*.jpeg
LOG=$OUT/run.log; : > "$LOG"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "connect hdc"
for i in $(seq 1 80); do
  $HDC tconn 127.0.0.1:5555 >/dev/null 2>&1
  r=$($HDC shell "pidof render_service" 2>/dev/null | tr -d '\r')
  case "$r" in ''|*Fail*|*connect*) sleep 3;; *) say "rs=$r"; break;; esac
done

# wait a little for scene board windows to attach
sleep 8
cap(){ $HDC shell "snapshot_display -i 0 -f /data/local/tmp/$1.jpeg" >/dev/null 2>&1; \
       $HDC file recv /data/local/tmp/$1.jpeg "$OUT/$1.jpeg" >/dev/null 2>&1; }
cap boot_first
say "starting toggle loop"
for i in $(seq 1 100); do
  $HDC shell "sh /data/local/tmp/inj.sh 400 300 right" >/dev/null 2>&1
  sleep 1
  cap st_$i
  $HDC shell "sh /data/local/tmp/inj.sh 1000 200 left" >/dev/null 2>&1
  sleep 0.6
  if [ $((i % 10)) -eq 0 ]; then say "iter $i"; fi
done
say done
