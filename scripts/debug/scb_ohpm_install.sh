#!/bin/bash
export NODE_HOME=/home/katax/Public/OHOS/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64
export DEVECO_SDK_HOME=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/porting/sdk
export PATH=$NODE_HOME/bin:/home/katax/.local/deveco/command-line-tools/bin:$PATH
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/porting/scb_src
dirs=$(grep -oE '\$\{PROJECT_PATH\}[A-Za-z0-9_/.]*' build.sh | sed 's|${PROJECT_PATH}||' | sort -u)
ok=0; fail=0
for d in $dirs; do
  t="${d#/}"
  [ -d "$t" ] || continue
  echo "--- ohpm install $t"
  ( cd "$t" && ohpm install --all ) && ok=$((ok+1)) || { echo "FAILED: $t"; fail=$((fail+1)); }
done
echo "=== ohpm install done: ok=$ok fail=$fail ==="
