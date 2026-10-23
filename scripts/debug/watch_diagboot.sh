#!/bin/bash
# Host watcher: wait for guest, keep a filtered RS diagnostic log, capture the
# first menu open after boot, then dump RS state.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
OUT=$BASE/verify_rsbugs2/${OUTDIR:-diagboot}
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
mkdir -p "$OUT"; : > "$OUT/dbglog.txt"; : > "$OUT/run.log"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }
cap(){ $HDC shell "snapshot_display -i 0 -f /data/local/tmp/$1.jpeg" >/dev/null 2>&1; \
       $HDC file recv /data/local/tmp/$1.jpeg "$OUT/$1.jpeg" >/dev/null 2>&1; }

say "waiting hdc"
for i in $(seq 1 120); do
  $HDC tconn 127.0.0.1:5555 >/dev/null 2>&1
  r=$($HDC shell "pidof render_service" 2>/dev/null | tr -d '\r')
  case "$r" in ''|*Fail*|*onnect*) sleep 3;; *) say "RS=$r (iter $i)"; break;; esac
done

# Optional live param overrides (space-separated "key=value").
for kv in ${PARAMS:-}; do
  key=${kv%%=*}; val=${kv#*=}
  say "param set $key $val"
  $HDC shell "param set $key $val" 2>&1 | tr -d '\r' | tee -a "$OUT/run.log"
done

# Continuous filtered diagnostic dump (dedup later).
( while true; do
    $HDC shell "hilog -x" 2>/dev/null | tr -d '\r' | grep -E 'RSFILTDBG|RSBUFDBG' >> "$OUT/dbglog.txt"
    sleep 2
  done ) &
LOOP=$!
say "diag loop pid $LOOP"

# Capture the earliest state.
cap t0
say "t0 captured"
# wait for desktop/unlock by pc_session; poll for a menu-less desktop
for i in $(seq 1 40); do
  cap poll_$i
  sleep 3
done
say "polling done"

kill $LOOP 2>/dev/null
$HDC shell "hilog -x" 2>/dev/null | tr -d '\r' > "$OUT/hilog_full.txt"
$HDC shell "hidumper -s RenderService -a allInfo" 2>/dev/null | tr -d '\r' > "$OUT/rs_allinfo.txt"
say "done"
