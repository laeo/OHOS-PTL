#!/bin/bash
# blur_ab2.sh <tag> [key=val ...]
# Sets params, restarts RS, then captures BOTH the context menu and the same
# region with the menu closed (wallpaper), from the same RS session.
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
HDC=~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
tag="$1"; shift
for kv in "$@"; do
  "$HDC" shell "param set ${kv%%=*} ${kv#*=}" >/dev/null 2>&1
done
pid=$("$HDC" shell pidof render_service | tr -d '\r')
"$HDC" shell "kill -9 $pid" >/dev/null 2>&1
sleep 22
newpid=$("$HDC" shell pidof render_service | tr -d '\r')
sleep 1
# menu open
"$HDC" shell "/data/local/tmp/inj.sh 40 600 left" >/dev/null 2>&1; sleep 1
"$HDC" shell "/data/local/tmp/inj.sh 640 400 right" >/dev/null 2>&1; sleep 1
"$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/_m.jpeg" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/_m.jpeg "$BASE/verify_blur/${tag}_menu.jpeg" >/dev/null 2>&1
# menu closed (move pointer away, click to dismiss)
"$HDC" shell "/data/local/tmp/inj.sh 40 600 left" >/dev/null 2>&1; sleep 1.2
"$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/_w.jpeg" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/_w.jpeg "$BASE/verify_blur/${tag}_wall.jpeg" >/dev/null 2>&1
echo "RS $pid -> $newpid ; saved ${tag}_menu/_wall"
