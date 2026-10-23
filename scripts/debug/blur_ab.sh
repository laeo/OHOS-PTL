#!/bin/bash
# blur_ab.sh <outname> [key=val ...]
# Sets params, restarts render_service, waits, opens the desktop context menu,
# captures a snapshot to verify_blur/<outname>.jpeg.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
HDC=~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
out="$1"; shift
for kv in "$@"; do
  k="${kv%%=*}"; v="${kv#*=}"
  "$HDC" shell "param set $k $v" >/dev/null 2>&1
done
echo "params:"; for kv in "$@"; do echo "  $kv"; done
pid=$("$HDC" shell pidof render_service | tr -d '\r')
"$HDC" shell "kill -9 $pid" >/dev/null 2>&1
sleep 22
newpid=$("$HDC" shell pidof render_service | tr -d '\r')
echo "RS $pid -> $newpid"
# settle frames
"$HDC" shell "/data/local/tmp/inj.sh 40 600 left" >/dev/null 2>&1
sleep 1
"$HDC" shell "/data/local/tmp/inj.sh 640 400 right" >/dev/null 2>&1
sleep 1
"$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/_ab.jpeg" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/_ab.jpeg "$BASE/verify_blur/$out.jpeg" >/dev/null 2>&1
echo "saved $out.jpeg"
