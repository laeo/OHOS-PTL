#!/bin/bash
set -x
cd /home/katax/Public/OHOS
export RUBYOPT="-r/home/katax/Public/OHOS/build/compat/erb_compat.rb"
export JAVA_HOME=/home/katax/.gradle/jdks/jetbrains_s_r_o_-17-amd64-linux.2
export PATH="$JAVA_HOME/bin:$PATH"
./build.sh --product-name x86_64_virt --ccache --jobs 16 --keep-ninja-going \
  --device-type 2in1 --deps-guard=false \
  --gn-args linux_kernel_version='"linux-6.18"' \
  --build-target libbms
