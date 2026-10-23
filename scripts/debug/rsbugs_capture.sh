#!/bin/bash
# Capture boot-time RS render bugs (backdrop blur partial, cursor not drawn).
# Assumes QEMU (3D blob, pc_session auto-unlock) is already starting.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
OUT=$BASE/verify_rsbugs
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
mkdir -p "$OUT"
LOG=$OUT/capture.log
: > "$LOG"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "waiting hdc"
for i in $(seq 1 60); do
  $HDC tconn 127.0.0.1:5555 >/dev/null 2>&1
  if $HDC shell true >/dev/null 2>&1; then break; fi
  sleep 3
done
say "hdc up"

# wait for scene board + desktop
for i in $(seq 1 60); do
  p=$($HDC shell "pidof com.ohos.sceneboard" 2>/dev/null | tr -d '\r')
  rs=$($HDC shell "pidof render_service" 2>/dev/null | tr -d '\r')
  say "sceneboard=$p rs=$rs"
  [ -n "$p" ] && [ -n "$rs" ] && break
  sleep 4
done
sleep 10

cap(){ # cap <name>
  $HDC shell "snapshot_display -i 0 -f /data/local/tmp/$1.jpeg" >/dev/null 2>&1
  $HDC file recv /data/local/tmp/$1.jpeg "$OUT/$1.jpeg" >/dev/null 2>&1
  say "captured $1 ($(stat -c%s "$OUT/$1.jpeg" 2>/dev/null) bytes)"
}

say "== boot-time desktop (cursor should be missing) =="
cap boot_desk
$HDC shell "hidumper -s RenderService -a allInfo > /data/local/tmp/rs_boot.txt 2>&1"; \
  $HDC file recv /data/local/tmp/rs_boot.txt "$OUT/rs_boot.txt" >/dev/null 2>&1
say "rs_boot dumped"

say "== open right-click menu and capture burst =="
$HDC shell "sh /data/local/tmp/inj.sh 640 360 right" >/dev/null 2>&1
for i in 1 2 3 4; do cap boot_menu_$i; sleep 1; done
$HDC shell "hidumper -s RenderService -a allInfo > /data/local/tmp/rs_menu.txt 2>&1"; \
  $HDC file recv /data/local/tmp/rs_menu.txt "$OUT/rs_menu.txt" >/dev/null 2>&1
say "rs_menu dumped"

say "== move cursor and capture (bug2) =="
$HDC shell "sh /data/local/tmp/inj.sh 300 500 left" >/dev/null 2>&1
sleep 1
cap boot_cursor
say done
