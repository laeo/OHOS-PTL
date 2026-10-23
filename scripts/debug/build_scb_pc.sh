#!/bin/bash
export NODE_HOME=/home/katax/Public/OHOS/prebuilts/build-tools/common/nodejs/node-v18.20.1-linux-x64
export DEVECO_SDK_HOME=/home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/porting/sdk
export OHOS_BASE_SDK_HOME=$DEVECO_SDK_HOME
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH=$JAVA_HOME/bin:$NODE_HOME/bin:/home/katax/.local/deveco/command-line-tools/bin:$PATH
export NODE_OPTIONS="--max-old-space-size=20000"
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/porting/scb_src
echo "=== node=$(node -v) hvigorw=$(which hvigorw) sdk=$(cat local.properties|head -1) ==="
hvigorw assembleHap --mode module -p module=pc_sceneboard --no-daemon -p debuggable=false -p build_mode=release -p hvigor-obfuscation=true
rc=$?
echo "=== BUILD EXIT CODE: $rc ==="
ls -la product/pc/build/default/outputs/default/ 2>/dev/null
