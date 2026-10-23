#!/bin/bash
# Incremental build of the display HDI targets + DPI prebuilt_etc for pc_ptl.
# Verifies the backlight / eDP-DP / mode-log changes compile before the full build.
set -e
cd /home/katax/Public/OHOS
export RUBYOPT="-r$PWD/build/compat/erb_compat.rb"
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH="$JAVA_HOME/bin:$PATH"
echo "JAVA: $(java -version 2>&1 | head -1)"
./build.sh --product-name pc_ptl --ccache --jobs 8 --keep-ninja-going \
  --device-type 2in1 \
  --gn-args linux_kernel_version='"linux-7.2"' --deps-guard=false \
  --build-target display_composer_model --build-target display_buffer_model \
  --build-target vendor/pc/pc_ptl/window_config:window_config
