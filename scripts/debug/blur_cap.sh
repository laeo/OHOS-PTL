#!/bin/bash
# blur_cap.sh <tag> <hps> <kawase> [extra key=val ...]
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
HDC=~/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
tag="$1"; hps="$2"; kawase="$3"; shift 3
"$HDC" shell "param set persist.sys.graphic.HpsBlurEnable $hps" >/dev/null 2>&1
"$HDC" shell "param set persist.sys.graphic.kawaseEnable $kawase" >/dev/null 2>&1
for kv in "$@"; do "$HDC" shell "param set ${kv%%=*} ${kv#*=}" >/dev/null 2>&1; done
sleep 0.6
"$HDC" shell "/data/local/tmp/inj.sh 40 600 left" >/dev/null 2>&1; sleep 1
"$HDC" shell "/data/local/tmp/inj.sh 640 400 right" >/dev/null 2>&1; sleep 1.3
"$HDC" shell "snapshot_display -i 0 -f /data/local/tmp/c.jpeg" >/dev/null 2>&1
"$HDC" file recv /data/local/tmp/c.jpeg "$BASE/verify_blur/${tag}.jpeg" >/dev/null 2>&1
echo "captured $tag hps=$hps kawase=$kawase"
