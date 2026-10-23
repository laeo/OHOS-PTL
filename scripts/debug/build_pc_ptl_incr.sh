#!/bin/bash
# Incremental full build of pc_ptl to repack images (backlight HDI + DPI config).
# Runs the same command as the last full build; ninja only rebuilds what changed.
set -e
cd /home/katax/Public/OHOS
export RUBYOPT="-r$PWD/build/compat/erb_compat.rb"
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH="$JAVA_HOME/bin:$PATH"
echo "JAVA: $(java -version 2>&1 | head -1)"
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --device-type 2in1 \
  --gn-args linux_kernel_version='"linux-7.2"' --deps-guard=false
