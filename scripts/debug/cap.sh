#!/bin/bash
# Host-side: capture a guest snapshot via snapshot_display and pull it back.
# usage: cap.sh <name> <outdir>
HDC=/home/katax/.local/deveco/command-line-tools/sdk/default/openharmony/toolchains/hdc
NAME=${1:-shot}
OUT=${2:-/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/verify_rsbugs2}
mkdir -p "$OUT"
$HDC shell "snapshot_display -i 0 -f /data/local/tmp/$NAME.jpeg" >/dev/null 2>&1
$HDC file recv /data/local/tmp/$NAME.jpeg "$OUT/$NAME.jpeg" >/dev/null 2>&1
echo "$OUT/$NAME.jpeg"
