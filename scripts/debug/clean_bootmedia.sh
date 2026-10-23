#!/bin/bash
# 只保留最新的 N 个 bootmedia* 目录（默认 1），其余删除。用法: clean_bootmedia.sh [N]
BASE=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg
KEEP=${1:-1}
cd "$BASE" || exit 1
dirs=$(ls -dt bootmedia* 2>/dev/null)
n=0
for d in $dirs; do
  n=$((n+1))
  if [ "$n" -le "$KEEP" ]; then
    echo "keep   $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
  else
    echo "delete $d ($(du -sh "$d" 2>/dev/null | cut -f1))"
    rm -rf "$d"
  fi
done
# 顺带清理各 bootmedia 目录之外的重复 ISO（若存在）
find "$BASE" -maxdepth 2 -name 'ohos-pc-*.iso' -not -path "*/$(ls -dt bootmedia* 2>/dev/null | head -1)/*" -delete 2>/dev/null
df -h /home | tail -1
